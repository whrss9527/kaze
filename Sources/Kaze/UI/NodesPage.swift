import AppKit
import SwiftUI

/// 节点与订阅页：订阅地址、节点列表、策略组、代理模式、端口、内核状态和日志。
struct NodesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var navigation: SettingsNavigation
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addProblem: String?
    @State private var mixedPortText = ""
    @State private var apiPortText = ""
    @State private var showLog = false
    @State private var logText = ""
    @State private var editingSubscription: Subscription?
    @State private var editingGroup: PolicyGroup?
    @State private var importing = false
    @State private var newGroupName = ""
    @State private var newGroupKind: PolicyGroupKind = .select
    @State private var newGroupFilter = ""
    @State private var groupProblem: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "节点与订阅", subtitle: "填一个机场的订阅地址，节点就会出现在面板里；策略组给某类流量单独选节点")
            Form {
                coreSection
                subscriptionsSection
                ManualNodesSection(state: state, engine: engine)
                NodeListSection(state: state, engine: engine)
                groupsSection
                modeSection
                portsSection
                if showLog {
                    logSection
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            mixedPortText = String(state.config.engine.mixedPort)
            apiPortText = String(state.config.engine.apiPort)
        }
        .sheet(item: $editingSubscription) { subscription in
            SubscriptionEditor(state: state, engine: engine, subscription: subscription)
        }
        .sheet(item: $editingGroup) { group in
            GroupEditor(state: state, engine: engine, group: group)
        }
        .sheet(isPresented: $importing) {
            ImportSheet(state: state, initial: nil)
        }
    }

    // MARK: - 内核

    private var coreSection: some View {
        Section("内置代理") {
            Toggle("启用内置代理（内核 mihomo）", isOn: Binding(get: { state.config.engine.enabled }, set: { engine.setEnabled($0) }))
            LabeledContent("状态") { statusView }
            if !engine.coreAvailable {
                Label("这个 Kaze 里没有打包内核，请到发布页重新下载完整版本", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let profile = state.engineProfile {
                Text("配置列表里的「\(profile.name)」就是它：开启后系统代理指向 127.0.0.1:\(String(profile.port))，面板里可以选节点、切换模式。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("添加订阅后，配置列表里会多一条「节点代理」，开关它就是开关内置代理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("重启内核") {
                    Task { await engine.restartCore() }
                }
                .disabled(!state.config.engine.wantsCore)
                Button(showLog ? "隐藏日志" : "查看日志") { showLog.toggle() }
            }
            if let error = engine.lastError {
                Label(error, systemImage: "xmark.octagon")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch engine.status {
        case .off:
            Text(state.config.engine.wantsCore ? "未运行" : "还没有订阅")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在启动…")
                    .foregroundStyle(.secondary)
            }
        case .running(let version):
            Label("运行中 · mihomo \(version) · \(engine.nodes.count) 个节点", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 订阅

    private var subscriptionsSection: some View {
        Section("订阅") {
            if state.config.engine.subscriptions.isEmpty {
                Text("还没有订阅。把机场给你的订阅地址粘到下面，节点由内核下载和解析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.subscriptions) { subscription in
                SubscriptionRow(
                    subscription: subscription,
                    status: engine.subscriptionStatus[subscription.id],
                    updating: engine.updatingSubscription == subscription.id,
                    canUpdate: engine.isRunning,
                    options: optionsSummary(subscription),
                    onUpdate: { Task { await engine.updateSubscription(subscription.id) } },
                    onToggle: { engine.setSubscription(subscription.id, enabled: $0) },
                    onEdit: { editingSubscription = subscription },
                    onDelete: { engine.removeSubscription(subscription.id) }
                )
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("", text: $newName, prompt: Text("名称（可选）"))
                        .labelsHidden()
                        .frame(width: 140)
                    TextField("", text: $newURL, prompt: Text("订阅地址 https://…"))
                        .labelsHidden()
                        .onSubmit { add() }
                    Button("添加") { add() }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addProblem {
                    Text(addProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("导入配置…") { importing = true }
                    .controlSize(.small)
                    .help("导入 Clash / Surge / 小火箭 / Quantumult X 的配置或者 Kaze 的配置")
            }
            if !state.config.engine.subscriptions.isEmpty {
                Text("订阅每 \(String(state.config.engine.updateIntervalHours)) 小时自动更新一次。内核以 clash.meta 的身份下载，机场返回 Clash 配置或 base64 节点列表都可以。齿轮里能设筛选（只要某些地区、去掉「剩余流量」这类假节点）、名字前缀和前置代理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 订阅设了哪些选项，一句话。
    private func optionsSummary(_ subscription: Subscription) -> String {
        var parts: [String] = []
        if !subscription.filter.isEmpty { parts.append("只保留 \(subscription.filter)") }
        if !subscription.exclude.isEmpty { parts.append("去掉 \(subscription.exclude)") }
        if !subscription.prefix.isEmpty { parts.append("前缀「\(subscription.prefix)」") }
        if let dialer = subscription.dialer { parts.append("经 \(DialerReference.title(dialer, profiles: state.config.profiles))") }
        return parts.joined(separator: " · ")
    }

    private func add() {
        addProblem = engine.addSubscription(name: newName, url: newURL)
        if addProblem == nil {
            newName = ""
            newURL = ""
            state.selectEngineProfile()
        }
    }

    // MARK: - 策略组

    private var nodeNames: [String] { engine.nodes.map(\.name) }

    private var groupsSection: some View {
        Section("策略组") {
            if state.config.engine.groups.isEmpty {
                Text("给某类流量单独选节点：比如建一个「流媒体」组，分流规则里把 Netflix、YouTube 指到它，面板里就能单独给它选节点。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.groups) { group in
                PolicyGroupRow(
                    group: group,
                    nodeNames: nodeNames,
                    current: engine.groupStates.first { $0.name == group.name }?.now,
                    onSave: { engine.saveGroup($0) },
                    onEdit: { editingGroup = group },
                    onDelete: { engine.removeGroup(group.id) },
                    onMove: { engine.moveGroup(group.id, up: $0) }
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("", text: $newGroupName, prompt: Text("名字，比如 流媒体"))
                        .labelsHidden()
                        .frame(width: 140)
                    Picker("", selection: $newGroupKind) {
                        ForEach(PolicyGroupKind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    TextField("", text: $newGroupFilter, prompt: Text("节点名筛选（正则），比如 港|HK；空为全部节点"))
                        .labelsHidden()
                        .onSubmit { addGroup() }
                    Button("添加") { addGroup() }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text(newGroupPreview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let groupProblem {
                    Text(groupProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Text("手动选择的组多了「节点」「自动选择」和直连三个候选，默认跟随「节点」，所以刚建好时行为不变；自动选择、故障转移、负载均衡只在筛出来的节点里挑，一个都筛不到时内核退回直连。组名不能和节点、内核保留的名字重复。每个组的「高级」里能限定只用某几个订阅、排除节点、把别的组放进来、单独设测速地址和间隔；节点列表里也能按筛选条件直接建组。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var newGroupPreview: String {
        let draft = PolicyGroup(name: newGroupName, kind: newGroupKind, filter: newGroupFilter)
        if PolicyGroup.validateFilter(draft.filter) != nil { return "筛选不是正确的正则表达式" }
        let matched = draft.matches(nodeNames)
        var text = newGroupKind.detail + "。"
        if nodeNames.isEmpty {
            text += "内核启动后能预览筛选到的节点。"
        } else if draft.filter.isEmpty {
            text += "没有筛选：全部 \(nodeNames.count) 个节点。"
        } else {
            text += "筛选到 \(matched.count) 个节点" + (matched.isEmpty ? "。" : "：\(matched.prefix(4).joined(separator: "、"))\(matched.count > 4 ? "…" : "")")
        }
        return text
    }

    private func addGroup() {
        groupProblem = engine.addGroup(name: newGroupName, kind: newGroupKind, filter: newGroupFilter)
        if groupProblem == nil {
            newGroupName = ""
            newGroupFilter = ""
            newGroupKind = .select
        }
    }

    // MARK: - 模式

    private var modeSection: some View {
        Section("模式") {
            Picker("代理模式", selection: Binding(get: { state.config.engine.mode }, set: { engine.setMode($0) })) {
                ForEach(EngineMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Text(state.config.engine.mode == .global ? "全局代理：除局域网和自定义规则外的全部流量都走选中的节点。" : "规则分流：按规则集和自定义规则决定哪些走节点、哪些直连、哪些拦截。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("管理分流规则") { navigation.page = .rules }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - 端口

    private var portsValid: Bool {
        guard let mixed = Int(mixedPortText), let api = Int(apiPortText) else { return false }
        return (1024...65535).contains(mixed) && (1024...65535).contains(api) && mixed != api
    }

    private var portsChanged: Bool {
        Int(mixedPortText) != state.config.engine.mixedPort || Int(apiPortText) != state.config.engine.apiPort
    }

    private var portsSection: some View {
        Section("端口") {
            HStack {
                TextField("代理端口", text: $mixedPortText)
                    .onChange(of: mixedPortText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { mixedPortText = digits }
                    }
                TextField("API 端口", text: $apiPortText)
                    .onChange(of: apiPortText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { apiPortText = digits }
                    }
                Button("应用") {
                    engine.setPorts(mixed: Int(mixedPortText) ?? 7890, api: Int(apiPortText) ?? 9097)
                }
                .disabled(!portsValid || !portsChanged)
            }
            Text("改端口后内核会重启，配置列表里「节点代理」的端口会跟着改。默认代理端口 7890、API 端口 9097。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section("内核日志") {
            ScrollView {
                Text(logText.isEmpty ? "还没有日志" : logText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 200)
            Text("完整日志在配置目录的 core/core.log。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            while !Task.isCancelled {
                logText = engine.logTail
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// 订阅列表里的一行。
struct SubscriptionRow: View {
    var subscription: Subscription
    var status: Engine.SubscriptionStatus?
    var updating: Bool
    var canUpdate: Bool
    /// 筛选、前缀、前置代理的一句话；空表示没设。
    var options: String = ""
    var onUpdate: () -> Void
    var onToggle: (Bool) -> Void
    var onEdit: () -> Void = {}
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { subscription.enabled }, set: onToggle))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(subscription.name)
                    .font(.system(size: 12, weight: .medium))
                Text(subscription.url)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !options.isEmpty {
                    Text(options)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer()
            Button {
                onEdit()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("筛选、前缀、前置代理")
            if updating {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("更新") { onUpdate() }
                    .controlSize(.small)
                    .disabled(!canUpdate || !subscription.enabled)
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("删除这条订阅")
        }
    }

    private var detail: String {
        guard subscription.enabled else { return "已停用" }
        guard let status else { return "还没有读取到节点" }
        var parts = ["\(status.nodeCount) 个节点"]
        if let info = status.info {
            if let total = info.total, total > 0 {
                parts.append("已用 \(Engine.bytesText(info.used)) / \(Engine.bytesText(total))")
            }
            if let expire = info.expireDate {
                parts.append("到期 \(Self.dateFormatter.string(from: expire))")
            }
        }
        if let updated = status.updatedAt {
            parts.append("更新于 \(Engine.relative(updated))")
        }
        return parts.joined(separator: " · ")
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// 策略组列表里的一行：名字、类型、筛选可以直接改，改了出现「保存」。
struct PolicyGroupRow: View {
    var group: PolicyGroup
    var nodeNames: [String]
    /// 内核里现在用的成员。
    var current: String?
    var onSave: (PolicyGroup) -> String?
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onMove: (Bool) -> Void
    @State private var name: String
    @State private var kind: PolicyGroupKind
    @State private var filter: String
    @State private var problem: String?

    init(group: PolicyGroup, nodeNames: [String], current: String?, onSave: @escaping (PolicyGroup) -> String?, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void, onMove: @escaping (Bool) -> Void) {
        self.group = group
        self.nodeNames = nodeNames
        self.current = current
        self.onSave = onSave
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onMove = onMove
        _name = State(initialValue: group.name)
        _kind = State(initialValue: group.kind)
        _filter = State(initialValue: group.filter)
    }

    private var changed: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines) != group.name || kind != group.kind || filter.trimmingCharacters(in: .whitespaces) != group.filter
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: kind.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                TextField("", text: $name, prompt: Text("名字"))
                    .labelsHidden()
                    .frame(width: 140)
                    .onSubmit { save() }
                Picker("", selection: $kind) {
                    ForEach(PolicyGroupKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                TextField("", text: $filter, prompt: Text("节点名筛选（正则），空为全部"))
                    .labelsHidden()
                    .onSubmit { save() }
                if changed {
                    Button("保存") { save() }
                        .controlSize(.small)
                }
                Button("高级") { onEdit() }
                    .controlSize(.small)
                    .help("只用某几个订阅、排除节点、包含别的组、测速地址和间隔")
                Menu {
                    Button("上移") { onMove(true) }
                    Button("下移") { onMove(false) }
                    Divider()
                    Button("删除策略组", role: .destructive) { onDelete() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("上移、下移、删除")
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        var draft = group
        draft.kind = kind
        draft.filter = filter.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if PolicyGroup.validateFilter(draft.filter) != nil {
            parts.append("筛选不是正确的正则表达式")
        } else if nodeNames.isEmpty {
            parts.append("内核启动后能看到筛选到的节点")
        } else {
            let matched = draft.matches(nodeNames)
            parts.append(draft.filter.isEmpty ? "全部 \(nodeNames.count) 个节点" : "筛选到 \(matched.count) 个节点")
        }
        if let current, !current.isEmpty {
            parts.append("现在用 \(current)")
        }
        if group.hasAdvancedOptions {
            var advanced: [String] = []
            if !group.sources.isEmpty { advanced.append("限定来源") }
            if !group.exclude.isEmpty { advanced.append("排除 \(group.exclude)") }
            if !group.includeGroups.isEmpty { advanced.append("包含 \(group.includeGroups.joined(separator: "、"))") }
            if !group.testURL.isEmpty || group.interval != 0 { advanced.append("单独测速") }
            if group.kind == .loadBalance && group.strategy != .roundRobin { advanced.append(group.strategy.title) }
            parts.append(advanced.joined(separator: "，"))
        }
        return parts.joined(separator: " · ")
    }

    private func save() {
        guard changed else { return }
        // 只改名字、类型、筛选，高级选项保持原样。
        var updated = group
        updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.kind = kind
        updated.filter = filter.trimmingCharacters(in: .whitespaces)
        problem = onSave(updated)
    }
}
