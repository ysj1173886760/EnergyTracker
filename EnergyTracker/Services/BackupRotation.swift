import Foundation

enum BackupRotation {
    static let prefix = "健康助手备份-"

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        formatter.isLenient = false
        return formatter
    }

    static func filename(for date: Date) -> String {
        prefix + formatter().string(from: date) + ".json"
    }

    static func date(from filename: String) -> Date? {
        guard filename.hasPrefix(prefix), filename.hasSuffix(".json") else { return nil }
        let stamp = String(filename.dropFirst(prefix.count).dropLast(5))
        let format = formatter()
        guard let date = format.date(from: stamp), format.string(from: date) == stamp else { return nil }
        return date
    }

    static func filesToDelete(_ names: [String], keeping count: Int = 14) -> [String] {
        names.filter { date(from: $0) != nil }.sorted(by: >).dropFirst(max(0, count)).map { $0 }
    }

    static func needsBackup(configured: Bool, lastSuccess: Date?, now: Date) -> Bool {
        configured && (lastSuccess.map { now.timeIntervalSince($0) >= 86400 } ?? true)
    }
}
