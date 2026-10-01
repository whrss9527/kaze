import Foundation

/// 一条订阅：服务提供方给的地址，内核负责下载和解析节点。
struct Subscription: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = L("订阅")
    var url: String = ""
    var enabled: Bool = true
    /// 只保留名字匹配这个正则的节点（不区分大小写）；空表示全部。
    var filter: String = ""
    /// 去掉名字匹配这个正则的节点（不区分大小写），比如「过期|剩余|官网」。
    var exclude: String = ""
    /// 节点名前面加上这段文字，几个订阅来源的节点同名时好区分。
    var prefix: String = ""
    /// 前置代理：这个订阅的节点先经它再连出去（链式代理）。策略组名、节点名，或者 "profile:<配置 id>"。
    var dialer: String?

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, enabled, filter, exclude, prefix, dialer
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? L("订阅")
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        filter = try container.decodeIfPresent(String.self, forKey: .filter) ?? ""
        exclude = try container.decodeIfPresent(String.self, forKey: .exclude) ?? ""
        prefix = try container.decodeIfPresent(String.self, forKey: .prefix) ?? ""
        dialer = try container.decodeIfPresent(String.self, forKey: .dialer)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(url, forKey: .url)
        try container.encode(enabled, forKey: .enabled)
        if !filter.isEmpty { try container.encode(filter, forKey: .filter) }
        if !exclude.isEmpty { try container.encode(exclude, forKey: .exclude) }
        if !prefix.isEmpty { try container.encode(prefix, forKey: .prefix) }
        try container.encodeIfPresent(dialer, forKey: .dialer)
    }

    /// 有没有设置过筛选、前缀或前置代理。
    var hasOptions: Bool { !filter.isEmpty || !exclude.isEmpty || !prefix.isEmpty || dialer != nil }

    /// 校验筛选、排除和前缀，返回问题；没问题返回 nil。
    static func validateOptions(filter: String, exclude: String, prefix: String) -> String? {
        if let problem = PolicyGroup.validateFilter(filter) { return problem }
        if let problem = PolicyGroup.validateFilter(exclude, exclude: true) { return problem }
        if prefix.count > 12 { return L("前缀太长了，12 个字以内") }
        if prefix.contains(where: { $0 == "," || $0 == "，" || $0.isNewline || $0 == "\"" || $0 == "#" }) { return L("前缀里不能有逗号、引号、# 或换行") }  // l10n-ignore：全角逗号
        return nil
    }

    /// 内核配置里 provider 的名字，只用 ASCII，省得在 YAML 里折腾引号。
    var providerName: String { "sub-" + id.uuidString.prefix(8).lowercased() }

    /// 校验地址，返回问题；没问题返回 nil。支持 http(s) 地址和本机的 file:// 文件。
    static func validate(url text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return L("订阅地址要以 http:// 或 https:// 开头")
        }
        if scheme == "file" {
            return url.path.isEmpty ? L("文件地址不对") : nil
        }
        guard ["http", "https"].contains(scheme), url.host != nil else {
            return L("订阅地址要以 http:// 或 https:// 开头")
        }
        return nil
    }

    /// 本机文件的路径（file:// 订阅）。
    var filePath: String? {
        guard let parsed = URL(string: url), parsed.scheme?.lowercased() == "file" else { return nil }
        return parsed.path
    }
}

/// 代理模式：按规则分流，或者全部走节点。
enum EngineMode: String, Codable, CaseIterable, Identifiable {
    case rule
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rule: return L("规则分流")
        case .global: return L("全局代理")
        }
    }
}

/// 0.6 及以前的分流规则来源：只有一个。现在只用来读旧配置，迁移成规则集列表。
enum RuleSource: Equatable, Codable {
    /// 内置的「智能分流」：.cn 域名和 GEOIP 为 CN 的地址直连，其余走节点。
    case chinaDirect
    /// 小火箭 / Surge / Clash 格式的规则地址。
    case url(String)

    private enum CodingKeys: String, CodingKey {
        case kind, url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "chinaDirect"
        if kind == "url", let url = try container.decodeIfPresent(String.self, forKey: .url), !url.isEmpty {
            self = .url(url)
        } else {
            self = .chinaDirect
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .chinaDirect:
            try container.encode("chinaDirect", forKey: .kind)
        case .url(let url):
            try container.encode("url", forKey: .kind)
            try container.encode(url, forKey: .url)
        }
    }

    var url: String? {
        if case .url(let url) = self { return url }
        return nil
    }
}

/// 规则的去向：「节点」组、直连、拦截，或者某个自定义策略组。
/// 存成一个字符串："proxy"、"direct"、"reject"、"group:名字"，旧配置里只有前三个。
enum RuleTarget: Codable, Equatable, Hashable {
    case proxy
    case direct
    case reject
    case group(String)

    static let fixed: [RuleTarget] = [.proxy, .direct, .reject]

    /// 选择器里的候选：固定的三个加上现有的策略组。
    static func options(groups: [PolicyGroup]) -> [RuleTarget] {
        fixed + groups.map { .group($0.name) }
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RuleTarget(rawValue: raw)
    }

    init(rawValue: String) {
        switch rawValue {
        case "proxy": self = .proxy
        case "direct": self = .direct
        case "reject": self = .reject
        default:
            if rawValue.hasPrefix("group:"), rawValue.count > 6 {
                self = .group(String(rawValue.dropFirst(6)))
            } else {
                self = .proxy
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var rawValue: String {
        switch self {
        case .proxy: return "proxy"
        case .direct: return "direct"
        case .reject: return "reject"
        case .group(let name): return "group:" + name
        }
    }

    var title: String {
        switch self {
        case .proxy: return L("走节点")
        case .direct: return L("直连")
        case .reject: return L("拦截")
        case .group(let name): return name
        }
    }

    /// 「让 xx …」句式里用的：走节点、直连、拦截、走「组名」。
    var actionTitle: String {
        if case .group(let name) = self { return L("走「%@」", name) }
        return title
    }

    /// 内核里的策略名。指向的策略组已经不存在时退回「节点」，免得内核因为找不到策略拒绝启动。
    func resolved(groups: [String]) -> String {
        switch self {
        case .proxy: return RuleConverter.proxyGroup
        case .direct: return "DIRECT"
        case .reject: return "REJECT"
        case .group(let name): return groups.contains(name) ? name : RuleConverter.proxyGroup
        }
    }

    /// 内核策略名对应的显示文字。
    static func title(forCorePolicy policy: String) -> String {
        switch policy {
        case "DIRECT": return L("直连")
        case "REJECT": return L("拦截")
        case RuleConverter.proxyGroup: return L("走节点")
        default: return L("走「%@」", policy)
        }
    }
}

/// 代理引擎（内核）的设置。
struct EngineConfig: Codable, Equatable {
    var enabled: Bool = true
    var subscriptions: [Subscription] = []
    var mode: EngineMode = .rule
    var mixedPort: Int = 7890
    var apiPort: Int = 9097
    /// 「节点」组里选中的节点；nil 表示自动选择。
    var selectedNode: String?
    /// 订阅和规则自动更新的间隔（小时）。
    var updateIntervalHours: Int = 24
    /// 自定义规则，排在规则集前面。
    var customRules: [CustomRule] = []
    /// 自定义策略组：在「节点」和「自动选择」之外，给某类流量单独选节点。
    var groups: [PolicyGroup] = []
    /// 分流规则集，按顺序匹配，靠前的优先。
    var ruleSets: [RuleSet] = []
    /// 没被任何规则命中的流量往哪走；nil 表示跟随规则文件里的 FINAL（没有就走节点）。
    var finalPolicy: RuleTarget?
    /// 手动添加的节点（分享链接）。
    var manualNodes: [ManualNode] = []
    /// 手动节点的前置代理，写法和订阅的一样。
    var manualDialer: String?
    /// 内核的 DNS。
    var dns = DNSSettings()
    /// Hosts：固定解析。
    var hosts: [HostEntry] = []
    /// 允许 IPv6：内核解析和连接 IPv6 地址。
    var ipv6: Bool = false
    /// 内核配置补丁（YAML），合并进生成的配置；高级功能。
    var patch: String = ""
    /// 收藏的节点，排在列表和菜单的最前面。
    var favoriteNodes: [String] = []
    /// 节点列表的排序。
    var nodeSort: NodeSort = .original

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, subscriptions, mode, ruleSource, mixedPort, apiPort, selectedNode, updateIntervalHours, customRules, groups, ruleSets, finalPolicy
        case manualNodes, manualDialer, dns, hosts, ipv6, patch, favoriteNodes, nodeSort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        subscriptions = try container.decodeIfPresent([Subscription].self, forKey: .subscriptions) ?? []
        mode = try container.decodeIfPresent(EngineMode.self, forKey: .mode) ?? .rule
        mixedPort = try container.decodeIfPresent(Int.self, forKey: .mixedPort) ?? 7890
        apiPort = try container.decodeIfPresent(Int.self, forKey: .apiPort) ?? 9097
        selectedNode = try container.decodeIfPresent(String.self, forKey: .selectedNode)
        updateIntervalHours = try container.decodeIfPresent(Int.self, forKey: .updateIntervalHours) ?? 24
        customRules = try container.decodeIfPresent([CustomRule].self, forKey: .customRules) ?? []
        groups = try container.decodeIfPresent([PolicyGroup].self, forKey: .groups) ?? []
        if let sets = try container.decodeIfPresent([RuleSet].self, forKey: .ruleSets) {
            ruleSets = sets
        } else if let source = try container.decodeIfPresent(RuleSource.self, forKey: .ruleSource) {
            // 旧配置：单一的规则来源变成一条规则集，行为和以前一样。
            ruleSets = RuleSet.migrated(from: source)
        } else {
            ruleSets = []
        }
        finalPolicy = try container.decodeIfPresent(RuleTarget.self, forKey: .finalPolicy)
        manualNodes = try container.decodeIfPresent([ManualNode].self, forKey: .manualNodes) ?? []
        manualDialer = try container.decodeIfPresent(String.self, forKey: .manualDialer)
        dns = try container.decodeIfPresent(DNSSettings.self, forKey: .dns) ?? DNSSettings()
        hosts = try container.decodeIfPresent([HostEntry].self, forKey: .hosts) ?? []
        ipv6 = try container.decodeIfPresent(Bool.self, forKey: .ipv6) ?? false
        patch = try container.decodeIfPresent(String.self, forKey: .patch) ?? ""
        favoriteNodes = try container.decodeIfPresent([String].self, forKey: .favoriteNodes) ?? []
        nodeSort = (try? container.decodeIfPresent(NodeSort.self, forKey: .nodeSort)) ?? .original
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(subscriptions, forKey: .subscriptions)
        try container.encode(mode, forKey: .mode)
        try container.encode(mixedPort, forKey: .mixedPort)
        try container.encode(apiPort, forKey: .apiPort)
        try container.encodeIfPresent(selectedNode, forKey: .selectedNode)
        try container.encode(updateIntervalHours, forKey: .updateIntervalHours)
        try container.encode(customRules, forKey: .customRules)
        try container.encode(groups, forKey: .groups)
        try container.encode(ruleSets, forKey: .ruleSets)
        try container.encodeIfPresent(finalPolicy, forKey: .finalPolicy)
        try container.encode(manualNodes, forKey: .manualNodes)
        try container.encodeIfPresent(manualDialer, forKey: .manualDialer)
        try container.encode(dns, forKey: .dns)
        try container.encode(hosts, forKey: .hosts)
        try container.encode(ipv6, forKey: .ipv6)
        try container.encode(patch, forKey: .patch)
        try container.encode(favoriteNodes, forKey: .favoriteNodes)
        try container.encode(nodeSort, forKey: .nodeSort)
    }

    var activeSubscriptions: [Subscription] { subscriptions.filter { $0.enabled && !$0.url.isEmpty } }

    /// 数据目录换了位置（改名）：指向旧目录里文件的订阅和规则集（导入时存下的）换到新目录。
    /// old、new 是两个目录的 file:// 网址，以 / 结尾。有改动返回 true。
    mutating func relocateFiles(from old: String, to new: String) -> Bool {
        var changed = false
        for index in subscriptions.indices where subscriptions[index].url.hasPrefix(old) {
            subscriptions[index].url = new + subscriptions[index].url.dropFirst(old.count)
            changed = true
        }
        for index in ruleSets.indices where ruleSets[index].url.hasPrefix(old) {
            ruleSets[index].url = new + ruleSets[index].url.dropFirst(old.count)
            changed = true
        }
        return changed
    }

    /// 启用的手动节点。
    var activeManualNodes: [ManualNode] { manualNodes.filter { $0.enabled && !$0.link.isEmpty } }

    /// 有订阅或手动节点、而且没关掉时内核才需要运行。
    var wantsCore: Bool { enabled && (!activeSubscriptions.isEmpty || !activeManualNodes.isEmpty) }

    /// 内核里的节点来源（订阅和手动节点）的名字，按顺序。
    var providerNames: [String] {
        var names = activeSubscriptions.map(\.providerName)
        if !activeManualNodes.isEmpty {
            names.append(ManualNode.providerName)
        }
        return names
    }

    /// 某个策略组用的节点来源：没限定时是全部；限定了就只要选中的（都不在了也退回全部，免得组是空的）。
    func providerNames(for group: PolicyGroup) -> [String] {
        let all = providerNames
        guard !group.sources.isEmpty else { return all }
        var picked: [String] = []
        for subscription in activeSubscriptions where group.sources.contains(subscription.id) {
            picked.append(subscription.providerName)
        }
        if group.sources.contains(ManualNode.sourceID), !activeManualNodes.isEmpty {
            picked.append(ManualNode.providerName)
        }
        return picked.isEmpty ? all : picked
    }

    /// 自定义策略组的名字，按配置里的顺序。
    var groupNames: [String] { groups.map(\.name) }

    /// 启用的自定义规则对应的内核规则行。
    var customRuleLines: [String] { customRules.filter(\.enabled).compactMap { $0.line(groups: groupNames) } }

    /// 启用的规则集。
    var activeRuleSets: [RuleSet] { ruleSets.filter(\.enabled) }

    /// 策略组被删掉或改名后，把指向它的规则改到新的去向；包含它的组、用它当前置代理的订阅跟着改。
    mutating func retarget(from name: String, to target: RuleTarget) {
        let newName: String? = {
            if case .group(let renamed) = target { return renamed }
            return nil
        }()
        for index in groups.indices {
            groups[index].renameMember(from: name, to: newName)
        }
        for index in subscriptions.indices where subscriptions[index].dialer == name {
            subscriptions[index].dialer = newName
        }
        if manualDialer == name {
            manualDialer = newName
        }
        let old = RuleTarget.group(name)
        for index in customRules.indices where customRules[index].policy == old {
            customRules[index].policy = target
        }
        for index in ruleSets.indices where ruleSets[index].policy == old {
            ruleSets[index].policy = target
        }
        if finalPolicy == old {
            finalPolicy = target
        }
    }
}

/// 节点列表怎么排；收藏的节点总在最前面。
enum NodeSort: String, Codable, CaseIterable, Identifiable {
    /// 订阅里的顺序。
    case original
    /// 按名字。
    case name
    /// 按延迟，没测过和超时的在后面。
    case delay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: return L("订阅顺序")
        case .name: return L("按名字")
        case .delay: return L("按延迟")
        }
    }
}

/// 前置代理的一个候选。
struct DialerCandidate: Identifiable, Equatable {
    /// 存进配置里的写法。
    var value: String
    var title: String

    var id: String { value }
}

/// 前置代理（链式代理）的写法：策略组名或节点名原样写；"profile:<id>" 是配置列表里的一个 HTTP / SOCKS5 代理。
enum DialerReference {
    static let profilePrefix = "profile:"

    static func profile(_ id: UUID) -> String { profilePrefix + id.uuidString }

    /// 是配置列表里的代理时返回它的 id。
    static func profileID(_ value: String) -> UUID? {
        guard value.hasPrefix(profilePrefix) else { return nil }
        return UUID(uuidString: String(value.dropFirst(profilePrefix.count)))
    }

    /// 配置列表里的代理在内核里的名字。
    static func coreName(for profile: Profile) -> String { "前置·" + profile.name }  // l10n-ignore：内核配置里的名字，界面上用 CoreConfigBuilder.displayName

    /// 能当前置代理的配置：HTTP 或 SOCKS5，不是代理引擎自己。
    static func usable(_ profile: Profile) -> Bool {
        !profile.engine && (profile.kind == .http || profile.kind == .socks5)
    }

    /// 显示用的文字。
    static func title(_ value: String, profiles: [Profile]) -> String {
        if let id = profileID(value) {
            return profiles.first { $0.id == id }.map { L("代理「%@」", $0.name) } ?? L("已删除的代理")
        }
        return value
    }
}
