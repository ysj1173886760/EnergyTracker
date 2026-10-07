import SwiftData
import SwiftUI

struct CheckInView: View {
    @Query private var meals: [Meal]
    @Query private var exercises: [ExerciseSession]
    @Query private var weights: [WeightEntry]
    @State private var selectedDate: Date?
    @State private var heatmapWidth: CGFloat = 300

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let stats = CheckIn(meals: meals, exercises: exercises, weights: weights, now: timeline.date)
            List {
                Section {
                    HStack(spacing: 0) {
                        statistic("当前连续", value: "\(stats.currentStreak)", flame: stats.currentStreak > 0)
                        statistic("最长连续", value: "\(stats.longestStreak)")
                        statistic("近 30 天", value: "\(stats.recentCount)/\(stats.recentTotal)")
                        statistic("累计", value: "\(stats.totalCount)")
                    }
                    .padding(.vertical, 4)
                    Text(stats.encouragement).font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    heatmap(stats)
                    HStack(spacing: 4) {
                        Text("向左滑动查看更早记录")
                        Spacer(minLength: 4)
                        Text("少")
                        ForEach(0..<5) { level in
                            RoundedRectangle(cornerRadius: 2).fill(color(level)).frame(width: 10, height: 10)
                        }
                        Text("多")
                    }
                    .font(.caption2).foregroundStyle(.secondary)
                } header: {
                    Text("打卡日历")
                } footer: {
                    Text("记录餐食、体重或运动即可打卡。点按格子查看当天详情。")
                }
                if let selectedDate {
                    details(stats.day(on: selectedDate))
                }
            }
        }
    }

    private func statistic(_ title: String, value: String, flame: Bool = false) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 3) {
                if flame { Image(systemName: "flame.fill").foregroundStyle(Color.accentColor) }
                Text(value).monospacedDigit()
            }
            .font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func color(_ level: Int) -> Color {
        level == 0 ? Color(.secondarySystemFill) : Color.accentColor.opacity(Double(level) / 4)
    }

    private func heatmap(_ stats: CheckIn) -> some View {
        let calendar = Calendar.mondayFirst
        let thisWeek = calendar.weekStart(for: stats.today)
        let firstWeek = calendar.weekStart(for: stats.firstDate ?? stats.today)
        let elapsed = (calendar.dateComponents([.day], from: firstWeek, to: thisWeek).day ?? 0) / 7 + 1
        let count = max(52, elapsed)
        let start = calendar.date(byAdding: .day, value: -7 * (count - 1), to: thisWeek)!
        return GeometryReader { geometry in
            let size = max(1, (geometry.size.width - 22 - 25 * 3) / 26)
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 3) {
                    Color.clear.frame(height: 18)
                    ForEach(0..<7) { row in
                        Text(row == 0 ? "一" : row == 2 ? "三" : row == 4 ? "五" : "")
                            .font(.system(size: 9)).frame(width: 18, height: size)
                    }
                }
                .frame(width: 18)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 3) {
                        ForEach(0..<count, id: \.self) { week in
                            let date = calendar.date(byAdding: .day, value: week * 7, to: start)!
                            VStack(spacing: 3) {
                                Color.clear.frame(width: size, height: 18)
                                    .overlay(alignment: .leading) {
                                        if let month = monthLabel(date, calendar: calendar, today: stats.today) {
                                            Text("\(month)月").font(.system(size: 9))
                                                .foregroundStyle(.secondary).fixedSize()
                                        }
                                    }
                                ForEach(0..<7) { row in
                                    let day = calendar.date(byAdding: .day, value: row, to: date)!
                                    if day <= stats.today {
                                        cell(stats.day(on: day), size: size)
                                    } else {
                                        Color.clear.frame(width: size, height: size)
                                    }
                                }
                            }
                            .id(week)
                        }
                    }
                }
                .defaultScrollAnchor(.trailing)
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in heatmapWidth = width }
        }
        .frame(height: 21 + 7 * max(1, (heatmapWidth - 22 - 75) / 26) + 18)
    }

    private func monthLabel(_ week: Date, calendar: Calendar, today: Date) -> Int? {
        for offset in 0..<7 {
            let date = calendar.date(byAdding: .day, value: offset, to: week)!
            if date <= today, calendar.component(.day, from: date) == 1 {
                return calendar.component(.month, from: date)
            }
        }
        return nil
    }

    private func cell(_ day: CheckInDay, size: CGFloat) -> some View {
        Button { selectedDate = day.date } label: {
            RoundedRectangle(cornerRadius: 2)
                .fill(color(day.level))
                .overlay {
                    if selectedDate == day.date {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary, lineWidth: 1)
                    }
                }
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(day.date.formatted(.dateTime.month().day()))，\(day.isLogged ? "已打卡" : "没有记录")")
        .accessibilityAddTraits(selectedDate == day.date ? .isSelected : [])
    }

    private func details(_ day: CheckInDay) -> some View {
        Section(day.date.formatted(.dateTime.year().month().day().weekday(.wide))) {
            if day.isLogged {
                Text("\(day.mealCount) 餐 · \(day.hasWeight ? "已称重" : "未称重") · \(day.hasExercise ? "已运动" : "未运动")")
                    .font(.subheadline)
            } else {
                Text("这天没有记录").foregroundStyle(.secondary)
            }
            NavigationLink("查看这一天") {
                DayMealList(date: day.date)
                    .navigationTitle(day.date.formatted(.dateTime.month().day().weekday()))
                    .navigationBarTitleDisplayMode(.inline)
            }
        }
    }
}

struct CheckInStreakRow: View {
    @Query private var meals: [Meal]
    @Query private var exercises: [ExerciseSession]
    @Query private var weights: [WeightEntry]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let streak = CheckIn(meals: meals, exercises: exercises, weights: weights,
                                 now: timeline.date).currentStreak
            Group {
                if streak > 0 {
                    Label("连续打卡 \(streak) 天", systemImage: "flame.fill").foregroundStyle(Color.accentColor)
                } else {
                    Text("今天记一笔，开始连续打卡").foregroundStyle(.secondary)
                }
            }
            .font(.footnote)
        }
    }
}
