import Foundation
import SwiftData

@Model
final class ChatThread {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var title: String = ""
    /// "chat" for free-form questions, "plan" for the training-plan intake conversation.
    var kind: String = "chat"

    @Relationship(deleteRule: .cascade, inverse: \ChatMessage.thread)
    var messages: [ChatMessage] = []

    init(kind: String, title: String) {
        self.kind = kind
        self.title = title
    }

    var isPlanIntake: Bool { kind == "plan" }
    var sortedMessages: [ChatMessage] { messages.sorted { $0.createdAt < $1.createdAt } }
}

@Model
final class ChatMessage {
    var createdAt: Date = Date()
    var role: String = "user"
    var content: String = ""
    var thread: ChatThread?

    init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    var isUser: Bool { role == "user" }
}

@Model
final class TrainingPlan {
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var model: String = ""
    var isActive: Bool = true
    var contentJSON: String = "{}"
    var rawResponse: String = ""

    init(model: String, content: PlanContent, rawResponse: String) {
        self.model = model
        self.rawResponse = rawResponse
        self.content = content
    }

    var content: PlanContent? {
        get { try? JSONDecoder().decode(PlanContent.self, from: Data(contentJSON.utf8)) }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else { return }
            contentJSON = String(decoding: data, as: UTF8.self)
        }
    }
}

struct PlanContent: Codable {
    struct Exercise: Codable, Hashable {
        var name: String
        var sets: Int?
        var reps: String
        var durationMin: Double?
        var intensity: String
        var notes: String

        var summary: String {
            var parts = [name]
            if let sets, !reps.isEmpty { parts.append("\(sets)组×\(reps)") }
            else if !reps.isEmpty { parts.append(reps) }
            if let durationMin { parts.append("\(Int(durationMin.rounded()))分钟") }
            if !intensity.isEmpty { parts.append(intensity) }
            return parts.joined(separator: " ")
        }
    }

    struct Day: Codable, Hashable {
        /// 1 = Monday … 7 = Sunday.
        var weekday: Int
        var title: String
        var focus: String
        var durationMin: Double?
        var isRest: Bool
        var exercises: [Exercise]
        var notes: String

        static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
        var weekdayName: String { (1...7).contains(weekday) ? Self.weekdayNames[weekday - 1] : "" }

        /// Description used when logging this day's session as an exercise.
        var logText: String {
            let list = exercises.map(\.summary).joined(separator: "；")
            let duration = durationMin.map { "，共约\(Int($0.rounded()))分钟" } ?? ""
            return "按训练计划完成「\(title)」\(duration)：\(list)"
        }
    }

    var title: String
    var summary: String
    var weeks: Int?
    var days: [Day]
    var progression: String
    var tips: [String]
    var cautions: [String]

    init(json: [String: Any]) {
        title = JSONValue.string(json["title"])
        summary = JSONValue.string(json["summary"])
        weeks = JSONValue.int(json["weeks"])
        days = (json["days"] as? [[String: Any]] ?? []).map { raw in
            Day(
                weekday: JSONValue.int(raw["weekday"]) ?? 0,
                title: JSONValue.string(raw["title"]),
                focus: JSONValue.string(raw["focus"]),
                durationMin: JSONValue.double(raw["duration_min"]),
                isRest: (raw["rest"] as? Bool) ?? false,
                exercises: (raw["exercises"] as? [[String: Any]] ?? []).map { item in
                    Exercise(
                        name: JSONValue.string(item["name"]),
                        sets: JSONValue.int(item["sets"]),
                        reps: JSONValue.string(item["reps"]),
                        durationMin: JSONValue.double(item["duration_min"]),
                        intensity: JSONValue.string(item["intensity"]),
                        notes: JSONValue.string(item["notes"])
                    )
                },
                notes: JSONValue.string(raw["notes"])
            )
        }
        .sorted { $0.weekday < $1.weekday }
        progression = JSONValue.string(json["progression"])
        tips = (json["tips"] as? [Any] ?? []).map(JSONValue.string).filter { !$0.isEmpty }
        cautions = (json["cautions"] as? [Any] ?? []).map(JSONValue.string).filter { !$0.isEmpty }
    }

    func day(for date: Date) -> Day? {
        // Calendar weekday: 1 = Sunday … 7 = Saturday.
        let weekday = Calendar.current.component(.weekday, from: date)
        let mondayBased = weekday == 1 ? 7 : weekday - 1
        return days.first { $0.weekday == mondayBased }
    }
}
