import Foundation

enum AppSettings {
    enum Key {
        static let visionModel = "visionModel"
        static let nutritionModel = "nutritionModel"
        static let nutritionReasoning = "nutritionReasoning"
        static let reviewModel = "reviewModel"
        static let exerciseModel = "exerciseModel"
    }

    static let defaultVisionModel = "qwen/qwen3.8-max-0902"
    static let defaultNutritionModel = "deepseek/deepseek-v4.1-flash"
    static let defaultReviewModel = "moonshotai/kimi-k3"
    static let defaultExerciseModel = "moonshotai/kimi-k3"

    static let exerciseModelSuggestions = [
        "moonshotai/kimi-k3",
        "z-ai/glm-5.3",
        "deepseek/deepseek-v4.1-flash",
        "qwen/qwen3.8-max-0902",
    ]

    static var exerciseModel: String {
        let value = UserDefaults.standard.string(forKey: Key.exerciseModel)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? defaultExerciseModel : value
    }

    static let reviewModelSuggestions = [
        "moonshotai/kimi-k3",
        "deepseek/deepseek-v4.1-flash",
        "deepseek/deepseek-v4-pro-0813",
    ]

    static var reviewModel: String {
        let value = UserDefaults.standard.string(forKey: Key.reviewModel)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? defaultReviewModel : value
    }

    static let visionModelSuggestions = [
        "qwen/qwen3.8-max-0902",
        "qwen/qwen3.7-plus",
        "qwen/qwen3.8-max-prime",
        "z-ai/glm-5v-turbo",
    ]

    static let nutritionModelSuggestions = [
        "deepseek/deepseek-v4.1-flash",
        "xiaomi/mimo-v2.6-pro",
        "z-ai/glm-5.3",
        "deepseek/deepseek-v4-pro-0813",
    ]

    static var visionModel: String {
        let value = UserDefaults.standard.string(forKey: Key.visionModel)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? defaultVisionModel : value
    }

    static var nutritionModel: String {
        let value = UserDefaults.standard.string(forKey: Key.nutritionModel)?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? defaultNutritionModel : value
    }

    static var nutritionReasoning: Bool {
        UserDefaults.standard.object(forKey: Key.nutritionReasoning) as? Bool ?? true
    }
}
