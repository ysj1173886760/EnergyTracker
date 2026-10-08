import SwiftData
import SwiftUI

struct MealDetailView: View {
    @Environment(\.modelContext) private var context
    @Environment(MealAnalyzer.self) private var analyzer
    @Bindable var meal: Meal

    @State private var editingItem: FoodItem?
    @State private var addingItem = false
    @State private var confirmingReanalyze = false
    @State private var followUpText = ""
    @FocusState private var followUpFocused: Bool

    private var busy: Bool { analyzer.isRunning(meal) }

    var body: some View {
        List {
            if let filename = meal.photoFilename, let image = PhotoStore.load(filename) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .listRowInsets(EdgeInsets())
                }
            }

            statusSection
            itemsSection
            if !meal.isManualEntry {
                followUpSection
            }
            infoSection
            if !meal.isManualEntry {
                actionsSection
            }
            debugSection
        }
        .navigationTitle(meal.mealType.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingItem) { item in
            if item.isManualEntry {
                ManualItemEditor(item: item) { save() }
            } else {
                FoodItemEditor(item: item) { item, reestimate in
                    save()
                    if reestimate { analyzer.estimateNutrition(meal, items: [item]) }
                }
            }
        }
        .sheet(isPresented: $addingItem) {
            FoodItemEditor(item: nil) { item, reestimate in
                item.sortIndex = (meal.items.map(\.sortIndex).max() ?? -1) + 1
                meal.items.append(item)
                save()
                if reestimate { analyzer.estimateNutrition(meal, items: [item]) }
            }
        }
        .confirmationDialog("重新识别会替换当前所有食物和修改，确定吗？", isPresented: $confirmingReanalyze, titleVisibility: .visible) {
            Button("重新识别", role: .destructive) { analyzer.analyze(meal) }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        if busy {
            Section {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(meal.status.title)
                    Spacer()
                    Text(meal.status == .estimating ? "2/2" : "1/2").foregroundStyle(.secondary)
                }
            } footer: {
                Text("可以先离开这个页面，识别会在后台继续。")
            }
        } else if meal.status == .failed || meal.status.isInProgress {
            Section {
                Label(meal.status.isInProgress ? "任务已中断" : (meal.errorMessage ?? "未知错误"),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Button("重试", action: retry)
            }
        }
    }

    private func retry() {
        if meal.rawVisionResponse == nil {
            analyzer.analyze(meal)
        } else if meal.hasPendingFollowUps {
            analyzer.applyFollowUps(meal)
        } else {
            analyzer.estimateNutrition(meal, items: meal.items.filter { !$0.hasNutrition })
        }
    }

    private var itemsSection: some View {
        Section {
            ForEach(meal.sortedItems) { item in
                Button { editingItem = item } label: { FoodItemRow(item: item) }
                    .tint(.primary)
                    .disabled(busy)
            }
            .onDelete { offsets in
                let sorted = meal.sortedItems
                for index in offsets { context.delete(sorted[index]) }
                save()
            }

            Button { addingItem = true } label: { Label("添加食物", systemImage: "plus") }
                .disabled(busy)
        } header: {
            Text("食物")
        } footer: {
            if !meal.items.isEmpty {
                HStack {
                    Text("合计")
                    Spacer()
                    Text(nutritionSummaryText)
                        .monospacedDigit()
                }
                .font(.footnote.weight(.medium))
                NutritionTotalsRow(totals: NutritionTotals(meals: [meal]))
            }
        }
    }

    private var nutritionSummaryText: String {
        let uncertainty = EstimateUncertainty.meal(meal).kcalText
        return "\(meal.totalKcal.kcalText) ±\(uncertainty) kcal · 蛋白 \(meal.totalProtein.gramsText)g"
            + " · 脂肪 \(meal.totalFat.gramsText)g · 碳水 \(meal.totalCarbs.gramsText)g"
    }

    private var canSendFollowUp: Bool {
        !busy && meal.rawVisionResponse != nil
            && !followUpText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var followUpSection: some View {
        Section {
            ForEach(meal.sortedFollowUps) { followUp in
                VStack(alignment: .leading, spacing: 4) {
                    Text(followUp.text)
                    if let reply = followUp.reply {
                        Label(reply, systemImage: "sparkles")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(busy ? "处理中…" : "未生效，可点上方「重试」")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { offsets in
                let sorted = meal.sortedFollowUps
                for index in offsets { context.delete(sorted[index]) }
                save()
            }

            HStack(alignment: .bottom) {
                TextField("例如：饭只吃了一半、汤没拍到、是无糖可乐", text: $followUpText, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($followUpFocused)
                Button(action: sendFollowUp) {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
                .disabled(!canSendFollowUp)
                .buttonStyle(.borderless)
            }
        } header: {
            Text("补充修正")
        } footer: {
            Text(meal.rawVisionResponse == nil
                 ? "识别完成后可以在这里补充说明。"
                 : "模型会结合照片和你的说明修正清单，只重新估算有变化的项。删除补充记录不会撤销已做的调整。")
        }
    }

    private func sendFollowUp() {
        let text = followUpText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        meal.followUps.append(MealFollowUp(text: text))
        save()
        followUpText = ""
        followUpFocused = false
        analyzer.applyFollowUps(meal)
    }

    private var infoSection: some View {
        Section("信息") {
            Picker("餐次", selection: $meal.mealType) {
                ForEach(MealType.allCases) { Text($0.title).tag($0) }
            }
            if !meal.isManualEntry {
                OilLevelPicker(selection: $meal.oilLevelRaw)
                    .disabled(busy)
                    .onChange(of: meal.oilLevelRaw) {
                        save()
                        analyzer.estimateNutrition(meal)
                    }
            }
            DatePicker("时间", selection: $meal.timestamp)
            TextField("初始说明", text: $meal.note, axis: .vertical)
                .lineLimit(1...4)
            if let scene = meal.sceneNotes, !scene.isEmpty {
                LabeledContent("模型备注") {
                    Text(scene).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: meal.mealTypeRaw) { save() }
        .onChange(of: meal.timestamp) { save() }
        .onChange(of: meal.note) { save() }
    }

    private var actionsSection: some View {
        Section {
            Button {
                analyzer.estimateNutrition(meal)
            } label: {
                Label("重新估算热量", systemImage: "flame")
            }
            .disabled(busy || meal.items.isEmpty)

            Button {
                confirmingReanalyze = true
            } label: {
                Label(meal.photoFilename == nil ? "根据描述重新识别" : "重新识别照片", systemImage: "arrow.clockwise")
            }
            .disabled(busy)
        } footer: {
            Text("修改克数会直接按每 100 克数值重算，不需要重新估算。修改了食物名称或描述时会自动重新估算该项。重新识别时会带上所有补充修正。")
        }
    }

    private var debugSection: some View {
        Section("模型信息") {
            LabeledContent("识别模型", value: meal.visionModel ?? "-")
            LabeledContent("热量模型", value: meal.nutritionModel ?? "-")
            if let original = meal.estimatedTotalKcal {
                LabeledContent("模型原始估算", value: "\(original.kcalText) kcal")
            }
            if let raw = meal.rawVisionResponse {
                DisclosureGroup("识别原始返回") {
                    Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            if let raw = meal.rawNutritionResponse {
                DisclosureGroup("热量原始返回") {
                    Text(raw).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
    }

    private func save() {
        try? context.save()
    }
}

struct FoodItemRow: View {
    let item: FoodItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name).font(.body.weight(.medium))
                    if let count = item.count {
                        Text("×\(count)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if !item.isManualEntry, (item.confidence ?? 1) < 0.6, !EstimateUncertainty.gramsEdited(item) {
                    Text("份量把握较低，建议核对克数").font(.caption2).foregroundStyle(.orange)
                }
            }
            Spacer()
            if item.hasNutrition {
                Text("\(item.kcal.kcalText) kcal").monospacedDigit()
            } else {
                Text("待估算").foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        if item.isManualEntry {
            var text = "手动填写"
            if item.proteinPer100g != nil || item.fatPer100g != nil || item.carbsPer100g != nil {
                text += " · 蛋白 \(item.protein.gramsText) 脂肪 \(item.fat.gramsText) 碳水 \(item.carbs.gramsText)"
            }
            return text
        }
        var text = "\(item.grams.gramsText) g"
        if let estimated = item.estimatedGrams, abs(estimated - item.grams) >= 1 {
            text += "（识别 \(estimated.gramsText) g）"
        }
        if item.hasNutrition {
            text += " · 蛋白 \(item.protein.gramsText) 脂肪 \(item.fat.gramsText) 碳水 \(item.carbs.gramsText)"
        }
        return text
    }
}
