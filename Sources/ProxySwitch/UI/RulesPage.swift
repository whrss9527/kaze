import AppKit
import SwiftUI

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
    @State private var ruleProblem: String?
    @State private var refreshingAll = false

    private var groups: [PolicyGroup] { state.config.engine.groups }
    private var targets: [RuleTarget] { RuleTarget.options(groups: groups) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "分流规则", subtitle: "哪些网站走节点、哪些直连、哪些拦截：自定义规则最先匹配，然后按规则集的顺序，都没命中的按「其余流量」")
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
        Section("状态") {
            if state.config.engine.mode == .global {
                HStack {
                    Label("现在是全局代理，规则集不生效（自定义规则和局域网直连除外）", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("切回规则分流") { engine.setMode(.rule) }
                        .controlSize(.small)
                }
            } else {
                HStack(alignment: .top) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(refreshingAll ? "正在更新…" : "重新下载全部") { refreshAll() }
                        .controlSize(.small)
                        .disabled(refreshingAll || !state.config.engine.wantsCore)
                }
            }
            Text("规则每 \(String(state.config.engine.updateIntervalHours)) 小时自动更新一次（和订阅同一个间隔）。GitHub 上的规则国内直连不通时，会经内核或 jsDelivr 镜像下载；还没下载下来的先跳过，内核照常启动，下好了自动生效。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        if !engine.rulesInfo.isEmpty { return engine.rulesInfo }
        return state.config.engine.wantsCore ? "内核启动后生效" : "添加订阅、内核启动后生效"
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
        Section("规则集") {
            if state.config.engine.ruleSets.isEmpty {
                Text("还没有规则集。从规则库里挑几条，或者把规则地址粘到下面。")
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
                    TextField("", text: $newName, prompt: Text("名字（可选）"))
                        .labelsHidden()
                        .frame(width: 120)
                    TextField("", text: $newURL, prompt: Text("规则地址：.list / .yaml / .mrs 列表，或者小火箭、Surge 的 .conf"))
                        .labelsHidden()
                        .onSubmit { add() }
                    Picker("", selection: $newPolicy) {
                        ForEach(targets, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button("添加") { add() }
                        .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let addProblem {
                    Text(addProblem)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Button("从规则库添加…") { showLibrary = true }
                    .controlSize(.small)
            }
            Text("靠前的规则集先匹配，右边的菜单可以调顺序。纯规则列表（.list、.yaml、.mrs）由内核直接加载，更新不用重启；小火箭 / Surge 的完整配置（.conf）会转换后并入，默认按文件里写的策略走，添加后可以改成统一的去向。「走节点」用面板里选中的节点，策略组的成员在「节点与订阅」页设置。")
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
        Section("自定义规则") {
            if state.config.engine.customRules.isEmpty {
                Text("让某个网站固定走节点、直连、拦截或者走某个策略组。排在所有规则集前面，全局模式下也生效。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(state.config.engine.customRules) { rule in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { value in
                        var updated = rule
                        updated.enabled = value
                        engine.updateCustomRule(updated)
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text(rule.pattern)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Picker("", selection: Binding(get: { rule.policy }, set: { value in
                        var updated = rule
                        updated.policy = value
                        engine.updateCustomRule(updated)
                    })) {
                        ForEach(targets, id: \.self) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)
                    Button(role: .destructive) {
                        engine.removeCustomRule(rule.id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("删除这条规则")
                }
            }
            HStack(spacing: 10) {
                TextField("", text: $newRulePattern, prompt: Text("域名（含子域名）或 IP / 网段，比如 youtube.com、8.8.8.8、10.0.0.0/8"))
                    .labelsHidden()
                    .onSubmit { addRule() }
                Picker("", selection: $newRulePolicy) {
                    ForEach(targets, id: \.self) { target in
                        Text(target.title).tag(target)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                Button("添加") { addRule() }
                    .disabled(newRulePattern.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let ruleProblem {
                Text(ruleProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("规则立刻生效，不用重启内核。共享给 PS5 等设备的流量同样遵守这些规则；在「连接」页和「局域网共享」页的连接上右键也能直接加。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addRule() {
        ruleProblem = engine.addCustomRule(pattern: newRulePattern, policy: newRulePolicy)
        if ruleProblem == nil {
            newRulePattern = ""
        }
    }

    // MARK: - 其余流量

    private var finalBinding: Binding<RuleTarget?> {
        Binding(get: { state.config.engine.finalPolicy }, set: { engine.setFinalPolicy($0) })
    }

    private var finalSection: some View {
        Section("其余流量") {
            Picker("没被任何规则命中的流量", selection: finalBinding) {
                Text("跟随规则文件（没有就走节点）").tag(RuleTarget?.none)
                ForEach(targets, id: \.self) { target in
                    Text(target.title).tag(Optional(target))
                }
            }
            Text("小火箭 / Surge 的完整配置里有自己的 FINAL：黑名单类的是直连，白名单类的是走节点。「跟随规则文件」用的是最后一个这样的规则集的 FINAL；纯规则列表没有 FINAL，全是列表时其余流量走节点。")
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
                    Text("按文件里的").tag(RuleTarget?.none)
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
                Button("更新") { onRefresh() }
                    .controlSize(.small)
                    .disabled(!set.enabled)
                    .help("重新下载这个规则集")
            }
            Menu {
                Button("上移") { onMove(true) }
                Button("下移") { onMove(false) }
                if !set.isBuiltin {
                    Button("复制地址") { TerminalCommands.copy(set.url) }
                }
                Divider()
                Button("删除规则集", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("上移、下移、删除")
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
        case .builtin: return "内置"
        case .provider: return "内核加载 · \(set.effectiveBehavior.title)"
        case .inline: return "转换并入"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if let count = status?.count {
            parts.append("\(count) 条")
        }
        if let date = status?.updatedAt {
            parts.append("更新于 \(Engine.relative(date))")
        }
        if let problem = status?.problem {
            parts.append(problem)
        }
        if parts.isEmpty {
            parts.append(set.isBuiltin ? "不用下载" : (set.enabled ? "还没有下载" : "已停用"))
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
                    Text("规则库")
                        .font(.system(size: 16, weight: .semibold))
                    Text("blackmatrix7、MetaCubeX、ACL4SSR 和 johnshall 维护的公开规则，点「添加」加进规则集，去向可以再改")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("完成") { dismiss() }
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
            Text(entry.policy?.title ?? "按文件里的")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
            Button(done ? "已添加" : "添加") {
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
