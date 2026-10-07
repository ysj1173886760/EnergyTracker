import Foundation

struct NutritionGoal {
    var kcal: Int
    var proteinG: Int?
    var bmr: Int?
    var bmrSource: UserProfile.BMRSource?
    var tdee: Int?
    var warnings: [String] = []
    var isManual = false

    static let fallback = NutritionGoal(kcal: 2000)

    /// Base target plus the configured share of exercise burn.
    func budget(exerciseKcal: Double, eatBackRatio: Double) -> Int {
        kcal + Int((exerciseKcal * eatBackRatio).rounded())
    }
}

/// Latest known body composition values (each may come from a different measurement).
struct BodySnapshot {
    var bodyFatPct: Double?
    var scaleBMR: Double?
    var waistCm: Double?
    var muscleKg: Double?
}

struct BodyMetrics {
    let weightKg: Double
    let bmi: Double
    let fatMassKg: Double?
    let leanMassKg: Double?
    let bmrMifflin: Double
    let bmrKatch: Double?
    let bmrScale: Double?
    /// Weight at the target body fat %, assuming lean mass is preserved.
    let targetWeightFromBodyFat: Double?

    init(profile: UserProfile, weightKg: Double, body: BodySnapshot) {
        self.weightKg = weightKg
        let heightM = profile.heightCm / 100
        bmi = weightKg / (heightM * heightM)
        bmrMifflin = GoalCalculator.mifflin(profile: profile, weightKg: weightKg)
        bmrScale = body.scaleBMR
        if let fat = body.bodyFatPct, fat > 0, fat < 70 {
            let lean = weightKg * (1 - fat / 100)
            fatMassKg = weightKg - lean
            leanMassKg = lean
            bmrKatch = 370 + 21.6 * lean
            if let target = profile.targetBodyFatPct, target > 0, target < 70 {
                targetWeightFromBodyFat = lean / (1 - target / 100)
            } else {
                targetWeightFromBodyFat = nil
            }
        } else {
            fatMassKg = nil
            leanMassKg = nil
            bmrKatch = nil
            targetWeightFromBodyFat = nil
        }
    }

    func bmr(for source: UserProfile.BMRSource) -> (value: Double, source: UserProfile.BMRSource) {
        switch source {
        case .katch: if let bmrKatch { return (bmrKatch, .katch) }
        case .scale: if let bmrScale { return (bmrScale, .scale) }
        case .mifflin: break
        }
        return (bmrMifflin, .mifflin)
    }
}

enum GoalCalculator {
    static let kcalPerKgFat = 7700.0

    static func mifflin(profile: UserProfile, weightKg: Double) -> Double {
        let base = 10 * weightKg + 6.25 * profile.heightCm - 5 * Double(profile.age)
        return profile.sex == .male ? base + 5 : base - 161
    }

    static func goal(profile: UserProfile, weightKg: Double?, body: BodySnapshot = BodySnapshot()) -> NutritionGoal {
        guard profile.isConfigured, let weightKg else {
            return NutritionGoal(kcal: profile.manualKcalTarget ?? NutritionGoal.fallback.kcal,
                                 isManual: profile.manualKcalTarget != nil)
        }

        let (bmr, bmrSource) = BodyMetrics(profile: profile, weightKg: weightKg, body: body).bmr(for: profile.bmrSource)
        let tdee = bmr * profile.activity.factor
        let wantsLoss = (profile.goalWeightKg ?? weightKg) < weightKg
        let deficit = wantsLoss ? profile.weeklyLossKg * kcalPerKgFat / 7 : 0
        let floor: Double = profile.sex == .male ? 1500 : 1200

        var warnings: [String] = []
        var target = tdee - deficit
        if target < floor {
            warnings.append("按当前减重速度，热量会低于 \(Int(floor)) kcal 的安全下限，已按下限设置。建议放慢减重速度或增加活动。")
            target = floor
        }
        if wantsLoss, profile.weeklyLossKg > weightKg * 0.01 {
            warnings.append("每周减 \(profile.weeklyLossKg.formatted()) kg 超过了体重的 1%，容易掉肌肉和反弹。")
        }

        // Protein is anchored to goal weight so heavier users don't get inflated targets.
        let proteinReference = min(weightKg, profile.goalWeightKg ?? weightKg)
        var result = NutritionGoal(
            kcal: Int((target / 10).rounded() * 10),
            proteinG: Int((proteinReference * profile.proteinPerKg).rounded()),
            bmr: Int(bmr.rounded()),
            bmrSource: bmrSource,
            tdee: Int(tdee.rounded()),
            warnings: warnings
        )
        if let manual = profile.manualKcalTarget {
            result.kcal = manual
            result.isManual = true
            if Double(manual) < floor {
                result.warnings.append("手动目标低于 \(Int(floor)) kcal 的安全下限。")
            }
        }
        return result
    }
}

struct WeightTrendPoint: Identifiable {
    let date: Date
    let kg: Double
    let trendKg: Double
    var id: Date { date }
}

enum WeightTrend {
    /// Exponential smoothing (10%/day) to filter out water and digestion noise;
    /// gaps between weigh-ins weigh the new value proportionally more.
    static func compute(_ entries: [WeightEntry]) -> [WeightTrendPoint] {
        let sorted = entries.sorted { $0.date < $1.date }
        var points: [WeightTrendPoint] = []
        var trend: Double?
        var lastDate: Date?
        for entry in sorted {
            if let previous = trend, let lastDate {
                let days = max(1, entry.date.timeIntervalSince(lastDate) / 86_400)
                let alpha = 1 - pow(0.9, days)
                trend = previous + alpha * (entry.kg - previous)
            } else {
                trend = entry.kg
            }
            lastDate = entry.date
            points.append(WeightTrendPoint(date: entry.date, kg: entry.kg, trendKg: trend!))
        }
        return points
    }

    /// kg per week from a least-squares fit of the trend over the last `days` days; negative means losing.
    static func weeklyRate(_ points: [WeightTrendPoint], days: Int = 21) -> Double? {
        guard let last = points.last else { return nil }
        let cutoff = last.date.addingTimeInterval(-Double(days) * 86_400)
        let recent = points.filter { $0.date >= cutoff }
        guard recent.count >= 3,
              let first = recent.first, last.date.timeIntervalSince(first.date) >= 6 * 86_400 else { return nil }

        let xs = recent.map { $0.date.timeIntervalSince(first.date) / 86_400 }
        let ys = recent.map(\.trendKg)
        let meanX = xs.reduce(0, +) / Double(xs.count)
        let meanY = ys.reduce(0, +) / Double(ys.count)
        let numerator = zip(xs, ys).reduce(0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let denominator = xs.reduce(0) { $0 + ($1 - meanX) * ($1 - meanX) }
        guard denominator > 0 else { return nil }
        return numerator / denominator * 7
    }

    static func projectedDate(currentKg: Double, goalKg: Double, weeklyRate: Double) -> Date? {
        let remaining = currentKg - goalKg
        guard remaining > 0, weeklyRate < -0.01 else { return nil }
        let days = remaining / -weeklyRate * 7
        guard days < 3 * 365 else { return nil }
        return Calendar.current.date(byAdding: .day, value: Int(days.rounded()), to: .now)
    }
}
