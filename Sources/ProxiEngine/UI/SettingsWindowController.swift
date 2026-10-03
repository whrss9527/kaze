import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsPage: String, CaseIterable, Identifiable {
    case nodes
    case rules
    case share
    case connections
    case diagnose
    case advanced
    case core
    case general
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nodes: return L("节点与订阅")
        case .rules: return L("分流规则")
        case .share: return L("局域网共享")
        case .connections: return L("连接")
        case .diagnose: return L("网址诊断")
        case .advanced: return L("高级")
        case .core: return L("内核")
        case .general: return L("通用")
        case .about: return L("关于")
        }
    }

    var symbol: String {
        switch self {
        case .nodes: return "antenna.radiowaves.left.and.right"
        case .rules: return "arrow.triangle.branch"
        case .share: return "wifi.router"
        case .connections: return "list.bullet.rectangle"
        case .diagnose: return "stethoscope"
        case .advanced: return "slider.horizontal.3"
        case .core: return "cpu"
        case .general: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .nodes
    /// 从别处发起的诊断（proxi://diagnose 等），诊断页拿走后清空。
    @Published var diagnoseRequest: DiagnoseRequest?
    /// 要导入的配置（proxi://import、拖进窗口的文件），高级页拿走后打开导入预览。
    @Published var importRequest: String?
}

/// 设置窗口：透明标题栏、全尺寸内容，内容是 SwiftUI。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let navigation = SettingsNavigation()
    private var window: NSWindow?

    func show(page: SettingsPage?) {
        if let page {
            navigation.page = page
        }
        if window == nil {
            window = makeWindow()
        }
        // 设置窗口打开期间当普通应用：菜单栏显示编辑菜单，⌘Tab 能切到它；关闭后回到后台运行。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsRootView(state: AppState.shared, navigation: navigation)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = L("代理引擎设置")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(NSSize(width: 900, height: 620))
        window.minSize = NSSize(width: 760, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

/// 设置窗口的内容：左侧导航，右侧各页；整个窗口透出桌面的毛玻璃。
struct SettingsRootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var navigation: SettingsNavigation

    var body: some View {
        NavigationSplitView {
            List(SettingsPage.allCases, selection: pageSelection) { page in
                Label(page.title, systemImage: page.symbol)
                    .tag(page)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: AppLanguage.width(170, english: 190), ideal: AppLanguage.width(190, english: 215), max: 260)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text(L("代理引擎"))
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.top, 34)
                .padding(.bottom, 4)
            }
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectView(material: .underWindowBackground).ignoresSafeArea())
        }
        .frame(minWidth: 760, minHeight: 520)
        // 把配置文件拖进窗口就导入（先预览）。
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in
                    navigation.importRequest = url.absoluteString
                    navigation.page = .advanced
                }
            }
            return true
        }
    }

    private var pageSelection: Binding<SettingsPage?> {
        Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.page {
        case .nodes: NodesPage(state: state, engine: state.engine, navigation: navigation)
        case .rules: RulesPage(state: state, engine: state.engine, navigation: navigation)
        case .share: SharePage(state: state, engine: state.engine, sleepGuard: state.sleepGuard)
        case .connections: ConnectionsPage(state: state, engine: state.engine)
        case .diagnose: DiagnosePage(state: state, engine: state.engine, navigation: navigation)
        case .advanced: AdvancedPage(state: state, engine: state.engine, navigation: navigation)
        case .core: CorePage(state: state, core: state.core, engine: state.engine)
        case .general: GeneralPage(state: state)
        case .about: AboutPage(state: state)
        }
    }
}

/// 页面标题。
struct PageHeader: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 8)
    }
}

// MARK: - 通用

struct GeneralPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("通用"), subtitle: L("通知、本机控制接口"))
            Form {
                Section(L("通知")) {
                    Picker(L("通知"), selection: $state.config.notifyLevel) {
                        ForEach(NotifyLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                }
                Section(L("本机控制接口")) {
                    Picker(L("权限"), selection: $state.config.automation.permission) {
                        ForEach(ControlPermission.allCases) { permission in
                            Text(permission.title).tag(permission)
                        }
                    }
                    Text(L("在终端里直接运行代理引擎程序里的二进制并带上子命令（比如 status、nodes），经这个接口操作正在运行的代理引擎；只有你这个账户能连。完整的用法："))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(Shell.shellQuote(AdminCommand.executablePath) + " help")
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                }
                Section(L("界面语言")) {
                    Text(L("跟 Proxi 的界面语言一致，在 Proxi 的「设置 → 通用」里改。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - 内核

/// 内核页：下载的内核和 GeoIP 数据库，删除，以及代理引擎自己的日志。
struct CorePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var core: CoreDownload
    @ObservedObject var engine: Engine
    @State private var logText = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("内核"), subtitle: L("内核 mihomo 和 GeoIP 数据库不打包在程序里，第一次运行时从上游的发布下载并校验"))
            Form {
                Section(L("内核")) {
                    LabeledContent(L("版本"), value: CorePin.version)
                    LabeledContent(L("状态")) { phaseView }
                    LabeledContent(L("位置"), value: CoreDownload.directory.path)
                    HStack {
                        Button(core.isReady ? L("重新下载") : L("下载")) {
                            core.remove()
                            core.install()
                        }
                        .disabled(core.isBusy)
                        Button(L("删除内核"), role: .destructive) {
                            engine.shutdown()
                            core.remove()
                        }
                        .disabled(core.isBusy || !core.isReady)
                    }
                    Text(L("下载地址：%@；下载后先核对写在程序里的 SHA-256，对不上就不用。删除后代理引擎不能运行，下次打开时重新下载。", CorePin.asset()?.url.absoluteString ?? ""))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Button(L("内核项目主页")) { NSWorkspace.shared.open(AppInfo.coreProjectURL) }
                        .buttonStyle(.link)
                }
                Section(L("日志")) {
                    ScrollView {
                        Text(logText.isEmpty ? L("还没有日志") : logText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    HStack {
                        Button(L("刷新")) { logText = Log.tail(lines: 120) }
                        Button(L("打开数据目录")) { NSWorkspace.shared.open(Store.directory) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task { logText = Log.tail(lines: 120) }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch core.phase {
        case .unknown, .verifying:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(L("正在校验…"))
            }
        case .missing:
            Text(L("还没有下载")).foregroundStyle(.orange)
        case .downloading(let title, let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(L("正在下载%@…", title))
            }
        case .ready:
            Label(L("已下载并校验"), systemImage: "checkmark.circle").foregroundStyle(.green)
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message).foregroundStyle(.red).multilineTextAlignment(.trailing)
                Button(L("重试")) { core.install() }
            }
        }
    }
}

// MARK: - 关于

struct AboutPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("关于"), subtitle: L("代理引擎（Proxi 的扩展）"))
            ScrollView {
                VStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 96, height: 96)
                    Text(L("代理引擎"))
                        .font(.system(size: 20, weight: .bold))
                    Text(L("版本 %@ · 内核 %@", UpdateChecker.currentVersion, CorePin.version))
                        .foregroundStyle(.secondary)
                    Text(L("Proxi 的可选扩展：本机运行的代理引擎，由 Proxi 下载、启动和更新。在 Proxi 的「设置 → 扩展」里可以关闭或移除。"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: 380)
                    HStack(spacing: 10) {
                        Button(L("说明")) { NSWorkspace.shared.open(AppInfo.documentationURL) }
                        Button(L("内核项目主页")) { NSWorkspace.shared.open(AppInfo.coreProjectURL) }
                    }
                    Text("GPL-3.0 License")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .glassCard(cornerRadius: 20)
                .padding(24)
            }
        }
    }
}
