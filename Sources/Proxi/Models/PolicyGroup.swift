import Foundation

/// 策略组的类型。
enum PolicyGroupKind: String, Codable, CaseIterable, Identifiable {
    /// 自己选。
    case select
    /// 定期测延迟，用最低的。
    case urlTest
    /// 按顺序用第一个可用的，坏了换下一个。
    case fallback
    /// 多个节点轮流用。
    case loadBalance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return L("手动选择")
        case .urlTest: return L("自动选择")
        case .fallback: return L("故障转移")
        case .loadBalance: return L("负载均衡")
        }
    }

    var detail: String {
        switch self {
        case .select: return L("在面板里自己选，默认跟随「节点」的选择")
        case .urlTest: return L("定期测延迟，自动用最低的那个")
        case .fallback: return L("按列表顺序用第一个可用的节点，坏了自动换下一个")
        case .loadBalance: return L("匹配到的节点轮流用，分摊流量")
        }
    }

    /// 内核（mihomo）里的类型。
    var coreType: String {
        switch self {
        case .select: return "select"
        case .urlTest: return "url-test"
        case .fallback: return "fallback"
        case .loadBalance: return "load-balance"
        }
    }

    var symbol: String {
        switch self {
        case .select: return "hand.tap"
        case .urlTest: return "bolt"
        case .fallback: return "arrow.triangle.2.circlepath"
        case .loadBalance: return "arrow.left.arrow.right"
        }
    }
}

/// 负载均衡怎么分配。
enum LoadBalanceStrategy: String, Codable, CaseIterable, Identifiable {
    /// 轮流用。
    case roundRobin
    /// 同一个网站总是用同一个节点（换节点少，适合要保持登录的网站）。
    case consistentHashing
    /// 同一来源访问同一网站，一段时间内用同一个节点。
    case stickySessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .roundRobin: return L("轮流")
        case .consistentHashing: return L("同一网站固定节点")
        case .stickySessions: return L("同一会话固定节点")
        }
    }

    /// 内核（mihomo）里的写法。
    var coreValue: String {
        switch self {
        case .roundRobin: return "round-robin"
        case .consistentHashing: return "consistent-hashing"
        case .stickySessions: return "sticky-sessions"
        }
    }
}

/// 一个自定义策略组：给某类流量（流媒体、Telegram……）单独选节点。成员是订阅里按名字筛选出来的节点；
/// 手动选择的组还多了「节点」「自动选择」和直连三个候选，默认跟随「节点」，所以刚建好时行为和以前一样。
/// 高级选项：只用某几个订阅的节点、排除某些节点、把别的策略组也放进来、单独的测速地址和间隔、负载均衡的方式。
struct PolicyGroup: Codable, Identifiable, Equatable, Hashable {
    static let defaultInterval = 600
    static let defaultTolerance = 80

    var id: UUID = UUID()
    var name: String = ""
    var kind: PolicyGroupKind = .select
    /// 节点名的正则筛选（不区分大小写），比如「港|HK」；空表示所有节点。
    var filter: String = ""
    /// 排除节点名匹配这个正则的节点（不区分大小写），比如「过期|剩余」。
    var exclude: String = ""
    /// 也放进来的策略组（其他自定义组，或者「节点」「自动选择」），排在筛出来的节点前面。
    var includeGroups: [String] = []
    /// 只用这些来源的节点（订阅的 id，手动节点是 ManualNode.sourceID）；空表示全部。
    var sources: [UUID] = []
    /// 测速地址；空表示用通用设置里的。
    var testURL: String = ""
    /// 自动测速的间隔（秒）；0 表示默认的 600。
    var interval: Int = 0
    /// 自动选择：比现在用的快多少毫秒以上才换；0 表示默认的 80。
    var tolerance: Int = 0
    /// 负载均衡的分配方式。
    var strategy: LoadBalanceStrategy = .roundRobin

    init(name: String, kind: PolicyGroupKind = .select, filter: String = "") {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.filter = filter.trimmingCharacters(in: .whitespaces)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, filter, exclude, includeGroups, sources, testURL, interval, tolerance, strategy
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try container.decodeIfPresent(PolicyGroupKind.self, forKey: .kind) ?? .select
        filter = try container.decodeIfPresent(String.self, forKey: .filter) ?? ""
        exclude = try container.decodeIfPresent(String.self, forKey: .exclude) ?? ""
        includeGroups = try container.decodeIfPresent([String].self, forKey: .includeGroups) ?? []
        sources = try container.decodeIfPresent([UUID].self, forKey: .sources) ?? []
        testURL = try container.decodeIfPresent(String.self, forKey: .testURL) ?? ""
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 0
        tolerance = try container.decodeIfPresent(Int.self, forKey: .tolerance) ?? 0
        strategy = (try? container.decodeIfPresent(LoadBalanceStrategy.self, forKey: .strategy)) ?? .roundRobin
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(filter, forKey: .filter)
        // 高级选项只在设置过时写出来，配置文件保持简洁。
        if !exclude.isEmpty { try container.encode(exclude, forKey: .exclude) }
        if !includeGroups.isEmpty { try container.encode(includeGroups, forKey: .includeGroups) }
        if !sources.isEmpty { try container.encode(sources, forKey: .sources) }
        if !testURL.isEmpty { try container.encode(testURL, forKey: .testURL) }
        if interval != 0 { try container.encode(interval, forKey: .interval) }
        if tolerance != 0 { try container.encode(tolerance, forKey: .tolerance) }
        if strategy != .roundRobin { try container.encode(strategy, forKey: .strategy) }
    }

    /// 内核自己用的名字，不能拿来当组名。
    static let reservedNames: Set<String> = [
        RuleConverter.proxyGroup, CoreConfigBuilder.autoGroup, CoreConfigBuilder.upstreamProxy, CoreConfigBuilder.shareListener,
        CoreConfigBuilder.probeGroup, "DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL", "COMPATIBLE",
    ]
    static let maxNameLength = 20

    /// 能被放进别的组的内置组。
    static let builtinMembers = [RuleConverter.proxyGroup, CoreConfigBuilder.autoGroup]

    /// 校验名字和筛选，返回问题；没问题返回 nil。others 是其他已有的组（改名时不含自己）。
    static func validate(name rawName: String, filter: String, others: [PolicyGroup]) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return L("请填写策略组的名字") }
        if name.count > maxNameLength { return L("名字太长了，%@ 个字以内", maxNameLength) }
        // 规则行用逗号分隔字段，名字里有逗号会被拆开。
        if name.contains(where: { $0 == "," || $0 == "，" || $0.isNewline || $0 == "\"" || $0 == "`" || $0 == "#" }) { return L("名字里不能有逗号、引号、# 或换行") }  // l10n-ignore：全角逗号
        if reservedNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return L("「%@」是内核保留的名字，换一个", name) }
        let lowered = name.lowercased()
        if lowered.hasPrefix("sub-") || lowered.hasPrefix("rs-") || lowered.hasPrefix("ps-") || lowered == ManualNode.providerName { return L("名字不能以 sub-、rs-、ps- 开头，也不能叫 manual，这些是给订阅和规则集用的") }
        if others.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return L("已经有叫「%@」的策略组了", name) }
        return validateFilter(filter)
    }

    /// 筛选要是正确的正则表达式。exclude 为 true 时校验的是排除，提示里说「排除」。
    static func validateFilter(_ filter: String, exclude: Bool = false) -> String? {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("`") { return exclude ? L("排除里不能有反引号") : L("筛选里不能有反引号") }
        do {
            _ = try NSRegularExpression(pattern: trimmed)
        } catch {
            return exclude ? L("排除不是正确的正则表达式") : L("筛选不是正确的正则表达式")
        }
        return nil
    }

    /// 校验高级选项：排除的正则、包含的组（不能包含自己，也不能绕一圈包含回来）、测速地址和间隔。all 是全部的组（改过的这个替换进去）。
    static func validateAdvanced(_ group: PolicyGroup, all: [PolicyGroup]) -> String? {
        if let problem = validateFilter(group.exclude, exclude: true) { return problem }
        let names = Set(all.map(\.name))
        for member in group.includeGroups {
            if member == group.name { return L("策略组不能包含自己") }
            if !names.contains(member) && !builtinMembers.contains(member) { return L("没有叫「%@」的策略组", member) }
        }
        var groups = all.map { $0.id == group.id ? group : $0 }
        if !groups.contains(where: { $0.id == group.id }) {
            groups.append(group)
        }
        if let cycle = cycle(in: groups) {
            return L("策略组互相包含：%@", cycle.joined(separator: " → "))
        }
        let url = group.testURL.trimmingCharacters(in: .whitespaces)
        if !url.isEmpty {
            guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased(), ["http", "https"].contains(scheme), parsed.host != nil else {
                return L("测速地址要以 http:// 或 https:// 开头")
            }
        }
        if group.interval != 0 && !(30...86400).contains(group.interval) { return L("测速间隔在 30 秒到 1 天之间") }
        if group.tolerance < 0 || group.tolerance > 5000 { return L("切换的容差在 0~5000 毫秒之间") }
        return nil
    }

    /// 找出互相包含形成的环；没有返回 nil。
    static func cycle(in groups: [PolicyGroup]) -> [String]? {
        var edges: [String: [String]] = [:]
        for group in groups {
            edges[group.name] = group.includeGroups
        }
        var state: [String: Int] = [:]
        var path: [String] = []
        func visit(_ name: String) -> [String]? {
            if state[name] == 1 {
                let start = path.firstIndex(of: name) ?? 0
                return Array(path[start...]) + [name]
            }
            if state[name] == 2 { return nil }
            state[name] = 1
            path.append(name)
            for next in edges[name] ?? [] where edges[next] != nil {
                if let found = visit(next) { return found }
            }
            path.removeLast()
            state[name] = 2
            return nil
        }
        for group in groups {
            if let found = visit(group.name) { return found }
        }
        return nil
    }

    /// 内核配置里的 filter：默认不区分大小写，写了自己的标志就照用。
    var coreFilter: String? { PolicyGroup.coreRegex(filter) }

    /// 内核配置里的 exclude-filter。
    var coreExclude: String? { PolicyGroup.coreRegex(exclude) }

    static func coreRegex(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return trimmed.hasPrefix("(?") ? trimmed : "(?i)" + trimmed
    }

    /// 实际的测速间隔。
    var effectiveInterval: Int { interval > 0 ? interval : PolicyGroup.defaultInterval }

    /// 实际的容差。
    var effectiveTolerance: Int { tolerance > 0 ? tolerance : PolicyGroup.defaultTolerance }

    /// 有没有设置过高级选项（界面上默认展开与否）。
    var hasAdvancedOptions: Bool {
        !exclude.isEmpty || !includeGroups.isEmpty || !sources.isEmpty || !testURL.isEmpty || interval != 0 || tolerance != 0 || strategy != .roundRobin
    }

    /// 用筛选挑出的节点名，和内核的做法一致（正则、不区分大小写，再去掉排除的）；筛选为空时是全部。
    func matches(_ nodeNames: [String]) -> [String] {
        var result = nodeNames
        if let pattern = coreFilter {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            result = result.filter { name in
                regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            }
        }
        if let pattern = coreExclude, let regex = try? NSRegularExpression(pattern: pattern) {
            result = result.filter { name in
                regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) == nil
            }
        }
        return result
    }

    /// 策略组被改名后，包含它的组跟着改；被删掉时从包含列表里去掉（to 为 nil）。
    mutating func renameMember(from old: String, to new: String?) {
        includeGroups = includeGroups.compactMap { $0 == old ? new : $0 }
    }
}
