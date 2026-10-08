// Run from the repository root: Tests/run-offline.sh
import Foundation
import SwiftData

// No images are used in these backup fixtures.
enum PhotoStore {
    static func rawData(_ filename: String) -> Data? { nil }
    static func restore(_ data: Data, filename: String) throws {}
}
extension Calendar {
    func dayRange(for date: Date) -> (Date, Date) {
        let start = startOfDay(for: date)
        return (start, self.date(byAdding: .day, value: 1, to: start)!)
    }
}

@main
struct OfflineChecks {
    @MainActor
    static func main() throws {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            precondition(condition(), name)
            checks += 1
        }
        let calendar = Calendar.current
        let now = calendar.startOfDay(for: Date())
        func date(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }
        let parsedUsage = UsageParser.parse([
            "id": "generation-1", "provider": "test",
            "usage": ["prompt_tokens": "100", "completion_tokens": 20, "cost": "0.012",
                      "completion_tokens_details": ["reasoning_tokens": "5"]]
        ], model: "requested", feature: .vision)
        check(parsedUsage.promptTokens == 100 && parsedUsage.reasoningTokens == 5, "宽松 usage tokens")
        check(parsedUsage.cost == 0.012 && parsedUsage.model == "requested", "费用及请求模型")
        check(UsageParser.parse([:], model: "m", feature: .chat).cost == nil, "费用缺失不伪造零")
        let usageEntries = [
            UsageEntry(date: date(0), feature: "vision", model: "a", cost: 0.01, subjectID: "meal1"),
            UsageEntry(date: date(-1), feature: "nutrition", model: "b", cost: 0.03, subjectID: "meal1"),
            UsageEntry(date: date(-6), feature: "vision", model: "a", cost: 0.02, subjectID: "meal2"),
            UsageEntry(date: date(-7), feature: "chat", model: "b", cost: nil),
            UsageEntry(date: date(1), feature: "chat", model: "b", cost: 9)
        ]
        check(CostSummary.filter(usageEntries, period: .today, now: now).count == 1, "今天边界")
        check(CostSummary.filter(usageEntries, period: .week, now: now).count == 3, "七天边界")
        check(CostSummary.filter(usageEntries, period: .month, now: now).count == 4, "三十天排除未来")
        check(CostSummary.filter(usageEntries, period: .all, now: now).count == 4, "全部排除未来")
        check(abs((CostSummary.mealAverage(usageEntries) ?? 0) - 0.03) < 0.000001, "按餐合并平均")
        check(CostSummary.mealAverage([]) == nil, "空餐平均")
        let features = CostSummary.groups(Array(usageEntries.prefix(4)), by: \.feature)
        check(features.count == 3 && features.last?.cost == 0, "功能汇总及费用排序")
        check(CostSummary.groups(Array(usageEntries.prefix(4)), by: \.model).first?.count == 2, "模型分组")
        func meal(_ offset: Int, _ kcal: Double, manual: Bool = false) -> Meal {
            let m = Meal(timestamp: date(offset), mealType: .lunch, note: "测试", photoFilename: nil)
            let item = FoodItem(name: "食物", grams: 100, sortIndex: 0)
            item.kcalPer100g = kcal
            if manual { item.portionBasis = FoodItem.manualMarker }
            m.items = [item]
            m.status = .done
            return m
        }
        for count in 0...5 {
            for hasWeight in [false, true] {
                for hasExercise in [false, true] {
                    let score = min(count, 3) + (hasWeight ? 1 : 0) + (hasExercise ? 1 : 0)
                    let expected = [0, 1, 2, 3, 3, 4][score]
                    let day = CheckInDay(date: now, mealCount: count,
                                         hasWeight: hasWeight, hasExercise: hasExercise)
                    check(day.level == expected, "打卡等级及餐数上限")
                }
            }
        }
        let yesterdayStreak = CheckIn(meals: [-3, -2, -1].map { meal($0, 100) },
                                      exercises: [], weights: [], now: now)
        check(yesterdayStreak.currentStreak == 3, "今天未记录从昨天计算连续天数")
        check(yesterdayStreak.recentCount == 3 && yesterdayStreak.recentTotal == 4, "新用户近30天分母含今天")
        let gap = CheckIn(meals: [-10, -9, -8, -7, -3, -2].map { meal($0, 100) },
                          exercises: [], weights: [], now: now)
        check(gap.currentStreak == 0 && gap.longestStreak == 4, "断档归零且保留最长连续")
        let empty = CheckIn(meals: [], exercises: [], weights: [], now: now)
        check(empty.recentTotal == 0 && empty.totalCount == 0 && empty.longestStreak == 0, "无记录统计")
        let pending = meal(-100, 0)
        pending.status = .pending
        let failed = meal(0, 0)
        failed.status = .failed
        let exercise = ExerciseSession(timestamp: date(-1), text: "步行", weightKg: 70)
        exercise.status = .done
        let unfinished = ExerciseSession(timestamp: date(0), text: "步行", weightKg: 70)
        unfinished.status = .failed
        let mixed = CheckIn(meals: [pending, failed, meal(1, 100)], exercises: [exercise, unfinished],
                            weights: [WeightEntry(date: date(-2), kg: 70), WeightEntry(date: date(-2), kg: 71)],
                            now: now)
        check(mixed.currentStreak == 2 && mixed.totalCount == 2, "体重运动独立打卡且同日去重")
        check(mixed.recentTotal == 3 && !mixed.day(on: now).isLogged, "排除未完成和未来记录")
        let fullWindow = CheckIn(meals: [-40, -30, -29, 0].map { meal($0, 100) },
                                exercises: [], weights: [], now: now)
        check(fullWindow.recentTotal == 30 && fullWindow.recentCount == 2, "近30天包含今天及前29天")
        let tie = CheckIn(meals: [-5, -4, -1, 0].map { meal($0, 100) },
                          exercises: [], weights: [], now: now)
        check(tie.currentStreak == 2 && !tie.isNewRecord, "追平历史连续不是新纪录")
        let record = CheckIn(meals: [-5, -4, -2, -1, 0].map { meal($0, 100) },
                             exercises: [], weights: [], now: now)
        check(record.isNewRecord && record.longestStreak == 3, "今天创连续新纪录")
        var dstCalendar = Calendar(identifier: .gregorian)
        dstCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstStart = dstCalendar.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let dstWeights = (0..<3).map {
            WeightEntry(date: dstCalendar.date(byAdding: .day, value: $0, to: dstStart)!, kg: 70)
        }
        let dst = CheckIn(meals: [], exercises: [], weights: dstWeights,
                          now: dstWeights[2].date, calendar: dstCalendar)
        check(dst.currentStreak == 3 && dst.recentTotal == 3, "夏令时按日历天连续计数")

        let sample = meal(-1, 200)
        let item = sample.items[0]
        item.kcalUncertainty = 0.2
        check(abs(EstimateUncertainty.meal(sample) - 200 * sqrt(0.35 * 0.35 + 0.04)) < 0.001, "文字份量误差")
        sample.photoFilename = "fixture.jpg"
        check(abs(EstimateUncertainty.meal(sample) - 200 * sqrt(0.09 + 0.04)) < 0.001, "照片缺少置信度")
        item.estimatedGrams = 101
        check(EstimateUncertainty.gramsEdited(item), "1g 编辑边界")
        check(abs(EstimateUncertainty.meal(sample) - 200 * sqrt(0.0025 + 0.04)) < 0.001, "手动修改份量误差")
        item.portionBasis = FoodItem.manualMarker
        check(EstimateUncertainty.meal(sample) == 0, "手动记录误差为零")
        let two = [meal(-1, 200), meal(-1, 200)]
        check(abs(EstimateUncertainty.day(two) - sqrt(2) * EstimateUncertainty.meal(two[0])) < 0.001, "独立误差平方合并")
        item.fiberPer100g = 3
        item.sodiumMgPer100g = 100
        item.addedSugarPer100g = 0
        check(sample.totalAddedSugar == 0 && sample.totalFiber == 3, "已知零与缺失区分")
        check(NutritionTotals(meals: [sample, meal(-1, 400)]).isPartial, "部分营养数据")
        item.clearNutrition()
        check(
            item.fiberPer100g == nil && item.sodiumMgPer100g == nil && item.addedSugarPer100g == nil
                && item.kcalUncertainty == nil, "清空新增营养字段")

        var profile = UserProfile()
        profile.isConfigured = true
        profile.goalWeightKg = 65
        profile.heightCm = 175
        profile.activity = .moderate
        profile.weeklyLossKg = 0.5
        let base = GoalCalculator.goal(profile: profile, weightKg: 70)
        profile.kcalAdjustment = 100
        check(GoalCalculator.goal(profile: profile, weightKg: 70).kcal == base.kcal + 100, "公式目标校准")
        profile.manualKcalTarget = 1805
        check(GoalCalculator.goal(profile: profile, weightKg: 70).kcal == 1805, "手动目标不叠加校准")
        profile.manualKcalTarget = nil
        profile.kcalAdjustment = -10000
        check(GoalCalculator.goal(profile: profile, weightKg: 70).kcal == 1500, "校准安全下限")
        profile.kcalAdjustment = nil
        let weights = [-21, -18, -15, -12, -9, -7].map { WeightEntry(date: date($0), kg: 70) }
        let meals = (-21 ... -10).map { meal($0, 2500) }
        let goal = NutritionGoal(kcal: 1805, bmr: 1600, tdee: 2200)
        let result = TargetCalibration.calculate(
            meals: meals, exercises: [], weights: weights, profile: profile, goal: goal, currentWeight: 70, now: now)
        check(result.expenditure == 2500, "平稳体重推算消耗")
        check(result.suggestedTarget == 1950, "调整取整不超过150")
        check(
            TargetCalibration.calculate(
                meals: Array(meals.dropLast()), exercises: [], weights: weights, profile: profile, goal: goal,
                currentWeight: 70, now: now
            ).suggestedTarget == nil, "12天门槛")
        check(
            TargetCalibration.calculate(
                meals: meals, exercises: [], weights: Array(weights.dropFirst()), profile: profile, goal: goal,
                currentWeight: 70, now: now
            ).suggestedTarget == nil, "体重条数跨度门槛")
        let withToday = TargetCalibration.calculate(
            meals: meals + [meal(0, 99999)], exercises: [], weights: weights, profile: profile, goal: goal,
            currentWeight: 70, now: now)
        check(withToday.expenditure == result.expenditure, "校准排除今天")
        let stableGoal = NutritionGoal(kcal: 1950)
        check(
            TargetCalibration.calculate(
                meals: meals, exercises: [], weights: weights, profile: profile, goal: stableGoal, currentWeight: 70,
                now: now
            ).suggestedTarget == nil, "差值不足80不建议")

        let historicalWeights = (-90 ... -1).map { offset in
            WeightEntry(date: date(offset), kg: 70 - Double(offset) * 0.1)
        }
        let historicalResult = TargetCalibration.calculate(
            meals: meals, exercises: [], weights: historicalWeights,
            profile: profile, goal: goal, currentWeight: 70, now: now
        )
        let expectedExpenditure = 2500 + 0.1 * 7700
        check(
            abs(Double(historicalResult.expenditure ?? 0) - expectedExpenditure) < 5,
            "窗口前历史保留平滑状态，下降速度接近每周0.7kg")
        check(
            historicalResult.weightCount == 21 && historicalResult.weightSpan == 20,
            "完整历史不计入窗口记录门槛")
        let withTodayWeight = TargetCalibration.calculate(
            meals: meals, exercises: [], weights: historicalWeights + [WeightEntry(date: date(0), kg: 120)],
            profile: profile, goal: goal, currentWeight: 70, now: now
        )
        check(withTodayWeight.expenditure == historicalResult.expenditure, "趋势速度排除今天体重")
        let sparseWindow = historicalWeights.filter { $0.date < date(-21) } + Array(weights.dropFirst())
        let sparseResult = TargetCalibration.calculate(
            meals: meals, exercises: [], weights: sparseWindow,
            profile: profile, goal: goal, currentWeight: 70, now: now
        )
        check(
            sparseResult.suggestedTarget == nil && sparseResult.weightCount == 5,
            "窗口前历史不能补足窗口内体重门槛")

        let metrics = BodyMetrics(profile: profile, weightKg: 70, body: BodySnapshot())
        func flags(_ meals: [Meal], exercises: [ExerciseSession] = [], points: [WeightTrendPoint] = []) -> Set<String> {
            Set(
                HealthGuard.flags(
                    meals: meals, exercises: exercises, trend: points, profile: profile, goal: goal, metrics: metrics,
                    now: now
                ).map(\.id))
        }
        check(flags([meal(0, 100)]).isEmpty, "今天不报警")
        check(!flags([meal(-1, 100), meal(-2, 100)]).contains("low_intake_days"), "少于3天不报警")
        check(flags([meal(-1, 1000), meal(-2, 1000), meal(-3, 1000)]).contains("low_intake_days"), "三天低摄入")
        check(flags((-4 ... -1).map { meal($0, 1500) }).contains("below_bmr"), "四天平均低于BMR")
        check(!flags([meal(-1, 3000), meal(-3, 100)]).contains("restrict_after_overeating"), "缺失日期不视为节食")
        check(
            flags([meal(-4, 3000), meal(-3, 1000), meal(-2, 3000), meal(-1, 1000)]).contains(
                "restrict_after_overeating"), "两次相邻补偿循环")
        let runs = (-3 ... -1).map { offset -> ExerciseSession in
            let session = ExerciseSession(timestamp: date(offset), text: "运动", weightKg: 70)
            session.status = .done
            session.items = [ExerciseItem(name: "跑步", durationMin: 60, met: 11, sortIndex: 0)]
            return session
        }
        check(flags((-3 ... -1).map { meal($0, 1900) }, exercises: runs).contains("low_net_intake"), "三天运动净摄入不足")
        let points = [-14, -7, -1].enumerated().map { index, offset in
            WeightTrendPoint(date: date(offset), kg: 70 - Double(index), trendKg: 70 - Double(index))
        }
        check(flags([], points: points).contains("rapid_weight_loss"), "趋势下降过快")
        profile.goalWeightKg = 45
        check(flags([]).contains("low_target_weight"), "低BMI目标")

        let schema = Schema([
            Meal.self, FoodItem.self, MealFollowUp.self, WeightEntry.self, BodyMeasurement.self,
            BodyAssessment.self, WeeklyReview.self, ExerciseSession.self, ExerciseItem.self,
            DailySummary.self, ChatThread.self, ChatMessage.self, TrainingPlan.self, UsageRecord.self
        ])
        let container = try ModelContainer(for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let backedMeal = meal(-1, 400)
        backedMeal.oilLevelRaw = "less"
        backedMeal.items[0].kcalUncertainty = 0.15
        backedMeal.items[0].fiberPer100g = 4
        backedMeal.items[0].sodiumMgPer100g = 500
        backedMeal.items[0].addedSugarPer100g = 2
        context.insert(backedMeal)
        let weight = WeightEntry(date: date(-1), kg: 70)
        weight.healthKitSampleID = "sample-id"
        context.insert(weight)
        let body = BodyMeasurement(date: date(-1))
        body.healthKitSource = "Apple Health"
        body.healthKitFatDate = date(-1)
        body.bodyFatPct = 20
        context.insert(body)
        context.insert(UsageRecord(parsedUsage))
        context.insert(UsageRecord(usageEntries[0]))
        try context.save()
        profile.kcalAdjustment = 100
        let url = try BackupService.export(context: context, profile: profile, includePhotos: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(BackupService.Backup.self, from: Data(contentsOf: url))
        check(backup.meals[0].oilLevelRaw == "less" && backup.meals[0].items[0].sodiumMgPer100g == 500, "新增餐食字段导出")
        check(
            backup.weights[0].healthKitSampleID == "sample-id" && backup.measurements?[0].healthKitFatDate != nil,
            "健康来源导出")
        check(backup.usageRecords?.count == 2, "调用记录导出")
        check(backup.profile.kcalAdjustment == 100, "校准字段导出")
        let restoredContainer = try ModelContainer(
            for: schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let defaults = UserDefaults.standard
        let savedProfile = defaults.object(forKey: "userProfile")
        defer {
            if let savedProfile {
                defaults.set(savedProfile, forKey: "userProfile")
            } else {
                defaults.removeObject(forKey: "userProfile")
            }
        }
        let store = ProfileStore()
        store.profile = UserProfile()
        _ = try BackupService.importBackup(from: url, context: restoredContainer.mainContext, profileStore: store)
        _ = try BackupService.importBackup(from: url, context: restoredContainer.mainContext, profileStore: store)
        let restoredUsage = try restoredContainer.mainContext.fetch(FetchDescriptor<UsageRecord>())
        check(restoredUsage.count == 2, "重复导入按 generationID 及日期模型功能去重")
        check(restoredUsage.contains { $0.cost == 0.012 && $0.reasoningTokens == 5 }, "调用费用备份往返")
        let restored = try restoredContainer.mainContext.fetch(FetchDescriptor<Meal>())[0]
        check(
            restored.oilLevelRaw == "less" && restored.items[0].kcalUncertainty == 0.15 && restored.totalFiber == 4
                && restored.totalAddedSugar == 2, "新增字段备份往返")
        WeightEntry.upsert(kg: 72, on: date(-1), in: restoredContainer.mainContext)
        let manual = try restoredContainer.mainContext.fetch(FetchDescriptor<WeightEntry>())
        check(manual.count == 1 && manual[0].healthKitSampleID == nil && manual[0].kg == 72, "手动体重覆盖导入并清除来源")
        let newKeys: Set<String> = [
            "oilLevelRaw", "kcalUncertainty", "fiberPer100g", "sodiumMgPer100g", "addedSugarPer100g",
            "usageRecords", "healthKitSampleID", "healthKitSource", "healthKitFatDate",
            "healthKitWaistDate", "kcalAdjustment"
        ]
        func legacy(_ value: Any) -> Any {
            if let values = value as? [String: Any] {
                return values.filter { !newKeys.contains($0.key) }.mapValues(legacy)
            }
            if let values = value as? [Any] { return values.map(legacy) }
            return value
        }
        let oldData = try JSONSerialization.data(
            withJSONObject: legacy(try JSONSerialization.jsonObject(with: Data(contentsOf: url))))
        let old = try decoder.decode(BackupService.Backup.self, from: oldData)
        check(old.usageRecords == nil, "旧备份缺少调用记录兼容")
        check(
            old.profile.kcalAdjustment == nil && old.meals[0].oilLevelRaw == nil
                && old.weights[0].healthKitSampleID == nil, "旧备份兼容")
        print("PASS: \(checks) offline checks; no network requests")
    }
}
