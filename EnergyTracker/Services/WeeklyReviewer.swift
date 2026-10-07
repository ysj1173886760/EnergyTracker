import Foundation
import Observation
import SwiftData
import UIKit

@MainActor
@Observable
final class WeeklyReviewer {
    private(set) var generating: Set<Date> = []
    private(set) var errors: [Date: String] = [:]

    func isGenerating(_ weekStart: Date) -> Bool { generating.contains(weekStart) }

    func generate(_ stats: WeeklyStats, profile: UserProfile, previous: WeeklyReview?, context: ModelContext) {
        let weekStart = stats.weekStart
        guard !generating.contains(weekStart) else { return }
        generating.insert(weekStart)
        errors[weekStart] = nil

        let activity = BackgroundActivity("WeeklyReview")
        Task {
            do {
                let client = try OpenRouterClient.fromKeychain()
                let model = AppSettings.reviewModel
                let input = try Self.payload(stats, profile: profile, previous: previous, context: context)
                let response = try await client.chatJSON(model: model, system: Prompts.weeklyReview, user: [.text(input)])
                let content = ReviewContent(json: response.json)
                guard !content.summary.isEmpty || !content.headline.isEmpty else {
                    throw OpenRouterError.invalidJSON(response.raw)
                }

                let existing = try context.fetch(FetchDescriptor<WeeklyReview>(predicate: #Predicate { $0.weekStart == weekStart }))
                existing.forEach(context.delete)
                context.insert(WeeklyReview(weekStart: weekStart, model: model, isPartial: stats.isPartial,
                                            content: content, rawResponse: response.raw))
                try context.save()
                NotificationCenterService.notifyIfInBackground(title: "周复盘已生成", body: content.headline)
            } catch {
                errors[weekStart] = error.localizedDescription
            }
            generating.remove(weekStart)
            activity.end()
        }
    }

    private static func payload(
        _ stats: WeeklyStats, profile: UserProfile, previous: WeeklyReview?, context: ModelContext
    ) throws -> String {
        let goal = stats.goal
        let dateFormat = Date.FormatStyle().year().month(.twoDigits).day(.twoDigits)
        let weekdayFormat = Date.FormatStyle().weekday(.wide)
        let round: (Double?) -> Any = { $0.map { Int($0.rounded()) } ?? NSNull() }

        var profileInfo: [String: Any] = [
            "daily_kcal_target": goal.kcal,
            "safety_floor_kcal": profile.sex == .male ? 1500 : 1200,
        ]
        if profile.isConfigured {
            profileInfo["sex"] = profile.sex.title
            profileInfo["age"] = profile.age
            profileInfo["height_cm"] = profile.heightCm
            profileInfo["activity"] = "\(profile.activity.title)（\(profile.activity.detail)）"
            profileInfo["weekly_loss_target_kg"] = profile.weeklyLossKg
            if let goalWeight = profile.goalWeightKg { profileInfo["goal_weight_kg"] = goalWeight }
        }
        if let protein = goal.proteinG { profileInfo["daily_protein_target_g"] = protein }
        if let bmr = goal.bmr { profileInfo["bmr"] = bmr }
        if let tdee = goal.tdee { profileInfo["tdee"] = tdee }

        let mealShare = Dictionary(uniqueKeysWithValues: stats.mealTypeShare.map { ($0.key.title, (100 * $0.value).rounded() / 100) })
        let statsInfo: [String: Any] = [
            "logged_days": stats.loggedDays.count,
            "days_elapsed": stats.days.count,
            "avg_kcal": round(stats.avgKcal),
            "avg_protein_g": round(stats.avgProtein),
            "weekday_avg_kcal": round(stats.weekdayAvgKcal),
            "weekend_avg_kcal": round(stats.weekendAvgKcal),
            "days_over_target": stats.daysOverTarget,
            "meal_kcal_share": mealShare,
            "exercise_days": stats.exerciseDays,
            "total_exercise_kcal": Int(stats.totalExerciseKcal.rounded()),
        ]

        let days: [[String: Any]] = stats.days.map { day in
            var info: [String: Any] = [
                "date": day.date.formatted(dateFormat),
                "weekday": day.date.formatted(weekdayFormat),
                "logged": day.logged,
            ]
            if !day.exercises.isEmpty {
                info["exercise_kcal"] = Int(day.exerciseKcal.rounded())
                info["exercises"] = day.exercises.map(\.summaryText)
            }
            guard day.logged else { return info }
            info["kcal"] = Int(day.kcal.rounded())
            info["protein_g"] = Int(day.protein.rounded())
            info["fat_g"] = Int(day.fat.rounded())
            info["carbs_g"] = Int(day.carbs.rounded())
            info.merge(NutritionTotals(meals: day.meals).payload) { _, new in new }
            info["meals"] = day.meals.map { meal -> [String: Any] in
                var entry: [String: Any] = [
                    "type": meal.mealType.title,
                    "time": meal.timestamp.formatted(date: .omitted, time: .shortened),
                    "kcal": Int(meal.totalKcal.rounded()),
                    "items": meal.sortedItems.map { "\($0.name) \(Int($0.grams.rounded()))g" },
                ]
                if !meal.note.isEmpty { entry["note"] = meal.note }
                return entry
            }
            return info
        }

        var weight: [String: Any] = [
            "entries": stats.weights.map { ["date": $0.date.formatted(dateFormat), "kg": ($0.kg * 10).rounded() / 10] },
        ]
        if let start = stats.trendStartKg { weight["trend_start_kg"] = (start * 10).rounded() / 10 }
        if let end = stats.trendEndKg { weight["trend_end_kg"] = (end * 10).rounded() / 10 }
        if let change = stats.trendChangeKg { weight["trend_change_kg"] = (change * 100).rounded() / 100 }

        let allWeights = try context.fetch(FetchDescriptor<WeightEntry>())
        let cutoff = min(Date.now, stats.weekEnd)
        let points = WeightTrend.compute(allWeights.filter { $0.date < cutoff })
        let metrics = points.last.map { BodyMetrics(profile: profile, weightKg: $0.trendKg, body: BodySnapshot()) }
        let flags = HealthGuard.flags(
            meals: try context.fetch(FetchDescriptor<Meal>()),
            exercises: try context.fetch(FetchDescriptor<ExerciseSession>()),
            trend: points, profile: profile, goal: goal, metrics: metrics, now: cutoff)
        var payload: [String: Any] = [
            "health_flags": flags.map(\.payload),
            "week": "\(stats.weekStart.formatted(dateFormat)) 至 \(stats.weekEnd.addingTimeInterval(-1).formatted(dateFormat))",
            "is_partial_week": stats.isPartial,
            "profile": profileInfo,
            "stats": statsInfo,
            "days": days,
            "weight": weight,
        ]
        if let content = previous?.content {
            payload["previous_review"] = [
                "focus": content.focus,
                "diet_suggestions": content.dietSuggestions.map(\.title),
                "exercise_suggestions": content.exerciseSuggestions.map(\.title),
            ]
        }

        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }
}
