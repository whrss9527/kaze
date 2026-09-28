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
        case .select: return "手动选择"
        case .urlTest: return "自动选择"
        case .fallback: return "故障转移"
        case .loadBalance: return "负载均衡"
        }
    }

    var detail: String {
        switch self {
        case .select: return "在面板里自己选，默认跟随「节点」的选择"
        case .urlTest: return "定期测延迟，自动用最低的那个"
        case .fallback: return "按列表顺序用第一个可用的节点，坏了自动换下一个"
        case .loadBalance: return "匹配到的节点轮流用，分摊流量"
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

/// 一个自定义策略组：给某类流量（流媒体、Telegram……）单独选节点。成员是订阅里按名字筛选出来的节点；
/// 手动选择的组还多了「节点」「自动选择」和直连三个候选，默认跟随「节点」，所以刚建好时行为和以前一样。
struct PolicyGroup: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var kind: PolicyGroupKind = .select
    /// 节点名的正则筛选（不区分大小写），比如「港|HK」；空表示所有节点。
    var filter: String = ""

    init(name: String, kind: PolicyGroupKind = .select, filter: String = "") {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.kind = kind
        self.filter = filter.trimmingCharacters(in: .whitespaces)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, filter
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try container.decodeIfPresent(PolicyGroupKind.self, forKey: .kind) ?? .select
        filter = try container.decodeIfPresent(String.self, forKey: .filter) ?? ""
    }

    /// 内核自己用的名字，不能拿来当组名。
    static let reservedNames: Set<String> = [
        RuleConverter.proxyGroup, CoreConfigBuilder.autoGroup, CoreConfigBuilder.upstreamProxy, CoreConfigBuilder.shareListener,
        "DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL", "COMPATIBLE",
    ]
    static let maxNameLength = 20

    /// 校验名字和筛选，返回问题；没问题返回 nil。others 是其他已有的组（改名时不含自己）。
    static func validate(name rawName: String, filter: String, others: [PolicyGroup]) -> String? {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return "请填写策略组的名字" }
        if name.count > maxNameLength { return "名字太长了，\(maxNameLength) 个字以内" }
        // 规则行用逗号分隔字段，名字里有逗号会被拆开。
        if name.contains(where: { $0 == "," || $0 == "，" || $0.isNewline || $0 == "\"" || $0 == "`" }) { return "名字里不能有逗号、引号或换行" }
        if reservedNames.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return "「\(name)」是内核保留的名字，换一个" }
        let lowered = name.lowercased()
        if lowered.hasPrefix("sub-") || lowered.hasPrefix("rs-") { return "名字不能以 sub- 或 rs- 开头，这是给订阅和规则集用的" }
        if others.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return "已经有叫「\(name)」的策略组了" }
        return validateFilter(filter)
    }

    /// 筛选要是正确的正则表达式。
    static func validateFilter(_ filter: String) -> String? {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: trimmed)
        } catch {
            return "筛选不是正确的正则表达式"
        }
        return nil
    }

    /// 内核配置里的 filter：默认不区分大小写，写了自己的标志就照用。
    var coreFilter: String? {
        let trimmed = filter.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return nil }
        return trimmed.hasPrefix("(?") ? trimmed : "(?i)" + trimmed
    }

    /// 用筛选挑出的节点名，和内核的做法一致（正则、不区分大小写）；筛选为空时是全部。
    func matches(_ nodeNames: [String]) -> [String] {
        guard let pattern = coreFilter else { return nodeNames }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return nodeNames.filter { name in
            regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
        }
    }
}
