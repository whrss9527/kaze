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
            button.image = StatusIcon.image(for: iconState, upload: SpeedFormatter.compact(bytesPerSecond: meter.upload), download: SpeedFormatter.compact(bytesPerSecond: meter.download), textColor: labelColor(for: button))
        }
        button.imagePosition = .imageOnly
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
        }
        menu.addItem(.separator())
        let shareItem = item("局域网共享（PS5 等设备）", action: #selector(menuToggleShare), key: "")
        shareItem.state = state.share.enabled ? .on : .off
        menu.addItem(shareItem)
        if state.share.enabled, let address = state.lanAddress {
            menu.addItem(header("设备上填 \(address.ip):\(state.share.port)"))
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
        for node in engine.nodes {
            let title = node.delayText.isEmpty ? node.name : "\(node.name)　\(node.delayText)"
            let menuItem = NSMenuItem(title: title, action: #selector(menuSelectNode(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = node.name
            menuItem.state = engine.currentSelection == node.name ? .on : .off
            menu.addItem(menuItem)
        }
        return menu
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
