import Foundation
import Observation
import SwiftData
import UIKit

/// Parses a free-text exercise description into items with MET values; kcal is computed locally.
@MainActor
@Observable
final class ExerciseAnalyzer {
    private let context: ModelContext
    private var running: Set<UUID> = []

    init(container: ModelContainer) {
        context = container.mainContext
    }

    func isRunning(_ session: ExerciseSession) -> Bool {
        running.contains(session.id)
    }

    func estimate(_ session: ExerciseSession, profile: UserProfile) {
        guard !running.contains(session.id) else { return }
        running.insert(session.id)
        session.status = .estimating
        session.errorMessage = nil
        save()

        let activity = BackgroundActivity("EstimateExercise")
        Task {
            do {
                try await run(session, profile: profile)
                session.status = .done
                NotificationCenterService.notifyIfInBackground(
                    title: "运动估算完成", body: "消耗约 \(session.netKcal.kcalText) kcal：\(session.summaryText)")
            } catch {
                session.status = .failed
                session.errorMessage = error.localizedDescription
                NotificationCenterService.notifyIfInBackground(title: "运动估算失败", body: error.localizedDescription)
            }
            running.remove(session.id)
            save()
            activity.end()
        }
    }

    func resumeInterrupted(profile: UserProfile) {
        let sessions = (try? context.fetch(FetchDescriptor<ExerciseSession>())) ?? []
        for session in sessions where session.status.isInProgress {
            estimate(session, profile: profile)
        }
    }

    private func run(_ session: ExerciseSession, profile: UserProfile) async throws {
        let client = try OpenRouterClient.fromKeychain()
        var user: [String: Any] = ["weight_kg": (session.weightKg * 10).rounded() / 10]
        if profile.isConfigured {
            user["sex"] = profile.sex.title
            user["age"] = profile.age
        }
        let payload: [String: Any] = ["description": session.text, "user": user]
        let input = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)

        let model = AppSettings.exerciseModel
        let response = try await client.chatJSON(model: model, system: Prompts.exercise, user: [.text(input)])
        guard let rawItems = response.json["items"] as? [[String: Any]] else {
            throw OpenRouterError.invalidJSON(response.raw)
        }

        session.items.forEach(context.delete)
        session.items = []
        for (index, raw) in rawItems.enumerated() {
            let item = ExerciseItem(
                name: JSONValue.string(raw["name"]),
                durationMin: JSONValue.double(raw["duration_min"]) ?? 0,
                met: JSONValue.double(raw["met"]) ?? 3,
                sortIndex: index
            )
            item.intensity = JSONValue.string(raw["intensity"])
            item.basis = JSONValue.string(raw["basis"])
            session.items.append(item)
        }
        let note = JSONValue.string(response.json["note"])
        session.note = note.isEmpty ? nil : note
        session.model = model
        session.rawResponse = response.raw
    }

    private func save() {
        try? context.save()
    }
}
