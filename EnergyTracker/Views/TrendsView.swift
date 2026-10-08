import Charts
import SwiftData
import SwiftUI

struct TrendsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case weight = "体重"
        case calories = "热量"
        case checkin = "打卡"
        var id: String { rawValue }
    }

    @State private var tab: Tab = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DEBUG_TRENDS_TAB"] == "checkin" { return .checkin }
        if ProcessInfo.processInfo.environment["DEBUG_TRENDS_TAB"] == "calories" { return .calories }
        #endif
        return .weight
    }()

    var body: some View {
        NavigationStack {
            Group {
                switch tab {
                case .weight: WeightTrendList()
                case .calories: CalorieHistoryList()
                case .checkin: CheckInView()
                }
            }
            .navigationTitle("趋势")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("类型", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
            }
        }
    }
}

// MARK: - Weight

private struct WeightTrendList: View {
    private enum Range: Int, CaseIterable, Identifiable {
        case month = 30
        case quarter = 90
        case all = 0
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .month: "30 天"
            case .quarter: "90 天"
            case .all: "全部"
            }
        }
    }

    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Query(sort: \WeightEntry.date, order: .reverse) private var entries: [WeightEntry]
    @State private var range: Range = .month
    @State private var adding = false

    private var points: [WeightTrendPoint] { WeightTrend.compute(entries) }

    private var visiblePoints: [WeightTrendPoint] {
        guard range != .all else { return points }
        let cutoff = Calendar.current.date(byAdding: .day, value: -range.rawValue, to: .now)!
        return points.filter { $0.date >= cutoff }
    }

    var body: some View {
        List {
            if points.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("还没有体重记录", systemImage: "scalemass")
                    } description: {
                        Text("每天早上称一次，几天后就能看到趋势。")
                    } actions: {
                        Button("记录体重") { adding = true }.buttonStyle(.borderedProminent)
                    }
                }
            } else {
                Section {
                    Picker("范围", selection: $range) {
                        ForEach(Range.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    chart
                }
                statsSection
                Section("记录") {
                    ForEach(Array(points.reversed())) { point in
                        HStack {
                            Text(point.date, format: .dateTime.month().day().weekday())
                            Spacer()
                            Text("\(point.kg, specifier: "%.1f") kg").monospacedDigit()
                            Text("趋势 \(point.trendKg, specifier: "%.1f")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .trailing)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { adding = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
            }
        }
        .sheet(isPresented: $adding) { WeightEntrySheet() }
    }

    private var chart: some View {
        let values = visiblePoints.flatMap { [$0.kg, $0.trendKg] } + [profileStore.profile.goalWeightKg].compactMap { $0 }
        let lower = (values.min() ?? 60) - 1
        let upper = (values.max() ?? 80) + 1
        return Chart {
            ForEach(visiblePoints) { point in
                PointMark(x: .value("日期", point.date, unit: .day), y: .value("体重", point.kg))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .symbolSize(20)
                LineMark(x: .value("日期", point.date, unit: .day), y: .value("趋势", point.trendKg))
                    .foregroundStyle(Color.accentColor)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                    .interpolationMethod(.monotone)
            }
            if let goal = profileStore.profile.goalWeightKg, goal >= lower, goal <= upper {
                RuleMark(y: .value("目标", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.green)
                    .annotation(position: .top, alignment: .leading) {
                        Text("目标 \(goal, specifier: "%.1f")").font(.caption2).foregroundStyle(.green)
                    }
            }
        }
        .chartYScale(domain: lower...upper)
        .frame(height: 220)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statsSection: some View {
        let rate = WeightTrend.weeklyRate(points)
        Section {
            if let trend = points.last?.trendKg {
                LabeledContent("当前趋势体重", value: String(format: "%.1f kg", trend))
                if let first = points.first {
                    LabeledContent("累计变化", value: String(format: "%+.1f kg", trend - first.trendKg))
                }
            }
            if let rate {
                LabeledContent("近 3 周速度", value: String(format: "%+.2f kg / 周", rate))
            }
            if let goal = profileStore.profile.goalWeightKg, let trend = points.last?.trendKg {
                LabeledContent("距目标", value: String(format: "%.1f kg", max(0, trend - goal)))
                if let rate, let date = WeightTrend.projectedDate(currentKg: trend, goalKg: goal, weeklyRate: rate) {
                    LabeledContent("预计达成", value: date.formatted(.dateTime.year().month().day()))
                }
            }
        } footer: {
            if rate == nil {
                Text("记录满一周（至少 3 次）后会显示减重速度和预计达成日期。")
            } else {
                Text("灰点是每天的实际体重，橙线是过滤掉喝水、饮食波动后的趋势体重。")
            }
        }
    }

    private func delete(at offsets: IndexSet) {
        let reversed = Array(points.reversed())
        for index in offsets {
            let date = reversed[index].date
            entries.filter { $0.date == date }.forEach(context.delete)
        }
        try? context.save()
        profileStore.refresh(in: context)
    }
}

// MARK: - Calories

private struct CalorieHistoryList: View {
    @Environment(ProfileStore.self) private var profileStore
    @Query(sort: \Meal.timestamp, order: .reverse) private var meals: [Meal]
    @Query(sort: \ExerciseSession.timestamp, order: .reverse) private var exercises: [ExerciseSession]

    private struct DayTotal: Identifiable {
        let day: Date
        let kcal: Double
        let protein: Double
        let mealCount: Int
        var exerciseKcal: Double = 0
        var exerciseCount: Int = 0
        var id: Date { day }

        var subtitle: String {
            let diet = mealCount > 0 ? "\(mealCount) 餐 · 蛋白质 \(protein.gramsText) g" : "未记饮食"
            return exerciseCount > 0 ? "\(diet) · 运动 \(exerciseKcal.kcalText) kcal" : diet
        }
    }

    private var goal: NutritionGoal { profileStore.goal }

    private var dayTotals: [DayTotal] {
        let calendar = Calendar.current
        let mealsByDay = Dictionary(grouping: meals.filter { $0.status == .done }) {
            calendar.startOfDay(for: $0.timestamp)
        }
        let exercisesByDay = Dictionary(grouping: exercises.filter { $0.status == .done }) {
            calendar.startOfDay(for: $0.timestamp)
        }
        let days = Set(mealsByDay.keys).union(exercisesByDay.keys)
        return days.map { day in
            let meals = mealsByDay[day] ?? []
            let exercises = exercisesByDay[day] ?? []
            return DayTotal(day: day, kcal: meals.reduce(0) { $0 + $1.totalKcal },
                            protein: meals.reduce(0) { $0 + $1.totalProtein }, mealCount: meals.count,
                            exerciseKcal: exercises.reduce(0) { $0 + $1.netKcal }, exerciseCount: exercises.count)
        }
        .sorted { $0.day > $1.day }
    }

    private var lastTwoWeeks: [DayTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let byDay = Dictionary(uniqueKeysWithValues: dayTotals.map { ($0.day, $0) })
        return (0..<14).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            return byDay[day] ?? DayTotal(day: day, kcal: 0, protein: 0, mealCount: 0)
        }
    }

    private var weeklyAverage: (kcal: Double, protein: Double)? {
        let recorded = lastTwoWeeks.suffix(7).filter { $0.mealCount > 0 }
        guard !recorded.isEmpty else { return nil }
        let count = Double(recorded.count)
        return (recorded.reduce(0) { $0 + $1.kcal } / count, recorded.reduce(0) { $0 + $1.protein } / count)
    }

    var body: some View {
        List {
            Section {
                Chart {
                    ForEach(lastTwoWeeks) { day in
                        BarMark(x: .value("日期", day.day, unit: .day), y: .value("热量", day.kcal))
                            .foregroundStyle(day.kcal > Double(goal.kcal) ? Color.red.gradient : Color.accentColor.gradient)
                    }
                    RuleMark(y: .value("目标", goal.kcal))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(.secondary)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 2)) {
                        AxisValueLabel(format: .dateTime.day())
                    }
                }
                .frame(height: 180)
                .padding(.vertical, 8)
            } header: {
                Text("最近 14 天")
            } footer: {
                if let weeklyAverage {
                    let protein = goal.proteinG.map { " / \($0)" } ?? ""
                    Text("近 7 天有记录的日子平均 \(weeklyAverage.kcal.kcalText) kcal（目标 \(goal.kcal)），蛋白质 \(weeklyAverage.protein.gramsText)\(protein) g")
                }
            }

            Section("每日记录") {
                if dayTotals.isEmpty {
                    Text("还没有数据").foregroundStyle(.secondary)
                }
                ForEach(dayTotals) { day in
                    NavigationLink {
                        DayMealList(date: day.day)
                            .navigationTitle(day.day.formatted(.dateTime.month().day().weekday()))
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(day.day, format: .dateTime.month().day().weekday())
                                Text(day.subtitle)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(day.mealCount > 0 ? "\(day.kcal.kcalText) kcal" : "—")
                                .monospacedDigit()
                                .foregroundStyle(day.mealCount > 0 && day.kcal > Double(goal.budget(
                                    exerciseKcal: day.exerciseKcal,
                                    eatBackRatio: profileStore.profile.eatBackRatio
                                )) ? .red : .primary)
                        }
                    }
                }
            }
        }
    }
}
