import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class ProfileStore {
    private static let storageKey = "userProfile"

    var profile: UserProfile {
        didSet { persist() }
    }

    private(set) var latestWeightKg: Double?
    private(set) var trendWeightKg: Double?
    private(set) var body = BodySnapshot()

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode(UserProfile.self, from: data) {
            profile = saved
        } else {
            var initial = UserProfile()
            if let legacyGoal = UserDefaults.standard.object(forKey: "dailyGoalKcal") as? Int {
                initial.manualKcalTarget = legacyGoal
            }
            profile = initial
        }
    }

    var currentWeightKg: Double? { trendWeightKg ?? latestWeightKg }

    var goal: NutritionGoal {
        GoalCalculator.goal(profile: profile, weightKg: currentWeightKg, body: body)
    }

    var metrics: BodyMetrics? {
        guard profile.isConfigured, let weight = currentWeightKg else { return nil }
        return BodyMetrics(profile: profile, weightKg: weight, body: body)
    }

    /// Call after any change to weights or body measurements so goals follow the latest data.
    func refresh(in context: ModelContext) {
        let entries = (try? context.fetch(FetchDescriptor<WeightEntry>())) ?? []
        let points = WeightTrend.compute(entries)
        latestWeightKg = points.last?.kg
        trendWeightKg = points.last?.trendKg

        let measurements = (try? context.fetch(FetchDescriptor<BodyMeasurement>(sortBy: [SortDescriptor(\.date, order: .reverse)]))) ?? []
        body = BodySnapshot(
            bodyFatPct: measurements.lazy.compactMap(\.bodyFatPct).first,
            scaleBMR: measurements.lazy.compactMap(\.scaleBMR).first,
            waistCm: measurements.lazy.compactMap(\.waistCm).first,
            muscleKg: measurements.lazy.compactMap(\.muscleKg).first
        )
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(profile) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
