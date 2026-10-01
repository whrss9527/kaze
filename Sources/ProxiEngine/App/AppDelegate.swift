import AppKit

/// 代理引擎：Proxi 的可选扩展，一个单独的程序。由 Proxi 在用户同意说明、开启扩展后下载安装并启动，
/// 平时只有一个菜单栏图标；系统代理、终端、git 和 npm 仍由 Proxi 的开关设置（Proxi 的配置列表里有一条「代理引擎」）。
@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static func main() {
        // 带子命令运行（status、nodes、helper……）时是命令行工具，不启动界面。
        if CommandLineTool.shouldHandle(CommandLine.arguments) {
            exit(CommandLineTool.run(CommandLine.arguments))
        }
        // 同一个用户只运行一个代理引擎。
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: AppInfo.bundleIdentifier)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        if !running.isEmpty, Bundle.main.bundleIdentifier == AppInfo.bundleIdentifier {
            running.first?.activate()
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // 只有菜单栏图标，不在 Dock 里显示。
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusController: StatusItemController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installSignalHandlers()
        MainMenu.install()
        let state = AppState.shared
        Notifier.shared.start()
        Notifier.shared.onOpen = { _ in
            SettingsWindowController.shared.show(page: nil)
        }
        let controller = StatusItemController(state: state)
        statusController = controller
        state.onStatusChanged = { [weak controller] in controller?.updateIcon() }
        state.start()
        controller.updateIcon()
        Log.info("代理引擎已启动，版本 \(UpdateChecker.currentVersion)，数据目录 \(Store.directory.path)")
        // CI 按这一行确认界面语言（sample 是菜单里「设置…」的译文）。
        Log.info("界面语言 english=\(AppLanguage.isEnglish) sample=\"\(L("设置…"))\"")
        if ProcessInfo.processInfo.environment["PROXI_ENGINE_SHOW_SETTINGS"] == "1" {
            SettingsWindowController.shared.show(page: .nodes)
        }
    }

    /// 再次打开程序（Proxi 的扩展页里点「打开」、Finder 里双击）时打开设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show(page: nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.handleExit()
        Log.info("代理引擎已退出")
        Log.flush()
    }

    /// kill、logout 这类信号也走正常退出：停内核。
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }
}
