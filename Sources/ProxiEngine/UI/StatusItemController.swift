import AppKit
import Combine
import SwiftUI

/// 菜单栏图标：左键打开面板，右键弹出菜单（节点、策略组、局域网共享、增强模式、网关模式）。面板是一个无边框的毛玻璃浮动窗口。
@MainActor
final class StatusItemController: NSObject {
    private let state: AppState
    private let statusItem: NSStatusItem
    private var panel: PanelWindow?
    private var hostingView: NSHostingView<PanelView>?
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
        // 节点列表变化、下载进度变化时面板高度会变，跟着调整窗口。
        state.engine.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateIcon() } }
            .store(in: &cancellables)
        state.core.objectWillChange
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in Task { @MainActor in self?.updateIcon() } }
            .store(in: &cancellables)
        updateIcon()
    }

    // MARK: - 图标

    func updateIcon() {
        guard let button = statusItem.button else { return }
        let running = state.engine.isRunning
        let image = NSImage(systemSymbolName: running ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle", accessibilityDescription: L("代理引擎"))
        image?.isTemplate = true
        button.image = image
        button.toolTip = L("代理引擎：%@\n本机端口 127.0.0.1:%@", state.engine.statusTitle, String(state.config.engine.mixedPort))
        if let panel, panel.isVisible {
            resizePanel()
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
        togglePanel()
    }

    // MARK: - 右键菜单

    private func showContextMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(header(L("代理引擎：%@", state.engine.statusTitle)))
        let enabledItem = item(L("启用代理引擎"), action: #selector(menuToggleEnabled), key: "")
        enabledItem.state = state.config.engine.enabled ? .on : .off
        menu.addItem(enabledItem)
        if state.config.engine.wantsCore {
            menu.addItem(.separator())
            let nodesItem = NSMenuItem(title: L("节点‖列表"), action: nil, keyEquivalent: "")
            nodesItem.submenu = nodesMenu()
            menu.addItem(nodesItem)
            if !state.engine.groupStates.isEmpty {
                let groupsItem = NSMenuItem(title: L("策略组"), action: nil, keyEquivalent: "")
                groupsItem.submenu = groupsMenu()
                menu.addItem(groupsItem)
            }
        }
        menu.addItem(.separator())
        let shareItem = item(L("局域网共享（PS5 等设备）"), action: #selector(menuToggleShare), key: "")
        shareItem.state = state.share.enabled ? .on : .off
        menu.addItem(shareItem)
        if state.share.enabled, let address = state.lanAddress {
            menu.addItem(header(L("设备上填 %@:%@", address.ip, state.share.port)))
        }
        let tunItem = item(L("增强模式（所有程序都经过代理）"), action: #selector(menuToggleTun), key: "")
        tunItem.state = state.tun.enabled ? .on : .off
        menu.addItem(tunItem)
        let gatewayItem = item(L("网关模式（设备的路由器填这台 Mac）"), action: #selector(menuToggleGateway), key: "")
        gatewayItem.state = state.tun.gateway ? .on : .off
        menu.addItem(gatewayItem)
        if state.tun.gateway, let address = state.lanAddress {
            menu.addItem(header(L("设备的路由器和 DNS 填 %@", address.ip)))
        }
        menu.addItem(.separator())
        menu.addItem(item(L("设置…"), action: #selector(menuSettings), key: ","))
        menu.addItem(item(L("退出代理引擎"), action: #selector(menuQuit), key: "q"))
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

    @objc private func menuToggleEnabled() { state.engine.setEnabled(!state.config.engine.enabled) }
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
            menu.addItem(header(engine.status == .starting ? L("内核正在启动…") : L("内核未运行")))
            return menu
        }
        let auto = NSMenuItem(title: L("自动选择") + (engine.autoNode.map { L("（%@）", $0) } ?? ""), action: #selector(menuSelectNode(_:)), keyEquivalent: "")
        auto.target = self
        auto.representedObject = ""
        auto.state = engine.currentSelection == Engine.autoGroup ? .on : .off
        menu.addItem(auto)
        let favorites = Set(state.config.engine.favoriteNodes)
        for node in engine.sortedNodes {
            let name = favorites.contains(node.name) ? "★ " + node.name : node.name
            let title = node.delayText.isEmpty ? name : L("%@　%@", name, node.delayText)
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
            let groupItem = NSMenuItem(title: L("%@　%@", CoreConfigBuilder.displayName(group.name), CoreConfigBuilder.displayName(group.now ?? "")), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            submenu.addItem(header(L("%@：%@", group.kind.title, group.kind.detail)))
            for member in group.members {
                var title = member == "DIRECT" ? L("直连") : CoreConfigBuilder.displayName(member)
                if let node = engine.nodes.first(where: { $0.name == member }), !node.delayText.isEmpty {
                    title += L("　%@", node.delayText)
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
            let view = PanelView(state: state, engine: state.engine, core: state.core, actions: PanelActions(
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
