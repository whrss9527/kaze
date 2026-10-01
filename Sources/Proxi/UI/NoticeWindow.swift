import AppKit
import SwiftUI

/// 从以前的版本更新过来后显示一次的说明。用普通窗口而不是模态对话框：不挡住菜单栏图标、命令行和更新。
@MainActor
final class NoticeWindowController: NSObject, NSWindowDelegate {
    static let shared = NoticeWindowController()

    private var window: NSWindow?

    func showUpgradeNotice(turnedOff: Bool, helperInstalled: Bool) {
        let view = UpgradeNoticeView(turnedOff: turnedOff, helperInstalled: helperInstalled) { [weak self] in
            MainActor.assumeIsolated { self?.window?.close() }
        }
        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.title = L("Proxi 现在专注于切换代理")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        // 设置窗口没开着时回到只有菜单栏图标。
        if !NSApp.windows.contains(where: { $0.isVisible && $0.title == L("Proxi 设置") }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct UpgradeNoticeView: View {
    let turnedOff: Bool
    let helperInstalled: Bool
    let close: () -> Void
    @State private var removing = false
    @State private var removed = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 48, height: 48)
                Text(L("Proxi 现在专注于切换代理"))
                    .font(.system(size: 16, weight: .semibold))
            }
            Text(L("从这个版本起，Proxi 只负责一键把系统代理、终端、git 和 npm 指向你指定的代理服务器，比如公司代理、内网网关，或者本机的 Charles、Proxyman、mitmproxy。以前版本里的内置代理和相关的设置都已经移除，你自己添加的代理配置都还在。"))
                .fixedSize(horizontal: false, vertical: true)
            if turnedOff {
                Label(L("原来开着的内置代理已经关掉，系统代理、终端、git 和 npm 的代理设置都已清除。"), systemImage: "power")
                    .fixedSize(horizontal: false, vertical: true)
            }
            if helperInstalled && !removed {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("以前的版本还装过一个后台助手，现在用不上了。移除它需要输入一次管理员密码；也可以以后在「设置 → 通用」里移除。"))
                        .fixedSize(horizontal: false, vertical: true)
                    if let problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            } else if removed {
                Label(L("后台助手已移除。"), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            HStack {
                Spacer()
                if helperInstalled && !removed {
                    Button(L("以后再说")) { close() }
                    Button(removing ? L("正在移除…") : L("移除后台助手…")) { removeHelper() }
                        .buttonStyle(.borderedProminent)
                        .disabled(removing)
                } else {
                    Button(L("知道了")) { close() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 440)
    }

    private func removeHelper() {
        removing = true
        problem = nil
        Task { @MainActor in
            await AppState.shared.removeLegacyHelper()
            removing = false
            if AppState.shared.legacyHelperInstalled {
                problem = AppState.shared.lastError ?? L("后台助手没有移除")
            } else {
                removed = true
            }
        }
    }
}
