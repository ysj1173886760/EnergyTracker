import Foundation
import UIKit

/// Sends requests through a background URLSession so they keep running after the app is suspended.
/// The system performs the transfer out of process and wakes the app when the response arrives.
final class BackgroundTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundTransport()
    static let identifier = "local.personal.EnergyTracker.background"

    private let lock = NSLock()
    private struct Pending {
        let request: URLRequest
        let bodyFile: URL
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        var createdInForeground: Bool
        var task: URLSessionUploadTask
        var data = Data()
    }

    private var pending: [Int: Pending] = [:]

    override init() {
        super.init()
        _ = session
        NotificationCenter.default.addObserver(
            self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    /// Set by the app delegate when iOS relaunches the app to deliver session events.
    var eventsCompletionHandler: (() -> Void)?

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 20 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Tasks left over from a previous process can't be matched to anything, so drop them;
    /// interrupted jobs are restarted from their saved status instead.
    func cancelOrphanedTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            lock.lock()
            tasks.filter { self.pending[$0.taskIdentifier] == nil }.forEach { $0.cancel() }
            lock.unlock()
        }
    }

    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let file = FileManager.default.temporaryDirectory.appending(path: "request-\(UUID().uuidString).json")
        try body.write(to: file)
        return try await enqueue(request, bodyFile: file)
    }

    @MainActor
    private func enqueue(_ request: URLRequest, bodyFile: URL) async throws -> (Data, HTTPURLResponse) {
        let createdInForeground = UIApplication.shared.applicationState == .active
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let task = session.uploadTask(with: request, fromFile: bodyFile)
            pending[task.taskIdentifier] = Pending(
                request: request, bodyFile: bodyFile, continuation: continuation,
                createdInForeground: createdInForeground, task: task)
            task.resume()
            lock.unlock()
        }
    }

    @MainActor
    @objc private func didBecomeActive() {
        guard UIApplication.shared.applicationState == .active else { return }
        lock.lock()
        defer { lock.unlock() }
        let candidates = pending.filter { !$0.value.createdInForeground && $0.value.task.countOfBytesReceived == 0 }
        for (identifier, var request) in candidates {
            pending.removeValue(forKey: identifier)
            request.task.cancel()
            let task = session.uploadTask(with: request.request, fromFile: request.bodyFile)
            request.task = task
            request.createdInForeground = true
            request.data = Data()
            pending[task.taskIdentifier] = request
            task.resume()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        pending[dataTask.taskIdentifier]?.data.append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let request = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let request else { return }
        try? FileManager.default.removeItem(at: request.bodyFile)

        if let error {
            request.continuation.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            request.continuation.resume(returning: (request.data, response))
        } else {
            request.continuation.resume(throwing: URLError(.badServerResponse))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.eventsCompletionHandler?()
            self?.eventsCompletionHandler = nil
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransport.identifier else { return completionHandler() }
        BackgroundTransport.shared.eventsCompletionHandler = completionHandler
        _ = BackgroundTransport.shared.session
    }
}

/// Extra execution time after the app leaves the foreground. The expiration handler must end the
/// task, otherwise iOS terminates the app — which would also drop the in-memory request state.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(_ name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
