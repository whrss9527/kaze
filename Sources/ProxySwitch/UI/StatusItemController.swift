import AppKit
import Combine
import SwiftUI

/// 菜单栏图标：左键打开面板（或按设置直接开关），右键弹出简洁菜单。面板是一个无边框的毛玻璃浮动窗口。
@MainActor
final class StatusItemController: NSObject {
    private let state: AppState
    private let statusItem: NSStatusItem
    private var panel: PanelWindow?
    private var hostingView: NSHostingView<PanelView>?
    private var keyObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    init(state: AppState) {
        self.state = state
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
        }
        // 更新条出现、进度变化、节点列表变化时面板高度会变，跟着调整窗口。
        state.updater.$phase
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.resizePanelIfVisible() } }
            .store(in: &cancellables)
        state.engine.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.resizePanelIfVisible() } }
            .store(in: &cancellables)
        state.speed.onUpdate = { [weak self] in self?.updateSpeedLabel() }
        state.$config
            .map { SpeedLabelSettings(side: $0.speedSide, colorFollowsStatus: $0.speedColorFollowsStatus) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in Task { @MainActor in self?.updateSpeedLabel() } }
            .store(in: &cancellables)
        updateSpeedLabel()
    }

    // MARK: - 图标与网速

    /// 图标右边两行小字：上行、下行。和开关合成一张图，两行文字以开关的中线对齐。
    private func updateSpeedLabel() {
        guard let button = statusItem.button else { return }
        let meter = state.speed
        if meter.mode == .none {
            button.image = StatusIcon.image(for: iconState)
        } else {
            let iconState = self.iconState
            let layout = SpeedLayout.resolve(side: state.config.speedSide, state: iconState)
            var textColor = labelColor(for: button)
            if state.config.speedColorFollowsStatus, let accent = StatusIcon.speedTextColor(for: iconState, darkMenuBar: isDark(button)) {
                textColor = accent.cgColor
            }
            button.image = StatusIcon.image(for: iconState, upload: SpeedFormatter.compact(bytesPerSecond: meter.upload), download: SpeedFormatter.compact(bytesPerSecond: meter.download), textColor: textColor, layout: layout)
        }
        button.imagePosition = .imageOnly
    }

    /// 菜单栏现在是不是深色（深色模式，或者浅色模式下被桌面衬成深色）。
    private func isDark(_ button: NSStatusBarButton) -> Bool {
        let match = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        return match == .darkAqua || match == .vibrantDark
    }

    /// 菜单栏当前外观（深色 / 浅色）下的文字颜色。
    private func labelColor(for button: NSStatusBarButton) -> CGColor {
        var color = NSColor.labelColor.cgColor
        button.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.labelColor.cgColor
        }
        return color
    }

    private var iconState: StatusIconState {
        switch state.status {
        case .on(let profile):
            let color = NSColor(hex: profile.color)
            return state.health == .down ? .warning(color) : .on(color)
        case .external:
            return .external
        case .off:
            return .off
        }
    }

    func updateIcon() {
        guard let button = statusItem.button else { return }
        updateSpeedLabel()
        button.toolTip = tooltip + (state.speed.mode == .none ? "" : "\n↑ \(SpeedFormatter.full(bytesPerSecond: state.speed.upload))  ↓ \(SpeedFormatter.full(bytesPerSecond: state.speed.download))")
        if let panel, panel.isVisible {
            resizePanel()
        }
    }

    private var tooltip: String {
        switch state.status {
        case .on(let profile):
            return state.health == .down ? "ProxySwitch\n已开启：\(profile.name)\n代理服务器连不上" : "ProxySwitch\n已开启：\(profile.name)\n\(profile.summary)"
        case .external(let description):
            return "ProxySwitch\n系统代理由其他程序设置\n\(description)"
        case .off(let next):
            if let next {
                return "ProxySwitch\n已关闭，下次开启：\(next.name)"
            }
            return "ProxySwitch\n还没有代理配置"
        }
    }

    // MARK: - 点击

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            closePanel()
            showContextMenu()
            return
        }
        switch state.config.clickAction {
        case .toggle:
            closePanel()
            state.toggle()
        case .panel:
            togglePanel()
        }
    }

    func perform(_ command: URLCommand) {
        switch command {
        case .turnOn:
            if case .off(let next) = state.status, let next { state.turnOn(next) }
        case .turnOff:
            state.turnOff()
        case .toggle:
            state.toggle()
        case .use(let name):
            if !state.use(named: name) {
                state.notify(title: "没有找到配置", body: "没有叫「\(name)」的配置", problem: true)
            }
        case .settings(let page):
            SettingsWindowController.shared.show(page: page)
        case .panel:
            openPanel()
        case .update:
            SettingsWindowController.shared.show(page: .about)
            Task { await state.updater.checkAndInstall() }
        case .share(let enabled):
            state.setShareEnabled(enabled ?? !state.share.enabled)
        case .tun(let enabled):
            setTun(enabled ?? !state.tun.enabled)
        case .gateway(let enabled):
            setGateway(enabled ?? !state.tun.gateway)
        case .diagnose(let url, let device):
            SettingsWindowController.shared.navigation.diagnoseRequest = DiagnoseRequest(url: url ?? "", device: device)
            SettingsWindowController.shared.show(page: .diagnose)
        case .node(let name):
            runTool("select_node", ["name": name])
        case .mode(let mode):
            runTool("set_mode", ["mode": mode.rawValue])
        case .group(let name, let member):
            runTool("select_group", ["group": name, "member": member])
        case .importConfig(let target):
            // 网页也能触发 URL 命令：导入一定先给用户看预览、由用户确认。
            SettingsWindowController.shared.navigation.importRequest = target
            SettingsWindowController.shared.show(page: .advanced)
        case .tool(let name, let params):
            guard let tool = ControlCatalog.tool(named: name) else {
                state.notify(title: "没有这个命令", body: name, problem: true)
                return
            }
            guard tool.permission != .full else {
                state.notify(title: "URL 命令不能改配置", body: "「\(tool.title)」要改配置，请在设置里操作，或者用命令行、AI 助手", problem: true)
                return
            }
            runTool(name, params)
        }
    }

    /// 经本机控制接口执行（和命令行、AI 助手一样受权限限制，也记在操作记录里）。
    private func runTool(_ name: String, _ params: [String: Any]) {
        Task { @MainActor in
            do {
                let result = try await state.control.call(name, params: params, client: "url")
                if let text = result["text"] as? String {
                    Log.info("URL 命令 \(name)：\(text)")
                }
            } catch {
                state.notify(title: "命令没有执行", body: error.localizedDescription, problem: true)
            }
            updateIcon()
        }
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        switch state.status {
        case .on(let profile):
            menu.addItem(header("代理已开启：\(profile.name)"))
            menu.addItem(item("关闭代理", action: #selector(menuTurnOff), key: ""))
        case .external(let description):
            menu.addItem(header("系统代理由其他程序设置：\(description)"))
            menu.addItem(item("关闭系统代理", action: #selector(menuTurnOff), key: ""))
            menu.addItem(item("保存为配置", action: #selector(menuSaveExternal), key: ""))
        case .off(let next):
            menu.addItem(header("代理已关闭"))
            if next != nil {
                menu.addItem(item("开启代理", action: #selector(menuTurnOn), key: ""))
            }
        }
        if !state.config.profiles.isEmpty {
            menu.addItem(.separator())
            for profile in state.config.profiles {
                let menuItem = item(profile.name, action: #selector(menuUseProfile(_:)), key: "")
                menuItem.representedObject = profile.id.uuidString
                menuItem.image = StatusIcon.dotImage(color: NSColor(hex: profile.color))
                if case .on(let current) = state.status, current.id == profile.id {
                    menuItem.state = .on
                }
                menu.addItem(menuItem)
            }
        }
        if state.config.engine.wantsCore {
            menu.addItem(.separator())
            let nodesItem = NSMenuItem(title: "节点", action: nil, keyEquivalent: "")
            nodesItem.submenu = nodesMenu()
            menu.addItem(nodesItem)
            if !state.engine.groupStates.isEmpty {
                let groupsItem = NSMenuItem(title: "策略组", action: nil, keyEquivalent: "")
                groupsItem.submenu = groupsMenu()
                menu.addItem(groupsItem)
            }
        }
        menu.addItem(.separator())
        let shareItem = item("局域网共享（PS5 等设备）", action: #selector(menuToggleShare), key: "")
        shareItem.state = state.share.enabled ? .on : .off
        menu.addItem(shareItem)
        if state.share.enabled, let address = state.lanAddress {
            menu.addItem(header("设备上填 \(address.ip):\(state.share.port)"))
        }
        let tunItem = item("增强模式（所有程序都经过代理）", action: #selector(menuToggleTun), key: "")
        tunItem.state = state.tun.enabled ? .on : .off
        menu.addItem(tunItem)
        let gatewayItem = item("网关模式（设备的路由器填这台 Mac）", action: #selector(menuToggleGateway), key: "")
        gatewayItem.state = state.tun.gateway ? .on : .off
        menu.addItem(gatewayItem)
        if state.tun.gateway, let address = state.lanAddress {
            menu.addItem(header("设备的路由器和 DNS 填 \(address.ip)"))
        }
        menu.addItem(.separator())
        let updater = state.updater
        if let release = updater.release, updater.isInstalling {
            menu.addItem(header("正在更新到 \(release.version)…"))
        } else if let release = updater.release {
            menu.addItem(item("更新到 \(release.version)…", action: #selector(menuInstallUpdate), key: ""))
        } else {
            menu.addItem(item("检查更新…", action: #selector(menuCheckUpdates), key: ""))
        }
        menu.addItem(item("设置…", action: #selector(menuSettings), key: ","))
        menu.addItem(item("退出 ProxySwitch", action: #selector(menuQuit), key: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func header(_ title: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menuItem.isEnabled = false
        return menuItem
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
        menuItem.target = self
        return menuItem
    }

    @objc private func menuTurnOn() {
        if case .off(let next) = state.status, let next { state.turnOn(next) }
    }

    @objc private func menuTurnOff() { state.turnOff() }
    @objc private func menuSaveExternal() { state.saveExternalAsProfile() }
    @objc private func menuToggleShare() { state.setShareEnabled(!state.share.enabled) }
    @objc private func menuToggleTun() { setTun(!state.tun.enabled) }
    @objc private func menuToggleGateway() { setGateway(!state.tun.gateway) }

    /// 打开增强模式：还没装特权助手时带到高级页去装。
    private func setTun(_ enabled: Bool) {
        state.setTunEnabled(enabled)
        if enabled && !state.helper.isReady {
            SettingsWindowController.shared.show(page: .advanced)
        }
    }

    private func setGateway(_ enabled: Bool) {
        state.setGatewayEnabled(enabled)
        if enabled && !state.helper.isReady {
            SettingsWindowController.shared.show(page: .share)
        }
    }
    @objc private func menuSettings() { SettingsWindowController.shared.show(page: nil) }
    @objc private func menuQuit() { NSApp.terminate(nil) }

    @objc private func menuCheckUpdates() {
        SettingsWindowController.shared.show(page: .about)
        Task { await state.updater.check(manual: true) }
    }

    @objc private func menuInstallUpdate() {
        SettingsWindowController.shared.show(page: .about)
        state.updater.install()
    }

    /// 「节点」子菜单：模式、自动选择、所有节点。
    private func nodesMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for mode in EngineMode.allCases {
            let menuItem = NSMenuItem(title: mode.title, action: #selector(menuSetMode(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = mode.rawValue
            menuItem.state = state.config.engine.mode == mode ? .on : .off
            menu.addItem(menuItem)
        }
        menu.addItem(.separator())
        let engine = state.engine
        guard engine.isRunning else {
            menu.addItem(header(engine.status == .starting ? "内核正在启动…" : "内核未运行"))
            return menu
        }
        let auto = NSMenuItem(title: "自动选择" + (engine.autoNode.map { "（\($0)）" } ?? ""), action: #selector(menuSelectNode(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = engine.currentSelection == Engine.autoGroup ? .on : .off
        menu.addItem(auto)
        let favorites = Set(state.config.engine.favoriteNodes)
        for node in engine.sortedNodes {
            let name = favorites.contains(node.name) ? "★ " + node.name : node.name
            let title = node.delayText.isEmpty ? name : "\(name)　\(node.delayText)"
            let menuItem = NSMenuItem(title: title, action: #selector(menuSelectNode(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = node.name
            menuItem.state = engine.currentSelection == node.name ? .on : .off
            menu.addItem(menuItem)
        }
        return menu
    }

    /// 「策略组」子菜单：每个组一个子菜单，列出成员，手动选择的组可以点选。
    private func groupsMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let engine = state.engine
        for group in engine.groupStates {
            let groupItem = NSMenuItem(title: "\(group.name)　\(group.now ?? "")", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(header("\(group.kind.title)：\(group.kind.detail)"))
            for member in group.members {
                var title = member == "DIRECT" ? "直连" : member
                if let node = engine.nodes.first(where: { $0.name == member }), !node.delayText.isEmpty {
                    title += "　\(node.delayText)"
                }
                let menuItem = NSMenuItem(title: title, action: #selector(menuSelectGroupMember(_:)), keyEquivalent: "")
                menuItem.target = self
                menuItem.representedObject = ["group": group.name, "member": member]
                menuItem.state = group.now == member ? .on : .off
                menuItem.isEnabled = group.kind == .select
                submenu.addItem(menuItem)
            }
            groupItem.submenu = submenu
            menu.addItem(groupItem)
        }
        return menu
    }

    @objc private func menuSelectGroupMember(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? [String: String], let group = info["group"], let member = info["member"] else { return }
        Task { await state.engine.select(group: group, member: member) }
    }

    @objc private func menuSetMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = EngineMode(rawValue: raw) else { return }
        state.engine.setMode(mode)
    }

    @objc private func menuSelectNode(_ sender: NSMenuItem) {
        let name = sender.representedObject as? String
        state.selectEngineProfile()
        Task { await state.engine.select(name?.isEmpty == false ? name : nil) }
    }

    @objc private func menuUseProfile(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String, let id = UUID(uuidString: text),
              let profile = state.config.profile(id: id) else { return }
        state.use(profile)
    }

    // MARK: - 面板

    private func togglePanel() {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            openPanel()
        }
    }

    func openPanel() {
        if panel == nil {
            let view = PanelView(state: state, engine: state.engine, actions: PanelActions(
                openSettings: { [weak self] page in
                    MainActor.assumeIsolated {
                        self?.closePanel()
                        SettingsWindowController.shared.show(page: page)
                    }
                },
                close: { [weak self] in
                    MainActor.assumeIsolated { self?.closePanel() }
                },
                quit: {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                },
                layoutChanged: { [weak self] in
                    MainActor.assumeIsolated {
                        DispatchQueue.main.async { self?.resizePanelIfVisible() }
                    }
                },
                sizeChanged: { [weak self] size in
                    MainActor.assumeIsolated { self?.resizePanel(to: size) }
                }
            ))
            let hosting = NSHostingView(rootView: view)
            hostingView = hosting
            let panel = PanelWindow(contentView: hosting)
            panel.onClose = { [weak self] in
                MainActor.assumeIsolated { self?.closePanel() }
            }
            self.panel = panel
        }
        guard let panel else { return }
        resizePanel()
        position(panel)
        panel.orderFrontRegardless()
        panel.makeKey()
        statusItem.button?.highlight(true)
    }

    func closePanel() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
    }

    private func resizePanelIfVisible() {
        if let panel, panel.isVisible {
            resizePanel()
        }
    }

    private func resizePanel() {
        guard let hostingView else { return }
        resizePanel(to: hostingView.fittingSize)
    }

    /// 顶边不动，按内容尺寸调整窗口。
    private func resizePanel(to size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let rounded = NSSize(width: ceil(size.width), height: ceil(size.height))
        guard rounded != panel.frame.size else { return }
        let origin = NSPoint(x: panel.frame.origin.x, y: panel.frame.maxY - rounded.height)
        panel.setFrame(NSRect(origin: origin, size: rounded), display: true)
    }

    private func position(_ panel: PanelWindow) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let size = panel.frame.size
        var origin = NSPoint(x: buttonRect.midX - size.width / 2, y: buttonRect.minY - size.height - 6)
        if let screen = buttonWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
            origin.y = max(origin.y, visible.minY + 8)
        }
        panel.setFrameOrigin(origin)
    }
}

/// 无边框、不激活程序的浮动面板：点到别处或按 Esc 时关闭。
final class PanelWindow: NSPanel {
    var onClose: (() -> Void)?

    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 200), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        self.contentView = contentView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onClose?()
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }
}

extension StatusIcon {
    /// 菜单里配置的颜色圆点。
    static func dotImage(color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        return image
    }
}

/// 影响网速文字怎么画的设置，变了就重画。
private struct SpeedLabelSettings: Equatable {
    var side: SpeedSide
    var colorFollowsStatus: Bool
}
