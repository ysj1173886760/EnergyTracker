import SwiftUI

struct HealthSettingsView: View {
    @Environment(HealthSync.self) private var sync
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.modelContext) private var context

    var body: some View {
        @Bindable var sync = sync
        Form {
            if !sync.isAvailable {
                Text("此设备不支持 Apple 健康。")
            } else {
                Section {
                    Toggle(
                        "连接 Apple 健康",
                        isOn: Binding(
                            get: { sync.isEnabled },
                            set: { value in
                                if value {
                                    Task {
                                        await sync.connect()
                                        await sync.sync(context: context, profileStore: profileStore, force: true)
                                    }
                                } else {
                                    sync.isEnabled = false
                                }
                            }))
                    Toggle("导入体重/体脂/腰围", isOn: $sync.importBody)
                    Toggle("写入饮食营养", isOn: $sync.writeMeals)
                    Toggle("写入体重", isOn: $sync.writeWeight)
                } footer: {
                    Text("步数和活动能量只用于展示和 AI 参考，不会加进热量额度。读取权限由系统管理；没有数据也可能是未允许读取，可到「健康」App 检查权限。")
                }
                Section {
                    LabeledContent(
                        "上次同步", value: sync.lastSync?.formatted(date: .abbreviated, time: .shortened) ?? "尚未同步")
                    Button(sync.isSyncing ? "同步中…" : "立即同步") {
                        Task { await sync.sync(context: context, profileStore: profileStore, force: true) }
                    }
                    .disabled(!sync.isEnabled || sync.isSyncing)
                    if let error = sync.lastError { Text(error).foregroundStyle(.orange).font(.footnote) }
                }
            }
        }
        .navigationTitle("Apple 健康")
    }
}
