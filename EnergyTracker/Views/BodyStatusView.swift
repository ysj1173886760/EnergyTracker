import SwiftData
import SwiftUI

struct BodyStatusView: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(HealthCoach.self) private var coach
    @Query(sort: \BodyMeasurement.date, order: .reverse) private var measurements: [BodyMeasurement]
    @Query(sort: \BodyAssessment.createdAt, order: .reverse) private var assessments: [BodyAssessment]

    @State private var addingMeasurement = false
    @State private var editingProfile = false
    @State private var appliedAssessment: PersistentIdentifier?

    private var profile: UserProfile { profileStore.profile }

    var body: some View {
        Form {
            if !profile.isConfigured || profileStore.currentWeightKg == nil {
                Section {
                    Button { editingProfile = true } label: {
                        Label("先填写身高、年龄和体重，才能计算身体指标", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            currentSection
            if let metrics = profileStore.metrics {
                metricsSection(metrics)
            }
            assessmentSections
            historySection
        }
        .navigationTitle("身体状态")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { addingMeasurement = true } label: { Image(systemName: "plus.circle.fill") }
            }
        }
        .sheet(isPresented: $addingMeasurement) {
            BodyMeasurementSheet()
        }
        .sheet(isPresented: $editingProfile) {
            NavigationStack { ProfileEditorView() }
        }
    }

    // MARK: Current

    private var currentSection: some View {
        Section {
            if let weight = profileStore.currentWeightKg {
                LabeledContent("体重（趋势）", value: String(format: "%.1f kg", weight))
            }
            let body = profileStore.body
            if let v = body.bodyFatPct { LabeledContent("体脂率", value: String(format: "%.1f%%", v)) }
            if let v = body.waistCm { LabeledContent("腰围", value: String(format: "%.1f cm", v)) }
            if let v = body.muscleKg { LabeledContent("肌肉量", value: String(format: "%.1f kg", v)) }
            if let v = body.scaleBMR { LabeledContent("体脂秤基础代谢", value: "\(Int(v.rounded())) kcal") }
            Button { addingMeasurement = true } label: {
                Label("记录身体数据", systemImage: "ruler")
            }
        } header: {
            Text("最新数据")
        } footer: {
            Text("体脂率、腰围等可以从体脂秤或软尺获得，有就填，没有可以留空。每项显示最近一次记录。")
        }
    }

    // MARK: Metrics

    private func metricsSection(_ metrics: BodyMetrics) -> some View {
        Section {
            LabeledContent("BMI", value: String(format: "%.1f（%@）", metrics.bmi, Self.bmiCategory(metrics.bmi)))
            if let fat = metrics.fatMassKg, let lean = metrics.leanMassKg {
                LabeledContent("脂肪量", value: String(format: "%.1f kg", fat))
                LabeledContent("去脂体重", value: String(format: "%.1f kg", lean))
            }
            bmrRow("基础代谢 · Mifflin-St Jeor", metrics.bmrMifflin, source: .mifflin)
            if let v = metrics.bmrKatch { bmrRow("基础代谢 · Katch-McArdle", v, source: .katch) }
            if let v = metrics.bmrScale { bmrRow("基础代谢 · 体脂秤", v, source: .scale) }
            if let target = metrics.targetWeightFromBodyFat, let pct = profile.targetBodyFatPct {
                LabeledContent("体脂 \(pct.formatted())% 时体重", value: String(format: "%.1f kg", target))
            }
        } header: {
            Text("计算指标")
        } footer: {
            Text("BMI 按中国标准：18.5–23.9 正常，24–27.9 超重，≥28 肥胖。目标体重按保持去脂体重不变估算。勾选的基础代谢用于计算每日目标，可在个人资料中切换。")
        }
    }

    private func bmrRow(_ label: String, _ value: Double, source: UserProfile.BMRSource) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text("\(Int(value.rounded())) kcal").monospacedDigit()
                if profileStore.goal.bmrSource == source {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                }
            }
        } label: {
            Text(label)
        }
    }

    private static func bmiCategory(_ bmi: Double) -> String {
        switch bmi {
        case ..<18.5: "偏瘦"
        case ..<24: "正常"
        case ..<28: "超重"
        default: "肥胖"
        }
    }

    // MARK: Assessment

    @ViewBuilder
    private var assessmentSections: some View {
        if let assessment = assessments.first, let content = assessment.content {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(content.headline).font(.title3.bold())
                    Text(content.overall).font(.subheadline)
                }
                .padding(.vertical, 4)
                if !content.bodyComposition.isEmpty {
                    SuggestionRow(title: "体成分", detail: content.bodyComposition, symbol: "figure.stand")
                }
                if !content.metabolism.isEmpty {
                    SuggestionRow(title: "基础代谢", detail: content.metabolism, symbol: "flame")
                }
                if !content.goalFeasibility.isEmpty {
                    SuggestionRow(title: "目标可行性", detail: content.goalFeasibility, symbol: "flag.checkered")
                }
            } header: {
                Label("AI 评估", systemImage: "sparkles")
            }

            recommendationSection(content, assessment: assessment)

            if !content.risks.isEmpty {
                Section("风险提醒") {
                    ForEach(content.risks, id: \.self) {
                        BulletRow(text: $0, symbol: "exclamationmark.circle.fill", color: .orange)
                    }
                }
            }
            if !content.actions.isEmpty {
                Section("行动建议") {
                    ForEach(content.actions, id: \.self) {
                        SuggestionRow(title: $0.title, detail: $0.detail, symbol: "checklist")
                    }
                }
            }
        }

        Section {
            if coach.isAssessing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("正在评估，大约需要 1–2 分钟…")
                }
            } else {
                Button {
                    coach.assess(profileStore: profileStore)
                } label: {
                    Label(assessments.isEmpty ? "生成 AI 身体评估" : "重新评估", systemImage: "sparkles")
                }
                .disabled(!profile.isConfigured || profileStore.currentWeightKg == nil)
            }
            if let error = coach.assessmentError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } footer: {
            if let assessment = assessments.first {
                Text("\(assessment.model) · 生成于 \(assessment.createdAt.formatted(date: .abbreviated, time: .shortened))。评估仅供参考，不能替代医生诊断。")
            } else {
                Text("AI 会结合身体数据、体重趋势和最近两周的饮食运动，评估当前状态和目标是否合理。")
            }
        }
    }

    @ViewBuilder
    private func recommendationSection(_ content: AssessmentContent, assessment: BodyAssessment) -> some View {
        let hasValues = content.targetWeightKg != nil || content.targetBodyFatPct != nil || content.dailyKcal != nil
            || content.proteinG != nil || content.weeklyLossKg != nil
        if hasValues {
            Section {
                if let v = content.targetWeightKg { LabeledContent("目标体重", value: String(format: "%.1f kg", v)) }
                if let v = content.targetBodyFatPct { LabeledContent("目标体脂率", value: String(format: "%.1f%%", v)) }
                if let v = content.weeklyLossKg { LabeledContent("每周减重", value: "\(v.formatted()) kg") }
                if let v = content.dailyKcal { LabeledContent("每日热量", value: "\(v) kcal") }
                if let v = content.proteinG { LabeledContent("每日蛋白质", value: "\(v) g") }
                if !content.recommendationReason.isEmpty {
                    Text(content.recommendationReason).font(.subheadline).foregroundStyle(.secondary)
                }
                let applied = appliedAssessment == assessment.persistentModelID
                Button(applied ? "已采用" : "采用建议目标") {
                    apply(content)
                    appliedAssessment = assessment.persistentModelID
                }
                .disabled(applied)
            } header: {
                Text("建议目标")
            } footer: {
                Text("采用后会更新个人资料里的目标体重、体脂率、减重速度和蛋白质；建议热量和自动计算相差超过 50 kcal 时会设为手动目标。")
            }
        }
    }

    private func apply(_ content: AssessmentContent) {
        var updated = profile
        if let v = content.targetWeightKg { updated.goalWeightKg = (v * 10).rounded() / 10 }
        if let v = content.targetBodyFatPct { updated.targetBodyFatPct = (v * 10).rounded() / 10 }
        if let v = content.weeklyLossKg {
            updated.weeklyLossKg = UserProfile.weeklyLossOptions.min { abs($0 - v) < abs($1 - v) } ?? updated.weeklyLossKg
        }
        if let protein = content.proteinG {
            let reference = [updated.goalWeightKg, profileStore.currentWeightKg].compactMap { $0 }.min()
            if let reference, reference > 0 {
                updated.proteinPerKg = min(2.4, max(1.0, (Double(protein) / reference * 10).rounded() / 10))
            }
        }
        if let kcal = content.dailyKcal {
            updated.manualKcalTarget = nil
            let auto = GoalCalculator.goal(profile: updated, weightKg: profileStore.currentWeightKg, body: profileStore.body).kcal
            if abs(auto - kcal) > 50 {
                updated.manualKcalTarget = Int((Double(kcal) / 50).rounded()) * 50
            }
        }
        profileStore.profile = updated
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        if !measurements.isEmpty {
            Section("测量记录") {
                ForEach(measurements) { m in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.date, format: .dateTime.year().month().day()).font(.subheadline.weight(.semibold))
                        Text(Self.describe(m)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(measurements[index]) }
                    try? context.save()
                    profileStore.refresh(in: context)
                }
            }
        }
    }

    private static func describe(_ m: BodyMeasurement) -> String {
        var parts: [String] = []
        if let v = m.weightKg { parts.append(String(format: "体重 %.1f kg", v)) }
        if let v = m.bodyFatPct { parts.append(String(format: "体脂 %.1f%%", v)) }
        if let v = m.waistCm { parts.append(String(format: "腰围 %.1f cm", v)) }
        if let v = m.muscleKg { parts.append(String(format: "肌肉 %.1f kg", v)) }
        if let v = m.scaleBMR { parts.append("基础代谢 \(Int(v.rounded()))") }
        if !m.note.isEmpty { parts.append(m.note) }
        return parts.joined(separator: " · ")
    }
}

struct BodyMeasurementSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore

    @State private var date = Date.now
    @State private var weightKg: Double?
    @State private var bodyFatPct: Double?
    @State private var waistCm: Double?
    @State private var muscleKg: Double?
    @State private var scaleBMR: Double?
    @State private var note = ""

    private var hasValue: Bool {
        weightKg != nil || bodyFatPct != nil || waistCm != nil || muscleKg != nil || scaleBMR != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                    field("体重", value: $weightKg, unit: "kg")
                    field("体脂率", value: $bodyFatPct, unit: "%")
                    field("腰围", value: $waistCm, unit: "cm")
                    field("肌肉量", value: $muscleKg, unit: "kg")
                    field("基础代谢", value: $scaleBMR, unit: "kcal")
                } footer: {
                    Text("都是可选项。体重会同步到体重记录。腰围在肚脐水平、呼气末测量。家用体脂秤误差较大，固定时间（如晨起空腹）测量，看趋势更可靠。")
                }
                Section("备注") {
                    TextField("例如：Keep 体脂秤 / 健身房 InBody", text: $note)
                }
            }
            .navigationTitle("记录身体数据")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(!hasValue)
                }
            }
        }
    }

    private func field(_ label: String, value: Binding<Double?>, unit: String) -> some View {
        HStack {
            Text(label)
            TextField("-", value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
        }
    }

    private func save() {
        let measurement = BodyMeasurement(date: date)
        measurement.weightKg = weightKg
        measurement.bodyFatPct = bodyFatPct
        measurement.waistCm = waistCm
        measurement.muscleKg = muscleKg
        measurement.scaleBMR = scaleBMR
        measurement.note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        context.insert(measurement)
        if let weightKg, (25...300).contains(weightKg) {
            WeightEntry.upsert(kg: weightKg, on: date, in: context)
        }
        try? context.save()
        profileStore.refresh(in: context)
        dismiss()
    }
}
