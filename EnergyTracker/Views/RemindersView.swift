import SwiftUI

struct RemindersView: View {
    @Environment(NotificationCenterService.self) private var notifications
    @Environment(\.openURL) private var openURL
    @State private var editing: Reminder?

    var body: some View {
        @Bindable var notifications = notifications
        Form {
            if notifications.authorization == .denied {
                Section {
                    Button("通知权限已关闭，去系统设置开启") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
            } else if notifications.authorization == .notDetermined {
                Section {
                    Button("允许发送通知") { Task { await notifications.requestAuthorization() } }
                }
            }

            Section {
                ForEach($notifications.reminders) { $reminder in
                    HStack {
                        Button {
                            editing = reminder
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(reminder.title).foregroundStyle(.primary)
                                Text(reminder.body).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        DatePicker("", selection: $reminder.time, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                        Toggle("", isOn: $reminder.isEnabled).labelsHidden()
                    }
                }
                .onDelete { notifications.reminders.remove(atOffsets: $0) }
                Button {
                    let reminder = Reminder(title: "提醒", body: "", hour: 20, minute: 0, isEnabled: true)
                    notifications.reminders.append(reminder)
                    editing = reminder
                } label: {
                    Label("添加提醒", systemImage: "plus")
                }
            } footer: {
                Text("每天在设定时间提醒。点名称可以修改提醒内容。另外，拍照识别、运动估算、AI 总结等任务在后台完成时也会发通知。")
            }
        }
        .navigationTitle("每日提醒")
        .navigationBarTitleDisplayMode(.inline)
        .task { await notifications.refreshAuthorization() }
        .sheet(item: $editing) { reminder in
            ReminderEditor(reminder: reminder) { updated in
                if let index = notifications.reminders.firstIndex(where: { $0.id == updated.id }) {
                    notifications.reminders[index] = updated
                }
            }
        }
    }
}

private struct ReminderEditor: View {
    @State var reminder: Reminder
    let onSave: (Reminder) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $reminder.title)
                TextField("内容", text: $reminder.body, axis: .vertical).lineLimit(1...4)
                DatePicker("时间", selection: $reminder.time, displayedComponents: .hourAndMinute)
                Toggle("开启", isOn: $reminder.isEnabled)
            }
            .navigationTitle("编辑提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(reminder)
                        dismiss()
                    }
                    .disabled(reminder.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
