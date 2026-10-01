import AppKit
import Combine

/// 当前代理状态：关着（下次会开哪个配置）、由本程序开着某个配置、系统代理被别的程序设置了。
enum ProxyStatus: Equatable {
    case off(next: Profile?)
    case on(Profile)
    case external(String)

    var isOn: Bool {
        if case .on = self { return true }
        return false
    }

    var profile: Profile? {
        switch self {
        case .on(let profile): return profile
        case .off(let next): return next
        case .external: return nil
        }
    }
}

enum Health: Equatable {
    case unknown
    case ok
    case down
}

/// 核心状态：配置、系统代理快照、开关操作，所有界面都观察它。只在主线程上使用。
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var config: AppConfig
    @Published private(set) var persisted: PersistedState
    @Published private(set) var snapshot: ProxySnapshot = SystemProxy.current()
    @Published private(set) var health: Health = .unknown
    @Published private(set) var busy = false
    @Published var lastError: String?
    @Published var testResults: [UUID: TestResult] = [:]
    @Published var loginItemEnabled = false
    /// 以前版本装的后台助手还在（要管理员密码才能删）。
    @Published private(set) var legacyHelperInstalled = false
    let updater = Updater()
    let sync = CloudSync()
    let speed = SpeedMeter()
    /// 本机控制接口（命令行、AI 助手）。
    let control = ControlService()
    /// 按网络自动切换。
    let network = NetworkAutomation()
    /// 更新后正在重新启动：退出时不要按「退出时关闭代理」清理。
    var relaunching = false

    private var watcher: SystemWatcher?
    private var refreshTimer: Timer?
    private var healthTimer: Timer?
    private var healthFailures = 0
    private var cancellables = Set<AnyCancellable>()

    var onStatusChanged: (@MainActor () -> Void)?
    /// 从以前的版本更新过来时要收尾的事（读配置之前看过原始文件）。
    private let legacy: LegacyCleanup.Findings

    private init() {
        legacy = LegacyCleanup.inspect()
        config = Store.loadConfig() ?? AppConfig()
        persisted = Store.loadState()
        $config
            .dropFirst()
            .removeDuplicates()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { config in Store.save(config) }
            .store(in: &cancellables)
    }

    /// 启动时调用：开始监听系统变化，注册快捷键。
    func start() {
        watcher = SystemWatcher { [weak self] in self?.refresh() }
        watcher?.start()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkHealth() }
        }
        loginItemEnabled = LoginItem.isEnabled
        finishLegacyMigration()
        registerHotkey()
        $config
            .map(\.toggleHotkey)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.registerHotkey() } }
            .store(in: &cancellables)
        refresh()
        Task { await checkHealth() }
        updater.notify = { [weak self] title, body in
            self?.notify(title: title, body: body, problem: false, route: "about", category: Notifier.updateCategory)
        }
        // 更新先经系统代理访问 GitHub，失败再直连。
        updater.routesProvider = { url in
            NetworkRoute.routes(for: url, system: SystemProxy.current())
        }
        updater.onRelaunch = { [weak self] in
            self?.relaunching = true
            NSApp.terminate(nil)
        }
        updater.startAutomaticChecks { [weak self] in self?.config.autoCheckUpdates ?? true }
        sync.currentConfig = { [weak self] in self?.config ?? AppConfig() }
        sync.applyRemote = { [weak self] config in self?.applyRemoteConfig(config) }
        sync.onEnabledChanged = { [weak self] enabled in
            guard let self else { return }
            self.persisted.syncEnabled = enabled
            Store.save(self.persisted)
        }
        $config
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] config in Task { @MainActor in self?.sync.localChanged(config) } }
            .store(in: &cancellables)
        sync.start(enabled: persisted.syncEnabled)
        control.start(state: self)
        network.start(state: self)
        speed.setMode(config.speedDisplay)
        $config
            .map(\.speedDisplay)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] mode in Task { @MainActor in self?.speed.setMode(mode) } }
            .store(in: &cancellables)
    }

    // MARK: - 从以前的版本更新过来

    /// 第一次启动新版本时：上次开着的是以前版本内置代理的那条配置就把代理关掉（不然系统代理指向一个已经不存在的本机端口），
    /// 删掉以前版本留下的文件，然后显示一次说明。
    private func finishLegacyMigration() {
        legacyHelperInstalled = LegacyCleanup.helperInstalled
        if legacyHelperInstalled {
            Log.info("以前版本的后台助手还在，等用户确认后移除")
        }
        let removed = LegacyCleanup.removeLegacyData()
        if !removed.isEmpty {
            Log.info("删掉了以前版本留下的数据：\(removed.joined(separator: "、"))")
        }
        if legacy.needsNotice {
            Log.info("配置里有以前版本的设置：去掉了 \(legacy.builtInProfiles.count) 条自动生成的配置")
        }
        if config.profile(id: persisted.lastProfileID) == nil, persisted.lastProfileID != nil {
            persisted.lastProfileID = config.profiles.first?.id
            Store.save(persisted)
        }
        // 去掉以前版本的设置后写回去。
        if legacy.needsNotice {
            Store.save(config)
            Store.save(persisted)
        }
        var turnedOff = false
        if let active = legacy.activeBuiltIn {
            turnedOff = true
            Log.info("上次开着的「\(active.name)」是以前版本的内置代理，关掉代理")
            busy = true
            let mode = config.offMode
            Task {
                var failures: [String] = []
                for target in ProxyTarget.allCases where active.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@：%@", target.title, error))
                    }
                }
                persisted.enabledByUs = false
                persisted.original = nil
                persisted.lastProfileID = config.profiles.first?.id
                Store.save(persisted)
                busy = false
                refresh()
                onStatusChanged?()
                if failures.isEmpty {
                    Log.info("已关闭以前版本的内置代理")
                } else {
                    let text = failures.joined(separator: L("；"))
                    Log.error("关闭以前版本的内置代理失败：\(text)")
                    lastError = text
                }
            }
        }
        guard !persisted.noticeShown, legacy.needsNotice || legacyHelperInstalled else { return }
        persisted.noticeShown = true
        Store.save(persisted)
        let helper = legacyHelperInstalled
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NoticeWindowController.shared.showUpgradeNotice(turnedOff: turnedOff, helperInstalled: helper)
        }
        Log.info("已显示 0.13.0 的说明")
    }

    /// 删掉以前版本的后台助手（系统会请用户输入管理员密码）。
    func removeLegacyHelper() async {
        do {
            try await LegacyCleanup.removeHelper()
        } catch {
            lastError = (error as? ControlError)?.message ?? error.localizedDescription
        }
        legacyHelperInstalled = LegacyCleanup.helperInstalled
    }

    // MARK: - 状态

    var status: ProxyStatus {
        if snapshot.isActive {
            if let profile = matchingProfile() {
                return .on(profile)
            }
            return .external(snapshot.summary)
        }
        let next = selectedProfile
        if let next, persisted.enabledByUs, !next.targets.contains(.system) {
            // 不含系统代理的配置（只设环境变量、git、npm）无法从系统代理判断，按记录的状态算。
            return .on(next)
        }
        return .off(next: next)
    }

    /// 最近使用的配置，没有记录时是第一个。
    var selectedProfile: Profile? {
        config.profile(id: persisted.lastProfileID) ?? config.profiles.first
    }

    private func matchingProfile() -> Profile? {
        if let selected = selectedProfile, snapshot.matches(selected) {
            return selected
        }
        return config.profiles.first { snapshot.matches($0) }
    }

    func refresh() {
        let current = SystemProxy.current()
        let changed = current != snapshot
        snapshot = current
        if changed {
            onStatusChanged?()
        }
    }

    // MARK: - 开关

    func toggle() {
        switch status {
        case .on, .external:
            turnOff()
        case .off(let next):
            if let next {
                turnOn(next)
            } else {
                lastError = L("还没有代理配置，请先在设置里添加一个")
                SettingsWindowController.shared.show(page: .profiles)
            }
        }
    }

    func turnOn(_ profile: Profile) {
        guard !busy else { return }
        busy = true
        let previous: Profile? = {
            if case .on(let current) = status { return current }
            return persisted.enabledByUs ? selectedProfile : nil
        }()
        if !status.isOn || persisted.original == nil {
            persisted.original = snapshot
        }
        let mode = config.offMode
        Task {
            var failures: [String] = []
            // 上一个配置设置过、新配置没有的项先清掉。
            if let previous {
                for target in previous.targets where !profile.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@（清除）：%@", target.title, error))
                    }
                }
            }
            for target in ProxyTarget.allCases where profile.targets.contains(target) {
                if let error = await set(target: target, profile: profile) {
                    failures.append(L("%@：%@", target.title, error))
                }
            }
            persisted.lastProfileID = profile.id
            persisted.enabledByUs = failures.count < profile.targets.count
            Store.save(persisted)
            finish(action: L("开启 %@", profile.name), failures: failures, successText: profile.summary)
        }
    }

    func turnOff() {
        guard !busy else { return }
        busy = true
        let current = status
        let mode = config.offMode
        Task {
            var failures: [String] = []
            switch current {
            case .external:
                if let error = await clear(target: .system, mode: .direct) {
                    failures.append(L("系统代理：%@", error))
                }
            case .on(let profile):
                for target in ProxyTarget.allCases where profile.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@：%@", target.title, error))
                    }
                }
            case .off:
                break
            }
            persisted.enabledByUs = false
            persisted.original = nil
            Store.save(persisted)
            finish(action: L("关闭代理"), failures: failures, successText: mode == .restore ? L("已恢复开启前的设置") : L("已改为直接连接"))
        }
    }

    func use(_ profile: Profile) {
        if case .on(let current) = status, current.id == profile.id {
            turnOff()
        } else {
            turnOn(profile)
        }
    }

    func use(named name: String) -> Bool {
        guard let profile = config.profiles.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return false
        }
        turnOn(profile)
        return true
    }

    private func finish(action: String, failures: [String], successText: String) {
        busy = false
        healthFailures = 0
        refresh()
        onStatusChanged?()
        if failures.isEmpty {
            Log.info("\(action) 成功")
            lastError = nil
            notify(title: action, body: successText, problem: false)
        } else {
            let text = failures.joined(separator: L("；"))
            Log.error("\(action) 失败：\(text)")
            lastError = text
            notify(title: L("%@时出错", action), body: text, problem: true)
        }
        Task { await checkHealth() }
    }

    private func set(target: ProxyTarget, profile: Profile) async -> String? {
        do {
            switch target {
            case .system:
                try await SystemProxy.apply(DesiredProxy(profile: profile))
            case .environment:
                try await EnvironmentProxy.set(proxyURL: profile.proxyURL, noProxy: profile.noProxy)
            case .git:
                try await GitProxy.set(proxyURL: profile.proxyURL)
            case .npm:
                try NpmProxy.set(proxyURL: profile.proxyURL, noProxy: profile.noProxy)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func clear(target: ProxyTarget, mode: OffMode) async -> String? {
        do {
            switch target {
            case .system:
                let current = SystemProxy.current()
                if mode == .restore, let original = persisted.original {
                    try await SystemProxy.apply(DesiredProxy(restoring: original))
                } else {
                    let autoDiscovery = persisted.original?.autoDiscovery ?? current.autoDiscovery
                    try await SystemProxy.apply(DesiredProxy(offWithAutoDiscovery: autoDiscovery, bypassDomains: current.exceptions))
                }
            case .environment:
                try await EnvironmentProxy.clear()
            case .git:
                try await GitProxy.clear()
            case .npm:
                try NpmProxy.clear()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - 配置

    func addProfile(_ profile: Profile) {
        config.profiles.append(profile)
        if config.profiles.count == 1 {
            persisted.lastProfileID = profile.id
            Store.save(persisted)
        }
    }

    func update(_ profile: Profile) {
        guard let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let previous = config.profiles[index]
        config.profiles[index] = profile
        // 正在使用的配置改了地址：立即重新应用。
        if case .on(let current) = status, current.id == profile.id, previous != profile {
            turnOn(profile)
        }
    }

    func remove(_ profile: Profile) {
        if case .on(let current) = status, current.id == profile.id {
            turnOff()
        }
        config.profiles.removeAll { $0.id == profile.id }
        if persisted.lastProfileID == profile.id {
            persisted.lastProfileID = config.profiles.first?.id
            Store.save(persisted)
        }
    }

    func move(from source: IndexSet, to destination: Int) {
        config.profiles.move(fromOffsets: source, toOffset: destination)
    }

    /// 来自 iCloud 的配置：整个换掉。正在使用的配置如果改了地址就重新应用，被删了就关闭代理。
    private func applyRemoteConfig(_ remote: AppConfig) {
        let active: Profile? = {
            if case .on(let profile) = status { return profile }
            return nil
        }()
        config = remote
        guard let active else { return }
        if let updated = remote.profile(id: active.id) {
            if updated != active {
                turnOn(updated)
            }
        } else {
            turnOff()
        }
    }

    /// 把别的程序设置的系统代理保存成配置。
    func saveExternalAsProfile() {
        guard var profile = snapshot.asProfile(name: L("系统代理")) else { return }
        var index = 1
        while config.profiles.contains(where: { $0.name == profile.name }) {
            index += 1
            profile.name = L("系统代理 %@", index)
        }
        profile.color = ProfilePalette.color(at: config.profiles.count)
        addProfile(profile)
        persisted.lastProfileID = profile.id
        Store.save(persisted)
        refresh()
    }

    func setLoginItem(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled: enabled)
            loginItemEnabled = LoginItem.isEnabled
        } catch {
            lastError = L("设置登录时启动失败：%@", error.localizedDescription)
            loginItemEnabled = LoginItem.isEnabled
        }
    }

    // MARK: - 测速与健康

    func test(_ profile: Profile) async {
        let result = await ProxyTester.test(profile: profile, testURL: config.testURL)
        testResults[profile.id] = result
    }

    func testAll() async {
        await withTaskGroup(of: Void.self) { group in
            for profile in config.profiles {
                group.addTask { await self.test(profile) }
            }
        }
    }

    func checkHealth() async {
        guard config.healthCheck, case .on(let profile) = status, profile.kind != .pac else {
            health = .unknown
            healthFailures = 0
            return
        }
        let reachable = await ProxyTester.reachable(host: profile.host, port: profile.port)
        if reachable {
            if health == .down {
                notify(title: L("代理服务器恢复了"), body: profile.summary, problem: false)
            }
            health = .ok
            healthFailures = 0
        } else {
            healthFailures += 1
            // 连续两次连不上才算故障，避免偶发抖动。
            if healthFailures >= 2 && health != .down {
                health = .down
                notify(title: L("连不上代理服务器"), body: L("%@（%@）没有响应，浏览器可能无法上网", profile.name, profile.summary), problem: true)
            }
        }
        onStatusChanged?()
    }

    // MARK: - 通知与退出

    func notify(title: String, body: String, problem: Bool, route: String? = nil, category: String? = nil) {
        switch config.notifyLevel {
        case .none: return
        case .problems where !problem: return
        default: break
        }
        Notifier.shared.show(title: title, body: body, route: route, category: category)
    }

    /// 退出时按设置关闭代理。
    func handleExit() {
        control.stop()
        guard !relaunching, config.disableOnExit, case .on(let profile) = status else { return }
        let desired = DesiredProxy(offWithAutoDiscovery: persisted.original?.autoDiscovery ?? snapshot.autoDiscovery, bypassDomains: snapshot.exceptions)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            if profile.targets.contains(.system) {
                try? await SystemProxy.apply(desired)
            }
            if profile.targets.contains(.environment) {
                try? await EnvironmentProxy.clear()
            }
            if profile.targets.contains(.git) {
                try? await GitProxy.clear()
            }
            if profile.targets.contains(.npm) {
                try? NpmProxy.clear()
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
    }

    private func registerHotkey() {
        HotkeyCenter.shared.unregister(id: 1)
        guard let binding = config.toggleHotkey else { return }
        if !HotkeyCenter.shared.register(id: 1, binding: binding, action: { [weak self] in
            Task { @MainActor in self?.toggle() }
        }) {
            lastError = L("快捷键 %@ 已被其他程序占用，请换一个", binding.display)
        }
    }
}
