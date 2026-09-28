import AppKit
import SwiftUI

struct PanelActions {
    var openSettings: (SettingsPage?) -> Void
    var close: () -> Void
    var quit: () -> Void
    /// 面板内容高度变了（展开节点列表等），窗口要跟着调整。
    var layoutChanged: () -> Void
    /// SwiftUI 量出来的面板实际尺寸。
    var sizeChanged: (CGSize) -> Void
}

/// 菜单栏面板：状态卡片和大开关、节点卡片、配置列表、快捷操作。
struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    let actions: PanelActions
    @State private var testing = false
    @State private var copied = false
    @AppStorage("panel.showNodes") private var showNodes = true
    @State private var nodeFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusCard
            if case .external = state.status {
                externalCard
            }
            UpdateBanner(updater: state.updater) { actions.openSettings(.about) }
            if state.config.engine.wantsCore {
                nodeCard
                if engine.isRunning, !engine.groupStates.isEmpty {
                    groupsCard
                }
            }
            if state.share.enabled {
                shareCard
            }
            if !state.config.profiles.isEmpty {
                profileList
            } else {
                emptyCard
            }
            if let error = state.lastError {
                errorCard(error)
            }
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(GlassPanelBackground())
        .padding(8)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: PanelSizeKey.self, value: proxy.size)
        })
        .onPreferenceChange(PanelSizeKey.self) { size in
            actions.sizeChanged(size)
        }
    }

    // MARK: - 状态

    private var isOn: Binding<Bool> {
        Binding(get: { state.status.isOn }, set: { _ in state.toggle() })
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            StatusBadge(status: state.status, health: state.health)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if state.busy {
                ProgressView()
                    .controlSize(.small)
            } else {
                Toggle("", isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(state.config.profiles.isEmpty && !state.status.isOn && !isExternal)
            }
        }
        .padding(12)
        .glassCard(prominent: true)
    }

    private var isExternal: Bool {
        if case .external = state.status { return true }
        return false
    }

    private var title: String {
        switch state.status {
        case .on(let profile): return "已开启 · \(profile.name)"
        case .external: return "系统代理由其他程序设置"
        case .off(let next): return next == nil ? "还没有代理配置" : "代理已关闭"
        }
    }

    private var subtitle: String {
        switch state.status {
        case .on(let profile):
            if state.health == .down { return "代理服务器连不上" }
            if profile.engine, let node = engine.effectiveNode {
                return "节点 \(node)" + (engine.effectiveNodeInfo?.delayText.isEmpty == false ? " · \(engine.effectiveNodeInfo!.delayText)" : "")
            }
            if let result = state.testResults[profile.id], result.ok, let latency = result.latencyMs {
                return "\(profile.summary) · \(latency) ms"
            }
            return profile.summary
        case .external(let description):
            return description
        case .off(let next):
            if let next { return "下次开启 \(next.name) · \(next.summary)" }
            return "在设置里添加一个代理配置"
        }
    }

    private var externalCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("别的程序改了系统代理，可以保存成配置以后一键切换")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button("保存") { state.saveExternalAsProfile() }
                .controlSize(.small)
        }
        .padding(10)
        .glassCard()
    }

    // MARK: - 节点

    private var nodeCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 14))
                    .foregroundStyle(engine.isRunning ? Color.accentColor : Color.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nodeTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Text(nodeSubtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onTapGesture { toggleNodes() }
                Spacer(minLength: 4)
                Picker("", selection: Binding(get: { state.config.engine.mode }, set: { engine.setMode($0) })) {
                    Text("全局").tag(EngineMode.global)
                    Text("规则").tag(EngineMode.rule)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 84)
                .help("全局：全部走节点；规则：按分流规则")
                Button {
                    toggleNodes()
                } label: {
                    HStack(spacing: 2) {
                        Text(showNodes ? "收起" : "节点列表")
                            .font(.system(size: 10))
                        Image(systemName: showNodes ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(showNodes ? "收起节点列表" : "展开节点列表")
            }
            if showNodes {
                nodeList
            }
        }
        .padding(10)
        .glassCard()
    }

    private func toggleNodes() {
        showNodes.toggle()
        actions.layoutChanged()
    }

    private var nodeTitle: String {
        switch engine.status {
        case .off: return state.config.engine.enabled ? "内置代理未运行" : "内置代理已停用"
        case .starting: return "内核正在启动…"
        case .failed: return "内核出错"
        case .running:
            if engine.currentSelection == Engine.autoGroup {
                return "自动选择 · \(engine.autoNode ?? "…")"
            }
            return engine.currentSelection ?? "未选择节点"
        }
    }

    private var nodeSubtitle: String {
        if case .failed(let message) = engine.status { return message }
        var parts: [String] = []
        if let node = engine.effectiveNodeInfo {
            parts.append(node.type.uppercased())
            if !node.delayText.isEmpty { parts.append(node.delayText) }
        }
        if let exit = engine.exitInfo, engine.isRunning {
            parts.append("出口 \(exit.short)")
        }
        parts.append("\(engine.nodes.count) 个节点 · \(state.config.engine.mode == .global ? "全局" : "规则分流")")
        return parts.joined(separator: " · ")
    }

    // MARK: - 策略组

    /// 每个自定义策略组一行：名字、现在用的成员；手动选择的组点开菜单换成员。
    private var groupsCard: some View {
        VStack(spacing: 0) {
            ForEach(engine.groupStates) { group in
                HStack(spacing: 8) {
                    Image(systemName: group.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(group.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if group.kind == .select {
                        Menu {
                            ForEach(group.members, id: \.self) { member in
                                Button {
                                    Task { await engine.select(group: group.name, member: member) }
                                } label: {
                                    if member == group.now {
                                        Label(memberTitle(member), systemImage: "checkmark")
                                    } else {
                                        Text(memberTitle(member))
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 3) {
                                Text(memberTitle(group.now ?? "", withDelay: false))
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .semibold))
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("给「\(group.name)」选节点")
                    } else {
                        Text(memberTitle(group.now ?? "", withDelay: true))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help("\(group.kind.title)：\(group.kind.detail)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
            }
        }
        .padding(6)
        .glassCard()
    }

    /// 成员的显示名：节点带延迟，DIRECT 写成直连。
    private func memberTitle(_ member: String, withDelay: Bool = true) -> String {
        if member.isEmpty { return "…" }
        if member == "DIRECT" { return "直连" }
        if withDelay, let node = engine.nodes.first(where: { $0.name == member }), !node.delayText.isEmpty {
            return "\(member) · \(node.delayText)"
        }
        return member
    }

    private var filteredNodes: [Engine.Node] {
        let filter = nodeFilter.trimmingCharacters(in: .whitespaces)
        if filter.isEmpty { return engine.nodes }
        return engine.nodes.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    private var nodeList: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                TextField("搜索节点", text: $nodeFilter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onChange(of: nodeFilter) { _, _ in actions.layoutChanged() }
                Button {
                    Task { await engine.testAll() }
                } label: {
                    if engine.testing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "speedometer")
                    }
                }
                .buttonStyle(IconButtonStyle())
                .help("测试全部节点的延迟")
                .disabled(engine.testing || !engine.isRunning)
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    nodeRow(name: Engine.autoGroup, type: "自动", delay: nil, subtitle: engine.autoNode.map { "当前 \($0)" } ?? "延迟最低的节点", selected: engine.currentSelection == Engine.autoGroup) {
                        Task { await engine.select(nil) }
                    }
                    ForEach(filteredNodes) { node in
                        nodeRow(name: node.name, type: node.type, delay: node.delay, subtitle: node.subscription, selected: engine.currentSelection == node.name) {
                            Task { await engine.select(node.name) }
                        }
                    }
                }
            }
            .frame(height: min(220, CGFloat(filteredNodes.count + 1) * 36))
        }
        .padding(.top, 4)
    }

    private func nodeRow(name: String, type: String, delay: Int?, subtitle: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            state.selectEngineProfile()
            action()
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.system(size: 11, weight: selected ? .semibold : .regular))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(type.uppercased())
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                if let delay {
                    Text(delay > 0 ? "\(delay) ms" : "超时")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(delayColor(delay))
                }
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
        .disabled(!engine.isRunning)
    }

    private func delayColor(_ delay: Int) -> Color {
        if delay <= 0 { return .red }
        if delay < 300 { return .green }
        if delay < 800 { return .orange }
        return .red
    }

    // MARK: - 局域网共享

    private var shareCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.router")
                .font(.system(size: 14))
                .foregroundStyle(shareColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(shareTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(shareSubtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
            .onTapGesture { actions.openSettings(.share) }
            .help("PS5、Switch 等设备把这台 Mac 当代理服务器，享受和本机一样的网络。点击查看设置")
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { state.share.enabled }, set: { state.setShareEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .help("关闭局域网共享")
        }
        .padding(10)
        .glassCard()
    }

    private var shareColor: Color {
        switch engine.shareStatus {
        case .listening: return .accentColor
        case .failed: return .red
        case .off, .starting: return .secondary
        }
    }

    private var shareTitle: String {
        if let address = state.lanAddress {
            return "局域网共享 · \(address.ip):\(String(state.share.port))"
        }
        return "局域网共享 · 没有连上局域网"
    }

    private var shareSubtitle: String {
        switch engine.shareStatus {
        case .off: return "未运行"
        case .starting: return "正在启动…"
        case .failed(let message): return message
        case .listening: return state.shareUpstream.summary
        }
    }

    // MARK: - 配置列表

    private var profileList: some View {
        VStack(spacing: 2) {
            ForEach(state.config.profiles) { profile in
                Button {
                    state.use(profile)
                } label: {
                    ProfileRow(profile: profile, active: isActive(profile), result: state.testResults[profile.id])
                }
                .buttonStyle(HoverRowStyle())
            }
        }
        .padding(6)
        .glassCard()
    }

    private func isActive(_ profile: Profile) -> Bool {
        if case .on(let current) = state.status { return current.id == profile.id }
        return false
    }

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "network.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text("还没有代理配置")
                .font(.system(size: 12, weight: .medium))
            Button("添加代理配置") { actions.openSettings(.profiles) }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .glassCard()
    }

    private func errorCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .foregroundStyle(.red)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(3)
            Spacer(minLength: 0)
            Button("诊断") { actions.openSettings(.diagnose) }
                .controlSize(.small)
                .help("把链路走一遍，找出打不开的原因")
            Button {
                state.lastError = nil
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .glassCard()
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                testing = true
                Task { @MainActor in
                    await state.testAll()
                    testing = false
                }
            } label: {
                if testing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "speedometer")
                }
            }
            .buttonStyle(IconButtonStyle())
            .help("测试全部配置的连接和延迟")
            .disabled(state.config.profiles.isEmpty || testing)

            if case .on(let profile) = state.status, profile.kind != .pac {
                Menu {
                    Button("zsh / bash（终端、iTerm）") { copy(TerminalCommands.export(proxyURL: profile.proxyURL, noProxy: profile.noProxy)) }
                    Button("fish") { copy(TerminalCommands.fish(proxyURL: profile.proxyURL, noProxy: profile.noProxy)) }
                } label: {
                    Image(systemName: copied ? "checkmark" : "terminal")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.primary.opacity(0.05)))
                .help("复制在当前终端里使用代理的命令")
            }

            Spacer()

            if let hotkey = state.config.toggleHotkey {
                Text("\(hotkey.display) 开关")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            Button {
                actions.openSettings(.diagnose)
            } label: {
                Image(systemName: "stethoscope")
            }
            .buttonStyle(IconButtonStyle())
            .help("网址诊断：某个网站打不开时查原因")

            Button {
                actions.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help("设置")

            Button {
                actions.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help("退出 ProxySwitch")
        }
        .padding(.horizontal, 2)
    }

    private func copy(_ text: String) {
        TerminalCommands.copy(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}

/// 状态卡片左侧的圆形图标。
struct StatusBadge: View {
    var status: ProxyStatus
    var health: Health

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
            Circle()
                .strokeBorder(color.opacity(0.5), lineWidth: 1)
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: 40, height: 40)
    }

    private var color: Color {
        switch status {
        case .on(let profile): return health == .down ? .red : Color(hex: profile.color)
        case .external: return .orange
        case .off: return .secondary
        }
    }

    private var symbol: String {
        switch status {
        case .on: return health == .down ? "exclamationmark.triangle.fill" : "checkmark.shield.fill"
        case .external: return "questionmark.circle.fill"
        case .off: return "power"
        }
    }
}

struct ProfileRow: View {
    var profile: Profile
    var active: Bool
    var result: TestResult?

    var body: some View {
        HStack(spacing: 10) {
            ColorDot(hex: profile.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .lineLimit(1)
                Text(profile.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if let result {
                Text(result.latencyText)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(result.ok ? Color.green : Color.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((result.ok ? Color.green : Color.red).opacity(0.12)))
            }
            Image(systemName: active ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(active ? Color(hex: profile.color) : Color.secondary.opacity(0.5))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// 面板内容的实际尺寸，窗口按它调整。
struct PanelSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
