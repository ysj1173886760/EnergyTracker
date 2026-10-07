import Foundation

struct CheckInDay: Identifiable {
    let date: Date
    var mealCount = 0
    var hasWeight = false
    var hasExercise = false
    var id: Date { date }
    var level: Int {
        let score = min(mealCount, 3) + (hasWeight ? 1 : 0) + (hasExercise ? 1 : 0)
        switch score {
        case 0...2: return score
        case 3...4: return 3
        default: return 4
        }
    }
    var isLogged: Bool { level > 0 }
}

struct CheckIn {
    let today: Date
    let days: [Date: CheckInDay]
    let currentStreak: Int
    let longestStreak: Int
    let isNewRecord: Bool
    let recentCount: Int
    let recentTotal: Int
    let calendar: Calendar
    var totalCount: Int { days.count }
    var firstDate: Date? { days.keys.min() }

    init(meals: [Meal], exercises: [ExerciseSession], weights: [WeightEntry],
         now: Date = .now, calendar: Calendar = .current) {
        self.calendar = calendar
        let today = calendar.startOfDay(for: now)
        self.today = today
        var grouped: [Date: CheckInDay] = [:]
        for meal in meals where meal.status == .done {
            let date = calendar.startOfDay(for: meal.timestamp)
            guard date <= today else { continue }
            grouped[date, default: CheckInDay(date: date)].mealCount += 1
        }
        for exercise in exercises where exercise.status == .done {
            let date = calendar.startOfDay(for: exercise.timestamp)
            guard date <= today else { continue }
            grouped[date, default: CheckInDay(date: date)].hasExercise = true
        }
        for weight in weights {
            let date = calendar.startOfDay(for: weight.date)
            guard date <= today else { continue }
            grouped[date, default: CheckInDay(date: date)].hasWeight = true
        }
        days = grouped
        let dates = grouped.keys.sorted()
        var longest = 0
        var run = 0
        var bestBeforeToday = 0
        var previous: Date?
        for date in dates {
            let adjacent = previous.map { calendar.date(byAdding: .day, value: 1, to: $0) == date } ?? false
            run = adjacent ? run + 1 : 1
            longest = max(longest, run)
            if date < today { bestBeforeToday = max(bestBeforeToday, run) }
            previous = date
        }
        longestStreak = longest
        var cursor = grouped[today] == nil ? calendar.date(byAdding: .day, value: -1, to: today)! : today
        var current = 0
        while grouped[cursor] != nil {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        currentStreak = current
        isNewRecord = grouped[today] != nil && current > bestBeforeToday
        let cutoff = calendar.date(byAdding: .day, value: -29, to: today)!
        recentCount = dates.filter { $0 >= cutoff }.count
        recentTotal = dates.first.map {
            min(30, (calendar.dateComponents([.day], from: $0, to: today).day ?? 0) + 1)
        } ?? 0
    }

    func day(on date: Date) -> CheckInDay {
        let start = calendar.startOfDay(for: date)
        return days[start] ?? CheckInDay(date: start)
    }

    var encouragement: String {
        if day(on: today).isLogged {
            let prefix = isNewRecord && currentStreak > 1 ? "新纪录！" : ""
            return "\(prefix)今天已打卡，连续 \(currentStreak) 天"
        }
        if currentStreak > 0 {
            return "今天还没打卡，记一笔就能延续至 \(currentStreak + 1) 天"
        }
        return "今天记一笔，开始连续打卡"
    }
}
