import SwiftData
import SwiftUI

struct AddExerciseView: View {
    let day: Date

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ExerciseAnalyzer.self) private var analyzer

    @State private var text = ""
    @State private var time: Date
    @FocusState private var focused: Bool

    private static let examples = ["跑步 5 公里，用时 32 分钟", "力量训练 1 小时，练腿", "快走 40 分钟", "今天走了 12000 步", "游泳 30 分钟，蛙泳"]

    init(day: Date) {
        self.day = day
        let calendar = Calendar.current
        if calendar.isDateInToday(day) {
            _time = State(initialValue: .now)
        } else {
            _time = State(initialValue: calendar.date(bySettingHour: 18, minute: 0, second: 0, of: day) ?? day)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：跑步 5 公里，用时 32 分钟，心率 150 左右", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                        .focused($focused)
                } footer: {
                    Text("写清楚项目、时长或距离，可以补充强度（配速、心率、重量、体感）。一次可以写多项。")
                }
                Section("示例") {
                    ForEach(Self.examples, id: \.self) { example in
                        Button(example) { text = example }
                    }
                }
                Section {
                    DatePicker("时间", selection: $time, displayedComponents: [.date, .hourAndMinute])
                    LabeledContent("计算用体重", value: String(format: "%.1f kg", weightKg))
                } footer: {
                    Text("AI 只负责判断运动项目、时长和强度（MET），热量按 (MET − 1) × 体重 × 时长 计算，扣除了静息代谢，避免和每日基础消耗重复。")
                }
            }
            .navigationTitle("记录运动")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("估算", action: save)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
    }

    private var weightKg: Double { profileStore.currentWeightKg ?? 70 }

    private func save() {
        let session = ExerciseSession(timestamp: time, text: text.trimmingCharacters(in: .whitespacesAndNewlines), weightKg: weightKg)
        context.insert(session)
        try? context.save()
        analyzer.estimate(session, profile: profileStore.profile)
        dismiss()
    }
}

struct ExerciseRow: View {
    @Environment(ExerciseAnalyzer.self) private var analyzer
    let session: ExerciseSession

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "figure.run")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(session.summaryText).font(.subheadline).lineLimit(2)
                Text(session.timestamp, format: .dateTime.hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            switch session.status {
            case .done:
                VStack(alignment: .trailing, spacing: 0) {
                    Text("-\(session.netKcal.kcalText)").font(.headline).monospacedDigit().foregroundStyle(.green)
                    Text("kcal").font(.caption2).foregroundStyle(.secondary)
                }
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            default:
                if analyzer.isRunning(session) {
                    ProgressView()
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .accessibilityLabel("任务已中断")
                }
            }
        }
    }
}

struct ExerciseDetailView: View {
    @Bindable var session: ExerciseSession

    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ExerciseAnalyzer.self) private var analyzer

    private var busy: Bool { analyzer.isRunning(session) }

    var body: some View {
        Form {
            Section("描述") {
                TextField("运动描述", text: $session.text, axis: .vertical)
                    .lineLimit(2...6)
                DatePicker("时间", selection: $session.timestamp, displayedComponents: [.date, .hourAndMinute])
            }

            Section {
                if busy {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("正在估算…")
                    }
                } else if session.status.isInProgress {
                    Label("任务已中断", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("重试", action: retry)
                }
                if let error = session.errorMessage, session.status == .failed {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
                ForEach(session.sortedItems) { item in
                    ExerciseItemEditor(item: item, weightKg: session.weightKg)
                }
                .onDelete { offsets in
                    let items = session.sortedItems
                    for index in offsets { context.delete(items[index]) }
                    try? context.save()
                }
                if session.status == .done, session.items.isEmpty {
                    Text("没有识别到运动项目").foregroundStyle(.secondary)
                }
            } header: {
                HStack {
                    Text("项目")
                    Spacer()
                    if !session.items.isEmpty {
                        Text("共 \(Int(session.totalMinutes.rounded())) 分钟 · \(session.netKcal.kcalText) kcal").monospacedDigit()
                    }
                }
            } footer: {
                if let note = session.note {
                    Text(note)
                } else if !session.items.isEmpty {
                    Text("可以直接修改时长和 MET，热量会自动重算。")
                }
            }

            Section {
                LabeledContent("计算用体重") {
                    TextField("kg", value: $session.weightKg, format: .number.precision(.fractionLength(0...1)))
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                Button(action: retry) {
                    Label("按描述重新估算", systemImage: "arrow.clockwise")
                }
                .disabled(busy || session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let raw = session.rawResponse {
                Section("调试") {
                    if let model = session.model { LabeledContent("模型", value: model) }
                    DisclosureGroup("原始返回") {
                        Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("运动详情")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
    }

    private func retry() {
        try? context.save()
        analyzer.estimate(session, profile: profileStore.profile)
    }
}

private struct ExerciseItemEditor: View {
    @Bindable var item: ExerciseItem
    let weightKg: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("项目", text: $item.name).font(.subheadline.weight(.semibold))
                if !item.intensity.isEmpty {
                    Text(item.intensity + "强度")
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.green.opacity(0.15), in: Capsule())
                }
                Text("\(item.netKcal(weightKg: weightKg).kcalText) kcal")
                    .font(.subheadline).monospacedDigit()
            }
            HStack(spacing: 16) {
                field("时长", value: $item.durationMin, unit: "分钟")
                field("MET", value: $item.met, unit: "")
            }
            if !item.basis.isEmpty {
                Text(item.basis).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func field(_ label: String, value: Binding<Double>, unit: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .frame(width: 56)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 6))
            if !unit.isEmpty {
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
