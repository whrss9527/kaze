import AppKit
import SwiftUI

/// 从以前的版本更新过来后显示一次的提示（以前装过、现在用不上的后台助手）。用普通窗口而不是模态对话框：不挡住菜单栏图标、命令行和更新。
@MainActor
final class NoticeWindowController: NSObject, NSWindowDelegate {
    static let shared = NoticeWindowController()

    private var window: NSWindow?

    /// 以前的版本装过后台助手、扩展没开：提示可以移除。
    func showHelperNotice() {
        let view = HelperNoticeView { [weak self] in
            MainActor.assumeIsolated { self?.window?.close() }
        }
        show(NSHostingController(rootView: view), title: L("以前版本的后台助手"))
    }

    private func show(_ controller: NSViewController, title: String) {
        window?.close()
        let window = NSWindow(contentViewController: controller)
        window.title = title
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
        guard (notification.object as? NSWindow) === window else { return }
        window = nil
        // 设置窗口没开着时回到只有菜单栏图标。
        if !NSApp.windows.contains(where: { $0.isVisible && $0.title == L("Proxi 设置") }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

/// 以前的版本装过后台助手：现在没开启扩展时用不上，可以移除（要管理员密码），也可以以后再说。
struct HelperNoticeView: View {
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
                Text(L("以前版本的后台助手"))
                    .font(.system(size: 16, weight: .semibold))
            }
            if removed {
                Label(L("后台助手已移除。"), systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            } else {
                Text(L("以前的版本还装过一个后台助手，没有开启扩展时用不上它。移除它需要输入一次管理员密码；也可以以后在「设置 → 通用」里移除。"))
                    .fixedSize(horizontal: false, vertical: true)
                if let problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Spacer()
                if removed {
                    Button(L("知道了")) { close() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(L("以后再说")) { close() }
                    Button(removing ? L("正在移除…") : L("移除后台助手…")) { removeHelper() }
                        .buttonStyle(.borderedProminent)
                        .disabled(removing)
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
