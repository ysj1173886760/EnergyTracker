import Foundation

struct CalibrationResult {
    var loggedDays: Int
    var weightCount: Int
    var weightSpan: Int
    var expenditure: Int?
    var suggestedTarget: Int?
    var progress: String { "近 21 天饮食记录 \(loggedDays)/12 天，体重 \(weightCount)/6 条，跨度 \(weightSpan)/14 天。" }
}

enum TargetCalibration {
    static func calculate(
        meals: [Meal], exercises: [ExerciseSession], weights: [WeightEntry], profile: UserProfile,
        goal: NutritionGoal, currentWeight: Double?, now: Date = .now
    ) -> CalibrationResult {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -21, to: end)!
        let meals = meals.filter { $0.timestamp >= start && $0.timestamp < end && $0.status == .done }
        let days = Set(meals.map { calendar.startOfDay(for: $0.timestamp) }).count
        let trend = WeightTrend.compute(weights).filter { $0.date < end }
        let windowWeights = weights.filter { $0.date >= start && $0.date < end }.sorted { $0.date < $1.date }
        let span: Int
        if let first = windowWeights.first, let last = windowWeights.last {
            span =
                calendar.dateComponents(
                    [.day],
                    from: calendar.startOfDay(for: first.date),
                    to: calendar.startOfDay(for: last.date)
                ).day ?? 0
        } else {
            span = 0
        }
        var result = CalibrationResult(loggedDays: days, weightCount: windowWeights.count, weightSpan: span)
        guard profile.isConfigured, days >= 12, windowWeights.count >= 6, span >= 14,
            let rate = WeightTrend.weeklyRate(trend, days: 21), let currentWeight
        else { return result }
        let expenditure = meals.reduce(0) { $0 + $1.totalKcal } / Double(days) - rate * 7700 / 7
        let deficit = (profile.goalWeightKg ?? currentWeight) < currentWeight ? profile.weeklyLossKg * 7700 / 7 : 0
        let bonus =
            exercises.filter { $0.timestamp >= start && $0.timestamp < end && $0.status == .done }
            .reduce(0) { $0 + $1.netKcal } / 21 * profile.eatBackRatio
        let delta = expenditure - deficit - bonus - Double(goal.kcal)
        result.expenditure = Int(expenditure.rounded())
        guard abs(delta) >= 80 else { return result }
        let floor = profile.sex == .male ? 1500 : 1200
        let rounded = Int(((Double(goal.kcal) + min(150, max(-150, delta))) / 10).rounded()) * 10
        let lower = Int(ceil(Double(goal.kcal - 150) / 10)) * 10
        let upper = Int(Foundation.floor(Double(goal.kcal + 150) / 10)) * 10
        result.suggestedTarget = max(floor, min(upper, max(lower, rounded)))
        if result.suggestedTarget == goal.kcal { result.suggestedTarget = nil }
        return result
    }
}
