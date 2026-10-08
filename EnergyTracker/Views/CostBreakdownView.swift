import Charts
import SwiftData
import SwiftUI

struct CostBreakdownView: View {
    @Query(sort: \UsageRecord.date, order: .reverse) private var records: [UsageRecord]
    @Environment(UsageMonitor.self) private var monitor
    @State private var period: CostPeriod = .week

    private var entries: [UsageEntry] { CostSummary.filter(records.map(\.entry), period: period) }
    private var total: CostSummary.Group { .init(id: "total", entries: entries) }
    private var comparison: Double? {
        guard let updated = monitor.updatedAt, Calendar.current.isDateInToday(updated) else { return nil }
        switch period {
        case .today: return monitor.keyInfo?.usageDaily
        case .week: return monitor.keyInfo?.usageWeekly
        case .month: return monitor.keyInfo?.usageMonthly
        case .all: return nil
        }
    }

    var body: some View {
        List {
            Section {
                Picker("期间", selection: $period) {
                    ForEach(CostPeriod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            if entries.isEmpty {
                ContentUnavailableView("还没有调用记录", systemImage: "chart.bar")
            } else {
                Section("本期总计") {
                    Text(CostSummary.money(total.cost)).font(.largeTitle.bold()).foregroundStyle(.tint)
                    HStack {
                        metric("调用次数", "\(total.count)")
                        Spacer()
                        metric("失败次数", "\(entries.filter { !$0.succeeded }.count)")
                        Spacer()
                        metric("平均每次", CostSummary.money(total.average))
                    }
                    if entries.contains(where: { $0.cost == nil }) {
                        Text("部分响应未提供费用，总计仅包含已知金额。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if period != .today {
                    Section("每日花费 · 美元") {
                        Chart(dailyCosts) { point in
                            BarMark(x: .value("日期", point.date, unit: .day), y: .value("费用", point.cost))
                                .foregroundStyle(by: .value("功能", point.title))
                        }
                        .chartForegroundStyleScale(domain: AIFeature.allCases.map(\.title), range: featureColors)
                        .chartLegend(position: .bottom, spacing: 8)
                        .frame(height: 240)
                    }
                }
                Section("按功能") {
                    ForEach(CostSummary.groups(entries, by: \.feature)) { group in
                        NavigationLink {
                            FeatureCostView(group: group)
                        } label: {
                            HStack {
                                Label(AIFeature(rawValue: group.id)?.title ?? group.id,
                                      systemImage: AIFeature(rawValue: group.id)?.symbol ?? "sparkles")
                                Spacer()
                                VStack(alignment: .trailing) {
                                    Text(CostSummary.money(group.cost))
                                    Text("\(group.count) 次 · \(percentage(group.cost))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                modelCosts(entries)
                Section("单次成本参考") {
                    if let average = CostSummary.mealAverage(entries) {
                        LabeledContent("拍一张照片 / 每餐", value: CostSummary.money(average))
                    }
                    ForEach([AIFeature.dailySummary, .chat], id: \.self) { feature in
                        let subset = entries.filter { $0.feature == feature.rawValue }
                        if !subset.isEmpty {
                            let group = CostSummary.Group(id: feature.rawValue, entries: subset)
                            LabeledContent(feature.title, value: CostSummary.money(group.average))
                        }
                    }
                    Text("按本期已记录调用计算；每餐合并识别、热量估算及补充修正，包含重试费用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                if let comparison {
                    LabeledContent(period == .today ? "OpenRouter 记录" : "OpenRouter 记录（近似）",
                                   value: CostSummary.money(comparison))
                    Text("Key 级别统计，可能包含其他设备或应用的调用；7 天与本周、30 天与本月仅作近似对照。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("本地统计只包含 App 收到响应的调用。如果 App 在后台被系统结束，少量调用可能没有记录，因此可能略低于 OpenRouter 后台的数字。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("费用明细")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.bold())
        }
    }

    private func percentage(_ cost: Double) -> String {
        String(format: "%.1f%%", total.cost == 0 ? 0 : cost / total.cost * 100)
    }

    private let featureColors: [Color] = [.blue, .orange, .green, .red, .pink, .yellow, .purple, .teal, .indigo, .brown]

    private struct DailyCost: Identifiable {
        var date: Date
        var feature: String
        var cost: Double
        var id: String { "\(date.timeIntervalSince1970)-\(feature)" }
        var title: String { AIFeature(rawValue: feature)?.title ?? feature }
    }

    private var dailyCosts: [DailyCost] {
        let days = Dictionary(grouping: entries, by: { Calendar.current.startOfDay(for: $0.date) })
        var result: [DailyCost] = []
        for (day, values) in days {
            for group in CostSummary.groups(values, by: \.feature) {
                result.append(DailyCost(date: day, feature: group.id, cost: group.cost))
            }
        }
        return result.sorted {
            if $0.date == $1.date { return $0.feature < $1.feature }
            return $0.date < $1.date
        }
    }
}

private struct FeatureCostView: View {
    let group: CostSummary.Group

    var body: some View {
        List {
            modelCosts(group.entries)
            Section("最近 20 条调用") {
                ForEach(Array(group.entries.sorted { $0.date > $1.date }.prefix(20).enumerated()), id: \.offset) {
                    _, entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                            Spacer()
                            Text(entry.succeeded ? "成功" : "失败")
                                .foregroundStyle(entry.succeeded ? .green : .red)
                        }
                        Text(entry.model).font(.caption.monospaced())
                        Text("输入 \(entry.promptTokens.map(String.init) ?? "—") · "
                             + "输出 \(entry.completionTokens.map(String.init) ?? "—") tokens")
                            .font(.caption).foregroundStyle(.secondary)
                        if let reasoning = entry.reasoningTokens {
                            Text("其中推理 \(reasoning) tokens").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(entry.cost.map(CostSummary.money) ?? "费用未提供")
                        if let error = entry.errorSummary {
                            Text(error).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(AIFeature(rawValue: group.id)?.title ?? group.id)
    }
}

private func modelCosts(_ entries: [UsageEntry]) -> some View {
    Section("按模型") {
        ForEach(CostSummary.groups(entries, by: \.model)) { group in
            VStack(alignment: .leading, spacing: 6) {
                Text(group.id).font(.caption.monospaced())
                HStack {
                    Text("\(group.count) 次 · \(group.tokens) tokens")
                    Spacer()
                    Text(CostSummary.money(group.cost))
                }.font(.subheadline)
                Text("平均每次 \(CostSummary.money(group.average))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
