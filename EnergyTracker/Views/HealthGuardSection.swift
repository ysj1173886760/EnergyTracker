import SwiftData
import SwiftUI

struct HealthGuardSection: View {
    @Environment(ProfileStore.self) private var store
    @Query private var meals: [Meal]
    @Query private var exercises: [ExerciseSession]
    @Query private var weights: [WeightEntry]
    @AppStorage("healthGuard.dismissed") private var dismissedData = Data()

    private var dismissed: [String: Date] {
        (try? JSONDecoder().decode([String: Date].self, from: dismissedData)) ?? [:]
    }
    var body: some View {
        let flags = HealthGuard.flags(
            meals: meals, exercises: exercises, trend: WeightTrend.compute(weights),
            profile: store.profile, goal: store.goal, metrics: store.metrics)
        ForEach(flags.filter { flag in !((dismissed[flag.id]).map { Calendar.current.isDateInToday($0) } ?? false) }) {
            flag in
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label(flag.title, systemImage: "exclamationmark.triangle.fill").font(.headline)
                    Text(flag.detail).font(.footnote)
                    Button("知道了") {
                        var values = dismissed.filter { Calendar.current.isDateInToday($0.value) }
                        values[flag.id] = .now
                        dismissedData = (try? JSONEncoder().encode(values)) ?? Data()
                    }
                    .buttonStyle(.bordered)
                }
                .foregroundStyle(flag.level == .warning ? Color.orange : Color.yellow)
            }
        }
    }
}
