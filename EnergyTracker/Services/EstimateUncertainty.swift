import Foundation

enum EstimateUncertainty {
    static func gramsEdited(_ item: FoodItem) -> Bool {
        item.estimatedGrams.map { abs($0 - item.grams) >= 1 } ?? false
    }

    static func item(_ item: FoodItem, hasPhoto: Bool) -> Double {
        guard !item.isManualEntry else { return 0 }
        let portion: Double
        if gramsEdited(item) {
            portion = 0.05
        } else if hasPhoto {
            portion = min(0.5, max(0.1, 0.1 + (1 - (item.confidence ?? 0.6)) * 0.5))
        } else {
            portion = 0.35
        }
        let density = min(0.5, max(0.05, item.kcalUncertainty ?? 0.2))
        return item.kcal * sqrt(portion * portion + density * density)
    }

    static func meal(_ meal: Meal) -> Double {
        sqrt(meal.items.reduce(0) { $0 + pow(item($1, hasPhoto: meal.photoFilename != nil), 2) })
    }

    static func day(_ meals: [Meal]) -> Double {
        sqrt(meals.reduce(0) { $0 + pow(meal($1), 2) })
    }
}
