import AppKit
import SwiftUI

/// iCloud 同步页：开关、状态、首次开启时的取舍。
struct SyncPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var sync: CloudSync

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "iCloud 同步", subtitle: "通过 iCloud 云盘在多台 Mac 之间同步代理配置和设置")
            Form {
                Section("同步") {
                    Toggle("通过 iCloud 同步配置", isOn: toggle)
                        .disabled(!sync.available && !sync.enabled)
                    LabeledContent("状态") { statusView }
                    if sync.enabled {
                        HStack {
                            Button("立即同步") {
                                Task { await sync.syncNow() }
                            }
                            .disabled(sync.status == .syncing)
                            Button("在 Finder 中显示") {
                                if let url = sync.folderURL {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    }
                    if !sync.available {
                        Text("这台 Mac 没有开启 iCloud 云盘。到系统设置的 Apple 账户 → iCloud 里打开「iCloud 云盘」，再回来开启同步。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")!)
                        }
                    }
                }
                Section("会同步什么") {
                    Text("全部代理配置，以及「通用」和「快捷键」页里的设置。登录时启动、上次使用的配置、更新提醒这些本机状态不同步。")
                    Text("文件放在 iCloud 云盘的 Kaze 文件夹里。别的 Mac 上开启同步时会读到它，可以选择用 iCloud 的、用本机的，或者把两边合并。之后任何一台的改动几秒内就会出现在其他 Mac 上；两台同时改动时，以改动时间晚的为准。")
                    Text("第一次开启时系统可能会询问是否允许 Kaze 访问 iCloud 云盘，需要允许。")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog("iCloud 里已经有配置", isPresented: pendingPresented, titleVisibility: .visible) {
            Button("用 iCloud 的替换本机的") { sync.resolve(.useCloud) }
            Button("合并两边的配置") { sync.resolve(.merge) }
            Button("用本机的覆盖 iCloud") { sync.resolve(.useLocal) }
            Button("取消", role: .cancel) { sync.cancelEnable() }
        } message: {
            Text(pendingMessage)
        }
    }

    private var toggle: Binding<Bool> {
        Binding(
            get: { sync.enabled },
            set: { on in
                if on {
                    Task { await sync.enable() }
                } else {
                    sync.disable()
                }
            }
        )
    }

    /// 对话框关闭时不做事：按钮的动作已经把 pending 清掉了。
    private var pendingPresented: Binding<Bool> {
        Binding(get: { sync.pending != nil }, set: { _ in })
    }

    private var pendingMessage: String {
        guard let remote = sync.pending else { return "" }
        let count = remote.config.profiles.count
        let local = state.config.profiles.count
        return "来自「\(remote.device)」，更新于 \(Self.dateFormatter.string(from: remote.updatedAt))，有 \(count) 套配置；本机现在有 \(local) 套。要怎么处理？"
    }

    @ViewBuilder
    private var statusView: some View {
        switch sync.status {
        case .off:
            Text("未开启")
                .foregroundStyle(.secondary)
        case .unavailable:
            Label("iCloud 云盘没有开启", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在同步…")
                    .foregroundStyle(.secondary)
            }
        case .synced(let date, let device):
            VStack(alignment: .trailing, spacing: 2) {
                Label("已同步", systemImage: "checkmark.icloud")
                    .foregroundStyle(.green)
                Text("最近一次改动来自「\(device)」，\(Self.relative(date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Label(message, systemImage: "xmark.icloud")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                Button("打开隐私设置") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
                .controlSize(.small)
                Text("如果是拒绝过访问 iCloud 云盘，在「文件和文件夹」里允许 Kaze 访问 iCloud 云盘。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
