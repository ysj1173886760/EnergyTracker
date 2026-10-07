import Foundation
import SwiftData

@Model
final class ExerciseSession {
    var id: UUID = UUID()
    var timestamp: Date = Date()
    var text: String = ""
    var statusRaw: String = MealStatus.pending.rawValue
    var errorMessage: String?
    var model: String?
    var rawResponse: String?
    var note: String?
    /// Body weight used for the kcal calculation, fixed at logging time so history doesn't shift.
    var weightKg: Double = 70

    @Relationship(deleteRule: .cascade, inverse: \ExerciseItem.session)
    var items: [ExerciseItem] = []

    init(timestamp: Date, text: String, weightKg: Double) {
        self.timestamp = timestamp
        self.text = text
        self.weightKg = weightKg
    }

    var status: MealStatus {
        get { MealStatus(rawValue: statusRaw) ?? .pending }
        set { statusRaw = newValue.rawValue }
    }

    var sortedItems: [ExerciseItem] { items.sorted { $0.sortIndex < $1.sortIndex } }
    var totalMinutes: Double { items.reduce(0) { $0 + $1.durationMin } }
    var netKcal: Double { items.reduce(0) { $0 + $1.netKcal(weightKg: weightKg) } }

    var summaryText: String {
        let names = sortedItems.map { "\($0.name) \(Int($0.durationMin.rounded()))分钟" }
        return names.isEmpty ? text : names.joined(separator: "、")
    }
}

@Model
final class ExerciseItem {
    var name: String = ""
    var durationMin: Double = 0
    var met: Double = 1
    var intensity: String = ""
    var basis: String = ""
    var sortIndex: Int = 0
    var session: ExerciseSession?

    init(name: String, durationMin: Double, met: Double, sortIndex: Int) {
        self.name = name
        self.durationMin = durationMin
        self.met = met
        self.sortIndex = sortIndex
    }

    /// Energy above resting (MET − 1), since resting burn is already counted in the daily TDEE.
    func netKcal(weightKg: Double) -> Double {
        max(0, met - 1) * weightKg * durationMin / 60
    }
}

@Model
final class DailySummary {
    var date: Date = Date()
    var createdAt: Date = Date()
    var model: String = ""
    var isPartial: Bool = false
    var contentJSON: String = "{}"
    var rawResponse: String = ""

    init(date: Date, model: String, isPartial: Bool, content: DailySummaryContent, rawResponse: String) {
        self.date = date
        self.model = model
        self.isPartial = isPartial
        self.rawResponse = rawResponse
        self.content = content
    }

    var content: DailySummaryContent? {
        get { try? JSONDecoder().decode(DailySummaryContent.self, from: Data(contentJSON.utf8)) }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            contentJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

struct DailySummaryContent: Codable {
    struct Suggestion: Codable, Hashable {
        var type: String
        var title: String
        var detail: String
    }

    var headline: String
    var diet: String
    var exercise: String
    var recentPattern: String
    var suggestions: [Suggestion]
    var tomorrowFocus: String

    init(json: [String: Any]) {
        headline = JSONValue.string(json["headline"])
        diet = JSONValue.string(json["diet"])
        exercise = JSONValue.string(json["exercise"])
        recentPattern = JSONValue.string(json["recent_pattern"])
        suggestions = (json["suggestions"] as? [[String: Any]] ?? []).map {
            Suggestion(type: JSONValue.string($0["type"]), title: JSONValue.string($0["title"]),
                       detail: JSONValue.string($0["detail"]))
        }
        tomorrowFocus = JSONValue.string(json["tomorrow_focus"])
    }
}
