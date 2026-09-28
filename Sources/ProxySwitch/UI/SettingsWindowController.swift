import AppKit
import SwiftUI

enum SettingsPage: String, CaseIterable, Identifiable {
    case profiles
    case nodes
    case share
    case diagnose
    case general
    case hotkey
    case sync
    case diagnostics
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profiles: return "代理配置"
        case .nodes: return "节点与订阅"
        case .share: return "局域网共享"
        case .diagnose: return "网址诊断"
        case .general: return "通用"
        case .hotkey: return "快捷键"
        case .sync: return "iCloud 同步"
        case .diagnostics: return "诊断"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .profiles: return "point.3.connected.trianglepath.dotted"
        case .nodes: return "antenna.radiowaves.left.and.right"
        case .share: return "wifi.router"
        case .diagnose: return "stethoscope"
        case .general: return "gearshape"
        case .hotkey: return "keyboard"
        case .sync: return "icloud"
        case .diagnostics: return "stethoscope"
        case .about: return "info.circle"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage = .profiles
    @Published var selectedProfileID: UUID?
    /// 从别处发起的诊断（proxyswitch://diagnose 等），诊断页拿走后清空。
    @Published var diagnoseRequest: DiagnoseRequest?
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
        // 设置窗口打开期间当普通应用：菜单栏显示编辑菜单，⌘Tab 能切到它；关闭后回到只有菜单栏图标。
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
        window.title = "ProxySwitch 设置"
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
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 28, height: 28)
                    Text("ProxySwitch")
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
    }

    private var pageSelection: Binding<SettingsPage?> {
        Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.page {
        case .profiles: ProfilesPage(state: state, navigation: navigation)
        case .nodes: NodesPage(state: state, engine: state.engine)
        case .share: SharePage(state: state, engine: state.engine, sleepGuard: state.sleepGuard)
        case .diagnose: DiagnosePage(state: state, engine: state.engine, navigation: navigation)
        case .general: GeneralPage(state: state)
        case .hotkey: HotkeyPage(state: state)
        case .sync: SyncPage(state: state, sync: state.sync)
        case .diagnostics: DiagnosticsPage(state: state)
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
            PageHeader(title: "通用", subtitle: "菜单栏图标的行为、关闭代理的方式、通知")
            Form {
                Section("启动") {
                    Toggle("登录时自动启动", isOn: Binding(get: { state.loginItemEnabled }, set: { state.setLoginItem($0) }))
                    Toggle("退出 ProxySwitch 时关闭代理", isOn: $state.config.disableOnExit)
                }
                Section("菜单栏图标") {
                    Picker("左键点击", selection: $state.config.clickAction) {
                        ForEach(ClickAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    Text("右键或 Control + 点击总是弹出菜单")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("实时网速", selection: $state.config.speedDisplay) {
                        ForEach(SpeedDisplay.allCases) { display in
                            Text(display.title).tag(display)
                        }
                    }
                    Picker("网速位置", selection: $state.config.speedSide) {
                        ForEach(SpeedSide.allCases) { side in
                            Text(side.title).tag(side)
                        }
                    }
                    .disabled(state.config.speedDisplay == .none)
                    Toggle("网速文字跟着代理状态变色", isOn: $state.config.speedColorFollowsStatus)
                        .disabled(state.config.speedDisplay == .none)
                    Text("上行在上、下行在下，默认显示在图标左边、开关在右边。「关代理时只显示网速」：代理关着时菜单栏里只有网速，开启后开关出现在网速左边，网速本身的位置不动；点网速和点开关一样。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("变色：开着代理时网速用开关的颜色，系统代理是别的程序设置的时候是黄色，代理服务器连不上时是红色，关着时是普通的菜单栏文字颜色。颜色会按菜单栏深浅自动调深或调浅，保证看得清。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("「系统网络总速度」统计有线和 Wi‑Fi 网卡的全部流量；「只算内置代理」是经过内核的流量。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("代理") {
                    Picker("关闭代理时", selection: $state.config.offMode) {
                        ForEach(OffMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Toggle("定期检查代理服务器能否连上", isOn: $state.config.healthCheck)
                    TextField("测速地址", text: $state.config.testURL)
                        .textFieldStyle(.roundedBorder)
                }
                Section("通知") {
                    Picker("通知", selection: $state.config.notifyLevel) {
                        ForEach(NotifyLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                }
                Section("更新") {
                    Toggle("自动检查更新", isOn: $state.config.autoCheckUpdates)
                    Text("启动后和之后每 6 小时检查一次 GitHub 上的新版本，有新版本时通知，不会自动安装。「关于」页里可以随时手动检查和一键更新。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - 快捷键

struct HotkeyPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "快捷键", subtitle: "在任何程序里按下它就能开关代理")
            Form {
                Section("开 / 关代理") {
                    HStack {
                        HotkeyRecorder(binding: $state.config.toggleHotkey)
                            .frame(width: 180, height: 28)
                        Button("清除") { state.config.toggleHotkey = nil }
                            .disabled(state.config.toggleHotkey == nil)
                    }
                    Text("点击方框后按下新的组合键，至少包含 ⌃、⌥、⇧、⌘ 中的一个。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = state.lastError, error.contains("快捷键") {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                Section("命令行与快捷指令") {
                    Text("终端里可以用 open 命令控制：")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(["open proxyswitch://toggle", "open proxyswitch://on", "open proxyswitch://off", "open \"proxyswitch://use?name=配置名\"", "open proxyswitch://share/on", "open proxyswitch://update"], id: \.self) { command in
                        HStack {
                            Text(command)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                TerminalCommands.copy(command)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }
}

// MARK: - 诊断

struct DiagnosticsPage: View {
    @ObservedObject var state: AppState
    @State private var environment: [String: String] = [:]
    @State private var gitProxy = ""
    @State private var npm: [String: String] = [:]
    @State private var services: [NetworkServices.Service] = []
    @State private var logText = ""
    @State private var clearing = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "诊断", subtitle: "系统里各处的代理设置，以及运行日志")
            Form {
                Section("系统代理") {
                    LabeledContent("当前生效", value: state.snapshot.summary)
                    LabeledContent("自动发现（WPAD）", value: state.snapshot.autoDiscovery ? "开" : "关")
                    LabeledContent("例外", value: state.snapshot.exceptions.isEmpty ? "无" : state.snapshot.exceptions.joined(separator: ", "))
                    LabeledContent("网络服务", value: services.isEmpty ? "无" : services.map { $0.enabled ? $0.name : "\($0.name)（已停用）" }.joined(separator: "、"))
                    HStack {
                        Button("打开系统的代理设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!)
                        }
                        Button(clearing ? "正在清除…" : "清除所有代理设置") {
                            clearAll()
                        }
                        .disabled(clearing)
                    }
                }
                Section("环境变量（launchd）") {
                    ForEach(EnvironmentProxy.names, id: \.self) { name in
                        LabeledContent(name, value: environment[name]?.isEmpty == false ? environment[name]! : "未设置")
                    }
                    Text("新打开的终端和程序会读到这些变量；已经打开的终端请用面板里的「复制终端命令」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("git 与 npm") {
                    LabeledContent("git http.proxy", value: gitProxy.isEmpty ? "未设置" : gitProxy)
                    LabeledContent("npm proxy", value: npm["proxy"] ?? "未设置")
                    LabeledContent("npm https-proxy", value: npm["https-proxy"] ?? "未设置")
                }
                Section("文件") {
                    LabeledContent("配置目录", value: Store.directory.path)
                    HStack {
                        Button("打开配置目录") { NSWorkspace.shared.open(Store.directory) }
                        Button("刷新") { reload() }
                    }
                }
                Section("日志") {
                    ScrollView {
                        Text(logText.isEmpty ? "还没有日志" : logText)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task { reload() }
    }

    private func reload() {
        services = NetworkServices.all()
        logText = Log.tail(lines: 120)
        npm = NpmProxy.current()
        Task { @MainActor in
            environment = await EnvironmentProxy.current()
            gitProxy = await GitProxy.current()
        }
    }

    private func clearAll() {
        clearing = true
        Task { @MainActor in
            state.turnOff()
            try? await EnvironmentProxy.clear()
            try? await GitProxy.clear()
            try? NpmProxy.clear()
            clearing = false
            reload()
        }
    }
}

// MARK: - 关于

struct AboutPage: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "关于", subtitle: "ProxySwitch for Mac")
            // 窗口够宽时赞赏码放在右边，一眼就能看到；窄的时候排到下面。
            // 按实际宽度判断（ViewThatFits 按理想宽度量，更新说明里一行长字就会让它一直选竖排）。
            GeometryReader { geometry in
                ScrollView {
                    if geometry.size.width >= 680 {
                        HStack(alignment: .top, spacing: 20) {
                            aboutCard
                            DonateCard()
                        }
                        .padding(24)
                    } else {
                        VStack(spacing: 20) {
                            aboutCard
                            DonateCard()
                        }
                        .padding(24)
                    }
                }
            }
        }
    }

    private var aboutCard: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)
            Text("ProxySwitch")
                .font(.system(size: 20, weight: .bold))
            Text("版本 \(UpdateChecker.currentVersion)")
                .foregroundStyle(.secondary)
            Text("菜单栏里的代理开关：一键切换系统代理、环境变量、git 和 npm 的代理设置。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("GitHub") { NSWorkspace.shared.open(AppInfo.repositoryURL) }
                Button("反馈问题") { NSWorkspace.shared.open(AppInfo.issuesURL) }
            }
            Divider()
                .padding(.horizontal, 40)
            UpdateSection(updater: state.updater)
            Text("MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
        .glassCard(cornerRadius: 20)
    }
}

/// 关于页的「请我喝杯咖啡」：微信赞赏码卡片，点一下放大，方便手机扫。图片不在（开发时直接运行二进制）就不显示。
struct DonateCard: View {
    @MainActor static let image: NSImage? = Bundle.main.url(forResource: "donate-wechat", withExtension: "png")
        .flatMap { NSImage(contentsOf: $0) }

    @State private var enlarged = false

    var body: some View {
        if let image = Self.image {
            VStack(spacing: 10) {
                Button {
                    enlarged = true
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 210)
                        .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
                }
                .buttonStyle(.plain)
                .help("点击放大")
                .accessibilityLabel("微信赞赏码：请我喝杯咖啡")
                .popover(isPresented: $enlarged, arrowEdge: .leading) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 420)
                        .padding(14)
                }
                Text("觉得好用的话，\n微信扫一扫请我喝杯咖啡")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Text("点图片可以放大")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 230)
            .padding(.vertical, 8)
        }
    }
}
