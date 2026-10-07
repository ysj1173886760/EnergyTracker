import Foundation
import HealthKit
import Observation
import SwiftData

@MainActor
@Observable
final class HealthSync {
    struct Activity {
        var steps: Double?
        var activeEnergy: Double?
    }
    private let store = HKHealthStore()
    private let defaults = UserDefaults.standard
    var isEnabled: Bool { didSet { defaults.set(isEnabled, forKey: "health.enabled") } }
    var importBody: Bool { didSet { defaults.set(importBody, forKey: "health.import") } }
    var writeMeals: Bool { didSet { defaults.set(writeMeals, forKey: "health.meals") } }
    var writeWeight: Bool { didSet { defaults.set(writeWeight, forKey: "health.weight") } }
    private(set) var lastSync: Date?
    private(set) var lastError: String?
    private(set) var isSyncing = false
    private var lastAttempt: Date?
    private var activities: [Date: Activity] = [:]
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }
    private static let nutrients: [HKQuantityTypeIdentifier] = [
        .dietaryEnergyConsumed, .dietaryProtein, .dietaryFatTotal, .dietaryCarbohydrates, .dietaryFiber, .dietarySodium,
        .dietarySugar
    ]

    init() {
        isEnabled = UserDefaults.standard.bool(forKey: "health.enabled")
        importBody = UserDefaults.standard.object(forKey: "health.import") as? Bool ?? true
        writeMeals = UserDefaults.standard.object(forKey: "health.meals") as? Bool ?? true
        writeWeight = UserDefaults.standard.object(forKey: "health.weight") as? Bool ?? true
        lastSync = UserDefaults.standard.object(forKey: "health.lastSync") as? Date
        lastAttempt = lastSync
    }

    func connect() async {
        guard isAvailable else { return }
        do {
            let write = Set<HKSampleType>((Self.nutrients + [.bodyMass]).map { HKQuantityType($0) })
            let read = Set<HKObjectType>(
                [
                    HKQuantityTypeIdentifier.bodyMass, .bodyFatPercentage, .waistCircumference, .stepCount,
                    .activeEnergyBurned
                ].map { HKQuantityType($0) })
            try await store.requestAuthorization(toShare: write, read: read)
            isEnabled = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func activity(on date: Date) -> Activity? {
        guard isEnabled else { return nil }
        return activities[Calendar.current.startOfDay(for: date)]
    }

    func activityText(on date: Date) -> String {
        let value = activity(on: date)
        let steps = value?.steps.map { String(Int($0.rounded())) } ?? "—"
        let energy = value?.activeEnergy.map { String(Int($0.rounded())) } ?? "—"
        return "步数 \(steps) · 活动能量 \(energy) kcal"
    }

    func sync(context: ModelContext, profileStore: ProfileStore, force: Bool = false) async {
        guard isEnabled, isAvailable, !isSyncing else { return }
        guard force || lastAttempt.map({ Date.now.timeIntervalSince($0) >= 600 }) ?? true else { return }
        isSyncing = true
        lastAttempt = .now
        defer { isSyncing = false }
        var errors: [String] = []
        if importBody {
            do {
                try await importMeasurements(context)
            } catch {
                errors.append(error.localizedDescription)
            }
            profileStore.refresh(in: context)
        }
        do {
            try await reconcile(context)
        } catch {
            errors.append(error.localizedDescription)
        }
        do {
            let steps = try await dailyStatistics(.stepCount, unit: .count())
            let energy = try await dailyStatistics(.activeEnergyBurned, unit: .kilocalorie())
            activities = Dictionary(
                uniqueKeysWithValues: Set(steps.keys).union(energy.keys).map {
                    ($0, Activity(steps: steps[$0], activeEnergy: energy[$0]))
                })
        } catch {
            errors.append(error.localizedDescription)
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        if errors.isEmpty {
            lastSync = .now
            defaults.set(lastSync, forKey: "health.lastSync")
        }
    }

    private func importMeasurements(_ context: ModelContext) async throws {
        let calendar = Calendar.current
        // A fixed first-import cutoff also lets anchored queries discover backdated samples.
        let cutoff =
            defaults.object(forKey: "health.importStart") as? Date
            ?? calendar.date(byAdding: .day, value: -90, to: .now)!
        defaults.set(cutoff, forKey: "health.importStart")
        for identifier in [HKQuantityTypeIdentifier.bodyMass, .bodyFatPercentage, .waistCircumference] {
            let key = "health.anchor." + identifier.rawValue
            let anchor = defaults.data(forKey: key).flatMap {
                try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
            }
            let (samples, next) = try await anchored(identifier, since: cutoff, anchor: anchor)
            var weights = try context.fetch(FetchDescriptor<WeightEntry>())
            var measurements = try context.fetch(FetchDescriptor<BodyMeasurement>())
            for sample in samples.sorted(by: { $0.startDate < $1.startDate })
            where sample.sourceRevision.source != HKSource.default() {
                let day = calendar.startOfDay(for: sample.startDate)
                if identifier == .bodyMass {
                    let matches = weights.filter { calendar.isDate($0.date, inSameDayAs: day) }
                    if matches.contains(where: { $0.healthKitSampleID == nil }) { continue }
                    let entry = matches.first ?? WeightEntry(date: sample.startDate, kg: 0)
                    if matches.isEmpty {
                        context.insert(entry)
                        weights.append(entry)
                    }
                    guard sample.startDate >= entry.date else { continue }
                    entry.date = sample.startDate
                    entry.kg = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
                    entry.healthKitSampleID = sample.uuid.uuidString
                } else {
                    let isBodyFat = identifier == .bodyFatPercentage
                    let unit: HKUnit = isBodyFat ? .percent() : .meterUnit(with: .centi)
                    let value = sample.quantity.doubleValue(for: unit) * (isBodyFat ? 100 : 1)
                    let matches = measurements.filter { calendar.isDate($0.date, inSameDayAs: day) }
                    let entry = matches.first ?? BodyMeasurement(date: day)
                    if matches.isEmpty {
                        context.insert(entry)
                        measurements.append(entry)
                    }
                    if identifier == .bodyFatPercentage {
                        if entry.bodyFatPct != nil && entry.healthKitFatDate == nil { continue }
                        if let previous = entry.healthKitFatDate, previous > sample.startDate { continue }
                        entry.bodyFatPct = value
                        entry.healthKitFatDate = sample.startDate
                    } else {
                        if entry.waistCm != nil && entry.healthKitWaistDate == nil { continue }
                        if let previous = entry.healthKitWaistDate, previous > sample.startDate { continue }
                        entry.waistCm = value
                        entry.healthKitWaistDate = sample.startDate
                    }
                    entry.healthKitSource = "Apple Health"
                }
            }
            try context.save()
            if let next {
                defaults.set(
                    try NSKeyedArchiver.archivedData(withRootObject: next, requiringSecureCoding: true), forKey: key)
            }
        }
    }

    private func anchored(_ identifier: HKQuantityTypeIdentifier, since: Date, anchor: HKQueryAnchor?) async throws -> (
        [HKQuantitySample], HKQueryAnchor?
    ) {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(
                type: HKQuantityType(identifier), predicate: HKQuery.predicateForSamples(withStart: since, end: nil),
                anchor: anchor, limit: HKObjectQueryNoLimit
            ) { _, samples, _, next, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: (samples as? [HKQuantitySample] ?? [], next))
                }
            }
            store.execute(query)
        }
    }

    private func dailyStatistics(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) async throws -> [Date: Double] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: -7, to: today)!
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsCollectionQuery(
                quantityType: HKQuantityType(identifier),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: .now),
                options: .cumulativeSum, anchorDate: today, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var result: [Date: Double] = [:]
                collection?.enumerateStatistics(from: start, to: .now) { statistics, _ in
                    if let quantity = statistics.sumQuantity() {
                        result[calendar.startOfDay(for: statistics.startDate)] = quantity.doubleValue(for: unit)
                    }
                }
                continuation.resume(returning: result)
            }
            store.execute(query)
        }
    }

    private func reconcile(_ context: ModelContext) async throws {
        let meals = try context.fetch(FetchDescriptor<Meal>())
        var fingerprints = defaults.dictionary(forKey: "health.mealFingerprints") as? [String: String] ?? [:]
        let allIDs = Set(meals.map { $0.id.uuidString })
        if writeMeals {
            for id in Array(fingerprints.keys) where !allIDs.contains(id) {
                try await deleteMeal(id)
                fingerprints[id] = nil
                defaults.set(fingerprints, forKey: "health.mealFingerprints")
            }
            let start = Calendar.current.date(byAdding: .day, value: -14, to: .now)!
            for meal in meals where meal.status == .done && meal.timestamp >= start {
                let id = meal.id.uuidString
                let values: [Double?] = [
                    meal.totalKcal, meal.totalProtein, meal.totalFat, meal.totalCarbs, meal.totalFiber,
                    meal.totalSodiumMg, meal.totalAddedSugar
                ]
                let fingerprint = "\(meal.timestamp.timeIntervalSince1970)|\(meal.summaryText)|\(values)"
                guard fingerprints[id] != fingerprint else { continue }
                for (identifier, value) in zip(Self.nutrients, values) where value == nil && fingerprints[id] != nil {
                    try await deleteSamples(type: HKQuantityType(identifier), id: id)
                }
                let version = nextVersion(id)
                let metadata: [String: Any] = [
                    HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: version,
                    HKMetadataKeyFoodType: meal.summaryText
                ]
                let samples = Set<HKSample>(
                    zip(Self.nutrients, values).compactMap { identifier, value -> HKSample? in
                        guard let value else { return nil }
                        let unit: HKUnit
                        switch identifier {
                        case .dietaryEnergyConsumed: unit = .kilocalorie()
                        case .dietarySodium: unit = .gramUnit(with: .milli)
                        default: unit = .gram()
                        }
                        let quantity = HKQuantity(unit: unit, doubleValue: max(0, value))
                        let metadata: [String: Any] = [
                            HKMetadataKeySyncIdentifier: id + "." + identifier.rawValue,
                            HKMetadataKeySyncVersion: version,
                            "mealID": id,
                            "sugarScope": "added sugar only"
                        ]
                        return HKQuantitySample(
                            type: HKQuantityType(identifier), quantity: quantity,
                            start: meal.timestamp, end: meal.timestamp, metadata: metadata
                        )
                    })
                let correlation = HKCorrelation(
                    type: HKCorrelationType(.food), start: meal.timestamp, end: meal.timestamp, objects: samples,
                    metadata: metadata)
                try await store.save(correlation)
                fingerprints[id] = fingerprint
                defaults.set(fingerprints, forKey: "health.mealFingerprints")
            }
        }
        if writeWeight {
            var saved = defaults.dictionary(forKey: "health.weightFingerprints") as? [String: String] ?? [:]
            for entry in try context.fetch(FetchDescriptor<WeightEntry>()) where entry.healthKitSampleID == nil {
                let id = "weight-\(Calendar.current.startOfDay(for: entry.date).timeIntervalSince1970)"
                let fingerprint = "\(entry.date.timeIntervalSince1970)|\(entry.kg)"
                guard saved[id] != fingerprint else { continue }
                let sample = HKQuantitySample(
                    type: HKQuantityType(.bodyMass),
                    quantity: HKQuantity(unit: .gramUnit(with: .kilo), doubleValue: entry.kg), start: entry.date,
                    end: entry.date,
                    metadata: [HKMetadataKeySyncIdentifier: id, HKMetadataKeySyncVersion: nextVersion(id)])
                try await store.save(sample)
                saved[id] = fingerprint
                defaults.set(saved, forKey: "health.weightFingerprints")
            }
        }
    }

    private func nextVersion(_ id: String) -> Int {
        let key = "health.version." + id
        let value = max(defaults.integer(forKey: key) + 1, Int(Date.now.timeIntervalSince1970 * 1000))
        defaults.set(value, forKey: key)
        return value
    }

    private func deleteSamples(type: HKSampleType, id: String) async throws {
        let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            HKQuery.predicateForObjects(from: HKSource.default()),
            HKQuery.predicateForObjects(withMetadataKey: "mealID", allowedValues: [id])
        ])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }

    private func deleteMeal(_ id: String) async throws {
        let source = HKQuery.predicateForObjects(from: HKSource.default())
        for type in Self.nutrients.map({ HKQuantityType($0) as HKSampleType }) + [HKCorrelationType(.food)] {
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                source,
                HKQuery.predicateForObjects(
                    withMetadataKey: type is HKCorrelationType ? HKMetadataKeySyncIdentifier : "mealID",
                    allowedValues: [id])
            ])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                store.deleteObjects(of: type, predicate: predicate) { _, _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        }
    }
}
