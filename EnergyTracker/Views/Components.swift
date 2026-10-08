import SwiftUI

extension Double {
    var kcalText: String { "\(Int(rounded()))" }
    var gramsText: String { self < 10 ? String(format: "%.1f", self) : "\(Int(rounded()))" }
}

extension Calendar {
    func dayRange(for date: Date) -> (start: Date, end: Date) {
        let start = startOfDay(for: date)
        return (start, self.date(byAdding: .day, value: 1, to: start)!)
    }
}

struct DailySummaryCard: View {
    let kcal: Double
    let protein: Double
    let fat: Double
    let carbs: Double
    let goal: NutritionGoal
    /// Kcal added to the budget from exercise.
    var exerciseBonus: Int = 0
    var uncertainty: Double?

    private var budget: Int { goal.kcal + exerciseBonus }
    private var progress: Double { budget > 0 ? kcal / Double(budget) : 0 }
    private var remaining: Int { budget - Int(kcal.rounded()) }

    var body: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.15), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: min(progress, 1))
                    .stroke(progress > 1 ? Color.red : Color.accentColor, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text(kcal.kcalText).font(.title2.bold()).monospacedDigit()
                    Text("/ \(budget) kcal").font(.caption2).foregroundStyle(.secondary)
                    if exerciseBonus > 0 {
                        Text("含运动 +\(exerciseBonus)").font(.caption2).foregroundStyle(.green)
                    }
                }
            }
            .frame(width: 110, height: 110)

            VStack(alignment: .leading, spacing: 10) {
                Text(remaining >= 0 ? "还可以吃 \(remaining) kcal" : "已超出 \(-remaining) kcal")
                    .font(.headline)
                    .foregroundStyle(remaining >= 0 ? Color.primary : Color.red)
                if let uncertainty, uncertainty > 0 {
                    Text("误差约 ±\(uncertainty.kcalText) kcal").font(.caption2).foregroundStyle(.secondary)
                }
                MacroRow(label: "蛋白质", grams: protein, target: goal.proteinG, color: .blue)
                MacroRow(label: "脂肪", grams: fat, color: .orange)
                MacroRow(label: "碳水", grams: carbs, color: .green)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
    }
}

struct MacroRow: View {
    let label: String
    let grams: Double
    var target: Int?
    let color: Color

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Group {
                    if let target {
                        Text("\(grams.gramsText) / \(target) g")
                    } else {
                        Text("\(grams.gramsText) g")
                    }
                }
                .font(.subheadline)
                .monospacedDigit()
            }
            if let target, target > 0 {
                ProgressView(value: min(grams / Double(target), 1))
                    .tint(color)
            }
        }
    }
}

struct MealThumbnail: View {
    let filename: String?
    var size: CGFloat = 56

    var body: some View {
        Group {
            if let filename, let image = PhotoStore.thumbnail(filename, size: size) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "text.alignleft")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(.secondarySystemFill))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct MealRow: View {
    @Environment(MealAnalyzer.self) private var analyzer
    let meal: Meal

    var body: some View {
        HStack(spacing: 12) {
            MealThumbnail(filename: meal.photoFilename)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(meal.mealType.title, systemImage: meal.mealType.symbol)
                        .font(.subheadline.weight(.semibold))
                    Text(meal.timestamp, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(meal.summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            trailing
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch meal.status {
        case .done:
            VStack(alignment: .trailing, spacing: 0) {
                Text(meal.totalKcal.kcalText).font(.headline).monospacedDigit()
                let uncertainty = EstimateUncertainty.meal(meal)
                if !meal.isManualEntry, uncertainty > 0 {
                    Text("±\(uncertainty.kcalText)").font(.caption2).foregroundStyle(.secondary)
                }
                Text("kcal").font(.caption2).foregroundStyle(.secondary)
            }
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        default:
            if analyzer.isRunning(meal) {
                ProgressView()
            } else {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .accessibilityLabel("任务已中断")
            }
        }
    }
}

struct OilLevelPicker: View {
    @Binding var selection: String?
    var body: some View {
        Picker("油量", selection: $selection) {
            Text("自动").tag(nil as String?)
            ForEach(OilLevel.allCases) { Text($0.title).tag(Optional($0.rawValue)) }
        }
        .pickerStyle(.segmented)
    }
}

struct NutritionTotalsRow: View {
    let totals: NutritionTotals
    var showsReferences = false
    var body: some View {
        if totals.hasData {
            VStack(alignment: .leading, spacing: 4) {
                Text(
                    nutrientText(
                        "膳食纤维", value: totals.fiber?.gramsText, reference: NutritionTotals.fiberReference, unit: "g"))
                Text(
                    nutrientText(
                        "钠", value: totals.sodium?.kcalText, reference: NutritionTotals.sodiumReference, unit: "mg")
                )
                .foregroundStyle((totals.sodium ?? 0) > NutritionTotals.sodiumReference ? Color.orange : .secondary)
                Text(
                    nutrientText(
                        "添加糖", value: totals.addedSugar?.gramsText, reference: NutritionTotals.addedSugarReference,
                        unit: "g")
                )
                .foregroundStyle(
                    (totals.addedSugar ?? 0) > NutritionTotals.addedSugarReference ? Color.orange : .secondary)
                if totals.isPartial { Text("部分餐食无数据") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func nutrientText(_ label: String, value: String?, reference: Double, unit: String) -> String {
        let referenceText = showsReferences ? " / \(Int(reference))" : ""
        return "\(label) \(value ?? "—")\(referenceText) \(unit)"
    }

}
