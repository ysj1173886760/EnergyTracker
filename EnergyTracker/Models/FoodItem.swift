import Foundation
import SwiftData

@Model
final class FoodItem {
    var name: String = ""
    var detail: String = ""
    var grams: Double = 0
    /// Weight originally estimated by the vision model; nil for manually added items.
    var estimatedGrams: Double?
    var count: Int?
    var portionBasis: String = ""
    var confidence: Double?

    var kcalPer100g: Double?
    var proteinPer100g: Double?
    var fatPer100g: Double?
    var carbsPer100g: Double?
    var nutritionBasis: String = ""

    var sortIndex: Int = 0
    var meal: Meal?

    init(name: String, detail: String = "", grams: Double, sortIndex: Int) {
        self.name = name
        self.detail = detail
        self.grams = grams
        self.sortIndex = sortIndex
    }

    static let manualMarker = "manual"

    /// Entered directly by the user: grams is fixed at 100 so the per-100g values are the absolute amounts.
    var isManualEntry: Bool { portionBasis == Self.manualMarker }

    var hasNutrition: Bool { kcalPer100g != nil }

    var kcal: Double { grams * (kcalPer100g ?? 0) / 100 }
    var protein: Double { grams * (proteinPer100g ?? 0) / 100 }
    var fat: Double { grams * (fatPer100g ?? 0) / 100 }
    var carbs: Double { grams * (carbsPer100g ?? 0) / 100 }

    func clearNutrition() {
        kcalPer100g = nil
        proteinPer100g = nil
        fatPer100g = nil
        carbsPer100g = nil
        nutritionBasis = ""
    }
}
