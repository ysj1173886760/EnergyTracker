import SwiftData
import SwiftUI

@main
struct EnergyTrackerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var healthSync: HealthSync
    @State private var usageMonitor = UsageMonitor()
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
        let healthSync = HealthSync()
        let coach = HealthCoach(container: container)
        coach.healthSync = healthSync
        _healthSync = State(initialValue: healthSync)
        _coach = State(initialValue: coach)
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
                .environment(healthSync)
                .environment(usageMonitor)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        Task { await healthSync.sync(context: container.mainContext, profileStore: profileStore) }
                        Task { await usageMonitor.refresh(force: false) }
                    }
                }
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
                    await healthSync.sync(context: container.mainContext, profileStore: profileStore)
                    await usageMonitor.refresh(force: false)
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
