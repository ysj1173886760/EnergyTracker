import SwiftData
import SwiftUI

@main
struct EnergyTrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let container: ModelContainer
    @State private var analyzer: MealAnalyzer
    @State private var profileStore = ProfileStore()
    @State private var reviewer = WeeklyReviewer()
    @State private var exerciseAnalyzer: ExerciseAnalyzer
    @State private var coach: HealthCoach
    @State private var notifications = NotificationCenterService()

    init() {
        do {
            container = try ModelContainer(for: Meal.self, FoodItem.self, MealFollowUp.self, WeightEntry.self,
                                           WeeklyReview.self, BodyMeasurement.self, BodyAssessment.self,
                                           ExerciseSession.self, ExerciseItem.self, DailySummary.self,
                                           ChatThread.self, ChatMessage.self, TrainingPlan.self)
        } catch {
            fatalError("无法打开本地数据库：\(error)")
        }
        _analyzer = State(initialValue: MealAnalyzer(container: container))
        _exerciseAnalyzer = State(initialValue: ExerciseAnalyzer(container: container))
        _coach = State(initialValue: HealthCoach(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(analyzer)
                .environment(profileStore)
                .environment(reviewer)
                .environment(exerciseAnalyzer)
                .environment(coach)
                .environment(notifications)
                .task {
                    BackgroundTransport.shared.cancelOrphanedTasks()
                    profileStore.refresh(in: container.mainContext)
                    analyzer.resumeInterrupted()
                    exerciseAnalyzer.resumeInterrupted(profile: profileStore.profile)
                    #if DEBUG
                    seedForTesting()
                    #endif
                    await notifications.requestAuthorization()
                    await notifications.reschedule()
                }
        }
        .modelContainer(container)
    }

    #if DEBUG
    /// Simulator testing hooks, passed as SIMCTL_CHILD_ environment variables.
    private func seedForTesting() {
        let env = ProcessInfo.processInfo.environment
        if let key = env["DEBUG_OPENROUTER_API_KEY"], !key.isEmpty {
            KeychainStore.apiKey = key
        }
        if let text = env["DEBUG_SEED_MEAL"], !text.isEmpty {
            let meal = Meal(timestamp: .now, mealType: .suggested(for: .now), note: text, photoFilename: nil)
            container.mainContext.insert(meal)
            try? container.mainContext.save()
            analyzer.analyze(meal)
        }
    }
    #endif
}

struct RootView: View {
    var body: some View {
        TabView {
            TodayView()
                .tabItem { Label("今天", systemImage: "fork.knife") }
            TrendsView()
                .tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }
            CoachView()
                .tabItem { Label("教练", systemImage: "bubble.left.and.text.bubble.right") }
            ReviewView()
                .tabItem { Label("复盘", systemImage: "sparkles") }
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
        }
    }
}
