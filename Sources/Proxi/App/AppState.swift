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
    /// 可选扩展「代理引擎」（默认关闭，见 ExtensionManager）。
    let extensions = ExtensionManager()
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
        extensions.readState = { [weak self] in self?.persisted.extensionState ?? ExtensionState() }
        extensions.writeState = { [weak self] state in
            guard let self else { return }
            self.persisted.extensionState = state
            Store.save(self.persisted)
        }
        extensions.onChange = { [weak self] in self?.extensionChanged() }
        reconcileEngineProfile()
        finishLegacyMigration()
        extensions.start()
        // 测试用：启动时当作用户在扩展页里点了「关闭并移除」（CI 用，界面上不会出现）。
        if ProcessInfo.processInfo.environment["PROXI_TEST_DISABLE_EXTENSION"] == "1", persisted.extensionState.enabled {
            Log.info("扩展：测试环境变量 PROXI_TEST_DISABLE_EXTENSION=1，关闭并移除")
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                await self.disableExtension(removeApp: true)
            }
        }
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
        // 同步的配置里不带「代理引擎」那条配置（AppConfig 写文件时就去掉了，这里再去一次，比较时也不算它）。
        sync.currentConfig = { [weak self] in
            var config = self?.config ?? AppConfig()
            config.profiles.removeAll { $0.engine }
            return config
        }
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

    /// 第一次启动新版本时：以前版本的代理引擎数据挪到代理引擎的数据目录（一个都不删）；上次开着的是代理引擎那条配置就先把代理关掉
    /// （不然系统代理指向一个没人监听的本机端口），记下来，等用户在「设置 → 扩展」里开启、代理引擎运行起来后再开回来。
    /// 不弹扩展的说明（只在扩展页里打开开关时显示）；只有以前装过后台助手、又没有代理引擎的数据时提示可以移除。
    private func finishLegacyMigration() {
        legacyHelperInstalled = LegacyCleanup.helperInstalled
        var ext = persisted.extensionState
        let firstLaunch = !ext.migrationChecked
        if firstLaunch {
            ext.migrationChecked = true
            if legacy.needsMigration || legacy.hasEngineData {
                let moved = LegacyCleanup.migrateEngineData()
                Log.info("以前版本的代理引擎数据已放到 \(ExtensionManager.dataDirectory.path)：\(moved.isEmpty ? "没有要挪的" : moved.joined(separator: "、"))，原来的数据都保留")
                if var profile = legacy.builtInProfiles.first {
                    profile.engine = true
                    ext.profile = profile
                }
                if legacy.activeBuiltIn != nil {
                    ext.restoreActive = true
                }
                // 去掉以前版本的设置后写回去（代理引擎的设置已经在它自己的目录里了）。
                Store.save(config)
            }
            if legacy.hasEngineData {
                // 有代理引擎的数据：以后开启扩展还要用以前的后台助手，不弹移除的提示（「设置 → 通用」里照样能移除）。
                persisted.noticeShown = true
            }
            persisted.extensionState = ext
            Store.save(persisted)
        }
        if legacyHelperInstalled {
            Log.info(ext.enabled ? "以前版本的后台助手还在，代理引擎开着，留着" : "以前版本的后台助手还在，扩展没开，等用户确认后移除")
        }
        if config.profile(id: persisted.lastProfileID) == nil, persisted.lastProfileID != nil {
            persisted.lastProfileID = config.profiles.first?.id
            Store.save(persisted)
        }
        if firstLaunch, let active = legacy.activeBuiltIn, !ext.enabled {
            Log.info("上次开着的「\(active.name)」是代理引擎，先关掉代理，用户开启扩展后再开回来")
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
                persisted.lastProfileID = config.profiles.first { !$0.engine }?.id
                Store.save(persisted)
                busy = false
                refresh()
                onStatusChanged?()
                if failures.isEmpty {
                    Log.info("已关闭以前版本开着的代理引擎配置")
                } else {
                    let text = failures.joined(separator: L("；"))
                    Log.error("关闭以前版本开着的代理引擎配置失败：\(text)")
                    lastError = text
                }
            }
        }
        guard !persisted.noticeShown, legacyHelperInstalled, !persisted.extensionState.enabled else { return }
        persisted.noticeShown = true
        Store.save(persisted)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            NoticeWindowController.shared.showHelperNotice()
        }
        Log.info("已显示后台助手的提示")
    }

    // MARK: - 扩展「代理引擎」

    /// 从以前的版本更新过来时开着的是代理引擎那条配置、现在代理关着：开启扩展、代理引擎运行起来后把它开回来（扩展页的说明里会提到）。
    var willRestoreEngineProfile: Bool {
        guard persisted.extensionState.restoreActive, case .off = status else { return false }
        return true
    }

    /// 用户勾选同意说明并点了开启。
    func enableExtension() {
        extensions.accept()
        reconcileEngineProfile()
        extensions.prepareAndLaunch()
    }

    /// 关闭扩展：正在用「代理引擎」那条配置就先关掉代理（恢复系统设置），再退出代理引擎、去掉那条配置。
    func disableExtension(removeApp: Bool) async {
        if case .on(let current) = status, current.engine {
            turnOff()
            for _ in 0..<100 where busy {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        await extensions.disable(removeApp: removeApp)
        reconcileEngineProfile()
    }

    /// 代理引擎开了、停了、换了端口：调整配置列表里的「代理引擎」；从以前的版本过来、以前开着它的，内核起来后开回来
    /// （这时用户已经开着别的配置就不动它）。
    private func extensionChanged() {
        reconcileEngineProfile()
        if persisted.extensionState.enabled, persisted.extensionState.restoreActive, extensions.status?.coreRunning != true {
            Log.info("扩展：等代理引擎的内核起来后开回以前开着的配置")
        }
        guard persisted.extensionState.enabled, persisted.extensionState.restoreActive,
              let engineStatus = extensions.status, engineStatus.coreRunning,
              let profile = config.profiles.first(where: { $0.engine }) else { return }
        persisted.extensionState.restoreActive = false
        Store.save(persisted)
        guard case .off = status else {
            Log.info("代理引擎运行起来了，现在开着别的配置，不开回以前开着的「\(profile.name)」")
            return
        }
        Log.info("代理引擎运行起来了，开回以前开着的「\(profile.name)」")
        turnOn(profile)
    }

    /// 配置列表里的「代理引擎」：扩展开着时在最前面（端口跟着代理引擎），关着时去掉。
    func reconcileEngineProfile() {
        let ext = persisted.extensionState
        guard ext.enabled else {
            if config.profiles.contains(where: { $0.engine }) {
                config.profiles.removeAll { $0.engine }
            }
            if let id = persisted.lastProfileID, ext.profile?.id == id {
                persisted.lastProfileID = config.profiles.first?.id
                Store.save(persisted)
            }
            return
        }
        var profile = ext.profile ?? Profile.engineProfile(port: 7890)
        profile.engine = true
        if let port = extensions.status?.mixedPort {
            profile.port = port
        }
        if ext.profile != profile {
            persisted.extensionState.profile = profile
            Store.save(persisted)
        }
        if let index = config.profiles.firstIndex(where: { $0.engine }) {
            if config.profiles[index] != profile {
                update(profile)
            }
        } else {
            config.profiles.insert(profile, at: 0)
            if config.profiles.count == 1 {
                persisted.lastProfileID = profile.id
                Store.save(persisted)
            }
        }
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

    func toggle(askForPassword: Bool = true) {
        switch status {
        case .on, .external:
            turnOff()
        case .off(let next):
            if let next {
                turnOn(next, askForPassword: askForPassword)
            } else {
                lastError = L("还没有代理配置，请先在设置里添加一个")
                SettingsWindowController.shared.show(page: .profiles)
            }
        }
    }

    /// askForPassword：钥匙串里没有密码时弹窗请用户输入；命令行和 AI 助手调用时不弹窗，直接报错。
    func turnOn(_ profile: Profile, askForPassword: Bool = true) {
        guard !busy else { return }
        // 要登录的代理：密码从这台 Mac 的钥匙串里取；还没有（比如配置是从别的 Mac 同步来的）就请用户输入一次。
        var password = ""
        if profile.needsPassword {
            if let saved = ProxyKeychain.password(for: profile.id, allowUI: askForPassword) {
                password = saved
            } else if askForPassword, let entered = PasswordPrompt.ask(for: profile), !entered.isEmpty {
                do {
                    try ProxyKeychain.set(entered, for: profile.id)
                } catch {
                    Log.error("保存「\(profile.name)」的密码失败：\(error.localizedDescription)")
                }
                password = entered
            } else {
                lastError = L("没有「%@」的代理密码，没有开启", profile.name)
                Log.error("这台 Mac 的钥匙串里没有「\(profile.name)」的代理密码，没有开启")
                onStatusChanged?()
                return
            }
        }
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
            // 代理引擎那条配置：先确认代理引擎在运行（没运行就启动它，等内核起来）。
            if profile.engine {
                do {
                    _ = try await extensions.ensureRunning()
                } catch {
                    finish(action: L("开启 %@", profile.name), failures: [error.localizedDescription], successText: "")
                    return
                }
            }
            // 上一个配置设置过、新配置没有的项先清掉。
            if let previous {
                for target in previous.targets where !profile.targets.contains(target) {
                    if let error = await clear(target: target, mode: mode) {
                        failures.append(L("%@（清除）：%@", target.title, error))
                    }
                }
            }
            for target in ProxyTarget.allCases where profile.targets.contains(target) {
                if let error = await set(target: target, profile: profile, password: password) {
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

    private func set(target: ProxyTarget, profile: Profile, password: String) async -> String? {
        let url = profile.proxyURL(password: password)
        do {
            switch target {
            case .system:
                try await SystemProxy.apply(DesiredProxy(profile: profile, password: password))
            case .environment:
                try await EnvironmentProxy.set(proxyURL: url, noProxy: profile.noProxy)
            case .git:
                try await GitProxy.set(proxyURL: url)
            case .npm:
                try NpmProxy.set(proxyURL: url, noProxy: profile.noProxy)
            }
            return nil
        } catch {
            return Redact.secrets(error.localizedDescription)
        }
    }

    /// 已经保存在钥匙串里的密码（没有就是空的）。
    func savedPassword(for profile: Profile) -> String {
        profile.needsPassword ? (ProxyKeychain.password(for: profile.id) ?? "") : ""
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

    /// passwordChanged：只改了钥匙串里的密码（配置本身没变）时也要重新应用。
    func update(_ profile: Profile, passwordChanged: Bool = false) {
        guard let index = config.profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        let previous = config.profiles[index]
        config.profiles[index] = profile
        if profile.engine, persisted.extensionState.profile != profile {
            persisted.extensionState.profile = profile
            Store.save(persisted)
        }
        // 正在使用的配置改了地址：立即重新应用。
        if case .on(let current) = status, current.id == profile.id, previous != profile || passwordChanged {
            turnOn(profile)
        }
    }

    func remove(_ profile: Profile) {
        // 「代理引擎」那条配置跟着扩展走，在扩展页里关闭扩展才会去掉。
        guard !profile.engine else { return }
        if case .on(let current) = status, current.id == profile.id {
            turnOff()
        }
        config.profiles.removeAll { $0.id == profile.id }
        ProxyKeychain.delete(for: profile.id)
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
        reconcileEngineProfile()
        guard let active, !active.engine else { return }
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
        let result = await ProxyTester.test(profile: profile, password: savedPassword(for: profile), testURL: config.testURL)
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

    /// 退出时按设置关闭代理；代理引擎开着的话也让它退出（它自己停内核）。
    func handleExit() {
        control.stop()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: ExtensionManager.bundleIdentifier) {
            app.terminate()
        }
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
