import CryptoKit
import Foundation
import Observation
import UserNotifications

@MainActor
@Observable
final class UsageMonitor {
    private struct Snapshot: Codable {
        let keyID: String
        let info: OpenRouterClient.KeyInfo?
        let credits: OpenRouterClient.Credits?
        let date: Date
    }
    private(set) var keyInfo: OpenRouterClient.KeyInfo?
    private(set) var accountCredits: OpenRouterClient.Credits?
    private(set) var updatedAt: Date?
    private(set) var isRefreshing = false
    private(set) var error: String?
    private var lastAttempt: Date?
    private var refreshAgain = false
    private var keyID: String?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        if let data = UserDefaults.standard.data(forKey: "usage.snapshot"),
            let saved = try? JSONDecoder().decode(Snapshot.self, from: data),
            saved.keyID == Self.currentKeyID
        {
            keyID = saved.keyID
            keyInfo = saved.info
            accountCredits = saved.credits
            updatedAt = saved.date
            lastAttempt = saved.date
        }
        observer = NotificationCenter.default.addObserver(
            forName: OpenRouterClient.paymentRequired, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private static var currentKeyID: String? {
        guard let key = KeychainStore.apiKey, !key.isEmpty else { return nil }
        return SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var availableBalance: Double? {
        guard keyID == Self.currentKeyID else { return nil }
        return [accountCredits?.balance, keyInfo?.limitRemaining].compactMap { $0 }.min()
    }

    var warning: String? {
        guard let balance = availableBalance, balance < 2 else { return nil }
        return balance <= 0 ? "OpenRouter 余额已用完，请充值" : String(format: "OpenRouter 余额不足（剩 $%.2f），识别和 AI 功能可能失败", balance)
    }

    func resetForKeyChange() {
        keyID = nil
        keyInfo = nil
        accountCredits = nil
        updatedAt = nil
        lastAttempt = nil
        error = nil
        UserDefaults.standard.removeObject(forKey: "usage.snapshot")
    }

    func refresh(force: Bool = true) async {
        if isRefreshing {
            if force { refreshAgain = true }
            return
        }
        guard let identity = Self.currentKeyID else {
            resetForKeyChange()
            return
        }
        if identity != keyID {
            resetForKeyChange()
            keyID = identity
        }
        guard force || lastAttempt.map({ Date.now.timeIntervalSince($0) >= 6 * 3600 }) ?? true else { return }
        isRefreshing = true
        lastAttempt = .now
        defer {
            isRefreshing = false
            if refreshAgain {
                refreshAgain = false
                Task { await refresh() }
            }
        }
        do {
            let client = try OpenRouterClient.fromKeychain()
            async let info = client.keyInfo()
            async let credits = client.credits()
            let values = try await (info, credits)
            guard identity == Self.currentKeyID else { return }
            keyInfo = values.0
            accountCredits = values.1
            updatedAt = .now
            error = nil
            let snapshot = Snapshot(keyID: identity, info: keyInfo, credits: accountCredits, date: updatedAt!)
            UserDefaults.standard.set(try JSONEncoder().encode(snapshot), forKey: "usage.snapshot")
            await notifyIfNeeded()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func notifyIfNeeded() async {
        guard let warning, let balance = availableBalance else { return }
        let key = "usage.notified." + (keyID ?? "") + (balance <= 0 ? ".empty" : ".low")
        let defaults = UserDefaults.standard
        guard (defaults.object(forKey: key) as? Date).map({ Date.now.timeIntervalSince($0) >= 86400 }) ?? true else {
            return
        }
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        let content = UNMutableNotificationContent()
        content.title = "OpenRouter 余额提醒"
        content.body = warning
        do {
            try await center.add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
            defaults.set(Date.now, forKey: key)
        } catch {
            self.error = "余额提醒发送失败：\(error.localizedDescription)"
        }
    }
}
