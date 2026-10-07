import Foundation
import SwiftData

enum OilLevel: String, CaseIterable, Identifiable {
    case less, normal, heavy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .less: "少油"
        case .normal: "正常"
        case .heavy: "重油"
        }
    }
}

enum MealStatus: String, Codable {
    case pending
    case recognizing
    case revising
    case estimating
    case done
    case failed

    var isInProgress: Bool {
        self == .pending || self == .recognizing || self == .revising || self == .estimating
    }

    var title: String {
        switch self {
        case .pending: "等待识别"
        case .recognizing: "正在识别食物…"
        case .revising: "正在根据补充调整…"
        case .estimating: "正在估算热量…"
        case .done: "完成"
        case .failed: "识别失败"
        }
    }
}

enum MealType: String, Codable, CaseIterable, Identifiable {
    case breakfast
    case lunch
    case dinner
    case snack

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breakfast: "早餐"
        case .lunch: "午餐"
        case .dinner: "晚餐"
        case .snack: "加餐"
        }
    }

    var symbol: String {
        switch self {
        case .breakfast: "sunrise"
        case .lunch: "sun.max"
        case .dinner: "moon.stars"
        case .snack: "cup.and.saucer"
        }
    }

    static func suggested(for date: Date) -> MealType {
        switch Calendar.current.component(.hour, from: date) {
        case 4..<10: .breakfast
        case 10..<15: .lunch
        case 17..<21: .dinner
        default: .snack
        }
    }
}

@Model
final class Meal {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var mealTypeRaw: String = MealType.snack.rawValue
    var note: String = ""
    var photoFilename: String?
    var oilLevelRaw: String?

    var statusRaw: String = MealStatus.pending.rawValue
    var errorMessage: String?
    var sceneNotes: String?

    var visionModel: String?
    var nutritionModel: String?
    var rawVisionResponse: String?
    var rawNutritionResponse: String?
    /// Total kcal as first produced by the models, before any manual edits.
    var estimatedTotalKcal: Double?

    @Relationship(deleteRule: .cascade, inverse: \FoodItem.meal)
    var items: [FoodItem] = []

    @Relationship(deleteRule: .cascade, inverse: \MealFollowUp.meal)
    var followUps: [MealFollowUp] = []

    init(timestamp: Date, mealType: MealType, note: String, photoFilename: String?) {
        self.timestamp = timestamp
        self.mealTypeRaw = mealType.rawValue
        self.note = note
        self.photoFilename = photoFilename
    }

    var status: MealStatus {
        get { MealStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var mealType: MealType {
        get { MealType(rawValue: mealTypeRaw) ?? .snack }
        set { mealTypeRaw = newValue.rawValue }
    }

    var sortedItems: [FoodItem] {
        items.sorted { $0.sortIndex < $1.sortIndex }
    }

    var sortedFollowUps: [MealFollowUp] {
        followUps.sorted { $0.createdAt < $1.createdAt }
    }

    var hasPendingFollowUps: Bool {
        followUps.contains { !$0.isApplied }
    }

    var totalSodiumMg: Double? {
        NutritionTotals.sum(items.map { item in item.sodiumMgPer100g.map { $0 * item.grams / 100 } })
    }
    var totalAddedSugar: Double? {
        NutritionTotals.sum(items.map { item in item.addedSugarPer100g.map { $0 * item.grams / 100 } })
    }
    var totalFiber: Double? {
        NutritionTotals.sum(items.map { item in item.fiberPer100g.map { $0 * item.grams / 100 } })
    }
    var totalKcal: Double { items.reduce(0) { $0 + $1.kcal } }
    var totalProtein: Double { items.reduce(0) { $0 + $1.protein } }
    var totalFat: Double { items.reduce(0) { $0 + $1.fat } }
    var totalCarbs: Double { items.reduce(0) { $0 + $1.carbs } }

    var isManualEntry: Bool { !items.isEmpty && items.allSatisfy(\.isManualEntry) }

    var summaryText: String {
        let names = sortedItems.map(\.name)
        if !names.isEmpty { return names.joined(separator: "、") }
        if !note.isEmpty { return note }
        return sceneNotes ?? ""
    }
}
