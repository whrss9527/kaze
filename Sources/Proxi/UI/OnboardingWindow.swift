import AppKit
import SwiftUI

/// 第一次打开（还没有任何代理配置）时的引导：填代理服务器的地址 → 选让哪些地方走代理 → 完成。
/// 已经有配置的不显示。点「跳过」打开设置的「代理配置」页自己填，和以前一样。
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    func show(state: AppState) {
        if window == nil {
            let view = OnboardingView(state: state) { [weak self] skipped in
                MainActor.assumeIsolated { self?.finish(skipped: skipped) }
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = L("欢迎使用 Proxi")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
            Log.info("已显示新手引导")
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func finish(skipped: Bool) {
        window?.close()
        if skipped {
            SettingsWindowController.shared.show(page: .profiles)
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        window = nil
        // 别的窗口（设置）也没开着时回到只有菜单栏图标。
        if !NSApp.windows.contains(where: { $0 !== closing && $0.isVisible && $0.styleMask.contains(.titled) }) {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

struct OnboardingView: View {
    @ObservedObject var state: AppState
    /// 引导结束：true 是点了「跳过」。
    let done: (Bool) -> Void

    @State private var step = 0
    @State private var draft = OnboardingDraft()
    @State private var showLogin = false
    @State private var problem: String?
    @State private var detecting = false
    @State private var found: [DetectedProxy]?
    @State private var testing = false
    @State private var result: TestResult?
    @State private var turnOnNow = true

    private static let steps = [L("代理服务器"), L("生效范围"), L("完成")]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 4)
            Group {
                switch step {
                case 0: addressStep
                case 1: targetsStep
                default: finishStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
        }
        .font(.system(size: 12))
        .frame(width: 520, height: 500)
    }

    // MARK: 各部分

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("欢迎使用 Proxi"))
                    .font(.system(size: 17, weight: .semibold))
                Text(L("第 %@ 步，共 %@ 步：%@", step + 1, Self.steps.count, Self.steps[step]))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var addressStep: some View {
        Form {
            Section {
                Text(L("Proxi 把系统代理、终端、git、npm 一起指向你自己的代理服务器：公司代理、内网网关，或者本机的 Charles、Proxyman、mitmproxy 这类调试代理。它只切换设置，自己不提供代理。"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Picker(L("类型"), selection: $draft.kind) {
                    ForEach(ProxyKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                TextField(draft.kind == .pac ? L("PAC 地址") : L("地址"), text: $draft.address,
                          prompt: Text(draft.kind == .pac ? "http://proxy.corp.example/proxy.pac" : "proxy.corp.example:3128"))
                    .onChange(of: draft.address) { old, value in
                        // 一次多出好几个字是粘贴进来的整段地址：带了类型、用户名就拆出来。
                        if value.count - old.count > 1 {
                            absorbAddress()
                        }
                    }
                TextField(L("名称"), text: $draft.name, prompt: Text(L("不填就按地址起名")))
            } footer: {
                if draft.kind != .pac {
                    Text(L("写成「主机:端口」，比如 proxy.corp.example:3128、127.0.0.1:8888，也可以粘贴 socks5://127.0.0.1:1080 这样的整段地址。常见的本机调试代理：Charles 是 8888，Proxyman 是 9090，mitmproxy 是 8080。"))
                }
            }
            if draft.kind != .pac {
                Section {
                    DisclosureGroup(L("代理服务器要求登录"), isExpanded: $showLogin) {
                        TextField(L("用户名"), text: $draft.username)
                        SecureField(L("密码"), text: $draft.password)
                        Text(L("密码只保存在这台 Mac 的钥匙串里。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    HStack {
                        Button {
                            detect()
                        } label: {
                            Label(L("自动检测本机代理"), systemImage: "wand.and.stars")
                        }
                        .disabled(detecting)
                        if detecting {
                            ProgressView().controlSize(.small)
                        }
                        Spacer()
                    }
                    if let found {
                        if found.isEmpty {
                            Text(L("没有找到正在运行的代理软件。请先启动代理软件，或者手动填写地址。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(found) { item in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.suggestedName)
                                    Text("\(item.kind.title) · \(item.host):\(item.port)" + (item.latencyMs.map { " · \($0) ms" } ?? ""))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L("用这个")) { use(item) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var targetsStep: some View {
        Form {
            Section {
                ForEach(ProxyTarget.allCases) { target in
                    Toggle(isOn: Binding(
                        get: { draft.kind == .pac ? target == .system : draft.targets.contains(target) },
                        set: { enabled in
                            if enabled { draft.targets.insert(target) } else { draft.targets.remove(target) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(target.title)
                            Text(target.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(draft.kind == .pac)
                }
            } header: {
                Text(L("开启代理时把勾上的地方都指向它，关闭时一起改回来"))
            } footer: {
                if draft.kind == .pac {
                    Text(L("PAC 脚本只能用于系统代理"))
                }
            }
            Section {
                HStack {
                    Button {
                        test()
                    } label: {
                        Label(L("测试连接"), systemImage: "speedometer")
                    }
                    .disabled(testing)
                    if testing {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if let result {
                    Label(result.ok ? L("%@，%@", result.latencyText, result.message) : result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.ok ? Color.green : Color.red)
                }
            } footer: {
                Text(L("经这个代理访问测速地址，看看能不能连上。连不上也可以先添加，以后再改。"))
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder
    private var finishStep: some View {
        if let built = try? makeProfile() {
            Form {
                Section {
                    HStack(spacing: 10) {
                        ColorDot(hex: built.profile.color, size: 12)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(built.profile.name)
                                .font(.system(size: 13, weight: .semibold))
                            Text(built.profile.summary)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent(L("生效范围"), value: ProxyTarget.allCases.filter { built.profile.targets.contains($0) }.map(\.title).joined(separator: L("、")))
                    Toggle(L("现在就开启"), isOn: $turnOnNow)
                }
                Section {
                    Text(hotkeyHint)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
    }

    private var hotkeyHint: String {
        if let hotkey = state.config.toggleHotkey {
            return L("以后点菜单栏的图标就能开关代理，也可以在任何程序里按 %@。改这条配置、再加别的（比如家里和公司各一套），在「设置 → 代理配置」里。", hotkey.display)
        }
        return L("以后点菜单栏的图标就能开关代理。改这条配置、再加别的（比如家里和公司各一套），在「设置 → 代理配置」里。")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step == 0 {
                Button(L("跳过")) { done(true) }
                    .help(L("到设置里自己填"))
            } else {
                Button(L("上一步")) {
                    problem = nil
                    step -= 1
                }
            }
            Spacer()
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            if step < Self.steps.count - 1 {
                Button(L("下一步")) { next() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Button(L("完成")) { finish() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: 动作

    private func makeProfile() throws -> (profile: Profile, password: String) {
        try draft.build(color: ProfilePalette.color(at: state.config.profiles.count), existingNames: state.config.profiles.map(\.name))
    }

    private func absorbAddress() {
        let before = draft
        draft.absorbAddress()
        if draft.username != before.username {
            showLogin = true
        }
    }

    private func next() {
        problem = nil
        if step == 0 {
            absorbAddress()
        }
        // 第一步只看地址和名称，生效范围在第二步选。
        var check = draft
        if step == 0 {
            check.targets = [.system]
        }
        do {
            _ = try check.build(color: ProfilePalette.colors[0], existingNames: [])
        } catch {
            problem = error.localizedDescription
            return
        }
        step += 1
    }

    private func use(_ item: DetectedProxy) {
        draft.kind = item.kind
        draft.address = "\(item.host):\(item.port)"
        if draft.name.trimmingCharacters(in: .whitespaces).isEmpty {
            draft.name = item.suggestedName
        }
        problem = nil
    }

    private func detect() {
        detecting = true
        let testURL = state.config.testURL
        Task { @MainActor in
            found = await LocalProxyDetector.detect(testURL: testURL)
            detecting = false
        }
    }

    private func test() {
        guard let built = try? makeProfile() else { return }
        testing = true
        result = nil
        let testURL = state.config.testURL
        Task { @MainActor in
            result = await ProxyTester.test(profile: built.profile, password: built.password, testURL: testURL)
            testing = false
        }
    }

    private func finish() {
        let made: (profile: Profile, password: String)
        do {
            made = try makeProfile()
        } catch {
            problem = error.localizedDescription
            return
        }
        var profile = made.profile
        if !made.password.isEmpty {
            do {
                try ProxyKeychain.set(made.password, for: profile.id)
                profile.hasPassword = true
            } catch {
                problem = error.localizedDescription
                return
            }
        }
        state.addProfile(profile)
        Log.info("新手引导添加了配置「\(profile.name)」")
        if turnOnNow {
            state.turnOn(profile)
        }
        done(false)
    }
}
