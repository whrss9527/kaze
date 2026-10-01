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

/// 菜单栏面板：代理引擎的状态和开关、节点卡片、策略组、局域网共享、快捷操作。
struct PanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var core: CoreDownload
    let actions: PanelActions
    @State private var testing = false
    @State private var copied = false
    @AppStorage("panel.showNodes") private var showNodes = true
    @State private var nodeFilter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            statusCard
            if !core.isReady {
                coreCard
            }
            if state.config.engine.wantsCore {
                nodeCard
                if engine.isRunning, !engine.groupStates.isEmpty {
                    groupsCard
                }
            }
            if state.share.enabled {
                shareCard
            }
            if !state.config.engine.wantsCore {
                emptyCard
            }
            if let error = state.lastError ?? engine.lastError {
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
        Binding(get: { state.config.engine.enabled }, set: { engine.setEnabled($0) })
    }

    private var statusCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(statusColor.opacity(0.18))
                Circle().strokeBorder(statusColor.opacity(0.5), lineWidth: 1)
                Image(systemName: engine.isRunning ? "bolt.horizontal.circle.fill" : "power")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(statusColor)
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("代理引擎 · %@", engine.statusTitle))
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .help(L("启用或停用代理引擎"))
        }
        .padding(12)
        .glassCard(prominent: true)
    }

    private var statusColor: Color {
        switch engine.status {
        case .running: return .accentColor
        case .failed: return .red
        case .starting: return .orange
        case .off: return .secondary
        }
    }

    private var subtitle: String {
        let port = L("本机端口 127.0.0.1:%@", String(state.config.engine.mixedPort))
        if case .on(let profile) = state.status, profile.engine {
            return port + L("（Proxi 正在用）")
        }
        return port + L("。在 Proxi 里开启「代理引擎」配置来使用")
    }

    private var coreCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.orange)
            Text(coreText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            Button(L("内核‖页面")) { actions.openSettings(.core) }
                .controlSize(.small)
        }
        .padding(10)
        .glassCard()
    }

    private var coreText: String {
        switch core.phase {
        case .downloading(let title, let fraction):
            return L("正在下载%@…", title) + (fraction.map { " \(Int($0 * 100))%" } ?? "")
        case .failed(let message): return message
        case .missing: return L("还没有下载内核")
        case .unknown, .verifying: return L("正在校验内核…")
        case .ready: return ""
        }
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
                    Text(L("全局")).tag(EngineMode.global)
                    Text(L("规则")).tag(EngineMode.rule)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: AppLanguage.width(84, english: 104))
                .help(L("全局：全部走节点；规则：按分流规则"))
                Button {
                    toggleNodes()
                } label: {
                    HStack(spacing: 2) {
                        Text(showNodes ? L("收起") : L("节点列表"))
                            .font(.system(size: 10))
                        Image(systemName: showNodes ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help(showNodes ? L("收起节点列表") : L("展开节点列表"))
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
        case .off: return state.config.engine.enabled ? L("代理引擎未运行") : L("代理引擎已停用")
        case .starting: return L("内核正在启动…")
        case .failed: return L("内核出错")
        case .running:
            if engine.currentSelection == Engine.autoGroup {
                return L("自动选择 · %@", engine.autoNode ?? L("…"))
            }
            return engine.currentSelection ?? L("未选择节点")
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
            parts.append(L("出口 %@", exit.short))
        }
        parts.append(L("%@ 个节点 · %@", engine.nodes.count, state.config.engine.mode == .global ? L("全局") : L("规则分流")))
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
                    Text(CoreConfigBuilder.displayName(group.name))
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
                        .help(L("给「%@」选节点", CoreConfigBuilder.displayName(group.name)))
                    } else {
                        Text(memberTitle(group.now ?? "", withDelay: true))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .help(L("%@：%@", group.kind.title, group.kind.detail))
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
        if member.isEmpty { return L("…") }
        if member == "DIRECT" { return L("直连") }
        if withDelay, let node = engine.nodes.first(where: { $0.name == member }), !node.delayText.isEmpty {
            return "\(member) · \(node.delayText)"
        }
        return CoreConfigBuilder.displayName(member)
    }

    /// 按设置里的排序（收藏的在最前面），再按搜索筛选。
    private var filteredNodes: [Engine.Node] {
        var query = NodeQuery(sort: state.config.engine.nodeSort)
        query.text = nodeFilter
        return query.apply(engine.nodes, favorites: state.config.engine.favoriteNodes)
    }

    private var nodeList: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                TextField(L("搜索节点"), text: $nodeFilter)
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
                .help(L("测试全部节点的延迟"))
                .disabled(engine.testing || !engine.isRunning)
            }
            ScrollView {
                LazyVStack(spacing: 1) {
                    nodeRow(name: CoreConfigBuilder.displayName(Engine.autoGroup), type: L("自动"), delay: nil, subtitle: engine.autoNode.map { L("当前 %@", $0) } ?? L("延迟最低的节点"), selected: engine.currentSelection == Engine.autoGroup) {
                        Task { await engine.select(nil) }
                    }
                    ForEach(filteredNodes) { node in
                        let favorite = state.config.engine.favoriteNodes.contains(node.name)
                        nodeRow(name: favorite ? "★ " + node.name : node.name, type: node.typeTitle, delay: node.delay, subtitle: node.subscription, selected: engine.currentSelection == node.name) {
                            Task { await engine.select(node.name) }
                        }
                        .contextMenu {
                            Button(favorite ? L("取消收藏") : L("收藏")) { engine.toggleFavorite(node.name) }
                            Button(L("测速")) { Task { await engine.test(node: node.name) } }
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
                    Text(delay > 0 ? "\(delay) ms" : L("超时"))
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
            .help(L("PS5、Switch 等设备把这台 Mac 当代理服务器，享受和本机一样的网络。点击查看设置"))
            Spacer(minLength: 4)
            Toggle("", isOn: Binding(get: { state.share.enabled }, set: { state.setShareEnabled($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.mini)
                .help(L("关闭局域网共享"))
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
            return L("局域网共享 · %@:%@", address.ip, String(state.share.port))
        }
        return L("局域网共享 · 没有连上局域网")
    }

    private var shareSubtitle: String {
        switch engine.shareStatus {
        case .off: return L("未运行")
        case .starting: return L("正在启动…")
        case .failed(let message): return message
        case .listening: return state.shareUpstream.summary
        }
    }

    // MARK: - 还没有节点

    private var emptyCard: some View {
        VStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
            Text(L("还没有订阅或节点"))
                .font(.system(size: 12, weight: .medium))
            Button(L("添加订阅或节点")) { actions.openSettings(.nodes) }
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
            Button(L("诊断")) { actions.openSettings(.diagnose) }
                .controlSize(.small)
                .help(L("把链路走一遍，找出打不开的原因"))
            Button {
                state.lastError = nil
                engine.lastError = nil
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
                Task { await engine.testAll() }
            } label: {
                if engine.testing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "speedometer")
                }
            }
            .buttonStyle(IconButtonStyle())
            .help(L("测试全部节点的延迟"))
            .disabled(engine.testing || !engine.isRunning)

            Spacer()

            Button {
                actions.openSettings(.diagnose)
            } label: {
                Image(systemName: "stethoscope")
            }
            .buttonStyle(IconButtonStyle())
            .help(L("网址诊断：某个网站打不开时查原因"))

            Button {
                actions.openSettings(nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(IconButtonStyle())
            .help(L("设置"))

            Button {
                actions.quit()
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(IconButtonStyle())
            .help(L("退出代理引擎"))
        }
        .padding(.horizontal, 2)
    }
}

/// 面板内容的实际尺寸，窗口按它调整。
struct PanelSizeKey: PreferenceKey {
    static let defaultValue = CGSize.zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}
