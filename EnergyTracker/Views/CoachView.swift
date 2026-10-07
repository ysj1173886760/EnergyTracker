import SwiftData
import SwiftUI

struct CoachView: View {
    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(HealthCoach.self) private var coach
    @Query(sort: \ChatThread.updatedAt, order: .reverse) private var threads: [ChatThread]
    @Query(filter: #Predicate<TrainingPlan> { $0.isActive }, sort: \TrainingPlan.createdAt, order: .reverse)
    private var activePlans: [TrainingPlan]

    @State private var openThread: ChatThread?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let plan = activePlans.first, let content = plan.content {
                        NavigationLink {
                            TrainingPlanView(plan: plan)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(content.title).font(.subheadline.weight(.semibold))
                                if let today = content.day(for: .now) {
                                    Text("今天：\(today.isRest ? "休息" : today.title)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    Button {
                        startPlanIntake()
                    } label: {
                        Label(activePlans.isEmpty ? "和教练聊聊，制定训练计划" : "重新制定训练计划", systemImage: "figure.strengthtraining.traditional")
                    }
                } header: {
                    Text("训练计划")
                } footer: {
                    if activePlans.isEmpty {
                        Text("教练会先问你几个问题（目标、每周几天、器械、伤病等），再生成每周的训练安排。")
                    }
                }

                Section {
                    Button {
                        let thread = ChatThread(kind: "chat", title: "新对话")
                        context.insert(thread)
                        try? context.save()
                        openThread = thread
                    } label: {
                        Label("新对话", systemImage: "plus.bubble")
                    }
                    ForEach(threads) { thread in
                        NavigationLink {
                            ChatView(thread: thread)
                        } label: {
                            ThreadRow(thread: thread, isBusy: coach.isSending(thread) || coach.isPlanning(thread))
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { context.delete(threads[index]) }
                        try? context.save()
                    }
                } header: {
                    Text("问教练")
                } footer: {
                    Text("教练能看到你的资料、身体数据、最近 7 天的饮食运动和训练计划，可以直接问「今晚吃什么」「这周进展怎么样」。")
                }
            }
            .navigationTitle("教练")
            .navigationDestination(item: $openThread) { thread in
                ChatView(thread: thread)
            }
        }
    }

    private func startPlanIntake() {
        let thread = ChatThread(kind: "plan", title: "制定训练计划")
        context.insert(thread)
        try? context.save()
        coach.send("帮我制定一份训练计划。", in: thread, profileStore: profileStore)
        openThread = thread
    }
}

private struct ThreadRow: View {
    let thread: ChatThread
    let isBusy: Bool

    var body: some View {
        HStack {
            Image(systemName: thread.isPlanIntake ? "figure.strengthtraining.traditional" : "bubble.left.and.bubble.right")
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(thread.title.isEmpty ? "新对话" : thread.title).font(.subheadline).lineLimit(1)
                if let last = thread.sortedMessages.last {
                    Text(last.content).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if isBusy {
                ProgressView()
            } else {
                Text(thread.updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct ChatView: View {
    @Bindable var thread: ChatThread

    @Environment(ProfileStore.self) private var profileStore
    @Environment(HealthCoach.self) private var coach
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private static let suggestions = [
        "今天剩下的额度，晚饭怎么吃比较好？",
        "我最近的进展怎么样？有什么需要改的？",
        "体重好几天没降了，正常吗？",
        "下周的运动怎么安排比较合理？",
    ]

    private var busy: Bool { coach.isSending(thread) || coach.isPlanning(thread) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if thread.messages.isEmpty {
                        emptyState
                    }
                    ForEach(thread.sortedMessages) { message in
                        MessageBubble(message: message)
                            .id(message.persistentModelID)
                    }
                    if coach.isSending(thread) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("教练正在思考…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    if coach.isPlanning(thread) {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("正在生成训练计划，大约需要 1–3 分钟，可以先切走…").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }
                    if let error = coach.chatError(thread) ?? coach.planError(thread) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(error).font(.footnote).foregroundStyle(.red)
                            if coach.chatError(thread) != nil {
                                Button("重试") { coach.send(nil, in: thread, profileStore: profileStore) }
                                    .font(.footnote)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: thread.messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: busy) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        .safeAreaInset(edge: .bottom) { inputBar }
        .navigationTitle(thread.isPlanIntake ? "制定训练计划" : (thread.title.isEmpty ? "新对话" : thread.title))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if thread.isPlanIntake {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("生成计划") { coach.generatePlan(from: thread, profileStore: profileStore) }
                        .disabled(busy || thread.messages.filter(\.isUser).count < 2)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("可以问我饮食、运动、身体状态相关的问题，我会结合你的记录来回答。")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(Self.suggestions, id: \.self) { suggestion in
                Button {
                    coach.send(suggestion, in: thread, profileStore: profileStore)
                } label: {
                    Text(suggestion).font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 8)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(thread.isPlanIntake ? "回答教练的问题…" : "问点什么…", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .focused($inputFocused)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            Button {
                coach.send(draft, in: thread, profileStore: profileStore)
                draft = ""
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 32))
            }
            .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 40) }
            Text(Self.markdown(message.content))
                .font(.subheadline)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(message.isUser ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                            in: RoundedRectangle(cornerRadius: 16))
            if !message.isUser { Spacer(minLength: 40) }
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct TrainingPlanView: View {
    let plan: TrainingPlan

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if let content = plan.content {
                Section {
                    Text(content.title).font(.title3.bold())
                    Text(content.summary).font(.subheadline)
                    if let weeks = content.weeks {
                        LabeledContent("建议周期", value: "\(weeks) 周")
                    }
                }
                ForEach(content.days, id: \.self) { day in
                    Section {
                        if day.isRest {
                            Text(day.notes.isEmpty ? "休息恢复" : day.notes).font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            if !day.focus.isEmpty {
                                Text(day.focus).font(.subheadline).foregroundStyle(.secondary)
                            }
                            ForEach(day.exercises, id: \.self) { exercise in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(exercise.summary).font(.subheadline.weight(.medium))
                                    if !exercise.notes.isEmpty {
                                        Text(exercise.notes).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            if !day.notes.isEmpty {
                                Text(day.notes).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(day.weekdayName) · \(day.isRest ? "休息" : day.title)")
                            Spacer()
                            if let minutes = day.durationMin, !day.isRest {
                                Text("\(Int(minutes.rounded())) 分钟")
                            }
                        }
                    }
                }
                if !content.progression.isEmpty {
                    Section("进阶方式") { Text(content.progression).font(.subheadline) }
                }
                if !content.tips.isEmpty {
                    Section("建议") {
                        ForEach(content.tips, id: \.self) { BulletRow(text: $0, symbol: "lightbulb", color: .yellow) }
                    }
                }
                if !content.cautions.isEmpty {
                    Section("注意事项") {
                        ForEach(content.cautions, id: \.self) { BulletRow(text: $0, symbol: "exclamationmark.triangle", color: .orange) }
                    }
                }
            }
            Section {
                Button("停用这个计划", role: .destructive) {
                    plan.isActive = false
                    try? context.save()
                    dismiss()
                }
            } footer: {
                Text("\(plan.model) · 生成于 \(plan.createdAt.formatted(date: .abbreviated, time: .shortened))")
            }
        }
        .navigationTitle("训练计划")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Today's planned session on the Today page, with one-tap logging.
struct TodayPlanSection: View {
    let date: Date
    let exercises: [ExerciseSession]

    @Environment(\.modelContext) private var context
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ExerciseAnalyzer.self) private var analyzer
    @Query(filter: #Predicate<TrainingPlan> { $0.isActive }, sort: \TrainingPlan.createdAt, order: .reverse)
    private var activePlans: [TrainingPlan]

    var body: some View {
        if let content = activePlans.first?.content, let day = content.day(for: date) {
            Section {
                if day.isRest {
                    Label(day.notes.isEmpty ? "今天是休息日，好好恢复" : day.notes, systemImage: "bed.double")
                        .font(.subheadline)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.title).font(.subheadline.weight(.semibold))
                        ForEach(day.exercises, id: \.self) { exercise in
                            Text("· \(exercise.summary)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if done {
                        Label("已记录", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button {
                            log(day)
                        } label: {
                            Label("完成了，记录这次训练", systemImage: "checkmark.circle")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("今日训练")
                    Spacer()
                    if let minutes = day.durationMin, !day.isRest { Text("约 \(Int(minutes.rounded())) 分钟") }
                }
            }
        }
    }

    private var done: Bool { exercises.contains { $0.text.hasPrefix("按训练计划完成") } }

    private func log(_ day: PlanContent.Day) {
        let time = Calendar.current.isDateInToday(date) ? Date.now : (Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: date) ?? date)
        let session = ExerciseSession(timestamp: time, text: day.logText, weightKg: profileStore.currentWeightKg ?? 70)
        context.insert(session)
        try? context.save()
        analyzer.estimate(session, profile: profileStore.profile)
    }
}
