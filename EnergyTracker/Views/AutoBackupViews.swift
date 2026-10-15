import SwiftUI
import UniformTypeIdentifiers

struct AutoBackupSection: View {
    @Environment(AutoBackup.self) private var backup
    @State private var choosingFolder = false
    @State private var message: String?

    var body: some View {
        Section("iCloud 自动备份") {
            if let folder = backup.folderName {
                LabeledContent("文件夹", value: folder)
                if let date = backup.lastBackupAt {
                    HStack {
                        Text("上次备份")
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(date, style: .relative)
                            Text(ByteCountFormatter.string(fromByteCount: backup.lastBackupSize, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text("尚未成功备份").foregroundStyle(.secondary)
                }
                if backup.isOverdue {
                    Label("已超过 7 天未成功备份，请检查文件夹并立即备份。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let error = backup.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                Button {
                    Task { await backup.backupNow() }
                } label: {
                    HStack {
                        Text("立即备份")
                        if backup.isRunning { Spacer(); ProgressView() }
                    }
                }
                .disabled(backup.isRunning)
                NavigationLink("从备份恢复") { AutoBackupListView() }
                    .disabled(backup.isRunning)
                Button("更换文件夹") { choosingFolder = true }.disabled(backup.isRunning)
                Button("停用自动备份", role: .destructive) { backup.disable() }.disabled(backup.isRunning)
            } else {
                Text("选择 iCloud 云盘里的一个文件夹，App 每天自动备份一次（含照片），保留最近 14 份。换手机或重装后可以从这里恢复。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("选择备份文件夹") { choosingFolder = true }
            }
        }
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            do {
                try backup.selectFolder(result.get())
                Task { await backup.refreshList() }
            } catch {
                message = "无法访问备份文件夹，请重新选择：\(error.localizedDescription)"
            }
        }
        .alert("备份文件夹", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }
}

struct AutoBackupListView: View {
    @Environment(AutoBackup.self) private var backup
    @State private var selected: AutoBackup.File?
    @State private var confirming = false
    @State private var message: String?

    var body: some View {
        List {
            Section {
                Text("恢复会合并导入，不会删除现有记录。已存在的记录会跳过。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error = backup.lastError { Text(error).foregroundStyle(.orange) }
                if backup.isRunning { ProgressView("正在处理备份…") }
                if backup.backups.isEmpty && !backup.isRunning {
                    Text("此文件夹中暂无自动备份").foregroundStyle(.secondary)
                }
                ForEach(backup.backups) { file in
                    Button {
                        selected = file
                        confirming = true
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(file.name).font(.subheadline)
                            Text(file.date.formatted(date: .abbreviated, time: .shortened) + " · "
                                 + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(backup.isRunning)
                }
            }
        }
        .navigationTitle("从备份恢复")
        .task { await backup.refreshList() }
        .refreshable { await backup.refreshList() }
        .confirmationDialog("确认恢复这份备份？", isPresented: $confirming, titleVisibility: .visible) {
            Button("合并恢复") {
                guard let selected else { return }
                Task {
                    do {
                        let summary = try await backup.restore(selected)
                        message = "导入了 \(summary.meals) 餐、\(summary.exercises) 次运动、\(summary.weights) 条体重记录，"
                            + "跳过 \(summary.skippedMeals) 餐已存在的记录。"
                        if summary.profileRestored { message! += "已恢复个人资料。" }
                    } catch { message = "恢复失败：\(error.localizedDescription)" }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将合并导入 \(selected?.name ?? "")，不会删除现有记录。")
        }
        .alert("恢复备份", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }
}
