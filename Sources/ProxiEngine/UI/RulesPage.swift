import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 分流规则页：规则集（远程的规则列表）按顺序匹配，自定义规则排在最前，最后是「其余流量」的去向；规则库一键添加。
struct RulesPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var navigation: SettingsNavigation
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newPolicy: RuleTarget = .proxy
    @State private var addProblem: String?
    @State private var showLibrary = false
    @State private var newRulePattern = ""
    @State private var newRulePolicy: RuleTarget = .proxy
    @State private var newRuleKind: CustomRuleKind = .auto
    @State private var ruleProblem: String?
    @State private var refreshingAll = false

    private var groups: [PolicyGroup] { state.config.engine.groups }
    private var targets: [RuleTarget] { RuleTarget.options(groups: groups) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("分流规则"), subtitle: L("哪些网站走节点、哪些直连、哪些拦截：自定义规则最先匹配，然后按规则集的顺序，都没命中的按「其余流量」"))
            Form {
                statusSection
                ruleSetsSection
                customRulesSection
                finalSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showLibrary) {
            RuleLibrarySheet(engine: engine, existing: Set(state.config.engine.ruleSets.map(\.url)))
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section(L("状态")) {
            if state.config.engine.mode == .global {
                HStack {
                    Label(L("现在是全局代理，规则集不生效（自定义规则和局域网直连除外）"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(L("切回规则分流")) { engine.setMode(.rule) }
                        .controlSize(.small)
                }
            } else {
                HStack(alignment: .top) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(refreshingAll ? L("正在更新…") : L("重新下载全部")) { refreshAll() }
                        .controlSize(.small)
                        .disabled(refreshingAll || !state.config.engine.wantsCore)
                }
            }
            Text(L("规则每 %@ 小时自动更新一次（和订阅同一个间隔）。规则地址直连不通时，会经内核或 jsDelivr 镜像下载；还没下载下来的先跳过，内核照常启动，下好了自动生效。", String(state.config.engine.updateIntervalHours)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if !engine.rulesInfo.isEmpty { return engine.rulesInfo }
        return state.config.engine.wantsCore ? L("内核启动后生效") : L("添加订阅、内核启动后生效")
    }

    private func refreshAll() {
        refreshingAll = true
        Task { @MainActor in
            await engine.refreshAllRuleSets()
            refreshingAll = false
        }
    }

    // MARK: - 规则集

    private var ruleSetsSection: some View {
        Section(L("规则集")) {
            if state.config.engine.ruleSets.isEmpty {
                Text(L("还没有规则集。从规则库里挑几条，或者把规则地址粘到下面。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.ruleSets) { set in
                RuleSetRow(
                    set: set,
                    status: engine.ruleSetStatus[set.id],
                    updating: engine.downloadingRuleSets.contains(set.id),
                    groups: groups,
                    onChange: { engine.saveRuleSet($0) },
                    onRefresh: { Task { await engine.refreshRuleSet(set.id) } },
                    onDelete: { engine.removeRuleSet(set.id) },
                    onMove: { engine.moveRuleSet(set.id, up: $0) }
                )
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("", text: $newName, prompt: Text(L("名字（可选）")))
                        .labelsHidden()
                        .frame(width: 120)
                    TextField("", text: $newURL, prompt: Text(L("规则地址：.list / .yaml / .mrs 列表，或者 Surge 格式的 .conf")))
                        .labelsHidden()
                        .onSubmit { add() }
                    Picker("", selection: $newPolicy) {
                        ForEach(targets, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button(L("添加")) { add() }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addProblem {
                    Text(addProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button(L("从规则库添加…")) { showLibrary = true }
                    .controlSize(.small)
            }
            Text(L("靠前的规则集先匹配，右边的菜单可以调顺序。纯规则列表（.list、.yaml、.mrs）由内核直接加载，更新不用重启；Surge 格式的完整配置（.conf）会转换后并入，默认按文件里写的策略走，添加后可以改成统一的去向。「走节点」用「节点与订阅」页里选中的节点，策略组的成员也在那一页设置。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func add() {
        let url = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let draft = RuleSet(name: "", url: url, policy: nil)
        // 完整配置按文件里的策略；纯列表用选的去向。
        let policy: RuleTarget? = draft.kind == .inline && !draft.isBuiltin ? nil : newPolicy
        addProblem = engine.addRuleSet(name: newName, url: url, policy: policy)
        if addProblem == nil {
            newName = ""
            newURL = ""
        }
    }

    // MARK: - 自定义规则

    private var customRulesSection: some View {
        Section(L("自定义规则")) {
            if state.config.engine.customRules.isEmpty {
                Text(L("让某个网站、某个应用、某台设备固定走节点、直连、拦截或者走某个策略组。排在所有规则集前面，全局模式下也生效。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.customRules) { rule in
                CustomRuleRow(
                    rule: rule,
                    targets: targets,
                    onChange: { engine.updateCustomRule($0) },
                    onMove: { engine.moveCustomRule(rule.id, up: $0) },
                    onDelete: { engine.removeCustomRule(rule.id) }
                )
            }
            HStack(spacing: 8) {
                Picker("", selection: $newRuleKind) {
                    ForEach(CustomRuleKind.common) { kind in
                        Text(kind.title).tag(kind)
                    }
                    Divider()
                    ForEach(CustomRuleKind.allCases.filter { !CustomRuleKind.common.contains($0) }) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: AppLanguage.width(110, english: 150))
                TextField("", text: $newRulePattern, prompt: Text(newRuleKind.placeholder))
                    .labelsHidden()
                    .onSubmit { addRule() }
                if newRuleKind == .app {
                    appMenu
                }
                Picker("", selection: $newRulePolicy) {
                    ForEach(targets, id: \.self) { target in
                        Text(target.title).tag(target)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button(L("添加")) { addRule() }
                    .disabled(newRulePattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let ruleProblem {
                Text(ruleProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(kindHelp)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("规则立刻生效，不用重启内核，从上到下匹配。共享给 PS5 等设备的流量同样遵守这些规则；在「连接」页和「局域网共享」页的连接上右键也能直接加。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var kindHelp: String {
        switch newRuleKind {
        case .app: return L("应用：这个 .app 以及它的辅助进程发起的连接（按路径匹配）。比如让某个程序走节点、让某个下载工具直连。")
        case .device: return L("局域网设备：按来源 IP 匹配经局域网共享上网的设备，比如让 PS5 走某个策略组。本机没开代理引擎时，设备规则里只有直连和拦截生效。")
        case .process: return L("进程名：命令行工具这类没有 .app 的程序，比如 git、node、curl。")
        case .logic: return L("组合规则：把几条条件用 AND（都满足）、OR（满足一个）、NOT（不满足）组合起来，写成 AND,((DOMAIN,a.com),(NETWORK,UDP))，里面每条是「类型,内容」。")
        case .geoip: return L("IP 归属地：目标 IP 属于某个国家或地区（要先解析域名）。")
        default: return L("「域名或 IP」按域名（含子域名）或 IP / 网段匹配；更多类型在左边的菜单里。")
        }
    }

    /// 选应用：正在运行的、或者到文件夹里选。
    private var appMenu: some View {
        Menu(L("选择应用")) {
            ForEach(runningApps, id: \.self) { path in
                Button((path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")) {
                    newRulePattern = path
                }
            }
            if !runningApps.isEmpty {
                Divider()
            }
            Button(L("到应用程序文件夹里选…")) { chooseApp() }
        }
        .fixedSize()
    }

    private var runningApps: [String] {
        let paths = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleURL?.path }
            .filter { !$0.hasPrefix("/System/") }
        return Array(Set(paths)).sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = L("选择要单独分流的应用")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        newRulePattern = url.path
    }

    private func addRule() {
        ruleProblem = engine.addCustomRule(pattern: newRulePattern, policy: newRulePolicy, kind: newRuleKind)
        if ruleProblem == nil {
            newRulePattern = ""
        }
    }

    // MARK: - 其余流量

    private var finalBinding: Binding<RuleTarget?> {
        Binding(get: { state.config.engine.finalPolicy }, set: { engine.setFinalPolicy($0) })
    }

    private var finalSection: some View {
        Section(L("其余流量")) {
            Picker(L("没被任何规则命中的流量"), selection: finalBinding) {
                Text(L("跟随规则文件（没有就走节点）")).tag(RuleTarget?.none)
                ForEach(targets, id: \.self) { target in
                    Text(target.title).tag(Optional(target))
                }
            }
            Text(L("Surge 格式的完整配置里有自己的 FINAL（其余流量的去向）。「跟随规则文件」用的是最后一个这样的规则集的 FINAL；纯规则列表没有 FINAL，全是列表时其余流量走节点。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 规则集列表里的一行。
struct RuleSetRow: View {
    var set: RuleSet
    var status: Engine.RuleSetStatus?
    var updating: Bool
    var groups: [PolicyGroup]
    var onChange: (RuleSet) -> Void
    var onRefresh: () -> Void
    var onDelete: () -> Void
    var onMove: (Bool) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Toggle("", isOn: Binding(get: { set.enabled }, set: { value in
                var updated = set
                updated.enabled = value
                onChange(updated)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(set.name)
                        .font(.system(size: 12, weight: .medium))
                    Text(kindText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                if !set.isBuiltin {
                    Text(set.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(status?.problem == nil ? Color.secondary : Color.orange)
            }
            Spacer()
            Picker("", selection: policyBinding) {
                if set.kind == .inline {
                    Text(L("按文件里的")).tag(RuleTarget?.none)
                }
                ForEach(RuleTarget.options(groups: groups), id: \.self) { target in
                    Text(target.title).tag(Optional(target))
                }
            }
            .labelsHidden()
            .frame(width: 120)
            .disabled(!set.enabled)
            if updating {
                ProgressView()
                    .controlSize(.small)
            } else if !set.isBuiltin {
                Button(L("更新")) { onRefresh() }
                    .controlSize(.small)
                    .disabled(!set.enabled)
                    .help(L("重新下载这个规则集"))
            }
            Menu {
                Button(L("上移")) { onMove(true) }
                Button(L("下移")) { onMove(false) }
                if !set.isBuiltin {
                    Button(L("复制地址")) { TerminalCommands.copy(set.url) }
                }
                Divider()
                Button(L("删除规则集"), role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("上移、下移、删除"))
        }
    }

    private var policyBinding: Binding<RuleTarget?> {
        Binding(
            get: { set.policy ?? (set.kind == .inline ? nil : .proxy) },
            set: { value in
                var updated = set
                updated.policy = value
                onChange(updated)
            }
        )
    }

    private var kindText: String {
        switch set.kind {
        case .builtin: return L("内置")
        case .provider: return L("内核加载 · %@", set.effectiveBehavior.title)
        case .inline: return L("转换并入")
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let count = status?.count {
            parts.append(L("%@ 条", count))
        }
        if let date = status?.updatedAt {
            parts.append(L("更新于 %@", Engine.relative(date)))
        }
        if let problem = status?.problem {
            parts.append(problem)
        }
        if parts.isEmpty {
            parts.append(set.isBuiltin ? L("按域名后缀和 IP 归属地判断，不用下载") : (set.enabled ? L("还没有下载") : L("已停用")))
        }
        return parts.joined(separator: " · ")
    }
}

/// 规则库：按分类列出常用的公开规则，点「添加」加进规则集。
struct RuleLibrarySheet: View {
    @ObservedObject var engine: Engine
    var existing: Set<String>
    @Environment(\.dismiss) private var dismiss
    @State private var added: Set<String> = []
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("规则库"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L("MetaCubeX 和 ACL4SSR 维护的公开规则，点「添加」加进规则集，去向可以再改"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("完成")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(RuleLibrary.categories, id: \.self) { category in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(category)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                ForEach(RuleLibrary.entries(in: category)) { entry in
                                    row(entry)
                                    if entry.id != RuleLibrary.entries(in: category).last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .glassCard()
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 660, height: 560)
    }

    private func row(_ entry: RuleLibraryEntry) -> some View {
        let done = existing.contains(entry.url) || added.contains(entry.url)
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.policy?.title ?? L("按文件里的"))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Button(done ? L("已添加") : L("添加")) {
                if let error = engine.add(entry) {
                    problem = error
                } else {
                    added.insert(entry.url)
                    problem = nil
                }
            }
            .controlSize(.small)
            .disabled(done)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// 自定义规则列表里的一行：种类、内容（应用显示图标和名字）、去向。
struct CustomRuleRow: View {
    var rule: CustomRule
    var targets: [RuleTarget]
    var onChange: (CustomRule) -> Void
    var onMove: (Bool) -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { value in
                var updated = rule
                updated.enabled = value
                onChange(updated)
            }))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            if rule.kind == .app {
                Image(nsImage: NSWorkspace.shared.icon(forFile: rule.pattern))
                    .resizable()
                    .frame(width: 18, height: 18)
            }
            if !rule.kind.badge.isEmpty {
                Text(rule.kind.badge)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
            }
            Text(rule.displayValue)
                .font(.system(size: 12, design: rule.kind == .app ? .default : .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(rule.pattern)
            Spacer()
            Picker("", selection: Binding(get: { rule.policy }, set: { value in
                var updated = rule
                updated.policy = value
                onChange(updated)
            })) {
                ForEach(targets, id: \.self) { target in
                    Text(target.title).tag(target)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            Menu {
                Button(L("上移")) { onMove(true) }
                Button(L("下移")) { onMove(false) }
                Button(L("复制内容")) { TerminalCommands.copy(rule.pattern) }
                Divider()
                Button(L("删除规则"), role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
