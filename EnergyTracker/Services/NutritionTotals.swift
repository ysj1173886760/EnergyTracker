import Foundation

struct NutritionTotals {
    static let fiberReference = 25.0
    static let sodiumReference = 2000.0
    static let addedSugarReference = 25.0
    let fiber: Double?
    let sodium: Double?
    let addedSugar: Double?
    let isPartial: Bool
    var hasData: Bool { fiber != nil || sodium != nil || addedSugar != nil }

    init(meals: [Meal]) {
        fiber = Self.sum(meals.map(\.totalFiber))
        sodium = Self.sum(meals.map(\.totalSodiumMg))
        addedSugar = Self.sum(meals.map(\.totalAddedSugar))
        isPartial = meals.contains {
            $0.items.isEmpty
                || $0.items.contains {
                    $0.fiberPer100g == nil || $0.sodiumMgPer100g == nil || $0.addedSugarPer100g == nil
                }
        }
    }

    static func sum(_ values: [Double?]) -> Double? {
        let known = values.compactMap { $0 }
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    var payload: [String: Any] {
        var value: [String: Any] = [:]
        if let fiber { value["fiber_g"] = fiber }
        if let sodium { value["sodium_mg"] = sodium }
        if let addedSugar { value["added_sugar_g"] = addedSugar }
        if hasData { value["nutrition_data_partial"] = isPartial }
        return value
    }
}
