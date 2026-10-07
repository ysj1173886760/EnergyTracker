import SwiftUI

/// Edits an existing item, or creates a new one when `item` is nil.
struct FoodItemEditor: View {
    @Environment(\.dismiss) private var dismiss

    let item: FoodItem?
    /// Receives the edited (or newly created) item; the flag is true when nutrition should be re-estimated.
    let onSave: (FoodItem, Bool) -> Void

    @State private var name: String
    @State private var detail: String
    @State private var grams: Double?
    @State private var kcal: Double?
    @State private var protein: Double?
    @State private var fat: Double?
    @State private var carbs: Double?

    init(item: FoodItem?, onSave: @escaping (FoodItem, Bool) -> Void) {
        self.item = item
        self.onSave = onSave
        _name = State(initialValue: item?.name ?? "")
        _detail = State(initialValue: item?.detail ?? "")
        _grams = State(initialValue: item?.grams)
        _kcal = State(initialValue: item?.kcalPer100g)
        _protein = State(initialValue: item?.proteinPer100g)
        _fat = State(initialValue: item?.fatPer100g)
        _carbs = State(initialValue: item?.carbsPer100g)
    }

    private var identityChanged: Bool {
        guard let item else { return true }
        return name != item.name || detail != item.detail
    }

    private var nutritionEdited: Bool {
        kcal != item?.kcalPer100g || protein != item?.proteinPer100g
            || fat != item?.fatPer100g || carbs != item?.carbsPer100g
    }

    private var willReestimate: Bool { identityChanged && !nutritionEdited }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && (grams ?? 0) > 0
    }

    private var previewKcal: Double? {
        guard let grams, let kcal else { return nil }
        return grams * kcal / 100
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称，例如：番茄炒蛋", text: $name)
                    HStack {
                        Text("重量")
                        TextField("克", value: $grams, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                        Text("g").foregroundStyle(.secondary)
                    }
                    TextField("描述（做法、油量等，可选）", text: $detail, axis: .vertical)
                        .lineLimit(1...4)
                } footer: {
                    if let item, let estimated = item.estimatedGrams {
                        Text("识别估算 \(estimated.gramsText) g。\(item.portionBasis)")
                    }
                }

                Section {
                    numberRow("热量", value: $kcal, unit: "kcal")
                    numberRow("蛋白质", value: $protein, unit: "g")
                    numberRow("脂肪", value: $fat, unit: "g")
                    numberRow("碳水", value: $carbs, unit: "g")
                } header: {
                    Text("每 100 克")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if let previewKcal {
                            Text("这一项约 \(previewKcal.kcalText) kcal").font(.footnote.weight(.semibold))
                        }
                        if willReestimate {
                            Text(item == nil ? "保存后会自动请模型估算，也可以手动填写。" : "名称或描述有变化，保存后会自动请模型重新估算。")
                        } else if let basis = item?.nutritionBasis, !basis.isEmpty {
                            Text(basis)
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "添加食物" : "编辑食物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(!canSave)
                }
            }
        }
    }

    private func numberRow(_ label: String, value: Binding<Double?>, unit: String) -> some View {
        HStack {
            Text(label)
            TextField("-", value: value, format: .number)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
        }
    }

    private func save() {
        let reestimate = willReestimate
        let target = item ?? FoodItem(name: "", grams: 0, sortIndex: 0)
        target.name = name.trimmingCharacters(in: .whitespaces)
        target.detail = detail.trimmingCharacters(in: .whitespaces)
        target.grams = grams ?? 0
        if reestimate {
            target.clearNutrition()
        } else {
            target.kcalPer100g = kcal
            target.proteinPer100g = protein
            target.fatPer100g = fat
            target.carbsPer100g = carbs
            if nutritionEdited { target.nutritionBasis = "手动填写" }
        }
        onSave(target, reestimate)
        dismiss()
    }
}
