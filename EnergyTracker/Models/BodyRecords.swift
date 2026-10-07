import Foundation
import SwiftData

/// A body composition snapshot, typically from a smart scale or tape measure. All fields optional.
@Model
final class BodyMeasurement {
    var date: Date = Date()
    var weightKg: Double?
    var bodyFatPct: Double?
    var waistCm: Double?
    var scaleBMR: Double?
    var muscleKg: Double?
    var note: String = ""
    var healthKitSource: String?
    var healthKitFatDate: Date?
    var healthKitWaistDate: Date?

    init(date: Date) {
        self.date = date
    }

    var isEmpty: Bool {
        weightKg == nil && bodyFatPct == nil && waistCm == nil && scaleBMR == nil && muscleKg == nil
    }
}

@Model
final class BodyAssessment {
    var createdAt: Date = Date()
    var model: String = ""
    var contentJSON: String = "{}"
    var rawResponse: String = ""

    init(model: String, content: AssessmentContent, rawResponse: String) {
        self.model = model
        self.rawResponse = rawResponse
        self.content = content
    }

    var content: AssessmentContent? {
        get { try? JSONDecoder().decode(AssessmentContent.self, from: Data(contentJSON.utf8)) }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            contentJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

struct AssessmentContent: Codable {
    struct Action: Codable, Hashable {
        var title: String
        var detail: String
    }

    var headline: String
    var overall: String
    var bodyComposition: String
    var metabolism: String
    var goalFeasibility: String
    var targetWeightKg: Double?
    var targetBodyFatPct: Double?
    var dailyKcal: Int?
    var proteinG: Int?
    var weeklyLossKg: Double?
    var recommendationReason: String
    var risks: [String]
    var actions: [Action]

    init(json: [String: Any]) {
        let recommended = json["recommended"] as? [String: Any] ?? [:]
        headline = JSONValue.string(json["headline"])
        overall = JSONValue.string(json["overall"])
        bodyComposition = JSONValue.string(json["body_composition"])
        metabolism = JSONValue.string(json["metabolism"])
        goalFeasibility = JSONValue.string(json["goal_feasibility"])
        targetWeightKg = JSONValue.double(recommended["target_weight_kg"])
        targetBodyFatPct = JSONValue.double(recommended["target_body_fat_pct"])
        dailyKcal = JSONValue.int(recommended["daily_kcal"])
        proteinG = JSONValue.int(recommended["protein_g"])
        weeklyLossKg = JSONValue.double(recommended["weekly_loss_kg"])
        recommendationReason = JSONValue.string(recommended["reason"])
        risks = (json["risks"] as? [Any] ?? []).map(JSONValue.string).filter { !$0.isEmpty }
        actions = (json["actions"] as? [[String: Any]] ?? []).map {
            Action(title: JSONValue.string($0["title"]), detail: JSONValue.string($0["detail"]))
        }
    }
}
