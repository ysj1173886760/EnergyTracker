import SwiftData
import SwiftUI

/// Entry point for the AI daily summary at the bottom of a day page.
struct DailySummarySection: View {
    let date: Date
    let summary: DailySummary?
    let hasData: Bool

    @Environment(ProfileStore.self) private var profileStore
    @Environment(HealthCoach.self) private var coach

    var body: some View {
        Section {
            if let summary, let content = summary.content {
                NavigationLink {
                    DailySummaryDetail(date: date)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(content.headline).font(.subheadline.weight(.semibold))
                        if !content.tomorrowFocus.isEmpty {
                            Text("明天重点：\(content.tomorrowFocus)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if coach.isSummarizing(date) {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在总结，大约需要 1 分钟…").foregroundStyle(.secondary)
                }
            } else {
                Button {
                    coach.summarize(day: date, profileStore: profileStore)
                } label: {
                    Label(summary == nil ? "生成今日总结和建议" : "重新总结", systemImage: "sparkles")
                }
                .disabled(!hasData)
            }
            if let error = coach.summaryError(date) {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("AI 总结")
        } footer: {
            if !hasData {
                Text("记录饮食或运动后可以生成。")
            } else if let summary, summary.isPartial, Calendar.current.isDateInToday(date) {
                Text("生成于 \(summary.createdAt.formatted(date: .omitted, time: .shortened))，之后有新记录可以重新总结。")
            }
        }
    }
}

struct DailySummaryDetail: View {
    let date: Date

    @Environment(ProfileStore.self) private var profileStore
    @Environment(HealthCoach.self) private var coach
    @Query private var summaries: [DailySummary]

    init(date: Date) {
        self.date = date
        let (start, end) = Calendar.current.dayRange(for: date)
        _summaries = Query(filter: #Predicate<DailySummary> { $0.date >= start && $0.date < end })
    }

    var body: some View {
        List {
            if let summary = summaries.first, let content = summary.content {
                Section {
                    Text(content.headline).font(.title3.bold()).padding(.vertical, 4)
                    if !content.tomorrowFocus.isEmpty {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("明天重点").font(.caption).foregroundStyle(.secondary)
                                Text(content.tomorrowFocus).font(.subheadline.weight(.semibold))
                            }
                        } icon: {
                            Image(systemName: "scope").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                Section {
                    if !content.diet.isEmpty {
                        SuggestionRow(title: "饮食", detail: content.diet, symbol: "fork.knife")
                    }
                    if !content.exercise.isEmpty {
                        SuggestionRow(title: "运动", detail: content.exercise, symbol: "figure.run")
                    }
                    if !content.recentPattern.isEmpty {
                        SuggestionRow(title: "最近 7 天", detail: content.recentPattern, symbol: "calendar")
                    }
                } header: {
                    Text(summary.isPartial ? "今日总结（截至 \(summary.createdAt.formatted(date: .omitted, time: .shortened))）" : "当天总结")
                }
                if !content.suggestions.isEmpty {
                    Section("建议") {
                        ForEach(content.suggestions, id: \.self) { suggestion in
                            SuggestionRow(title: suggestion.title, detail: suggestion.detail, symbol: symbol(for: suggestion.type))
                        }
                    }
                }
            }
            Section {
                if coach.isSummarizing(date) {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在重新总结…")
                    }
                } else {
                    Button {
                        coach.summarize(day: date, profileStore: profileStore)
                    } label: {
                        Label("重新总结", systemImage: "arrow.clockwise")
                    }
                }
                if let error = coach.summaryError(date) {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            } footer: {
                if let summary = summaries.first {
                    Text("\(summary.model) · 生成于 \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))")
                }
            }
        }
        .navigationTitle(date.formatted(.dateTime.month().day().weekday()))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func symbol(for type: String) -> String {
        if type.contains("运动") { return "figure.walk" }
        if type.contains("作息") { return "bed.double" }
        return "fork.knife"
    }
}
