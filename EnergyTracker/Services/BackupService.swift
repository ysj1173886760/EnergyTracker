import Foundation
import SwiftData

/// Full export/import of local data as a single JSON file (photos embedded as base64).
@MainActor
enum BackupService {
    struct Backup: Codable {
        var version = 1
        var exportedAt = Date()
        var profile: UserProfile
        var weights: [Weight]
        var meals: [MealRecord]
        var reviews: [Review]?
        var measurements: [Measurement]?
        var assessments: [Assessment]?
        var exercises: [Exercise]?
        var dailySummaries: [Summary]?
        var plans: [Plan]?
        var threads: [Thread]?
    }

    struct Plan: Codable {
        var id: UUID
        var createdAt: Date
        var model: String
        var isActive: Bool
        var contentJSON: String
        var rawResponse: String
    }

    struct Thread: Codable {
        struct Message: Codable {
            var createdAt: Date
            var role: String
            var content: String
        }

        var id: UUID
        var createdAt: Date
        var updatedAt: Date
        var title: String
        var kind: String
        var messages: [Message]
    }

    struct Measurement: Codable {
        var date: Date
        var weightKg: Double?
        var bodyFatPct: Double?
        var waistCm: Double?
        var scaleBMR: Double?
        var muscleKg: Double?
        var note: String
    }

    struct Assessment: Codable {
        var createdAt: Date
        var model: String
        var contentJSON: String
        var rawResponse: String
    }

    struct Exercise: Codable {
        struct Item: Codable {
            var name: String
            var durationMin: Double
            var met: Double
            var intensity: String
            var basis: String
            var sortIndex: Int
        }

        var id: UUID
        var timestamp: Date
        var text: String
        var status: String
        var errorMessage: String?
        var model: String?
        var rawResponse: String?
        var note: String?
        var weightKg: Double
        var items: [Item]
    }

    struct Summary: Codable {
        var date: Date
        var createdAt: Date
        var model: String
        var isPartial: Bool
        var contentJSON: String
        var rawResponse: String
    }

    struct Review: Codable {
        var weekStart: Date
        var createdAt: Date
        var model: String
        var isPartial: Bool
        var contentJSON: String
        var rawResponse: String
    }

    struct Weight: Codable {
        var date: Date
        var kg: Double
    }

    struct MealRecord: Codable {
        var id: UUID
        var timestamp: Date
        var mealType: String
        var note: String
        var status: String
        var errorMessage: String?
        var sceneNotes: String?
        var visionModel: String?
        var nutritionModel: String?
        var rawVisionResponse: String?
        var rawNutritionResponse: String?
        var estimatedTotalKcal: Double?
        var photoFilename: String?
        var photo: Data?
        var items: [Item]
        var followUps: [FollowUp]
    }

    struct Item: Codable {
        var name: String
        var detail: String
        var grams: Double
        var estimatedGrams: Double?
        var count: Int?
        var portionBasis: String
        var confidence: Double?
        var kcalPer100g: Double?
        var proteinPer100g: Double?
        var fatPer100g: Double?
        var carbsPer100g: Double?
        var nutritionBasis: String
        var sortIndex: Int
    }

    struct FollowUp: Codable {
        var text: String
        var createdAt: Date
        var reply: String?
    }

    struct ImportSummary {
        var meals = 0
        var skippedMeals = 0
        var weights = 0
        var exercises = 0
        var profileRestored = false
    }

    static func export(context: ModelContext, profile: UserProfile, includePhotos: Bool) throws -> URL {
        let meals = try context.fetch(FetchDescriptor<Meal>(sortBy: [SortDescriptor(\.timestamp)]))
        let weights = try context.fetch(FetchDescriptor<WeightEntry>(sortBy: [SortDescriptor(\.date)]))
        let reviews = try context.fetch(FetchDescriptor<WeeklyReview>(sortBy: [SortDescriptor(\.weekStart)]))
        let measurements = try context.fetch(FetchDescriptor<BodyMeasurement>(sortBy: [SortDescriptor(\.date)]))
        let assessments = try context.fetch(FetchDescriptor<BodyAssessment>(sortBy: [SortDescriptor(\.createdAt)]))
        let exercises = try context.fetch(FetchDescriptor<ExerciseSession>(sortBy: [SortDescriptor(\.timestamp)]))
        let summaries = try context.fetch(FetchDescriptor<DailySummary>(sortBy: [SortDescriptor(\.date)]))
        let plans = try context.fetch(FetchDescriptor<TrainingPlan>(sortBy: [SortDescriptor(\.createdAt)]))
        let threads = try context.fetch(FetchDescriptor<ChatThread>(sortBy: [SortDescriptor(\.createdAt)]))

        let backup = Backup(
            profile: profile,
            weights: weights.map { Weight(date: $0.date, kg: $0.kg) },
            meals: meals.map { meal in
                MealRecord(
                    id: meal.id, timestamp: meal.timestamp, mealType: meal.mealTypeRaw, note: meal.note,
                    status: meal.statusRaw, errorMessage: meal.errorMessage, sceneNotes: meal.sceneNotes,
                    visionModel: meal.visionModel, nutritionModel: meal.nutritionModel,
                    rawVisionResponse: meal.rawVisionResponse, rawNutritionResponse: meal.rawNutritionResponse,
                    estimatedTotalKcal: meal.estimatedTotalKcal, photoFilename: meal.photoFilename,
                    photo: includePhotos ? meal.photoFilename.flatMap(PhotoStore.rawData) : nil,
                    items: meal.sortedItems.map { item in
                        Item(name: item.name, detail: item.detail, grams: item.grams, estimatedGrams: item.estimatedGrams,
                             count: item.count, portionBasis: item.portionBasis, confidence: item.confidence,
                             kcalPer100g: item.kcalPer100g, proteinPer100g: item.proteinPer100g,
                             fatPer100g: item.fatPer100g, carbsPer100g: item.carbsPer100g,
                             nutritionBasis: item.nutritionBasis, sortIndex: item.sortIndex)
                    },
                    followUps: meal.sortedFollowUps.map { FollowUp(text: $0.text, createdAt: $0.createdAt, reply: $0.reply) }
                )
            },
            reviews: reviews.map {
                Review(weekStart: $0.weekStart, createdAt: $0.createdAt, model: $0.model, isPartial: $0.isPartial,
                       contentJSON: $0.contentJSON, rawResponse: $0.rawResponse)
            },
            measurements: measurements.map {
                Measurement(date: $0.date, weightKg: $0.weightKg, bodyFatPct: $0.bodyFatPct, waistCm: $0.waistCm,
                            scaleBMR: $0.scaleBMR, muscleKg: $0.muscleKg, note: $0.note)
            },
            assessments: assessments.map {
                Assessment(createdAt: $0.createdAt, model: $0.model, contentJSON: $0.contentJSON, rawResponse: $0.rawResponse)
            },
            exercises: exercises.map { session in
                Exercise(id: session.id, timestamp: session.timestamp, text: session.text, status: session.statusRaw,
                         errorMessage: session.errorMessage, model: session.model, rawResponse: session.rawResponse,
                         note: session.note, weightKg: session.weightKg,
                         items: session.sortedItems.map {
                             Exercise.Item(name: $0.name, durationMin: $0.durationMin, met: $0.met,
                                           intensity: $0.intensity, basis: $0.basis, sortIndex: $0.sortIndex)
                         })
            },
            dailySummaries: summaries.map {
                Summary(date: $0.date, createdAt: $0.createdAt, model: $0.model, isPartial: $0.isPartial,
                        contentJSON: $0.contentJSON, rawResponse: $0.rawResponse)
            },
            plans: plans.map {
                Plan(id: $0.id, createdAt: $0.createdAt, model: $0.model, isActive: $0.isActive,
                     contentJSON: $0.contentJSON, rawResponse: $0.rawResponse)
            },
            threads: threads.map { thread in
                Thread(id: thread.id, createdAt: thread.createdAt, updatedAt: thread.updatedAt, title: thread.title,
                       kind: thread.kind,
                       messages: thread.sortedMessages.map { Thread.Message(createdAt: $0.createdAt, role: $0.role, content: $0.content) })
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(backup)

        let stamp = Date().formatted(.iso8601.year().month().day())
        let url = FileManager.default.temporaryDirectory.appending(path: "健康助手备份-\(stamp).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Merges a backup into local data. Meals already present (same id) and days that already
    /// have a weight are skipped, so importing the same file twice is harmless.
    static func importBackup(from url: URL, context: ModelContext, profileStore: ProfileStore) throws -> ImportSummary {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(Backup.self, from: Data(contentsOf: url))
        var summary = ImportSummary()

        let existingIDs = Set(try context.fetch(FetchDescriptor<Meal>()).map(\.id))
        for record in backup.meals {
            guard !existingIDs.contains(record.id) else {
                summary.skippedMeals += 1
                continue
            }
            var filename = record.photoFilename
            if let photo = record.photo, let name = filename {
                try? PhotoStore.restore(photo, filename: name)
            } else if record.photo == nil, let name = filename, PhotoStore.rawData(name) == nil {
                filename = nil
            }

            let meal = Meal(timestamp: record.timestamp, mealType: MealType(rawValue: record.mealType) ?? .snack,
                            note: record.note, photoFilename: filename)
            meal.id = record.id
            meal.statusRaw = record.status
            if meal.status.isInProgress {
                meal.status = .failed
                meal.errorMessage = "备份时尚未完成识别"
            } else {
                meal.errorMessage = record.errorMessage
            }
            meal.sceneNotes = record.sceneNotes
            meal.visionModel = record.visionModel
            meal.nutritionModel = record.nutritionModel
            meal.rawVisionResponse = record.rawVisionResponse
            meal.rawNutritionResponse = record.rawNutritionResponse
            meal.estimatedTotalKcal = record.estimatedTotalKcal
            context.insert(meal)

            for raw in record.items {
                let item = FoodItem(name: raw.name, detail: raw.detail, grams: raw.grams, sortIndex: raw.sortIndex)
                item.estimatedGrams = raw.estimatedGrams
                item.count = raw.count
                item.portionBasis = raw.portionBasis
                item.confidence = raw.confidence
                item.kcalPer100g = raw.kcalPer100g
                item.proteinPer100g = raw.proteinPer100g
                item.fatPer100g = raw.fatPer100g
                item.carbsPer100g = raw.carbsPer100g
                item.nutritionBasis = raw.nutritionBasis
                meal.items.append(item)
            }
            for raw in record.followUps {
                let followUp = MealFollowUp(text: raw.text)
                followUp.createdAt = raw.createdAt
                followUp.reply = raw.reply ?? "导入"
                meal.followUps.append(followUp)
            }
            summary.meals += 1
        }

        let calendar = Calendar.current
        let existingDays = Set(try context.fetch(FetchDescriptor<WeightEntry>()).map { calendar.startOfDay(for: $0.date) })
        for weight in backup.weights where !existingDays.contains(calendar.startOfDay(for: weight.date)) {
            context.insert(WeightEntry(date: weight.date, kg: weight.kg))
            summary.weights += 1
        }

        let existingWeeks = Set(try context.fetch(FetchDescriptor<WeeklyReview>()).map(\.weekStart))
        for raw in backup.reviews ?? [] where !existingWeeks.contains(raw.weekStart) {
            guard let content = try? JSONDecoder().decode(ReviewContent.self, from: Data(raw.contentJSON.utf8)) else { continue }
            let review = WeeklyReview(weekStart: raw.weekStart, model: raw.model, isPartial: raw.isPartial,
                                      content: content, rawResponse: raw.rawResponse)
            review.createdAt = raw.createdAt
            context.insert(review)
        }

        let existingMeasurements = Set(try context.fetch(FetchDescriptor<BodyMeasurement>()).map(\.date))
        for raw in backup.measurements ?? [] where !existingMeasurements.contains(raw.date) {
            let measurement = BodyMeasurement(date: raw.date)
            measurement.weightKg = raw.weightKg
            measurement.bodyFatPct = raw.bodyFatPct
            measurement.waistCm = raw.waistCm
            measurement.scaleBMR = raw.scaleBMR
            measurement.muscleKg = raw.muscleKg
            measurement.note = raw.note
            context.insert(measurement)
        }

        let existingAssessments = Set(try context.fetch(FetchDescriptor<BodyAssessment>()).map(\.createdAt))
        for raw in backup.assessments ?? [] where !existingAssessments.contains(raw.createdAt) {
            guard let content = try? JSONDecoder().decode(AssessmentContent.self, from: Data(raw.contentJSON.utf8)) else { continue }
            let assessment = BodyAssessment(model: raw.model, content: content, rawResponse: raw.rawResponse)
            assessment.createdAt = raw.createdAt
            context.insert(assessment)
        }

        let existingExercises = Set(try context.fetch(FetchDescriptor<ExerciseSession>()).map(\.id))
        for raw in backup.exercises ?? [] where !existingExercises.contains(raw.id) {
            let session = ExerciseSession(timestamp: raw.timestamp, text: raw.text, weightKg: raw.weightKg)
            session.id = raw.id
            session.statusRaw = raw.status
            if session.status.isInProgress {
                session.status = .failed
                session.errorMessage = "备份时尚未完成估算"
            } else {
                session.errorMessage = raw.errorMessage
            }
            session.model = raw.model
            session.rawResponse = raw.rawResponse
            session.note = raw.note
            context.insert(session)
            for item in raw.items {
                let entry = ExerciseItem(name: item.name, durationMin: item.durationMin, met: item.met, sortIndex: item.sortIndex)
                entry.intensity = item.intensity
                entry.basis = item.basis
                session.items.append(entry)
            }
            summary.exercises += 1
        }

        let existingSummaryDays = Set(try context.fetch(FetchDescriptor<DailySummary>()).map(\.date))
        for raw in backup.dailySummaries ?? [] where !existingSummaryDays.contains(raw.date) {
            guard let content = try? JSONDecoder().decode(DailySummaryContent.self, from: Data(raw.contentJSON.utf8)) else { continue }
            let daily = DailySummary(date: raw.date, model: raw.model, isPartial: raw.isPartial,
                                     content: content, rawResponse: raw.rawResponse)
            daily.createdAt = raw.createdAt
            context.insert(daily)
        }

        let existingPlans = Set(try context.fetch(FetchDescriptor<TrainingPlan>()).map(\.id))
        let hasActivePlan = try context.fetch(FetchDescriptor<TrainingPlan>(predicate: #Predicate { $0.isActive })).isEmpty == false
        for raw in backup.plans ?? [] where !existingPlans.contains(raw.id) {
            guard let content = try? JSONDecoder().decode(PlanContent.self, from: Data(raw.contentJSON.utf8)) else { continue }
            let plan = TrainingPlan(model: raw.model, content: content, rawResponse: raw.rawResponse)
            plan.id = raw.id
            plan.createdAt = raw.createdAt
            plan.isActive = raw.isActive && !hasActivePlan
            context.insert(plan)
        }

        let existingThreads = Set(try context.fetch(FetchDescriptor<ChatThread>()).map(\.id))
        for raw in backup.threads ?? [] where !existingThreads.contains(raw.id) {
            let thread = ChatThread(kind: raw.kind, title: raw.title)
            thread.id = raw.id
            thread.createdAt = raw.createdAt
            thread.updatedAt = raw.updatedAt
            context.insert(thread)
            for message in raw.messages {
                let entry = ChatMessage(role: message.role, content: message.content)
                entry.createdAt = message.createdAt
                thread.messages.append(entry)
            }
        }

        if !profileStore.profile.isConfigured, backup.profile.isConfigured {
            profileStore.profile = backup.profile
            summary.profileRestored = true
        }

        try context.save()
        profileStore.refresh(in: context)
        return summary
    }
}
