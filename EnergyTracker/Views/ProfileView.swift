import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct ProfileView: View {
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        NavigationStack {
            Form {
                GoalSummarySection(goal: profileStore.goal, profile: profileStore.profile,
                    weightKg: profileStore.trendWeightKg ?? profileStore.latestWeightKg,
                    clearCalibration: { profileStore.profile.kcalAdjustment = nil })
                TargetCalibrationSection(showsProgress: true)

                Section {
                    NavigationLink { BodyStatusView() } label: {
                        Label("身体状态与 AI 评估", systemImage: "figure.stand")
                    }
                    NavigationLink { ProfileEditorView() } label: {
                        Label("个人资料与目标", systemImage: "person.text.rectangle")
                    }
                    NavigationLink { RemindersView() } label: {
                        Label("每日提醒", systemImage: "bell")
                    }
                    NavigationLink { ModelSettingsView() } label: {
                        Label("模型与 API Key", systemImage: "cpu")
                    }
                    NavigationLink {
                        HealthSettingsView()
                    } label: {
                        Label("Apple 健康", systemImage: "heart.fill")
                    }
                    NavigationLink { BackupView() } label: {
                        Label("数据备份", systemImage: "externaldrive")
                    }
                }
            }
            .navigationTitle("我的")
        }
    }
}

struct GoalSummarySection: View {
    let goal: NutritionGoal
    let profile: UserProfile
    let weightKg: Double?
    var clearCalibration: (() -> Void)?

    var body: some View {
        Section {
            if let adjustment = profile.kcalAdjustment, adjustment != 0 {
                Text("已按实测校准 \(adjustment >= 0 ? "+" : "")\(adjustment) kcal")
                if let clearCalibration { Button("清除校准", action: clearCalibration) }
            }
            LabeledContent("每日热量", value: "\(goal.kcal) kcal")
            if let protein = goal.proteinG {
                LabeledContent("每日蛋白质", value: "\(protein) g")
            }
            if let bmr = goal.bmr, let tdee = goal.tdee {
                LabeledContent("基础代谢", value: "\(bmr) kcal")
                LabeledContent("每日总消耗（估算）", value: "\(tdee) kcal")
                LabeledContent("每日缺口", value: "\(tdee - goal.kcal) kcal")
            }
            ForEach(goal.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        } header: {
            Text("当前目标")
        } footer: {
            if !profile.isConfigured {
                Text("填写个人资料后会根据身高、体重、年龄和活动水平自动计算。")
            } else if weightKg == nil {
                Text("还没有体重记录，记录一次体重后才能计算。")
            } else if goal.isManual {
                Text("当前使用手动设置的热量目标。")
            } else {
                Text("基础代谢按\(goal.bmrSource?.title ?? "公式")估算，会随趋势体重变化自动更新。估算有 ±10–20% 误差，以实际体重变化为准。")
            }
        }
    }
}

// MARK: - Profile editor

struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore

    @State private var draft = UserProfile()
    @State private var weightKg: Double?
    @State private var useManualTarget = false
    @State private var loaded = false

    private var currentYear: Int { Calendar.current.component(.year, from: .now) }

    private var preview: NutritionGoal {
        var profile = draft
        profile.isConfigured = true
        profile.manualKcalTarget = useManualTarget ? (draft.manualKcalTarget ?? 1800) : nil
        return GoalCalculator.goal(profile: profile, weightKg: weightKg, body: profileStore.body)
    }

    private var canSave: Bool {
        guard let weightKg else { return false }
        return (25...300).contains(weightKg) && (100...250).contains(draft.heightCm)
    }

    var body: some View {
        Form {
            Section("身体数据") {
                Picker("性别", selection: $draft.sex) {
                    ForEach(UserProfile.Sex.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("出生年份", selection: $draft.birthYear) {
                    ForEach((currentYear - 90)...(currentYear - 12), id: \.self) { Text(String($0)).tag($0) }
                }
                numberField("身高", value: Binding(nonOptional: $draft.heightCm), unit: "cm")
                numberField("当前体重", value: $weightKg, unit: "kg")
            }

            Section {
                Picker("活动水平", selection: $draft.activity) {
                    ForEach(UserProfile.Activity.allCases) { activity in
                        VStack(alignment: .leading) {
                            Text(activity.title)
                            Text(activity.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(activity)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } header: {
                Text("日常活动水平")
            } footer: {
                Text("拿不准就选低一档，大多数人会高估自己的活动量。")
            }

            Section {
                numberField("目标体重", value: $draft.goalWeightKg, unit: "kg")
                Picker("每周减重", selection: $draft.weeklyLossKg) {
                    ForEach(UserProfile.weeklyLossOptions, id: \.self) { Text("\($0.formatted()) kg").tag($0) }
                }
                numberField("目标体脂率", value: $draft.targetBodyFatPct, unit: "%")
                Stepper(value: $draft.proteinPerKg, in: 1.0...2.4, step: 0.1) {
                    LabeledContent("蛋白质", value: String(format: "%.1f g / kg", draft.proteinPerKg))
                }
            } header: {
                Text("目标")
            } footer: {
                Text("每周减 0.5 kg 约需每天 550 kcal 缺口。蛋白质按目标体重计算，减脂期建议 1.6 g/kg 左右，有助于保住肌肉。")
            }

            Section {
                Picker("基础代谢算法", selection: $draft.bmrSource) {
                    ForEach(UserProfile.BMRSource.allCases) { Text($0.title).tag($0) }
                }
                Picker("运动消耗加回", selection: $draft.eatBackRatio) {
                    ForEach(UserProfile.eatBackOptions, id: \.self) { ratio in
                        Text(ratio == 0 ? "不加回" : "\(Int(ratio * 100))%").tag(ratio)
                    }
                }
            } header: {
                Text("计算方式")
            } footer: {
                Text("有体脂率时可以用 Katch-McArdle 公式，有体脂秤的基础代谢读数时可以直接用；缺少对应数据会自动回落到 Mifflin-St Jeor。运动消耗估算偏高很常见，建议只加回 50% 左右。")
            }

            Section {
                Toggle("手动设置热量目标", isOn: $useManualTarget)
                if useManualTarget {
                    Stepper(value: Binding($draft.manualKcalTarget, default: 1800), in: 1000...4000, step: 50) {
                        LabeledContent("热量目标", value: "\(draft.manualKcalTarget ?? 1800) kcal")
                    }
                }
            }

            GoalSummarySection(goal: preview, profile: { var p = draft; p.isConfigured = true; return p }(), weightKg: weightKg)
        }
        .navigationTitle("个人资料与目标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存", action: save).disabled(!canSave)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            draft = profileStore.profile
            weightKg = profileStore.latestWeightKg
            useManualTarget = draft.manualKcalTarget != nil
        }
    }

    private func numberField(_ label: String, value: Binding<Double?>, unit: String) -> some View {
        HStack {
            Text(label)
            TextField("-", value: value, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary).frame(width: 28, alignment: .leading)
        }
    }

    private func save() {
        guard let weightKg else { return }
        var profile = draft
        profile.isConfigured = true
        profile.manualKcalTarget = useManualTarget ? (draft.manualKcalTarget ?? 1800) : nil
        profileStore.profile = profile

        if profileStore.latestWeightKg.map({ abs($0 - weightKg) >= 0.05 }) ?? true {
            WeightEntry.upsert(kg: weightKg, on: .now, in: context)
        }
        profileStore.refresh(in: context)
        dismiss()
    }
}

private extension Binding {
    init(_ source: Binding<Value?>, default defaultValue: Value) {
        self.init(get: { source.wrappedValue ?? defaultValue }, set: { source.wrappedValue = $0 })
    }

    /// Clearing the field keeps the previous value instead of writing nil.
    init(nonOptional source: Binding<Double>) where Value == Double? {
        self.init(get: { source.wrappedValue }, set: { if let value = $0 { source.wrappedValue = value } })
    }
}

// MARK: - Model settings

struct ModelSettingsView: View {
    @Environment(UsageMonitor.self) private var usageMonitor
    @AppStorage(AppSettings.Key.visionModel) private var visionModel = AppSettings.defaultVisionModel
    @AppStorage(AppSettings.Key.nutritionModel) private var nutritionModel = AppSettings.defaultNutritionModel
    @AppStorage(AppSettings.Key.nutritionReasoning) private var nutritionReasoning = true
    @AppStorage(AppSettings.Key.reviewModel) private var reviewModel = AppSettings.defaultReviewModel
    @AppStorage(AppSettings.Key.exerciseModel) private var exerciseModel = AppSettings.defaultExerciseModel

    @State private var apiKey = KeychainStore.apiKey ?? ""
    @State private var keyStatus: String?
    @State private var checkingKey = false

    var body: some View {
        Form {
            Section {
                SecureField("sk-or-...", text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: apiKey) { _, value in
                        KeychainStore.apiKey = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        keyStatus = nil
                        usageMonitor.resetForKeyChange()
                    }
                Button {
                    Task { await checkKey() }
                } label: {
                    HStack {
                        Text("测试连接")
                        if checkingKey { Spacer(); ProgressView() }
                    }
                }
                .disabled(apiKey.isEmpty || checkingKey)
            } header: {
                Text("OpenRouter API Key")
            } footer: {
                Text(keyStatus ?? "Key 保存在本机钥匙串中。建议为这个 App 单独创建一个设置了消费上限的 Key。")
            }

            Section("用量") {
                NavigationLink("费用明细") { CostBreakdownView() }
                LabeledContent("账户余额", value: money(usageMonitor.accountCredits?.balance))
                LabeledContent("Key 剩余额度", value: keyRemainingText)
                LabeledContent("今日花费", value: money(usageMonitor.keyInfo?.usageDaily))
                LabeledContent("本周花费", value: money(usageMonitor.keyInfo?.usageWeekly))
                LabeledContent("本月花费", value: money(usageMonitor.keyInfo?.usageMonthly))
                Button(usageMonitor.isRefreshing ? "刷新中…" : "刷新用量") { Task { await usageMonitor.refresh() } }
                    .disabled(usageMonitor.isRefreshing || apiKey.isEmpty)
                LabeledContent(
                    "更新时间", value: usageMonitor.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "尚未更新")
                if usageMonitor.accountCredits == nil {
                    Text("账户余额暂不可用，部分 Key 无权读取；仍可查看 Key 用量。").font(.footnote).foregroundStyle(.secondary)
                }
                if let error = usageMonitor.error { Text(error).font(.footnote).foregroundStyle(.orange) }
            }
            Section {
                ModelField(title: "识别模型（看图）", value: $visionModel, suggestions: AppSettings.visionModelSuggestions)
                ModelField(title: "热量模型（文本）", value: $nutritionModel, suggestions: AppSettings.nutritionModelSuggestions)
                Toggle("热量估算时深度思考", isOn: $nutritionReasoning)
                ModelField(title: "运动模型", value: $exerciseModel, suggestions: AppSettings.exerciseModelSuggestions)
                ModelField(title: "教练模型", value: $reviewModel, suggestions: AppSettings.reviewModelSuggestions)
            } header: {
                Text("模型")
            } footer: {
                Text("识别模型负责认出食物、估算重量；热量模型根据描述给出每 100 克的营养数值；运动模型解析运动项目和强度；教练模型负责身体评估、每日总结和每周复盘。填写 OpenRouter 上的模型 ID。深度思考结果更稳定，但会多等 5–20 秒。")
            }
        }
        .navigationTitle("模型与 API Key")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var keyRemainingText: String {
        if let info = usageMonitor.keyInfo, info.limit == nil {
            return "未设置上限"
        }
        return money(usageMonitor.keyInfo?.limitRemaining)
    }

    private func money(_ value: Double?) -> String { value.map { String(format: "$%.2f", $0) } ?? "—" }

    private func checkKey() async {
        checkingKey = true
        defer { checkingKey = false }
        do {
            let info = try await OpenRouterClient(apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)).keyInfo()
            var text = String(format: "连接成功，已用 $%.2f", info.usage)
            if let remaining = info.limitRemaining { text += String(format: "，剩余额度 $%.2f", remaining) }
            keyStatus = text
            await usageMonitor.refresh()
        } catch {
            keyStatus = "连接失败：\(error.localizedDescription)"
        }
    }
}

private struct ModelField: View {
    let title: String
    @Binding var value: String
    let suggestions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Menu {
                    ForEach(suggestions, id: \.self) { model in
                        Button(model) { value = model }
                    }
                } label: {
                    Label("常用", systemImage: "list.bullet").font(.caption)
                }
            }
            TextField("模型 ID", text: $value)
                .font(.callout.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Backup

struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore

    @State private var includePhotos = true
    @State private var exportURL: URL?
    @State private var importing = false
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                Toggle("包含照片", isOn: $includePhotos)
                Button {
                    do {
                        exportURL = try BackupService.export(context: context, profile: profileStore.profile,
                                                             includePhotos: includePhotos)
                    } catch {
                        message = "导出失败：\(error.localizedDescription)"
                    }
                } label: {
                    Label("导出备份", systemImage: "square.and.arrow.up")
                }
            } header: {
                Text("导出")
            } footer: {
                Text("导出为一个 JSON 文件，可以存到「文件」App、iCloud 云盘，或隔空投送到电脑。删除 App 会清空本地数据，建议定期导出。")
            }

            Section {
                Button { importing = true } label: {
                    Label("从备份文件恢复", systemImage: "square.and.arrow.down")
                }
            } footer: {
                Text("导入会与现有数据合并：已存在的餐食和已有体重的日期会跳过，重复导入同一个文件不会产生重复数据。")
            }
        }
        .navigationTitle("数据备份")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $exportURL) { url in
            ActivityView(items: [url])
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            switch result {
            case let .success(url):
                do {
                    let summary = try BackupService.importBackup(from: url, context: context, profileStore: profileStore)
                    var text = "导入了 \(summary.meals) 餐、\(summary.exercises) 次运动、\(summary.weights) 条体重记录"
                    if summary.skippedMeals > 0 { text += "，跳过 \(summary.skippedMeals) 餐已存在的记录" }
                    if summary.profileRestored { text += "，并恢复了个人资料" }
                    message = text + "。"
                } catch {
                    message = "导入失败：\(error.localizedDescription)"
                }
            case let .failure(error):
                message = "无法打开文件：\(error.localizedDescription)"
            }
        }
        .alert("数据备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: {
            Text(message ?? "")
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
