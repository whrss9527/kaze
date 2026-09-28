import Foundation

/// 一条订阅：机场给的地址，内核负责下载和解析节点。
struct Subscription: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = "订阅"
    var url: String = ""
    var enabled: Bool = true

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, url, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "订阅"
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// 内核配置里 provider 的名字，只用 ASCII，省得在 YAML 里折腾引号。
    var providerName: String { "sub-" + id.uuidString.prefix(8).lowercased() }

    /// 校验地址，返回问题；没问题返回 nil。支持 http(s) 地址和本机的 file:// 文件。
    static func validate(url text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return "订阅地址要以 http:// 或 https:// 开头"
        }
        if scheme == "file" {
            return url.path.isEmpty ? "文件地址不对" : nil
        }
        guard ["http", "https"].contains(scheme), url.host != nil else {
            return "订阅地址要以 http:// 或 https:// 开头"
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
        case .rule: return "规则分流"
        case .global: return "全局代理"
        }
    }
}

/// 0.6 及以前的分流规则来源：只有一个。现在只用来读旧配置，迁移成规则集列表。
enum RuleSource: Equatable, Codable {
    /// 内置：局域网和国内 IP 直连，其余走节点。
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
        case .proxy: return "走节点"
        case .direct: return "直连"
        case .reject: return "拦截"
        case .group(let name): return name
        }
    }

    /// 「让 xx …」句式里用的：走节点、直连、拦截、走「组名」。
    var actionTitle: String {
        if case .group(let name) = self { return "走「\(name)」" }
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
        case "DIRECT": return "直连"
        case "REJECT": return "拦截"
        case RuleConverter.proxyGroup: return "走节点"
        default: return "走「\(policy)」"
        }
    }
}

/// 一条自定义分流规则：域名（含子域名）或 IP / 网段固定走某个去向。排在预设规则前面，全局模式下也生效。
struct CustomRule: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var pattern: String = ""
    var policy: RuleTarget = .proxy
    var enabled: Bool = true

    init(pattern: String, policy: RuleTarget) {
        self.pattern = CustomRule.normalize(pattern)
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case id, pattern, policy, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        policy = try container.decodeIfPresent(RuleTarget.self, forKey: .policy) ?? .proxy
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// 把「https://www.YouTube.com/watch」「*.youtube.com」「youtube.com:443」这样的输入整理成 youtube.com 形式；IP 和网段原样保留。
    static func normalize(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for scheme in ["http://", "https://", "socks5://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if let slash = value.firstIndex(of: "/"), IPPrefix.normalize(value) == nil {
            value = String(value[..<slash])
        }
        if value.hasPrefix("*.") {
            value = String(value.dropFirst(2))
        } else if value.hasPrefix(".") {
            value = String(value.dropFirst())
        }
        // 域名后面带的端口去掉；IPv6 里的冒号不算。
        if !value.contains("]"), let colon = value.lastIndex(of: ":"), value[value.index(after: colon)...].allSatisfy(\.isNumber), value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// 校验输入，返回问题；没问题返回 nil。
    static func validate(_ text: String) -> String? {
        let value = normalize(text)
        if value.isEmpty { return "请填写域名或 IP" }
        if IPPrefix.normalize(value) != nil || RuleConverter.looksLikeDomain(value) { return nil }
        return "认不出「\(value)」：填域名（比如 youtube.com）或 IP / 网段（比如 8.8.8.8、10.0.0.0/8）"
    }

    /// 内核规则行；认不出来的返回 nil。groups 是现有的策略组名，去向指向已删除的组时退回「节点」。
    func line(groups: [String]) -> String? {
        let value = CustomRule.normalize(pattern)
        let target = policy.resolved(groups: groups)
        if let prefix = IPPrefix.normalize(value) {
            return "\(prefix.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\(prefix),\(target),no-resolve"
        }
        if RuleConverter.looksLikeDomain(value) {
            return "DOMAIN-SUFFIX,\(value),\(target)"
        }
        return nil
    }

    var line: String? { line(groups: []) }
}

/// 内置代理（内核）的设置。
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
    var ruleSets: [RuleSet] = [RuleSet.chinaDirect()]
    /// 没被任何规则命中的流量往哪走；nil 表示跟随规则文件里的 FINAL（没有就走节点）。
    var finalPolicy: RuleTarget?

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, subscriptions, mode, ruleSource, mixedPort, apiPort, selectedNode, updateIntervalHours, customRules, groups, ruleSets, finalPolicy
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
            ruleSets = [RuleSet.chinaDirect()]
        }
        finalPolicy = try container.decodeIfPresent(RuleTarget.self, forKey: .finalPolicy)
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
    }

    var activeSubscriptions: [Subscription] { subscriptions.filter { $0.enabled && !$0.url.isEmpty } }

    /// 有订阅且没关掉时内核才需要运行。
    var wantsCore: Bool { enabled && !activeSubscriptions.isEmpty }

    /// 自定义策略组的名字，按配置里的顺序。
    var groupNames: [String] { groups.map(\.name) }

    /// 启用的自定义规则对应的内核规则行。
    var customRuleLines: [String] { customRules.filter(\.enabled).compactMap { $0.line(groups: groupNames) } }

    /// 启用的规则集。
    var activeRuleSets: [RuleSet] { ruleSets.filter(\.enabled) }

    /// 策略组被删掉或改名后，把指向它的规则改到新的去向。
    mutating func retarget(from name: String, to target: RuleTarget) {
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
