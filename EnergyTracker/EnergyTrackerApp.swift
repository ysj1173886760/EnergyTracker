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
                                           ChatThread.self, ChatMessage.self, TrainingPlan.self, UsageRecord.self)
        } catch {
            fatalError("无法打开本地数据库：\(error)")
        }
        UsageLedger.shared.configure(container: container)
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
            Group {
                #if DEBUG
                if ProcessInfo.processInfo.environment["DEBUG_SEED_USAGE"] == "1" {
                    NavigationStack { CostBreakdownView() }
                } else {
                    RootView()
                }
                #else
                RootView()
                #endif
            }
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
                        #if DEBUG
                        if ProcessInfo.processInfo.environment["DEBUG_SEED_USAGE"] == "1" { return }
                        #endif
                        analyzer.resumeInterrupted()
                        exerciseAnalyzer.resumeInterrupted(profile: profileStore.profile)
                        Task { await healthSync.sync(context: container.mainContext, profileStore: profileStore) }
                        Task { await usageMonitor.refresh(force: false) }
                    }
                }
                .task {
                    #if DEBUG
                    if ProcessInfo.processInfo.environment["DEBUG_SEED_USAGE"] == "1" {
                        seedForTesting()
                        return
                    }
                    #endif
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
        if env["DEBUG_SEED_USAGE"] == "1" {
            let context = container.mainContext
            let existing = (try? context.fetch(FetchDescriptor<UsageRecord>())) ?? []
            if !existing.contains(where: { $0.generationID?.hasPrefix("debug-usage-") == true }) {
                for index in 0..<42 {
                    let feature = AIFeature.allCases[index % AIFeature.allCases.count]
                    let entry = UsageEntry(
                        date: Date.now.addingTimeInterval(-Double(index / 6) * 86400),
                        feature: feature.rawValue, model: index % 2 == 0 ? "google/gemini-flash" : "openai/gpt-test",
                        generationID: "debug-usage-\(index)", promptTokens: 1200, completionTokens: 350,
                        cost: Double(index % 7 + 1) * 0.003, succeeded: index % 9 != 0,
                        subjectID: "debug-meal-\(index / 3)")
                    context.insert(UsageRecord(entry))
                }
                try? context.save()
            }
        }
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
    @State private var selectedTab = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["DEBUG_INITIAL_TAB"] == "trends" { return "trends" }
        #endif
        return "today"
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            TodayView()
                .tabItem { Label("今天", systemImage: "fork.knife") }
                .tag("today")
            TrendsView()
                .tabItem { Label("趋势", systemImage: "chart.xyaxis.line") }
                .tag("trends")
            CoachView()
                .tabItem { Label("教练", systemImage: "bubble.left.and.text.bubble.right") }
                .tag("coach")
            ReviewView()
                .tabItem { Label("复盘", systemImage: "sparkles") }
                .tag("review")
            ProfileView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag("profile")
        }
    }
}
