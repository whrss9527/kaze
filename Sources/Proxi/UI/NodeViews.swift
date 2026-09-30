import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 节点列表

/// 节点列表：按订阅、地区、协议筛选，只看能用的或收藏的，按订阅顺序、名字或延迟排序；
/// 筛好的节点可以一起测速，也可以按现在的条件直接建一个策略组。
struct NodeListSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @State private var query = NodeQuery()
    @State private var showGroupSheet = false
    @State private var testingFiltered = false

    private var favorites: [String] { state.config.engine.favoriteNodes }
    private var results: [Engine.Node] { query.apply(engine.nodes, favorites: favorites) }

    var body: some View {
        Section(L("节点")) {
            if engine.nodes.isEmpty {
                Text(engine.isRunning ? L("订阅里没有解析出节点") : L("内核启动后这里会列出所有节点"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                filterBar
                summaryLine
                nodeRow(name: CoreConfigBuilder.displayName(Engine.autoGroup), subtitle: engine.autoNode.map { L("现在用的是 %@", $0) } ?? L("自动选延迟最低的节点"), type: L("自动"), delay: nil, favorite: false, selected: engine.currentSelection == Engine.autoGroup, node: nil) {
                    Task { await engine.select(nil) }
                }
                let list = results
                ForEach(list.prefix(300)) { node in
                    nodeRow(name: node.name, subtitle: subtitle(node), type: node.typeTitle, delay: node.delay, favorite: favorites.contains(node.name), selected: engine.currentSelection == node.name, node: node) {
                        Task { await engine.select(node.name) }
                    }
                }
                if list.count > 300 {
                    Text(L("还有 %@ 个没有列出，加个条件缩小范围。", list.count - 300))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(L("点一行就切换到那个节点；点星星收藏，收藏的排在最前面（面板和菜单里也是）。排序会记住，筛选条件只在这一页有效。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { query.sort = state.config.engine.nodeSort }
        .onChange(of: query.sort) { _, sort in
            if sort != state.config.engine.nodeSort {
                engine.setNodeSort(sort)
            }
        }
        .sheet(isPresented: $showGroupSheet) {
            GroupFromQuerySheet(state: state, engine: engine, query: query)
        }
    }

    private var sources: [DialerCandidate] {
        var result = state.config.engine.subscriptions.filter(\.enabled).map { DialerCandidate(value: $0.id.uuidString, title: $0.name) }
        if !state.config.engine.activeManualNodes.isEmpty {
            result.append(DialerCandidate(value: ManualNode.sourceID.uuidString, title: L("手动节点")))
        }
        return result
    }

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("", text: $query.text, prompt: Text(L("搜索节点")))
                    .labelsHidden()
                Picker("", selection: $query.sort) {
                    ForEach(NodeSort.allCases) { sort in
                        Text(sort.title).tag(sort)
                    }
                }
                .labelsHidden()
                .frame(width: AppLanguage.width(100, english: 150))
                Button(engine.testing || testingFiltered ? L("正在测速…") : (query.isFiltering ? L("测速这些") : L("测速全部"))) { test() }
                    .disabled(engine.testing || testingFiltered || !engine.isRunning)
            }
            // 窗口窄的时候，两个勾选框换到下一行。
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    conditionPickers
                    conditionToggles
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        conditionPickers
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 12) {
                        conditionToggles
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var conditionPickers: some View {
        Picker("", selection: $query.source) {
            Text(L("全部来源")).tag(UUID?.none)
            ForEach(sources) { source in
                Text(source.title).tag(UUID(uuidString: source.value))
            }
        }
        .labelsHidden()
        .frame(width: 130)
        Picker("", selection: $query.region) {
            Text(L("全部地区")).tag(String?.none)
            ForEach(NodeQuery.regions(in: engine.nodes)) { item in
                Text("\(item.region?.title ?? L("其他地区")) \(item.count)").tag(Optional(item.id))
            }
        }
        .labelsHidden()
        .frame(width: 130)
        Picker("", selection: $query.type) {
            Text(L("全部协议")).tag(String?.none)
            ForEach(NodeQuery.types(in: engine.nodes)) { item in
                Text("\(NodeQuery.typeTitle(item.type)) \(item.count)").tag(Optional(item.type))
            }
        }
        .labelsHidden()
        .frame(width: 120)
    }

    @ViewBuilder
    private var conditionToggles: some View {
        Toggle(L("只看能用的"), isOn: $query.onlyAvailable)
            .toggleStyle(.checkbox)
        Toggle(L("只看收藏"), isOn: $query.onlyFavorites)
            .toggleStyle(.checkbox)
    }

    /// 数量和清除、建组按钮；放不下时按钮换到下一行。
    private var summaryLine: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                summaryText
                Spacer(minLength: 8)
                filterActions
            }
            VStack(alignment: .leading, spacing: 6) {
                summaryText
                HStack(spacing: 8) {
                    filterActions
                }
            }
        }
    }

    private var summaryText: some View {
        HStack(spacing: 4) {
            Text(query.isFiltering ? L("筛出 %@ / %@ 个节点", results.count, engine.nodes.count) : L("共 %@ 个节点", engine.nodes.count))
                .font(.caption)
                .foregroundStyle(.secondary)
            if query.onlyAvailable && !engine.nodes.contains(where: { $0.delay != nil }) {
                Text(L("（还没测过速，先测一下）"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var filterActions: some View {
        if query.isFiltering {
            Button(L("清除条件")) { query.reset() }
                .controlSize(.small)
            Button(L("按这些条件建策略组…")) { showGroupSheet = true }
                .controlSize(.small)
                .disabled(results.isEmpty)
        }
    }

    private func subtitle(_ node: Engine.Node) -> String {
        var parts = [node.subscription]
        if let region = node.region { parts.append(region.title) }
        return parts.joined(separator: " · ")
    }

    private func test() {
        guard query.isFiltering else {
            Task { await engine.testAll() }
            return
        }
        let names = results.map(\.name)
        testingFiltered = true
        Task { @MainActor in
            await withTaskGroup(of: Void.self) { group in
                for name in names.prefix(100) {
                    group.addTask { @MainActor in _ = await engine.delay(of: name) }
                }
            }
            testingFiltered = false
        }
    }

    private func nodeRow(name: String, subtitle: String, type: String, delay: Int?, favorite: Bool, selected: Bool, node: Engine.Node?, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Button {
                state.selectEngineProfile()
                action()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name)
                            .font(.system(size: 12, weight: selected ? .semibold : .regular))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(type)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Text(delay.map { $0 > 0 ? "\($0) ms" : L("超时") } ?? "")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(delayColor(delay))
                        .frame(width: 60, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!engine.isRunning)
            if let node {
                Button {
                    engine.toggleFavorite(node.name)
                } label: {
                    Image(systemName: favorite ? "star.fill" : "star")
                        .foregroundStyle(favorite ? Color.yellow : Color.secondary.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(favorite ? L("取消收藏") : L("收藏"))
            } else {
                Image(systemName: "star")
                    .opacity(0)
            }
        }
        .contextMenu {
            if let node {
                Button(favorite ? L("取消收藏") : L("收藏")) { engine.toggleFavorite(node.name) }
                Button(L("测速")) { Task { await engine.test(node: node.name) } }
                Button(L("检测服务（ChatGPT、Netflix……）")) {
                    Task { await engine.checkServices(node: node.name) }
                    SettingsWindowController.shared.show(page: .connections)
                }
                Button(L("复制名字")) { TerminalCommands.copy(node.name) }
            }
        }
    }

    private func delayColor(_ delay: Int?) -> Color {
        guard let delay else { return .secondary }
        if delay <= 0 { return .red }
        if delay < 300 { return .green }
        if delay < 800 { return .orange }
        return .red
    }
}

/// 按节点列表现在的条件建策略组：来源、地区、关键词、收藏变成组的筛选。
struct GroupFromQuerySheet: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    var query: NodeQuery
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: PolicyGroupKind = .urlTest
    @State private var problem: String?

    private var draft: PolicyGroup {
        query.makeGroup(name: name, kind: kind, favorites: state.config.engine.favoriteNodes)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("按条件建策略组"))
                .font(.system(size: 16, weight: .semibold))
            HStack {
                TextField("", text: $name, prompt: Text(L("组名")))
                    .frame(width: 180)
                Picker("", selection: $kind) {
                    ForEach(PolicyGroupKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
            Text(kind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            let group = draft
            let matched = matchedNodes(group)
            VStack(alignment: .leading, spacing: 4) {
                if let source = group.sources.first {
                    Text(L("只用来源：%@", sourceName(source)))
                        .font(.caption)
                }
                if !group.filter.isEmpty {
                    Text(L("节点名筛选：%@", group.filter))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                Text(L("现在能匹配到 %@ 个节点：%@%@", matched.count, matched.prefix(5).joined(separator: L("、")), matched.count > 5 ? L("…") : ""))
                    .font(.caption)
                ForEach(query.groupNotes, id: \.self) { note in
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(L("建好后在「分流规则」里把某类流量指到这个组；以后订阅里新出现的符合条件的节点会自动进来。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("建组")) {
                    problem = engine.addGroup(draft)
                    if problem == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            let source = query.source.map(sourceName)
            name = query.suggestedGroupName(sourceName: source)
        }
    }

    private func sourceName(_ id: UUID) -> String {
        if id == ManualNode.sourceID { return L("手动节点") }
        return state.config.engine.subscriptions.first { $0.id == id }?.name ?? L("已删除的订阅")
    }

    private func matchedNodes(_ group: PolicyGroup) -> [String] {
        let candidates = engine.nodes.filter { group.sources.isEmpty || group.sources.contains($0.source ?? UUID()) }
        return group.matches(candidates.map(\.name))
    }
}

// MARK: - 手动节点

/// 手动节点：粘贴分享链接、扫二维码，交给内核解析；可以设前置代理。
struct ManualNodesSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @State private var text = ""
    @State private var problem: String?
    @State private var message: String?
    @State private var scanning = false

    private var nodes: [ManualNode] { state.config.engine.manualNodes }

    var body: some View {
        Section(L("手动节点")) {
            if nodes.isEmpty {
                Text(L("没有订阅也能用：把 ss://、vmess://、vless://、trojan://、hysteria2://、tuic:// 这样的节点链接粘到下面，或者扫一下二维码。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(nodes) { node in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { node.enabled }, set: { engine.setManualNode(node.id, enabled: $0) }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(node.name)
                            .font(.system(size: 12, weight: .medium))
                        Text(node.server)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(NodeQuery.typeTitle(node.scheme))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Menu {
                        Button(L("复制链接")) { TerminalCommands.copy(node.link) }
                        Divider()
                        Button(L("删除"), role: .destructive) { engine.removeManualNode(node.id) }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
            if let count = engine.manualNodeCount, count < state.config.engine.activeManualNodes.count {
                Label(L("内核只认出了 %@ 个，有的链接可能写错了（内核日志里有原因）", count), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                TextField("", text: $text, prompt: Text(L("粘贴节点链接，一行一条，或者整段 base64")), axis: .vertical)
                    .lineLimit(1...4)
                    .labelsHidden()
                Button(L("添加")) { add(text) }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 8) {
                Button(L("从剪贴板添加")) { fromPasteboard() }
                Button(scanning ? L("正在扫描…") : L("扫描屏幕上的二维码")) { scanScreen() }
                    .disabled(scanning)
                Button(L("选择二维码图片…")) { chooseImage() }
                Spacer()
            }
            .controlSize(.small)
            if !nodes.isEmpty {
                DialerPicker(title: L("前置代理"), selection: Binding(get: { state.config.engine.manualDialer }, set: { value in
                    problem = engine.setManualDialer(value)
                }), candidates: engine.dialerCandidates(for: ManualNode.providerName), profiles: state.config.profiles)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(L("手动节点和订阅的节点一起出现在节点列表和策略组里。扫描屏幕要「屏幕录制」权限，第一次会弹出系统询问；二维码里是订阅地址时会加成订阅。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add(_ content: String) {
        message = nil
        // 二维码或粘贴的是订阅地址：加成订阅。
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isNewline), NodeLink.extract(trimmed).isEmpty, Subscription.validate(url: trimmed) == nil, trimmed.lowercased().hasPrefix("http") {
            problem = engine.addSubscription(name: "", url: trimmed)
            if problem == nil {
                message = L("这是订阅地址，已经加到订阅里")
                text = ""
                state.selectEngineProfile()
            }
            return
        }
        let result = engine.addManualNodes(from: content)
        problem = result.problem
        if result.added > 0 {
            message = L("加了 %@ 个节点", result.added)
            text = ""
            state.selectEngineProfile()
        }
    }

    private func fromPasteboard() {
        if let string = NSPasteboard.general.string(forType: .string), !string.isEmpty {
            add(string)
            return
        }
        let codes = QRScanner.fromPasteboard()
        if codes.isEmpty {
            problem = L("剪贴板里没有节点链接，也没有二维码图片")
        } else {
            add(codes.joined(separator: "\n"))
        }
    }

    private func scanScreen() {
        scanning = true
        problem = nil
        message = nil
        Task { @MainActor in
            do {
                let codes = try await QRScanner.scanScreens()
                if codes.isEmpty {
                    problem = L("屏幕上没有找到二维码：把二维码放大一点、不要被挡住再试")
                } else {
                    add(codes.joined(separator: "\n"))
                }
            } catch {
                problem = L("扫描屏幕失败：%@。在「系统设置 → 隐私与安全性 → 屏幕录制」里允许 Proxi 后再试。", error.localizedDescription)
            }
            scanning = false
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.message = L("选择节点二维码的图片")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let codes = QRScanner.fromFile(url)
        if codes.isEmpty {
            problem = L("图片里没有认出二维码")
        } else {
            add(codes.joined(separator: "\n"))
        }
    }
}

/// 前置代理的选择：不用、配置列表里的代理、策略组、别的来源的节点。
struct DialerPicker: View {
    var title: String
    @Binding var selection: String?
    var candidates: [DialerCandidate]
    var profiles: [Profile]

    var body: some View {
        Picker(title, selection: $selection) {
            Text(L("不用（直接连节点）")).tag(String?.none)
            ForEach(candidates) { candidate in
                Text(candidate.title).tag(Optional(candidate.value))
            }
            if let current = selection, !candidates.contains(where: { $0.value == current }) {
                Text(DialerReference.title(current, profiles: profiles)).tag(Optional(current))
            }
        }
    }
}

// MARK: - 订阅设置

/// 一条订阅的设置：名字、地址、筛选、排除、名字前缀、前置代理。
struct SubscriptionEditor: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    var subscription: Subscription
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Subscription
    @State private var problem: String?

    init(state: AppState, engine: Engine, subscription: Subscription) {
        self.state = state
        self.engine = engine
        self.subscription = subscription
        _draft = State(initialValue: subscription)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("订阅设置"))
                .font(.system(size: 16, weight: .semibold))
            Form {
                TextField(L("名字"), text: $draft.name)
                TextField(L("地址"), text: $draft.url)
                TextField(L("只保留"), text: $draft.filter, prompt: Text(L("节点名的正则，比如 港|日|新；空为全部")))
                TextField(L("去掉"), text: $draft.exclude, prompt: Text(L("比如 过期|剩余|官网")))
                TextField(L("名字前缀"), text: $draft.prefix, prompt: Text(L("比如「甲 」，几个机场的节点同名时好区分")))
                DialerPicker(title: L("前置代理"), selection: $draft.dialer, candidates: engine.dialerCandidates(for: subscription.providerName), profiles: state.config.profiles)
            }
            .formStyle(.grouped)
            Text(preview)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("筛选和排除按机场给的原始名字匹配（不区分大小写），加前缀之前。前置代理：这个订阅的节点先经它再连出去（链式代理），比如先经公司的代理，或者先经另一个机场的节点；不能选含这个订阅自己节点的组。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) {
                    problem = engine.saveSubscription(draft)
                    if problem == nil { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// 现在这条订阅的节点里，按新的筛选会留下多少（内核已经按旧的筛过了，只能预览在它们之中）。
    private var preview: String {
        if let issue = Subscription.validateOptions(filter: draft.filter, exclude: draft.exclude, prefix: draft.prefix) { return issue }
        let names = engine.nodes.filter { $0.source == subscription.id }.map { name -> String in
            subscription.prefix.isEmpty ? name.name : String(name.name.dropFirst(subscription.prefix.count))
        }
        guard !names.isEmpty else { return L("保存后内核重新加载，节点列表里就能看到结果。") }
        var group = PolicyGroup(name: "x", filter: draft.filter)
        group.exclude = draft.exclude
        let kept = group.matches(names)
        return L("现在的 %@ 个节点里会留下 %@ 个（之前被筛掉的看不到，保存后以内核为准）。", names.count, kept.count)
    }
}

// MARK: - 策略组的高级选项

/// 策略组的高级选项：只用哪些订阅、排除、包含别的组、测速地址和间隔、容差、负载均衡方式。
struct GroupEditor: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    var group: PolicyGroup
    @Environment(\.dismiss) private var dismiss
    @State private var draft: PolicyGroup
    @State private var intervalText: String
    @State private var toleranceText: String
    @State private var problem: String?

    init(state: AppState, engine: Engine, group: PolicyGroup) {
        self.state = state
        self.engine = engine
        self.group = group
        _draft = State(initialValue: group)
        _intervalText = State(initialValue: group.interval == 0 ? "" : String(group.interval))
        _toleranceText = State(initialValue: group.tolerance == 0 ? "" : String(group.tolerance))
    }

    private var otherGroups: [String] {
        PolicyGroup.builtinMembers + state.config.engine.groups.filter { $0.id != group.id }.map(\.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("策略组「%@」", group.name))
                .font(.system(size: 16, weight: .semibold))
            Form {
                Section(L("成员")) {
                    TextField(L("节点名筛选"), text: $draft.filter, prompt: Text(L("正则，比如 港|HK；空为全部")))
                    TextField(L("排除"), text: $draft.exclude, prompt: Text(L("正则，比如 过期|0\\.1倍")))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("只用这些来源的节点（都不选就是全部）"))
                            .font(.system(size: 12))
                        ForEach(state.config.engine.subscriptions) { subscription in
                            Toggle(subscription.name, isOn: sourceBinding(subscription.id))
                                .toggleStyle(.checkbox)
                        }
                        if !state.config.engine.manualNodes.isEmpty {
                            Toggle(L("手动节点"), isOn: sourceBinding(ManualNode.sourceID))
                                .toggleStyle(.checkbox)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("也放进来的策略组"))
                            .font(.system(size: 12))
                        ForEach(otherGroups, id: \.self) { name in
                            Toggle(name, isOn: memberBinding(name))
                                .toggleStyle(.checkbox)
                        }
                    }
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if draft.kind != .select {
                    Section(L("测速")) {
                        TextField(L("测速地址"), text: $draft.testURL, prompt: Text(L("空为通用设置里的：%@", state.config.testURL)))
                        TextField(L("间隔（秒）"), text: $intervalText, prompt: Text(L("默认 %@", PolicyGroup.defaultInterval)))
                        if draft.kind == .urlTest {
                            TextField(L("容差（毫秒）"), text: $toleranceText, prompt: Text(L("默认 %@：比现在用的快这么多以上才换", PolicyGroup.defaultTolerance)))
                        }
                        if draft.kind == .loadBalance {
                            Picker(L("分配方式"), selection: $draft.strategy) {
                                ForEach(LoadBalanceStrategy.allCases) { strategy in
                                    Text(strategy.title).tag(strategy)
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 380)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button(L("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("保存")) { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    private func sourceBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { draft.sources.contains(id) }, set: { on in
            if on {
                if !draft.sources.contains(id) { draft.sources.append(id) }
            } else {
                draft.sources.removeAll { $0 == id }
            }
        })
    }

    private func memberBinding(_ name: String) -> Binding<Bool> {
        Binding(get: { draft.includeGroups.contains(name) }, set: { on in
            if on {
                if !draft.includeGroups.contains(name) { draft.includeGroups.append(name) }
            } else {
                draft.includeGroups.removeAll { $0 == name }
            }
        })
    }

    private var preview: String {
        if let issue = PolicyGroup.validateFilter(draft.filter) ?? PolicyGroup.validateFilter(draft.exclude) { return issue }
        let candidates = engine.nodes.filter { draft.sources.isEmpty || draft.sources.contains($0.source ?? UUID()) }
        let matched = draft.matches(candidates.map(\.name))
        var text = engine.nodes.isEmpty ? L("内核启动后能预览匹配到的节点") : L("匹配到 %@ 个节点", matched.count)
        if !draft.includeGroups.isEmpty {
            text += L("，另外包含 %@", draft.includeGroups.joined(separator: L("、")))
        }
        return text
    }

    private func save() {
        var updated = draft
        updated.interval = Int(intervalText.trimmingCharacters(in: .whitespaces)) ?? 0
        updated.tolerance = Int(toleranceText.trimmingCharacters(in: .whitespaces)) ?? 0
        problem = engine.saveGroup(updated)
        if problem == nil { dismiss() }
    }
}
