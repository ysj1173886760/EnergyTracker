import Foundation

struct HealthFlag: Identifiable {
    enum Level { case warning, caution }
    let id: String
    let level: Level
    let title: String
    let detail: String
    var aiKey: String { id }
    var payload: [String: String] { ["key": aiKey, "title": title, "detail": detail] }
}

enum HealthGuard {
    static func flags(
        meals: [Meal], exercises: [ExerciseSession], trend: [WeightTrendPoint], profile: UserProfile,
        goal: NutritionGoal, metrics: BodyMetrics?, now: Date = .now
    ) -> [HealthFlag] {
        let calendar = Calendar.current
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -14, to: end)!
        let week = calendar.date(byAdding: .day, value: -7, to: end)!
        let completedMeals = meals.filter { $0.timestamp >= start && $0.timestamp < end && $0.status == .done }
        let grouped = Dictionary(grouping: completedMeals) { calendar.startOfDay(for: $0.timestamp) }
        let intake = grouped.mapValues { $0.reduce(0) { $0 + $1.totalKcal } }
        let completedExercises = exercises.filter {
            $0.timestamp >= start && $0.timestamp < end && $0.status == .done
        }
        let exercisesByDay = Dictionary(grouping: completedExercises) { calendar.startOfDay(for: $0.timestamp) }
        let movement = exercisesByDay.mapValues { $0.reduce(0) { $0 + $1.netKcal } }
        let recent = intake.filter { $0.key >= week }
        let floor = profile.sex == .male ? 1500.0 : 1200.0
        var result: [HealthFlag] = []
        func add(_ id: String, _ level: HealthFlag.Level, _ title: String, _ detail: String) {
            result.append(HealthFlag(id: id, level: level, title: title, detail: detail))
        }
        let lowDays = recent.values.filter { $0 < floor }.count
        if lowDays >= 3 {
            add(
                "low_intake_days", .warning, "最近多天吃得太少",
                "最近 7 天有 \(lowDays) 个记录日摄入低于 \(Int(floor)) kcal。请核对是否漏记，并尽量规律、充足地进食。")
        }
        if let bmr = goal.bmr, recent.count >= 4 {
            let average = recent.values.reduce(0, +) / Double(recent.count)
            if average < Double(bmr) {
                add(
                    "below_bmr", .warning, "平均摄入低于基础代谢",
                    "记录日平均摄入约 \(Int(average.rounded())) kcal，基础代谢约 \(bmr) kcal。建议增加摄入，避免持续过大的缺口。")
            }
        }
        let points = trend.filter { $0.date >= start && $0.date < end }
        if let weight = metrics?.weightKg ?? points.last?.trendKg,
            let rate = WeightTrend.weeklyRate(points, days: 14), rate < -weight * 0.01
        {
            add(
                "rapid_weight_loss", .warning, "减重速度过快",
                String(format: "趋势显示每周下降 %.2f kg，超过当前体重的 1%%。建议放慢到每周不超过 %.2f kg，并关注体力和恢复。", -rate, weight * 0.01))
        }
        let targetBMI = profile.goalWeightKg.map { $0 / pow(profile.heightCm / 100, 2) }
        let losing = metrics.map { (profile.goalWeightKg ?? $0.weightKg) < $0.weightKg } ?? false
        if (targetBMI.map { $0 < 18.5 } ?? false) || ((metrics?.bmi ?? 100) < 18.5 && losing) {
            add("low_target_weight", .warning, "目标体重偏低", "目标体重对应 BMI 低于 18.5，或当前体重已偏低仍设有减重目标。建议暂停减重，和专业人士一起调整目标。")
        }
        var cycles = 0
        for (day, kcal) in intake {
            let next = calendar.date(byAdding: .day, value: 1, to: day)!
            let budget = goal.budget(exerciseKcal: movement[day] ?? 0, eatBackRatio: profile.eatBackRatio)
            if kcal > Double(budget) * 1.5, let nextKcal = intake[next], nextKcal < floor { cycles += 1 }
        }
        if cycles >= 2 {
            add(
                "restrict_after_overeating", .caution, "暴食后节食的循环",
                "最近 14 天出现 \(cycles) 次吃得较多后次日摄入偏低的情况。这不是意志力的问题，试着规律进食，不用节食补偿；若反复困扰你，可以寻求专业帮助。")
        }
        if let bmr = goal.bmr {
            let days = recent.filter { $0.value - (movement[$0.key] ?? 0) < Double(bmr) * 0.8 }.count
            if days >= 3 {
                add(
                    "low_net_intake", .caution, "运动量大但吃得不够",
                    "最近 7 天有 \(days) 天扣除运动后的净摄入低于基础代谢的 80%。建议补充饮食、安排恢复，避免用运动扩大缺口。")
            }
        }
        return result
    }
}
