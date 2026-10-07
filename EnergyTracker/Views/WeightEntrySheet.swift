import SwiftData
import SwiftUI

struct WeightEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore

    @State private var date: Date
    @State private var kg: Double?
    @FocusState private var focused: Bool

    init(date: Date = .now) {
        _date = State(initialValue: date)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("体重", value: $kg, format: .number.precision(.fractionLength(0...1)))
                            .keyboardType(.decimalPad)
                            .font(.system(size: 40, weight: .semibold, design: .rounded))
                            .focused($focused)
                        Text("kg").font(.title2).foregroundStyle(.secondary)
                    }
                    DatePicker("日期", selection: $date, in: ...Date.now, displayedComponents: .date)
                } footer: {
                    Text("建议每天早上起床、如厕后空腹称重。每天的体重会因为喝水和饮食波动 0.5–1.5 kg，趋势线比单日数字更有参考价值。同一天多次记录会覆盖。")
                }
            }
            .navigationTitle("记录体重")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save).disabled(!isValid)
                }
            }
            .onAppear {
                if kg == nil { kg = profileStore.latestWeightKg }
                focused = true
            }
        }
        .presentationDetents([.medium])
    }

    private var isValid: Bool {
        guard let kg else { return false }
        return (25...300).contains(kg)
    }

    private func save() {
        guard let kg else { return }
        WeightEntry.upsert(kg: kg, on: date, in: context)
        profileStore.refresh(in: context)
        dismiss()
    }
}
