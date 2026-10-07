import Foundation
import Observation
import SwiftData
import UIKit

/// Runs the two-stage pipeline: a vision model identifies foods and portions,
/// then a text model estimates per-100g nutrition. Totals are computed locally
/// so editing grams never requires another model call.
@MainActor
@Observable
final class MealAnalyzer {
    private let context: ModelContext
    private var running: Set<UUID> = []

    init(container: ModelContainer) {
        context = container.mainContext
    }

    func isRunning(_ meal: Meal) -> Bool {
        running.contains(meal.id)
    }

    /// Full pipeline: recognize foods, then estimate nutrition. Replaces existing items.
    func analyze(_ meal: Meal) {
        run(meal) { [self] in
            try await recognize(meal)
            try await estimate(meal, items: meal.sortedItems, recordAsOriginal: true)
        }
    }

    /// Stage two only, for the given items (defaults to all items).
    func estimateNutrition(_ meal: Meal, items: [FoodItem]? = nil) {
        run(meal) { [self] in
            try await estimate(meal, items: items ?? meal.sortedItems, recordAsOriginal: false)
        }
    }

    /// Applies all unapplied follow-ups: revise the item list, then estimate only new or changed items.
    func applyFollowUps(_ meal: Meal) {
        run(meal) { [self] in
            try await revise(meal)
            try await estimate(meal, items: meal.sortedItems.filter { !$0.hasNutrition }, recordAsOriginal: false)
        }
    }

    /// Restart work interrupted by the app being killed mid-request.
    func resumeInterrupted() {
        let descriptor = FetchDescriptor<Meal>()
        guard let meals = try? context.fetch(descriptor) else { return }
        for meal in meals where meal.status.isInProgress && !running.contains(meal.id) {
            if meal.hasPendingFollowUps, meal.rawVisionResponse != nil {
                applyFollowUps(meal)
            } else if meal.status == .estimating, !meal.items.isEmpty {
                estimateNutrition(meal, items: meal.items.filter { !$0.hasNutrition })
            } else {
                analyze(meal)
            }
        }
    }

    private func run(_ meal: Meal, _ work: @escaping () async throws -> Void) {
        guard !running.contains(meal.id) else { return }
        running.insert(meal.id)
        meal.errorMessage = nil
        meal.status = .pending
        save()

        let activity = BackgroundActivity("AnalyzeMeal")
        Task {
            do {
                try await work()
                meal.status = .done
                NotificationCenterService.notifyIfInBackground(
                    title: "\(meal.mealType.title)识别完成",
                    body: "约 \(meal.totalKcal.kcalText) kcal：\(meal.summaryText)")
            } catch {
                meal.status = .failed
                meal.errorMessage = error.localizedDescription
                NotificationCenterService.notifyIfInBackground(title: "\(meal.mealType.title)识别失败", body: error.localizedDescription)
            }
            running.remove(meal.id)
            save()
            activity.end()
        }
    }

    private func recognize(_ meal: Meal) async throws {
        let client = try OpenRouterClient.fromKeychain()
        meal.status = .recognizing
        save()

        var parts: [OpenRouterClient.Part] = []
        let note = ([meal.note] + meal.sortedFollowUps.map(\.text))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "；")
        if let filename = meal.photoFilename, let data = PhotoStore.uploadData(filename) {
            parts.append(.text(note.isEmpty ? "请识别这张照片。" : "请识别这张照片。用户补充说明：\(note)"))
            parts.append(.jpeg(data))
        } else {
            parts.append(.text("没有照片。用户的文字描述：\(note)"))
        }

        if let oil = meal.oilLevelRaw.flatMap(OilLevel.init) { parts.append(.text("用户确认油量：\(oil.title)")) }
        let model = AppSettings.visionModel
        let response = try await client.chatJSON(model: model, system: Prompts.vision, user: parts)

        for item in meal.items {
            context.delete(item)
        }
        meal.items = []
        meal.visionModel = model
        meal.rawVisionResponse = response.raw
        meal.sceneNotes = JSONValue.string(response.json["scene_notes"])

        let rawItems = response.json["items"] as? [[String: Any]] ?? []
        for (index, raw) in rawItems.enumerated() {
            let grams = JSONValue.double(raw["grams"]) ?? 0
            let item = FoodItem(
                name: JSONValue.string(raw["name"]),
                detail: JSONValue.string(raw["detail"]),
                grams: grams,
                sortIndex: index
            )
            item.estimatedGrams = grams
            item.count = JSONValue.int(raw["count"])
            item.portionBasis = JSONValue.string(raw["portion_basis"])
            item.confidence = JSONValue.double(raw["confidence"])
            meal.items.append(item)
        }
        for followUp in meal.followUps where !followUp.isApplied {
            followUp.reply = "已在重新识别时一并考虑"
        }
        save()
    }

    private func revise(_ meal: Meal) async throws {
        let pending = meal.sortedFollowUps.filter { !$0.isApplied }
        guard !pending.isEmpty else { return }
        let client = try OpenRouterClient.fromKeychain()
        meal.status = .revising
        save()

        let current = meal.sortedItems
        var payload: [String: Any] = [
            "current_items": current.enumerated().map { index, item -> [String: Any] in
                var entry: [String: Any] = ["index": index, "name": item.name, "detail": item.detail, "grams": item.grams]
                if let count = item.count { entry["count"] = count }
                return entry
            },
            "previous_followups": meal.sortedFollowUps.filter(\.isApplied).map(\.text),
            "new_followups": pending.map(\.text),
        ]
        payload["oil_level"] = meal.oilLevelRaw ?? "auto"
        if let scene = meal.sceneNotes, !scene.isEmpty { payload["scene_notes"] = scene }
        let note = meal.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { payload["original_note"] = note }

        let input = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        var parts: [OpenRouterClient.Part] = [.text(input)]
        if let filename = meal.photoFilename, let data = PhotoStore.uploadData(filename) {
            parts.append(.jpeg(data))
        }
        let response = try await client.chatJSON(model: AppSettings.visionModel, system: Prompts.revision, user: parts)
        guard let rawItems = response.json["items"] as? [[String: Any]] else {
            throw OpenRouterError.invalidJSON(response.raw)
        }

        var kept = Set<ObjectIdentifier>()
        for (position, raw) in rawItems.enumerated() {
            let name = JSONValue.string(raw["name"]).trimmingCharacters(in: .whitespaces)
            let detail = JSONValue.string(raw["detail"]).trimmingCharacters(in: .whitespaces)
            let grams = JSONValue.double(raw["grams"]) ?? 0
            let item: FoodItem
            if let source = JSONValue.int(raw["source_index"]), current.indices.contains(source),
               !kept.contains(ObjectIdentifier(current[source])) {
                item = current[source]
                // Grams-only changes keep per-100g values; totals recompute locally.
                if item.name != name || item.detail != detail {
                    item.clearNutrition()
                }
            } else {
                item = FoodItem(name: name, detail: detail, grams: grams, sortIndex: position)
                item.estimatedGrams = grams
                meal.items.append(item)
            }
            item.name = name
            item.detail = detail
            item.grams = grams
            item.count = JSONValue.int(raw["count"])
            item.sortIndex = position
            let basis = JSONValue.string(raw["portion_basis"])
            if !basis.isEmpty { item.portionBasis = basis }
            if let confidence = JSONValue.double(raw["confidence"]) { item.confidence = confidence }
            kept.insert(ObjectIdentifier(item))
        }
        for item in current where !kept.contains(ObjectIdentifier(item)) {
            context.delete(item)
        }

        let scene = JSONValue.string(response.json["scene_notes"])
        if !scene.isEmpty { meal.sceneNotes = scene }
        let reply = JSONValue.string(response.json["reply"])
        for followUp in pending {
            followUp.reply = reply.isEmpty ? "已调整" : reply
            followUp.rawResponse = response.raw
        }
        save()
    }

    private func estimate(_ meal: Meal, items: [FoodItem], recordAsOriginal: Bool) async throws {
        guard !items.isEmpty else { return }
        let client = try OpenRouterClient.fromKeychain()
        meal.status = .estimating
        save()

        var payload: [String: Any] = [
            "items": items.map { item -> [String: Any] in
                var entry: [String: Any] = ["name": item.name, "detail": item.detail, "grams": item.grams]
                if let count = item.count { entry["count"] = count }
                return entry
            },
        ]
        payload["oil_level"] = meal.oilLevelRaw ?? "auto"
        if let scene = meal.sceneNotes, !scene.isEmpty { payload["scene_notes"] = scene }
        let note = meal.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { payload["user_note"] = note }
        let followUps = meal.sortedFollowUps.map(\.text)
        if !followUps.isEmpty { payload["user_followups"] = followUps }

        let input = String(data: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8) ?? "{}"
        let model = AppSettings.nutritionModel
        let response = try await client.chatJSON(model: model, system: Prompts.nutrition, user: [.text(input)],
                                                 reasoning: AppSettings.nutritionReasoning)

        let results = response.json["items"] as? [[String: Any]] ?? []
        var matched = 0
        for (position, raw) in results.enumerated() {
            let index = JSONValue.int(raw["index"]) ?? position
            guard items.indices.contains(index), let kcal = JSONValue.double(raw["kcal_per_100g"]) else { continue }
            let item = items[index]
            item.kcalPer100g = kcal
            item.kcalUncertainty = JSONValue.double(raw["kcal_uncertainty"]).map { min(0.5, max(0.05, $0)) }
            item.proteinPer100g = JSONValue.double(raw["protein_per_100g"])
            item.fatPer100g = JSONValue.double(raw["fat_per_100g"])
            item.carbsPer100g = JSONValue.double(raw["carbs_per_100g"])
            item.fiberPer100g = JSONValue.double(raw["fiber_per_100g"]).map { max(0, $0) }
            item.sodiumMgPer100g = JSONValue.double(raw["sodium_mg_per_100g"]).map { max(0, $0) }
            item.addedSugarPer100g = JSONValue.double(raw["added_sugar_per_100g"]).map { max(0, $0) }
            item.nutritionBasis = JSONValue.string(raw["basis"])
            matched += 1
        }
        guard matched > 0 else { throw OpenRouterError.invalidJSON(response.raw) }

        meal.nutritionModel = model
        meal.rawNutritionResponse = response.raw
        if recordAsOriginal {
            meal.estimatedTotalKcal = meal.totalKcal
        }
        save()
    }

    private func save() {
        try? context.save()
    }
}
