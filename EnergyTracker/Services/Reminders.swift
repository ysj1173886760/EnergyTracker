import Foundation
import Observation
import UIKit
import UserNotifications

struct Reminder: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var body: String
    var hour: Int
    var minute: Int
    var isEnabled: Bool

    var time: Date {
        get { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? .now }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            hour = parts.hour ?? hour
            minute = parts.minute ?? minute
        }
    }

    static let defaults: [Reminder] = [
        Reminder(title: "称体重", body: "起床、如厕后空腹称一下体重", hour: 7, minute: 30, isEnabled: false),
        Reminder(title: "记录早餐", body: "早餐吃了什么？拍张照记一下", hour: 9, minute: 0, isEnabled: false),
        Reminder(title: "记录午餐", body: "午餐别忘了拍照记录", hour: 12, minute: 30, isEnabled: false),
        Reminder(title: "记录晚餐", body: "晚餐吃了什么？拍张照记一下", hour: 19, minute: 0, isEnabled: false),
        Reminder(title: "今日总结", body: "看看今天的饮食和运动，生成 AI 总结", hour: 21, minute: 30, isEnabled: false),
    ]
}

/// Daily reminders and "job finished" notices for work that completes while the app is in the background.
@MainActor
@Observable
final class NotificationCenterService {
    private static let storageKey = "reminders"
    private static let reminderPrefix = "reminder-"

    var reminders: [Reminder] {
        didSet {
            persist()
            Task { await reschedule() }
        }
    }

    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = saved
        } else {
            reminders = Reminder.defaults
        }
    }

    func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    func reschedule() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(Self.reminderPrefix) })

        for reminder in reminders where reminder.isEnabled {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let trigger = UNCalendarNotificationTrigger(dateMatching: DateComponents(hour: reminder.hour, minute: reminder.minute), repeats: true)
            try? await center.add(UNNotificationRequest(identifier: Self.reminderPrefix + reminder.id.uuidString, content: content, trigger: trigger))
        }
    }

    /// Posts a notice only when the user isn't looking at the app.
    static func notifyIfInBackground(title: String, body: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(reminders) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
