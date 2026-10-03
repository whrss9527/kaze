import AppKit
import SwiftUI

/// iCloud 同步页：开关、状态、首次开启时的取舍。
struct SyncPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var sync: CloudSync

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("iCloud 同步"), subtitle: L("通过 iCloud 云盘在多台 Mac 之间同步代理配置和设置"))
            Form {
                Section(L("同步")) {
                    Toggle(L("通过 iCloud 同步配置"), isOn: toggle)
                        .disabled(!sync.available && !sync.enabled)
                    LabeledContent(L("状态")) { statusView }
                    if sync.enabled {
                        HStack {
                            Button(L("立即同步")) {
                                Task { await sync.syncNow() }
                            }
                            .disabled(sync.status == .syncing)
                            Button(L("在 Finder 中显示")) {
                                if let url = sync.folderURL {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                        }
                    }
                    if !sync.available {
                        Text(L("这台 Mac 没有开启 iCloud 云盘。到系统设置的 Apple 账户 → iCloud 里打开「iCloud 云盘」，再回来开启同步。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(L("打开系统设置")) {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preferences.AppleIDPrefPane")!)
                        }
                    }
                }
                Section(L("会同步什么")) {
                    Text(L("全部代理配置，以及「通用」「快捷键」和「自动化」页里的设置。登录时启动、上次使用的配置、更新提醒这些本机状态不同步。"))
                    Text(L("文件放在 iCloud 云盘的 Proxi 文件夹里。别的 Mac 上开启同步时会读到它，可以选择用 iCloud 的、用本机的，或者把两边合并。之后任何一台的改动几秒内就会出现在其他 Mac 上；两台同时改动时，以改动时间晚的为准。"))
                    Text(L("第一次开启时系统可能会询问是否允许 Proxi 访问 iCloud 云盘，需要允许。"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .confirmationDialog(L("iCloud 里已经有配置"), isPresented: pendingPresented, titleVisibility: .visible) {
            Button(L("用 iCloud 的替换本机的")) { sync.resolve(.useCloud) }
            Button(L("合并两边的配置")) { sync.resolve(.merge) }
            Button(L("用本机的覆盖 iCloud")) { sync.resolve(.useLocal) }
            Button(L("取消"), role: .cancel) { sync.cancelEnable() }
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
        return L("来自「%@」，更新于 %@，有 %@ 套配置；本机现在有 %@ 套。要怎么处理？", remote.device, Self.dateFormatter.string(from: remote.updatedAt), count, local)
    }

    @ViewBuilder
    private var statusView: some View {
        switch sync.status {
        case .off:
            Text(L("未开启"))
                .foregroundStyle(.secondary)
        case .unavailable:
            Label(L("iCloud 云盘没有开启"), systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        case .syncing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(L("正在同步…"))
                    .foregroundStyle(.secondary)
            }
        case .synced(let date, let device):
            VStack(alignment: .trailing, spacing: 2) {
                Label(L("已同步"), systemImage: "checkmark.icloud")
                    .foregroundStyle(.green)
                Text(L("最近一次改动来自「%@」，%@", device, Self.relative(date)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .error(let message):
            VStack(alignment: .trailing, spacing: 6) {
                Label(message, systemImage: "xmark.icloud")
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.trailing)
                Button(L("打开隐私设置")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
                }
                .controlSize(.small)
                Text(L("如果是拒绝过访问 iCloud 云盘，在「文件和文件夹」里允许 Proxi 访问 iCloud 云盘。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
