import SwiftData

@MainActor
final class UsageLedger {
    static let shared = UsageLedger()
    private var context: ModelContext?

    func configure(container: ModelContainer) { context = container.mainContext }

    func record(_ entry: UsageEntry) {
        guard let context else { return }
        context.insert(UsageRecord(entry))
        try? context.save()
    }
}
