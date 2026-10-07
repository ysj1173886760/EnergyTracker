import Charts
import SwiftData
import SwiftUI

struct ReviewView: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(WeeklyReviewer.self) private var reviewer
    @Query(sort: \Meal.timestamp) private var meals: [Meal]
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query(sort: \ExerciseSession.timestamp) private var exercises: [ExerciseSession]
    @Query(sort: \WeeklyReview.weekStart, order: .reverse) private var reviews: [WeeklyReview]

    private var calendar: Calendar { .mondayFirst }

    private var weekStarts: [Date] {
        let current = calendar.weekStart(for: .now)
        let earliest = [meals.first?.timestamp, weights.first?.date].compactMap { $0 }.min() ?? .now
        let first = calendar.weekStart(for: earliest)
        var result: [Date] = []
        var week = current
        while week >= first {
            result.append(week)
            week = calendar.date(byAdding: .day, value: -7, to: week)!
        }
        return result
    }

    private func stats(for weekStart: Date) -> WeeklyStats {
        WeeklyStats(weekStart: weekStart, meals: meals, weights: weights, goal: profileStore.goal, exercises: exercises)
    }

    private func review(for weekStart: Date) -> WeeklyReview? {
        reviews.first { $0.weekStart == weekStart }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(weekStarts, id: \.self) { weekStart in
                    let stats = stats(for: weekStart)
                    NavigationLink {
                        WeekReviewDetail(weekStart: weekStart)
                    } label: {
                        WeekRow(stats: stats, review: review(for: weekStart),
                                isGenerating: reviewer.isGenerating(weekStart))
                    }
                }
            }
            .overlay {
                if meals.isEmpty, weights.isEmpty {
                    ContentUnavailableView("还没有数据", systemImage: "sparkles",
                                           description: Text("记录饮食和体重后，每周一会自动生成上周的复盘和建议。"))
                }
            }
            .navigationTitle("每周复盘")
            .task { autoGenerateLastWeek() }
        }
    }

    /// Generates last week's review once, the first time this page is opened after the week ends.
    private func autoGenerateLastWeek() {
        guard KeychainStore.apiKey != nil else { return }
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: calendar.weekStart(for: .now))!
        guard review(for: lastWeek) == nil, !reviewer.isGenerating(lastWeek) else { return }
        let stats = stats(for: lastWeek)
        guard !stats.loggedDays.isEmpty else { return }
        let previousWeek = calendar.date(byAdding: .day, value: -7, to: lastWeek)!
        reviewer.generate(stats, profile: profileStore.profile, previous: review(for: previousWeek), context: context)
    }
}

private struct WeekRow: View {
    let stats: WeeklyStats
    let review: WeeklyReview?
    let isGenerating: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(stats.title).font(.subheadline.weight(.semibold))
                if stats.isPartial {
                    Text("本周").font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                if isGenerating { ProgressView() }
            }
            Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if let headline = review?.content?.headline, !headline.isEmpty {
                Label(headline, systemImage: "sparkles").font(.footnote).foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        var parts = ["记录 \(stats.loggedDays.count)/\(stats.days.count) 天"]
        if let avg = stats.avgKcal { parts.append("日均 \(avg.kcalText) kcal") }
        if let change = stats.trendChangeKg { parts.append(String(format: "体重 %+.1f kg", change)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Detail

struct WeekReviewDetail: View {
    let weekStart: Date

    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(WeeklyReviewer.self) private var reviewer
    @Query(sort: \Meal.timestamp) private var meals: [Meal]
    @Query(sort: \WeightEntry.date) private var weights: [WeightEntry]
    @Query(sort: \ExerciseSession.timestamp) private var exercises: [ExerciseSession]
    @Query private var reviews: [WeeklyReview]
    @State private var appliedTarget = false

    private var stats: WeeklyStats {
        WeeklyStats(weekStart: weekStart, meals: meals, weights: weights, goal: profileStore.goal, exercises: exercises)
    }

    private var review: WeeklyReview? { reviews.first { $0.weekStart == weekStart } }

    private var previousReview: WeeklyReview? {
        let previous = Calendar.mondayFirst.date(byAdding: .day, value: -7, to: weekStart)!
        return reviews.first { $0.weekStart == previous }
    }

    var body: some View {
        let stats = stats
        List {
            statsSection(stats)
            if let review, let content = review.content {
                reviewSections(content, review: review)
            }
            generateSection(stats)
        }
        .navigationTitle(stats.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Stats

    @ViewBuilder
    private func statsSection(_ stats: WeeklyStats) -> some View {
        Section {
            Chart {
                ForEach(stats.days) { day in
                    BarMark(x: .value("日期", day.date, unit: .day), y: .value("热量", day.kcal))
                        .foregroundStyle(day.kcal > Double(stats.goal.kcal) ? Color.red.gradient : Color.accentColor.gradient)
                }
                RuleMark(y: .value("目标", stats.goal.kcal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundStyle(.secondary)
            }
            .chartXScale(domain: weekStart...stats.weekEnd)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) {
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .frame(height: 140)
            .padding(.vertical, 6)

            LabeledContent("记录天数", value: "\(stats.loggedDays.count) / \(stats.days.count) 天")
            if let avg = stats.avgKcal {
                LabeledContent("日均摄入", value: "\(avg.kcalText) kcal（目标 \(stats.goal.kcal)）")
                LabeledContent("超出目标", value: "\(stats.daysOverTarget) 天")
            }
            if let weekday = stats.weekdayAvgKcal, let weekend = stats.weekendAvgKcal {
                LabeledContent("工作日 / 周末", value: "\(weekday.kcalText) / \(weekend.kcalText) kcal")
            }
            if let protein = stats.avgProtein {
                let target = stats.goal.proteinG.map { "（目标 \($0)）" } ?? ""
                LabeledContent("日均蛋白质", value: "\(protein.gramsText) g\(target)")
            }
            if stats.exerciseDays > 0 {
                LabeledContent("运动", value: "\(stats.exerciseDays) 天 · 共 \(stats.totalExerciseKcal.kcalText) kcal")
            }
            if let change = stats.trendChangeKg, let end = stats.trendEndKg {
                LabeledContent("趋势体重", value: String(format: "%.1f kg（%+.1f）", end, change))
            } else if stats.weights.isEmpty {
                LabeledContent("趋势体重", value: "本周无记录")
            }
        } header: {
            Text("本周数据")
        }
    }

    // MARK: Review

    @ViewBuilder
    private func reviewSections(_ content: ReviewContent, review: WeeklyReview) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text(content.headline).font(.title3.bold())
                Text(content.summary).font(.subheadline)
            }
            .padding(.vertical, 4)
            if !content.focus.isEmpty {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("下周重点").font(.caption).foregroundStyle(.secondary)
                        Text(content.focus).font(.subheadline.weight(.semibold))
                    }
                } icon: {
                    Image(systemName: "scope").foregroundStyle(Color.accentColor)
                }
            }
        } header: {
            Label(review.isPartial ? "AI 复盘（阶段性）" : "AI 复盘", systemImage: "sparkles")
        }

        if !content.wins.isEmpty {
            Section("做得好的") {
                ForEach(content.wins, id: \.self) { BulletRow(text: $0, symbol: "checkmark.circle.fill", color: .green) }
            }
        }
        if !content.issues.isEmpty {
            Section("需要注意") {
                ForEach(content.issues, id: \.self) { BulletRow(text: $0, symbol: "exclamationmark.circle.fill", color: .orange) }
            }
        }
        if !content.dietSuggestions.isEmpty {
            Section("饮食建议") {
                ForEach(content.dietSuggestions, id: \.self) { SuggestionRow(title: $0.title, detail: $0.detail, symbol: "fork.knife") }
            }
        }
        if !content.exerciseSuggestions.isEmpty {
            Section("运动建议") {
                ForEach(content.exerciseSuggestions, id: \.self) { SuggestionRow(title: $0.title, detail: $0.detail, symbol: "figure.walk") }
            }
        }

        Section {
            if let kcal = content.targetKcal {
                LabeledContent("建议热量目标", value: "\(kcal) kcal")
            }
            if let protein = content.targetProteinG {
                LabeledContent("建议蛋白质目标", value: "\(protein) g")
            }
            if !content.targetReason.isEmpty {
                Text(content.targetReason).font(.subheadline)
            }
            if let kcal = content.targetKcal, kcal != profileStore.goal.kcal {
                Button(appliedTarget ? "已采用" : "采用建议：每日 \(kcal) kcal") {
                    profileStore.profile.manualKcalTarget = kcal
                    appliedTarget = true
                }
                .disabled(appliedTarget)
            }
        } header: {
            Text("目标调整")
        } footer: {
            if content.targetKcal != nil {
                Text("采用后会改为手动热量目标，可以在「我的 → 个人资料与目标」中改回自动计算。")
            }
        }
    }

    // MARK: Generate

    @ViewBuilder
    private func generateSection(_ stats: WeeklyStats) -> some View {
        Section {
            if reviewer.isGenerating(weekStart) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在生成复盘，大约需要 1 分钟…")
                }
            } else {
                Button {
                    reviewer.generate(stats, profile: profileStore.profile, previous: previousReview, context: context)
                } label: {
                    Label(review == nil ? "生成 AI 复盘" : "重新生成", systemImage: "sparkles")
                }
                .disabled(!stats.hasData)
            }
            if let error = reviewer.errors[weekStart] {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            if let review {
                Text("\(review.model) · 生成于 \(review.createdAt.formatted(date: .abbreviated, time: .shortened))")
            } else if stats.isPartial {
                Text("这周还没结束，可以先生成阶段性复盘，针对剩下几天给建议。")
            } else if !stats.hasData {
                Text("这周没有记录。")
            }
        }
    }
}

struct BulletRow: View {
    let text: String
    let symbol: String
    let color: Color

    var body: some View {
        Label {
            Text(text).font(.subheadline)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
    }
}

struct SuggestionRow: View {
    let title: String
    let detail: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.subheadline.weight(.semibold))
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}
