import Foundation
import SwiftData

@Model
final class WeeklyReview {
    var weekStart: Date = Date()
    var createdAt: Date = Date()
    var model: String = ""
    /// Generated before the week ended.
    var isPartial: Bool = false
    var contentJSON: String = "{}"
    var rawResponse: String = ""

    init(weekStart: Date, model: String, isPartial: Bool, content: ReviewContent, rawResponse: String) {
        self.weekStart = weekStart
        self.model = model
        self.isPartial = isPartial
        self.rawResponse = rawResponse
        self.content = content
    }

    var content: ReviewContent? {
        get { try? JSONDecoder().decode(ReviewContent.self, from: Data(contentJSON.utf8)) }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            contentJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

struct ReviewContent: Codable {
    struct Suggestion: Codable, Hashable {
        var title: String
        var detail: String
    }

    var headline: String
    var summary: String
    var wins: [String]
    var issues: [String]
    var dietSuggestions: [Suggestion]
    var exerciseSuggestions: [Suggestion]
    var targetKcal: Int?
    var targetProteinG: Int?
    var targetReason: String
    var focus: String

    init(json: [String: Any]) {
        func strings(_ key: String) -> [String] {
            (json[key] as? [Any] ?? []).map(JSONValue.string).filter { !$0.isEmpty }
        }
        func suggestions(_ key: String) -> [Suggestion] {
            (json[key] as? [[String: Any]] ?? []).map {
                Suggestion(title: JSONValue.string($0["title"]), detail: JSONValue.string($0["detail"]))
            }
        }
        let target = json["target_adjustment"] as? [String: Any] ?? [:]

        headline = JSONValue.string(json["headline"])
        summary = JSONValue.string(json["summary"])
        wins = strings("wins")
        issues = strings("issues")
        dietSuggestions = suggestions("diet_suggestions")
        exerciseSuggestions = suggestions("exercise_suggestions")
        targetKcal = JSONValue.int(target["kcal"])
        targetProteinG = JSONValue.int(target["protein_g"])
        targetReason = JSONValue.string(target["reason"])
        focus = JSONValue.string(json["focus"])
    }
}
