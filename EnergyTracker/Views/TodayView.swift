import SwiftData
import SwiftUI

struct TodayView: View {
    @State private var selectedDate = Calendar.current.startOfDay(for: .now)
    @State private var showingAdd = false
    @State private var hasAPIKey = KeychainStore.apiKey != nil

    private var isToday: Bool { Calendar.current.isDateInToday(selectedDate) }

    var body: some View {
        NavigationStack {
            DayMealList(date: selectedDate, showsTodayExtras: true, showsMissingKeyHint: !hasAPIKey)
                .navigationTitle(isToday ? "今天" : selectedDate.formatted(.dateTime.month().day().weekday()))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }
                        Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }
                            .disabled(isToday)
                        if !isToday {
                            Button("今天") { selectedDate = Calendar.current.startOfDay(for: .now) }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showingAdd = true } label: { Image(systemName: "plus.circle.fill").font(.title3) }
                    }
                }
                .sheet(isPresented: $showingAdd) {
                    AddMealView(day: selectedDate)
                }
                .onAppear { hasAPIKey = KeychainStore.apiKey != nil }
        }
    }

    private func shiftDay(_ delta: Int) {
        selectedDate = Calendar.current.date(byAdding: .day, value: delta, to: selectedDate)!
    }
}

struct DayMealList: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Query private var meals: [Meal]
    @Query private var weights: [WeightEntry]
    @Query private var exercises: [ExerciseSession]
    @Query private var summaries: [DailySummary]
    private let date: Date
    private let showsTodayExtras: Bool
    private let showsMissingKeyHint: Bool

    @State private var editingWeight = false
    @State private var editingProfile = false
    @State private var addingExercise = false

    init(date: Date, showsTodayExtras: Bool = false, showsMissingKeyHint: Bool = false) {
        let (start, end) = Calendar.current.dayRange(for: date)
        _meals = Query(filter: #Predicate<Meal> { $0.timestamp >= start && $0.timestamp < end },
                       sort: \Meal.timestamp)
        _weights = Query(filter: #Predicate<WeightEntry> { $0.date >= start && $0.date < end })
        _exercises = Query(filter: #Predicate<ExerciseSession> { $0.timestamp >= start && $0.timestamp < end },
                           sort: \ExerciseSession.timestamp)
        _summaries = Query(filter: #Predicate<DailySummary> { $0.date >= start && $0.date < end })
        self.date = date
        self.showsTodayExtras = showsTodayExtras
        self.showsMissingKeyHint = showsMissingKeyHint
    }

    var body: some View {
        List {
            if showsMissingKeyHint {
                Section {
                    Label("请先到「我的 → 模型与 API Key」中填写 OpenRouter API Key", systemImage: "key.fill")
                        .foregroundStyle(.orange)
                }
            }
            if showsTodayExtras, !profileStore.profile.isConfigured {
                Section {
                    Button { editingProfile = true } label: {
                        Label("填写身高体重和目标，自动计算每日热量和蛋白质目标", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            Section {
                DailySummaryCard(
                    kcal: meals.reduce(0) { $0 + $1.totalKcal },
                    protein: meals.reduce(0) { $0 + $1.totalProtein },
                    fat: meals.reduce(0) { $0 + $1.totalFat },
                    carbs: meals.reduce(0) { $0 + $1.totalCarbs },
                    goal: profileStore.goal,
                    exerciseBonus: exerciseBonus
                )
                if showsTodayExtras {
                    weightRow
                }
            }
            Section(meals.isEmpty ? "" : "餐食") {
                if meals.isEmpty {
                    ContentUnavailableView("还没有记录", systemImage: "camera",
                                           description: Text("点右上角 + 拍照或写一句描述"))
                }
                ForEach(meals) { meal in
                    NavigationLink {
                        MealDetailView(meal: meal)
                    } label: {
                        MealRow(meal: meal)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { delete(meals[index]) }
                }
            }
            TodayPlanSection(date: date, exercises: exercises)
            exerciseSection
            DailySummarySection(date: date, summary: summaries.first, hasData: !meals.isEmpty || !exercises.isEmpty)
        }
        .sheet(isPresented: $editingWeight) {
            WeightEntrySheet(date: Calendar.current.isDateInToday(date) ? .now : date)
        }
        .sheet(isPresented: $editingProfile) {
            NavigationStack { ProfileEditorView() }
        }
        .sheet(isPresented: $addingExercise) {
            AddExerciseView(day: date)
        }
    }

    private var exerciseKcal: Double { exercises.reduce(0) { $0 + $1.netKcal } }

    private var exerciseBonus: Int {
        Int((exerciseKcal * profileStore.profile.eatBackRatio).rounded())
    }

    private var exerciseSection: some View {
        Section {
            ForEach(exercises) { session in
                NavigationLink {
                    ExerciseDetailView(session: session)
                } label: {
                    ExerciseRow(session: session)
                }
            }
            .onDelete { offsets in
                for index in offsets { context.delete(exercises[index]) }
                try? context.save()
            }
            Button { addingExercise = true } label: {
                Label("记录运动", systemImage: "figure.run")
            }
        } header: {
            HStack {
                Text("运动")
                Spacer()
                if exerciseKcal > 0 {
                    Text("消耗 \(exerciseKcal.kcalText) kcal").monospacedDigit()
                }
            }
        } footer: {
            if exerciseKcal > 0 {
                let ratio = Int((profileStore.profile.eatBackRatio * 100).rounded())
                Text("按 \(ratio)% 加回今日额度（+\(exerciseBonus) kcal），可在个人资料中调整比例。")
            }
        }
    }

    private var weightRow: some View {
        Button { editingWeight = true } label: {
            HStack {
                Label("体重", systemImage: "scalemass")
                Spacer()
                if let entry = weights.first {
                    Text("\(entry.kg, specifier: "%.1f") kg").monospacedDigit()
                    if let trend = profileStore.trendWeightKg, Calendar.current.isDateInToday(date) {
                        Text("趋势 \(trend, specifier: "%.1f")").font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("记录体重").foregroundStyle(Color.accentColor)
                }
            }
        }
        .tint(.primary)
    }

    private func delete(_ meal: Meal) {
        if let filename = meal.photoFilename { PhotoStore.delete(filename) }
        context.delete(meal)
        try? context.save()
    }
}
