import Foundation
import Observation
import SwiftData

@MainActor @Observable
final class AutoBackup {
    struct File: Identifiable, Sendable {
        var name: String
        var date: Date
        var size: Int64
        var id: String { name }
    }

    private(set) var folderName: String?
    private(set) var lastBackupAt: Date?
    private(set) var lastBackupSize: Int64 = 0
    private(set) var lastError: String?
    private(set) var isRunning = false
    private(set) var backups: [File] = []
    private let context: ModelContext
    private let profileStore: ProfileStore
    private let defaults = UserDefaults.standard
    private var debugFolder: URL?
    private let key = "autoBackup."

    var isConfigured: Bool { folderName != nil }
    var isOverdue: Bool {
        guard isConfigured else { return false }
        let baseline = lastBackupAt ?? defaults.object(forKey: key + "configuredAt") as? Date ?? .now
        return Date.now.timeIntervalSince(baseline) >= 7 * 86400
    }

    init(context: ModelContext, profileStore: ProfileStore) {
        self.context = context
        self.profileStore = profileStore
        folderName = defaults.string(forKey: key + "folderName")
        lastBackupAt = defaults.object(forKey: key + "lastBackupAt") as? Date
        lastBackupSize = Int64(defaults.integer(forKey: key + "lastBackupSize"))
        lastError = defaults.string(forKey: key + "lastError")
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["DEBUG_BACKUP_FOLDER"], path.hasPrefix("/") {
            debugFolder = URL(fileURLWithPath: path, isDirectory: true)
            folderName = debugFolder?.lastPathComponent
        }
        #endif
    }

    func selectFolder(_ url: URL) throws {
        guard !isRunning else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard accessing else { throw Failure.access }
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil,
                                            relativeTo: nil)
        defaults.set(bookmark, forKey: key + "bookmark")
        debugFolder = nil
        folderName = url.lastPathComponent
        defaults.set(folderName, forKey: key + "folderName")
        defaults.set(Date.now, forKey: key + "configuredAt")
        lastBackupAt = nil
        lastBackupSize = 0
        defaults.removeObject(forKey: key + "lastBackupAt")
        defaults.removeObject(forKey: key + "lastBackupSize")
        backups = []
        setError(nil)
    }

    func disable() {
        guard !isRunning else { return }
        for suffix in ["bookmark", "folderName", "configuredAt", "lastBackupAt", "lastBackupSize", "lastError"] {
            defaults.removeObject(forKey: key + suffix)
        }
        debugFolder = nil
        folderName = nil
        lastBackupAt = nil
        lastBackupSize = 0
        lastError = nil
        backups = []
    }

    private func folder() throws -> (URL, Bool) {
        if let debugFolder { return (debugFolder, false) }
        guard let data = defaults.data(forKey: key + "bookmark") else { throw Failure.access }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else { throw Failure.access }
            do {
                if stale {
                    let bookmark = try url.bookmarkData(options: .minimalBookmark,
                                                       includingResourceValuesForKeys: nil, relativeTo: nil)
                    defaults.set(bookmark, forKey: key + "bookmark")
                }
                folderName = url.lastPathComponent
                defaults.set(folderName, forKey: key + "folderName")
                return (url, true)
            } catch {
                url.stopAccessingSecurityScopedResource()
                throw error
            }
        } catch { throw Failure.access }
    }

    private func setError(_ text: String?) {
        lastError = text
        defaults.set(text, forKey: key + "lastError")
    }

    func backupIfNeeded() async {
        guard BackupRotation.needsBackup(configured: isConfigured, lastSuccess: lastBackupAt, now: .now) else { return }
        await backupNow()
    }

    func backupNow() async {
        guard isConfigured, !isRunning else { return }
        isRunning = true
        let activity = BackgroundActivity("自动备份")
        defer { isRunning = false; activity.end() }
        do {
            let (folder, scoped) = try folder()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let temporary = try await BackupService.exportAsync(context: context, profile: profileStore.profile)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let name = BackupRotation.filename(for: .now)
            let size = try await Task.detached(priority: .utility) {
                let data = try Data(contentsOf: temporary)
                try Self.coordinate(folder.appendingPathComponent(name), writing: true) { url in
                    try data.write(to: url, options: .atomic)
                }
                return Int64(data.count)
            }.value
            lastBackupAt = .now
            lastBackupSize = size
            defaults.set(lastBackupAt, forKey: key + "lastBackupAt")
            defaults.set(size, forKey: key + "lastBackupSize")
            try await Task.detached(priority: .utility) {
                let files = try Self.list(folder)
                for name in BackupRotation.filesToDelete(files.map(\.name)) {
                    try Self.coordinate(folder.appendingPathComponent(name), writing: true, deleting: true) {
                        try FileManager.default.removeItem(at: $0)
                    }
                }
            }.value
            backups = try await Task.detached(priority: .utility) { try Self.list(folder) }.value
            setError(nil)
        } catch { setError("备份失败：\(error.localizedDescription)") }
    }

    func refreshList() async {
        guard isConfigured, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        do {
            let (folder, scoped) = try folder()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            backups = try await Task.detached(priority: .utility) { try Self.list(folder) }.value
        } catch { setError("读取备份列表失败：\(error.localizedDescription)") }
    }

    func restore(_ file: File) async throws -> BackupService.ImportSummary {
        guard !isRunning else { throw Failure.busy }
        guard BackupRotation.date(from: file.name) != nil, !file.name.contains("/") else { throw Failure.access }
        isRunning = true
        let activity = BackgroundActivity("恢复备份")
        defer { isRunning = false; activity.end() }
        do {
            let (folder, scoped) = try folder()
            defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
            let temporary = try await Task.detached(priority: .utility) {
                let source = folder.appendingPathComponent(file.name)
                let values = try source.resourceValues(forKeys: [.isUbiquitousItemKey,
                                                                 .ubiquitousItemDownloadingStatusKey])
                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus == .notDownloaded {
                    try FileManager.default.startDownloadingUbiquitousItem(at: source)
                    throw Failure.downloading
                }
                let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                do {
                    try Self.coordinate(source, writing: false) {
                        try FileManager.default.copyItem(at: $0, to: temporary)
                    }
                    return temporary
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            }.value
            defer { try? FileManager.default.removeItem(at: temporary) }
            let summary = try BackupService.importBackup(from: temporary, context: context, profileStore: profileStore)
            setError(nil)
            return summary
        } catch {
            setError("恢复失败：\(error.localizedDescription)")
            throw error
        }
    }

    nonisolated private static func list(_ folder: URL) throws -> [File] {
        var files: [File] = []
        try coordinate(folder, writing: false) { directory in
            let urls = try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles])
            files = try urls.compactMap { url in
                guard let date = BackupRotation.date(from: url.lastPathComponent) else { return nil }
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return nil }
                return File(name: url.lastPathComponent, date: date, size: Int64(values.fileSize ?? 0))
            }
        }
        return files.sorted { $0.name > $1.name }
    }

    nonisolated private static func coordinate(_ url: URL, writing: Bool, deleting: Bool = false,
                                              operation: (URL) throws -> Void) throws {
        var coordinationError: NSError?
        var operationError: Error?
        let accessor: (URL) -> Void = { coordinated in
            do { try operation(coordinated) } catch { operationError = error }
        }
        let coordinator = NSFileCoordinator()
        if writing {
            coordinator.coordinate(writingItemAt: url, options: deleting ? .forDeleting : .forReplacing,
                                   error: &coordinationError, byAccessor: accessor)
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinationError, byAccessor: accessor)
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private enum Failure: LocalizedError {
        case access, downloading, busy
        var errorDescription: String? {
            switch self {
            case .access: return "无法访问备份文件夹，请重新选择"
            case .downloading: return "正在从 iCloud 下载，请稍后再试"
            case .busy: return "正在处理备份，请稍后再试"
            }
        }
    }
}
