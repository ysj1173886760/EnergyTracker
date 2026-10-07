import Foundation

extension Calendar {
    /// Weeks run Monday–Sunday regardless of locale.
    static var mondayFirst: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    func weekStart(for date: Date) -> Date {
        dateInterval(of: .weekOfYear, for: date)?.start ?? startOfDay(for: date)
    }
}

struct WeeklyStats {
    struct Day: Identifiable {
        let date: Date
        let meals: [Meal]
        var exercises: [ExerciseSession] = []
        var id: Date { date }
        var exerciseKcal: Double { exercises.reduce(0) { $0 + $1.netKcal } }
        var logged: Bool { !meals.isEmpty }
        var kcal: Double { meals.reduce(0) { $0 + $1.totalKcal } }
        var protein: Double { meals.reduce(0) { $0 + $1.totalProtein } }
        var fat: Double { meals.reduce(0) { $0 + $1.totalFat } }
        var carbs: Double { meals.reduce(0) { $0 + $1.totalCarbs } }
        var isWeekend: Bool { Calendar.current.isDateInWeekend(date) }
    }

    let weekStart: Date
    let weekEnd: Date
    let isPartial: Bool
    /// Days elapsed so far (all 7 for a finished week).
    let days: [Day]
    let weights: [WeightTrendPoint]
    let trendStartKg: Double?
    let trendEndKg: Double?
    let goal: NutritionGoal

    init(weekStart: Date, meals: [Meal], weights: [WeightEntry], goal: NutritionGoal,
         exercises: [ExerciseSession] = [], now: Date = .now) {
        let calendar = Calendar.mondayFirst
        let end = calendar.date(byAdding: .day, value: 7, to: weekStart)!
        self.weekStart = weekStart
        weekEnd = end
        isPartial = now < end
        self.goal = goal

        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: meals.filter { $0.timestamp >= weekStart && $0.timestamp < end }) {
            calendar.startOfDay(for: $0.timestamp)
        }
        let exercisesByDay = Dictionary(grouping: exercises.filter { $0.timestamp >= weekStart && $0.timestamp < end }) {
            calendar.startOfDay(for: $0.timestamp)
        }
        days = (0..<7).compactMap { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: weekStart)!
            guard date <= today else { return nil }
            return Day(date: date, meals: (byDay[date] ?? []).sorted { $0.timestamp < $1.timestamp },
                       exercises: (exercisesByDay[date] ?? []).sorted { $0.timestamp < $1.timestamp })
        }

        let points = WeightTrend.compute(weights)
        self.weights = points.filter { $0.date >= weekStart && $0.date < end }
        trendStartKg = points.last(where: { $0.date < weekStart })?.trendKg ?? self.weights.first?.trendKg
        trendEndKg = self.weights.last?.trendKg
    }

    var loggedDays: [Day] { days.filter(\.logged) }
    var hasData: Bool { !loggedDays.isEmpty || !weights.isEmpty }

    private func average(_ days: [Day], _ value: (Day) -> Double) -> Double? {
        days.isEmpty ? nil : days.reduce(0) { $0 + value($1) } / Double(days.count)
    }

    var avgKcal: Double? { average(loggedDays, \.kcal) }
    var avgProtein: Double? { average(loggedDays, \.protein) }
    var weekdayAvgKcal: Double? { average(loggedDays.filter { !$0.isWeekend }, \.kcal) }
    var weekendAvgKcal: Double? { average(loggedDays.filter(\.isWeekend), \.kcal) }
    var exerciseDays: Int { days.filter { !$0.exercises.isEmpty }.count }
    var totalExerciseKcal: Double { days.reduce(0) { $0 + $1.exerciseKcal } }
    var daysOverTarget: Int { loggedDays.filter { $0.kcal > Double(goal.kcal) }.count }

    var trendChangeKg: Double? {
        guard let trendStartKg, let trendEndKg else { return nil }
        return trendEndKg - trendStartKg
    }

    var mealTypeShare: [MealType: Double] {
        let total = loggedDays.reduce(0) { $0 + $1.kcal }
        guard total > 0 else { return [:] }
        var share: [MealType: Double] = [:]
        for meal in loggedDays.flatMap(\.meals) {
            share[meal.mealType, default: 0] += meal.totalKcal / total
        }
        return share
    }

    var title: String {
        let calendar = Calendar.mondayFirst
        let last = calendar.date(byAdding: .day, value: 6, to: weekStart)!
        return "\(weekStart.formatted(.dateTime.month().day())) – \(last.formatted(.dateTime.month().day()))"
    }
}
