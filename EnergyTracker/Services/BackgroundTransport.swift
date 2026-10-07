import Foundation
import UIKit

/// Sends requests through a background URLSession so they keep running after the app is suspended.
/// The system performs the transfer out of process and wakes the app when the response arrives.
final class BackgroundTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = BackgroundTransport()
    static let identifier = "local.personal.EnergyTracker.background"

    private let lock = NSLock()
    private var buffers: [Int: Data] = [:]
    private var continuations: [Int: CheckedContinuation<(Data, HTTPURLResponse), Error>] = [:]
    private var bodyFiles: [Int: URL] = [:]

    /// Set by the app delegate when iOS relaunches the app to deliver session events.
    var eventsCompletionHandler: (() -> Void)?

    private(set) lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 6 * 3600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Tasks left over from a previous process can't be matched to anything, so drop them;
    /// interrupted jobs are restarted from their saved status instead.
    func cancelOrphanedTasks() {
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            lock.lock()
            let known = Set(continuations.keys)
            lock.unlock()
            tasks.filter { !known.contains($0.taskIdentifier) }.forEach { $0.cancel() }
        }
    }

    func send(_ request: URLRequest, body: Data) async throws -> (Data, HTTPURLResponse) {
        let file = FileManager.default.temporaryDirectory.appending(path: "request-\(UUID().uuidString).json")
        try body.write(to: file)
        return try await withCheckedThrowingContinuation { continuation in
            let task = session.uploadTask(with: request, fromFile: file)
            lock.lock()
            continuations[task.taskIdentifier] = continuation
            bodyFiles[task.taskIdentifier] = file
            lock.unlock()
            task.resume()
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        buffers[dataTask.taskIdentifier, default: Data()].append(data)
        lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = continuations.removeValue(forKey: task.taskIdentifier)
        let data = buffers.removeValue(forKey: task.taskIdentifier) ?? Data()
        let file = bodyFiles.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let file { try? FileManager.default.removeItem(at: file) }

        if let error {
            continuation?.resume(throwing: error)
        } else if let response = task.response as? HTTPURLResponse {
            continuation?.resume(returning: (data, response))
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
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
