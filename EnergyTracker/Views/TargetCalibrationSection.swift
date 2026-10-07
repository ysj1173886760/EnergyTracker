import SwiftData
import SwiftUI

struct TargetCalibrationSection: View {
    @Environment(ProfileStore.self) private var store
    @Query private var meals: [Meal]
    @Query private var exercises: [ExerciseSession]
    @Query private var weights: [WeightEntry]
    @AppStorage("calibration.dismissedUntil") private var dismissedUntil = 0.0
    var showsProgress = false
    private var result: CalibrationResult {
        TargetCalibration.calculate(
            meals: meals, exercises: exercises, weights: weights, profile: store.profile,
            goal: store.goal, currentWeight: store.currentWeightKg)
    }
    var body: some View {
        let value = result
        if let target = value.suggestedTarget, let expenditure = value.expenditure,
            showsProgress || Date.now.timeIntervalSince1970 >= dismissedUntil
        {
            Section {
                Text(suggestionText(expenditure: expenditure, target: target))
                HStack {
                    Button("应用") {
                        if store.goal.isManual {
                            store.profile.manualKcalTarget = target
                        } else {
                            store.profile.kcalAdjustment =
                                (store.profile.kcalAdjustment ?? 0) + target - store.goal.kcal
                        }
                        dismissedUntil =
                            Calendar.current.date(byAdding: .day, value: 14, to: .now)!.timeIntervalSince1970
                    }
                    .buttonStyle(.borderedProminent)
                    Button("忽略") {
                        dismissedUntil =
                            Calendar.current.date(byAdding: .day, value: 14, to: .now)!.timeIntervalSince1970
                    }
                    .buttonStyle(.bordered)
                }
            } header: {
                Text("目标校准")
            } footer: {
                Text("按你记录的摄入和体重实际变化反推，包含记录中长期漏记或低估的影响。")
            }
        } else if showsProgress {
            Section("目标校准") {
                Text(value.progress).font(.footnote).foregroundStyle(.secondary)
                if value.expenditure != nil { Text("当前目标无需调整。").font(.footnote) }
            }
        }
    }

    private func suggestionText(expenditure: Int, target: Int) -> String {
        let difference = expenditure - (store.goal.tdee ?? expenditure)
        let direction = difference >= 0 ? "高" : "低"
        let targetKind = store.goal.isManual ? "手动" : "每日"
        return "你的实际消耗约 \(expenditure) kcal，比公式估算\(direction) \(abs(difference))，"
            + "建议把\(targetKind)目标从 \(store.goal.kcal) 调到 \(target) kcal。"
    }

}
