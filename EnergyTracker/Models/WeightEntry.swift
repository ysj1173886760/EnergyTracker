import Foundation
import SwiftData

@Model
final class WeightEntry {
    var date: Date = Date()
    var kg: Double = 0
    var healthKitSampleID: String?

    init(date: Date, kg: Double) {
        self.date = date
        self.kg = kg
    }

    /// One entry per day: weighing again on the same day replaces the earlier value.
    @MainActor
    static func upsert(kg: Double, on date: Date, in context: ModelContext) {
        let (start, end) = Calendar.current.dayRange(for: date)
        let descriptor = FetchDescriptor<WeightEntry>(predicate: #Predicate { $0.date >= start && $0.date < end })
        if let existing = try? context.fetch(descriptor), let first = existing.first {
            first.healthKitSampleID = nil
            first.kg = kg
            first.date = date
            existing.dropFirst().forEach(context.delete)
        } else {
            context.insert(WeightEntry(date: date, kg: kg))
        }
        try? context.save()
    }
}
