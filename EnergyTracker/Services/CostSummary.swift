import Foundation

enum AIFeature: String, CaseIterable, Codable {
    case vision, textRecognition, revision, nutrition, exercise, assessment, dailySummary, weeklyReview, chat,
         planIntake, trainingPlan

    var title: String {
        switch self {
        case .vision: "拍照识别"
        case .textRecognition: "文字识别"
        case .revision: "补充修正"
        case .nutrition: "热量估算"
        case .exercise: "运动解析"
        case .assessment: "身体评估"
        case .dailySummary: "每日总结"
        case .weeklyReview: "每周复盘"
        case .chat: "教练聊天"
        case .planIntake: "计划问答"
        case .trainingPlan: "训练计划"
        }
    }

    var symbol: String {
        switch self {
        case .vision: "camera"
        case .textRecognition: "text.bubble"
        case .revision: "pencil"
        case .nutrition: "fork.knife"
        case .exercise: "figure.run"
        case .assessment: "heart.text.square"
        case .dailySummary: "sun.max"
        case .weeklyReview: "calendar"
        case .chat: "bubble.left"
        case .planIntake: "questionmark.bubble"
        case .trainingPlan: "list.bullet.clipboard"
        }
    }
}

struct UsageEntry: Codable {
    var date = Date()
    var feature: String
    var model: String
    var provider: String?
    var generationID: String?
    var promptTokens: Int?
    var completionTokens: Int?
    var reasoningTokens: Int?
    var cost: Double?
    var succeeded = false
    var errorSummary: String?
    var subjectID: String?

    var tokens: Int { (promptTokens ?? 0) + (completionTokens ?? 0) }
    var deduplicationKey: String {
        if let generationID, !generationID.isEmpty { return "generation:" + generationID }
        return "fallback:\(date.timeIntervalSince1970)|\(model)|\(feature)"
    }
}

enum UsageParser {
    static func parse(_ object: [String: Any], model: String, feature: AIFeature,
                      subjectID: String? = nil, date: Date = .now) -> UsageEntry {
        let usage = object["usage"] as? [String: Any] ?? [:]
        let details = usage["completion_tokens_details"] as? [String: Any]
        return UsageEntry(date: date, feature: feature.rawValue, model: model,
                          provider: object["provider"] as? String, generationID: object["id"] as? String,
                          promptTokens: JSONValue.int(usage["prompt_tokens"]),
                          completionTokens: JSONValue.int(usage["completion_tokens"]),
                          reasoningTokens: JSONValue.int(details?["reasoning_tokens"]),
                          cost: JSONValue.double(usage["cost"]), subjectID: subjectID)
    }
}

enum CostPeriod: String, CaseIterable {
    case today = "今天", week = "7 天", month = "30 天", all = "全部"
}

enum CostSummary {
    struct Group: Identifiable {
        let id: String
        let entries: [UsageEntry]
        var count: Int { entries.count }
        var cost: Double { entries.compactMap(\.cost).reduce(0, +) }
        var average: Double { count == 0 ? 0 : cost / Double(count) }
        var tokens: Int { entries.reduce(0) { $0 + $1.tokens } }
    }

    static func filter(_ entries: [UsageEntry], period: CostPeriod, now: Date = .now,
                       calendar: Calendar = .current) -> [UsageEntry] {
        let days: Int
        switch period {
        case .today: days = 0
        case .week: days = 6
        case .month: days = 29
        case .all: return entries.filter { $0.date <= now }
        }
        let start = calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!
        return entries.filter { $0.date >= start && $0.date <= now }
    }

    static func groups(_ entries: [UsageEntry], by key: KeyPath<UsageEntry, String>) -> [Group] {
        Dictionary(grouping: entries, by: { $0[keyPath: key] }).map { Group(id: $0.key, entries: $0.value) }
            .sorted { $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost }
    }

    static func mealAverage(_ entries: [UsageEntry]) -> Double? {
        let meals = Dictionary(grouping: entries.filter {
            $0.subjectID != nil && ["vision", "nutrition", "revision"].contains($0.feature)
        }, by: { $0.subjectID! })
        guard !meals.isEmpty else { return nil }
        return meals.values.reduce(0) { $0 + $1.compactMap(\.cost).reduce(0, +) } / Double(meals.count)
    }

    static func money(_ value: Double) -> String { String(format: "$%.4f", value) }
}

extension UsageEntry {
    private enum CodingKeys: String, CodingKey {
        case date, feature, model, provider, generationID, promptTokens, completionTokens
        case reasoningTokens, cost, succeeded, errorSummary, subjectID
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        date = Date(timeIntervalSince1970: try values.decode(Double.self, forKey: .date))
        feature = try values.decode(String.self, forKey: .feature)
        model = try values.decode(String.self, forKey: .model)
        provider = try values.decodeIfPresent(String.self, forKey: .provider)
        generationID = try values.decodeIfPresent(String.self, forKey: .generationID)
        promptTokens = try values.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try values.decodeIfPresent(Int.self, forKey: .completionTokens)
        reasoningTokens = try values.decodeIfPresent(Int.self, forKey: .reasoningTokens)
        cost = try values.decodeIfPresent(Double.self, forKey: .cost)
        succeeded = try values.decode(Bool.self, forKey: .succeeded)
        errorSummary = try values.decodeIfPresent(String.self, forKey: .errorSummary)
        subjectID = try values.decodeIfPresent(String.self, forKey: .subjectID)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(date.timeIntervalSince1970, forKey: .date)
        try values.encode(feature, forKey: .feature)
        try values.encode(model, forKey: .model)
        try values.encodeIfPresent(provider, forKey: .provider)
        try values.encodeIfPresent(generationID, forKey: .generationID)
        try values.encodeIfPresent(promptTokens, forKey: .promptTokens)
        try values.encodeIfPresent(completionTokens, forKey: .completionTokens)
        try values.encodeIfPresent(reasoningTokens, forKey: .reasoningTokens)
        try values.encodeIfPresent(cost, forKey: .cost)
        try values.encode(succeeded, forKey: .succeeded)
        try values.encodeIfPresent(errorSummary, forKey: .errorSummary)
        try values.encodeIfPresent(subjectID, forKey: .subjectID)
    }
}
