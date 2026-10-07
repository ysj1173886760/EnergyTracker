import Foundation

struct UserProfile: Codable, Equatable {
    enum Sex: String, Codable, CaseIterable, Identifiable {
        case male
        case female

        var id: String { rawValue }
        var title: String { self == .male ? "男" : "女" }
    }

    enum Activity: String, Codable, CaseIterable, Identifiable {
        case sedentary
        case light
        case moderate
        case active

        var id: String { rawValue }

        var factor: Double {
            switch self {
            case .sedentary: 1.2
            case .light: 1.375
            case .moderate: 1.55
            case .active: 1.725
            }
        }

        var title: String {
            switch self {
            case .sedentary: "久坐"
            case .light: "轻度活动"
            case .moderate: "中度活动"
            case .active: "高强度"
            }
        }

        var detail: String {
            switch self {
            case .sedentary: "办公室工作，基本不运动"
            case .light: "每周运动 1–3 次，或每天步行较多"
            case .moderate: "每周运动 3–5 次"
            case .active: "每周运动 6–7 次，或体力劳动"
            }
        }
    }

    var isConfigured = false
    var sex: Sex = .male
    var birthYear = 1995
    var heightCm: Double = 170
    var activity: Activity = .sedentary
    var goalWeightKg: Double?
    var weeklyLossKg: Double = 0.5
    var proteinPerKg: Double = 1.6
    /// Overrides the computed calorie target when set.
    var manualKcalTarget: Int?
    // Fields added after the first release must stay optional so older saved profiles still decode.
    var targetBodyFatPct: Double?
    var exerciseEatBack: Double?
    var bmrSourceRaw: String?
    var kcalAdjustment: Int?

    var age: Int {
        Calendar.current.component(.year, from: .now) - birthYear
    }

    /// Share of logged exercise kcal added back to the day's budget.
    var eatBackRatio: Double {
        get { exerciseEatBack ?? 0.5 }
        set { exerciseEatBack = newValue }
    }

    var bmrSource: BMRSource {
        get { bmrSourceRaw.flatMap(BMRSource.init) ?? .mifflin }
        set { bmrSourceRaw = newValue.rawValue }
    }

    enum BMRSource: String, CaseIterable, Identifiable {
        case mifflin
        case katch
        case scale

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mifflin: "Mifflin-St Jeor 公式"
            case .katch: "Katch-McArdle 公式（需体脂率）"
            case .scale: "体脂秤测量值"
            }
        }
    }

    static let weeklyLossOptions: [Double] = [0.25, 0.5, 0.75, 1.0]
    static let eatBackOptions: [Double] = [0, 0.25, 0.5, 0.75, 1]
}
