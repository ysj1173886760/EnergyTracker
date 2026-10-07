import PhotosUI
import SwiftUI

struct AddMealView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(MealAnalyzer.self) private var analyzer

    @State private var image: UIImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingCamera = false
    @State private var note = ""
    @State private var oilLevel: String?
    @State private var timestamp: Date
    @State private var mealType: MealType
    @State private var errorMessage: String?
    @State private var mode = Mode.ai
    @State private var manual = ManualNutrition()

    enum Mode: Hashable {
        case ai
        case manual
    }

    init(day: Date) {
        let calendar = Calendar.current
        let now = Date()
        let time = calendar.isDate(day, inSameDayAs: now)
            ? now
            : calendar.date(bySettingHour: calendar.component(.hour, from: now),
                            minute: calendar.component(.minute, from: now), second: 0, of: day) ?? day
        _timestamp = State(initialValue: time)
        _mealType = State(initialValue: MealType.suggested(for: time))
    }

    private var canSubmit: Bool {
        switch mode {
        case .ai: image != nil || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .manual: manual.isValid
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("方式", selection: $mode) {
                        Text("拍照 / 描述").tag(Mode.ai)
                        Text("直接填热量").tag(Mode.manual)
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }

                if mode == .ai {
                    aiSections
                } else {
                    ManualNutritionSection(value: $manual)
                    Section("备注（可选）") {
                        TextField("例如：同事请的蛋糕、包装上写的热量", text: $note, axis: .vertical)
                            .lineLimit(2...5)
                    }
                }

                Section {
                    Picker("餐次", selection: $mealType) {
                        ForEach(MealType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    DatePicker("时间", selection: $timestamp)
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("记录一餐")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(mode == .ai ? "开始识别" : "保存", action: submit).disabled(!canSubmit)
                }
            }
            .onChange(of: pickerItem) { _, item in
                Task { await loadPicked(item) }
            }
            .fullScreenCover(isPresented: $showingCamera) {
                CameraPicker { image = $0 }
                    .ignoresSafeArea()
            }
        }
    }

    @ViewBuilder
    private var aiSections: some View {
                Section {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 280)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                    }
                    HStack {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showingCamera = true } label: {
                                Label("拍照", systemImage: "camera.fill").frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label("相册", systemImage: "photo.on.rectangle").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                } footer: {
                    Text("没有照片也可以，只写文字描述，例如「一碗牛肉面，加了个煎蛋」。")
                }

        Section("油量") { OilLevelPicker(selection: $oilLevel) }
                Section("补充说明（可选）") {
                    TextField("例如：只吃了一半、外卖比较油、饭是半碗", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
    }

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item, let data = try? await item.loadTransferable(type: Data.self),
              let picked = UIImage(data: data) else { return }
        image = picked
    }

    private func submit() {
        if mode == .manual {
            let meal = Meal(timestamp: timestamp, mealType: mealType,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines), photoFilename: nil)
            meal.status = .done
            context.insert(meal)
            let item = FoodItem(name: manual.displayName, grams: 100, sortIndex: 0)
            manual.apply(to: item)
            meal.items.append(item)
            meal.estimatedTotalKcal = meal.totalKcal
            try? context.save()
            dismiss()
            return
        }
        do {
            let filename = try image.map { try PhotoStore.save($0) }
            let meal = Meal(timestamp: timestamp, mealType: mealType,
                            note: note.trimmingCharacters(in: .whitespacesAndNewlines), photoFilename: filename)
            meal.oilLevelRaw = oilLevel
            context.insert(meal)
            try context.save()
            analyzer.analyze(meal)
            dismiss()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct ManualNutrition {
    var name = ""
    var kcal: Double?
    var protein: Double?
    var fat: Double?
    var carbs: Double?

    var isValid: Bool { (kcal ?? 0) > 0 }
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "手动记录" : trimmed
    }

    init() {}

    init(item: FoodItem) {
        name = item.name
        kcal = item.kcalPer100g
        protein = item.proteinPer100g
        fat = item.fatPer100g
        carbs = item.carbsPer100g
    }

    func apply(to item: FoodItem) {
        item.name = displayName
        item.grams = 100
        item.portionBasis = FoodItem.manualMarker
        item.nutritionBasis = "手动填写"
        item.kcalPer100g = kcal
        item.proteinPer100g = protein
        item.fatPer100g = fat
        item.carbsPer100g = carbs
    }
}

struct ManualNutritionSection: View {
    @Binding var value: ManualNutrition

    var body: some View {
        Section {
            TextField("名称，例如：生日蛋糕一块", text: $value.name)
            field("热量", $value.kcal, unit: "kcal")
            field("蛋白质（可选）", $value.protein, unit: "g")
            field("脂肪（可选）", $value.fat, unit: "g")
            field("碳水（可选）", $value.carbs, unit: "g")
        } footer: {
            Text("适合包装食品或已知热量的情况，不会调用 AI。")
        }
    }

    private func field(_ label: String, _ binding: Binding<Double?>, unit: String) -> some View {
        HStack {
            Text(label)
            TextField("-", value: binding, format: .number.precision(.fractionLength(0...1)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
            Text(unit).foregroundStyle(.secondary).frame(width: 36, alignment: .leading)
        }
    }
}

struct ManualItemEditor: View {
    let item: FoodItem
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var value: ManualNutrition

    init(item: FoodItem, onSave: @escaping () -> Void) {
        self.item = item
        self.onSave = onSave
        _value = State(initialValue: ManualNutrition(item: item))
    }

    var body: some View {
        NavigationStack {
            Form { ManualNutritionSection(value: $value) }
                .navigationTitle("编辑")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            value.apply(to: item)
                            onSave()
                            dismiss()
                        }
                        .disabled(!value.isValid)
                    }
                }
        }
    }
}

struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
