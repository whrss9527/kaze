import Foundation

/// 自定义规则按什么匹配。
enum CustomRuleKind: String, Codable, CaseIterable, Identifiable {
    /// 域名（含子域名）或 IP / 网段，自动判断。
    case auto
    /// 完整域名，不含子域名。
    case domain
    /// 域名后缀：这个域名和它的所有子域名。
    case suffix
    /// 域名里含有这个词。
    case keyword
    /// 域名通配：* 任意多个字符，? 一个字符。
    case wildcard
    /// 域名正则。
    case regex
    /// 目标 IP 或网段。
    case ip
    /// 目标 IP 的归属地（国家代码）。
    case geoip
    /// 局域网里的某台设备（来源 IP），共享给 PS5 等设备时用。
    case device
    /// 目标端口。
    case port
    /// 某个应用（.app）发起的连接，连同它的辅助进程。
    case app
    /// 进程名，命令行工具这类没有 .app 的程序用。
    case process
    /// TCP 或 UDP。
    case network
    /// 组合规则：AND / OR / NOT。
    case logic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return L("域名或 IP")
        case .domain: return L("完整域名")
        case .suffix: return L("域名后缀")
        case .keyword: return L("域名关键词")
        case .wildcard: return L("域名通配")
        case .regex: return L("域名正则")
        case .ip: return L("IP / 网段")
        case .geoip: return L("IP 归属地")
        case .device: return L("局域网设备")
        case .port: return L("端口")
        case .app: return L("应用")
        case .process: return L("进程名")
        case .network: return L("协议")
        case .logic: return L("组合规则")
        }
    }

    /// 输入框里的提示。
    var placeholder: String {
        switch self {
        case .auto: return L("域名（含子域名）或 IP / 网段，比如 example.com、192.0.2.1、10.0.0.0/8")
        case .domain: return L("完整域名，不含子域名，比如 www.example.com")
        case .suffix: return L("域名后缀，比如 example.com（含所有子域名）")
        case .keyword: return L("域名里的关键词，比如 example")
        case .wildcard: return L("通配，比如 *.example.com、img?.example.com")
        case .regex: return L("正则，比如 ^ad[0-9]+\\.example\\.com$（不能有逗号）")
        case .ip: return L("目标 IP 或网段，比如 1.1.1.1、91.108.0.0/16")
        case .geoip: return L("国家代码，比如 CN、JP、US；LAN 表示局域网")
        case .device: return L("设备的 IP 或网段，比如 192.168.1.20")
        case .port: return L("端口，比如 22、8000-9000、80/443")
        case .app: return L("应用的路径，比如 /Applications/Safari.app")
        case .process: return L("进程名，比如 git、node、curl")
        case .network: return L("TCP 或 UDP")
        case .logic: return L("比如 AND,((DOMAIN-SUFFIX,example.com),(NETWORK,UDP))")
        }
    }

    /// 规则列表里的小标签。
    var badge: String {
        switch self {
        case .auto: return ""
        case .domain: return L("域名")
        case .suffix: return L("后缀")
        case .keyword: return L("关键词")
        case .wildcard: return L("通配")
        case .regex: return L("正则")
        case .ip: return "IP"
        case .geoip: return L("归属地")
        case .device: return L("设备")
        case .port: return L("端口")
        case .app: return L("应用")
        case .process: return L("进程")
        case .network: return L("协议")
        case .logic: return L("组合")
        }
    }

    /// 添加规则时直接列出的几种，其余的在「更多类型」里。
    static let common: [CustomRuleKind] = [.auto, .app, .device, .keyword]

    /// 从内核规则类型认出来的种类（导入 Clash / Surge 规则时用）；认不出返回 nil。
    static func from(coreType type: String) -> CustomRuleKind? {
        switch type.uppercased() {
        case "DOMAIN": return .domain
        case "DOMAIN-SUFFIX": return .suffix
        case "DOMAIN-KEYWORD": return .keyword
        case "DOMAIN-WILDCARD": return .wildcard
        case "DOMAIN-REGEX": return .regex
        case "IP-CIDR", "IP-CIDR6": return .ip
        case "GEOIP": return .geoip
        case "SRC-IP-CIDR", "SRC-IP": return .device
        case "DST-PORT", "DEST-PORT": return .port
        case "PROCESS-NAME": return .process
        case "NETWORK": return .network
        case "AND", "OR", "NOT": return .logic
        default: return nil
        }
    }
}

/// 一条自定义分流规则：某个域名、IP、应用、设备……固定走某个去向。排在规则集前面，全局模式下也生效。
struct CustomRule: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var kind: CustomRuleKind = .auto
    var pattern: String = ""
    var policy: RuleTarget = .proxy
    var enabled: Bool = true

    init(pattern: String, policy: RuleTarget, kind: CustomRuleKind = .auto) {
        self.kind = kind
        self.pattern = CustomRule.normalize(pattern, kind: kind)
        self.policy = policy
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, pattern, policy, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = (try? container.decodeIfPresent(CustomRuleKind.self, forKey: .kind)) ?? .auto
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        policy = try container.decodeIfPresent(RuleTarget.self, forKey: .policy) ?? .proxy
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    // MARK: - 整理和校验

    /// 把「https://www.Example.com/path」「*.example.com」「example.com:443」这样的输入整理成 example.com 形式；IP 和网段原样保留。
    static func normalize(_ text: String) -> String {
        normalize(text, kind: .auto)
    }

    /// 按种类整理输入。
    static func normalize(_ text: String, kind: CustomRuleKind) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .auto, .suffix:
            return hostPart(of: trimmed, stripWildcard: true)
        case .domain:
            return hostPart(of: trimmed, stripWildcard: false)
        case .keyword, .wildcard:
            return trimmed.lowercased()
        case .regex, .logic, .process:
            return trimmed
        case .ip, .device:
            return IPPrefix.normalize(trimmed) ?? trimmed
        case .geoip:
            return trimmed.uppercased()
        case .port:
            return trimmed.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "，", with: "/").replacingOccurrences(of: ",", with: "/")  // l10n-ignore：全角逗号
        case .app:
            var path = (trimmed as NSString).expandingTildeInPath
            while path.count > 1 && path.hasSuffix("/") {
                path.removeLast()
            }
            return path
        case .network:
            return trimmed.uppercased()
        }
    }

    /// 去掉协议、路径、端口，留下主机名；stripWildcard 时再去掉前面的 *. 和 .。
    private static func hostPart(of text: String, stripWildcard: Bool) -> String {
        var value = text.lowercased()
        for scheme in ["http://", "https://", "socks5://"] where value.hasPrefix(scheme) {
            value = String(value.dropFirst(scheme.count))
        }
        if let slash = value.firstIndex(of: "/"), IPPrefix.normalize(value) == nil {
            value = String(value[..<slash])
        }
        if stripWildcard {
            if value.hasPrefix("*.") || value.hasPrefix("+.") {
                value = String(value.dropFirst(2))
            } else if value.hasPrefix(".") {
                value = String(value.dropFirst())
            }
        }
        // 域名后面带的端口去掉；IPv6 里的冒号不算。
        if !value.contains("]"), let colon = value.lastIndex(of: ":"), value[value.index(after: colon)...].allSatisfy(\.isNumber), value.filter({ $0 == ":" }).count == 1 {
            value = String(value[..<colon])
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    /// 校验输入，返回问题；没问题返回 nil。
    static func validate(_ text: String) -> String? {
        validate(text, kind: .auto)
    }

    /// 按种类校验输入，返回问题；没问题返回 nil。
    static func validate(_ text: String, kind: CustomRuleKind) -> String? {
        let value = normalize(text, kind: kind)
        if value.isEmpty { return kind == .auto ? L("请填写域名或 IP") : L("请填写%@", kind.title) }
        // 规则行用逗号分隔字段，组合规则以外的内容里不能有逗号。
        if kind != .logic, value.contains(",") { return L("不能有逗号") }
        if value.contains(where: \.isNewline) { return L("不能换行") }
        switch kind {
        case .auto:
            if IPPrefix.normalize(value) != nil || RuleConverter.looksLikeDomain(value) { return nil }
            return L("认不出「%@」：填域名（比如 example.com）或 IP / 网段（比如 192.0.2.1、10.0.0.0/8）", value)
        case .domain, .suffix:
            return RuleConverter.looksLikeDomain(value) ? nil : L("认不出「%@」：填域名，比如 example.com", value)
        case .keyword:
            return value.contains(where: \.isWhitespace) ? L("关键词里不能有空格") : nil
        case .wildcard:
            let allowed = value.allSatisfy { $0.isLetter || $0.isNumber || "-_.*?".contains($0) }
            return allowed && value.contains(".") ? nil : L("通配只能有字母、数字、点、横线和 * ?，比如 *.example.com")
        case .regex:
            do {
                _ = try NSRegularExpression(pattern: value)
                return nil
            } catch {
                return L("不是正确的正则表达式")
            }
        case .ip, .device:
            return IPPrefix.normalize(value) != nil ? nil : L("认不出「%@」：填 IP 或网段，比如 192.168.1.20、10.0.0.0/8", value)
        case .geoip:
            let ok = value == "LAN" || (value.count == 2 && value.allSatisfy { $0.isASCII && $0.isLetter })
            return ok ? nil : L("填两个字母的国家代码，比如 CN、JP、US")
        case .port:
            return validPorts(value) ? nil : L("端口填 1~65535 的数字，范围用 -，多个用 /，比如 80/443、8000-9000")
        case .app:
            return value.hasPrefix("/") ? nil : L("选一个应用，或者填它的完整路径，比如 /Applications/Safari.app")
        case .process:
            return value.contains("/") ? L("进程名不含路径，比如 git；要按路径匹配请选「应用」") : nil
        case .network:
            return ["TCP", "UDP"].contains(value) ? nil : L("填 TCP 或 UDP")
        case .logic:
            let upper = value.uppercased()
            guard ["AND,", "OR,", "NOT,"].contains(where: { upper.hasPrefix($0) }) else { return L("组合规则以 AND、OR 或 NOT 开头") }
            var depth = 0
            for character in value {
                if character == "(" { depth += 1 }
                if character == ")" { depth -= 1 }
                if depth < 0 { return L("括号不配对") }
            }
            return depth == 0 && value.contains("((") ? nil : L("括号不配对，格式像 AND,((DOMAIN,a.com),(NETWORK,UDP))")
        }
    }

    /// 80、80/443、8000-9000 这样的端口写法。
    static func validPorts(_ text: String) -> Bool {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        for part in parts {
            let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(bounds.count) else { return false }
            let numbers = bounds.compactMap { Int($0) }
            guard numbers.count == bounds.count, numbers.allSatisfy({ (1...65535).contains($0) }) else { return false }
            if numbers.count == 2, numbers[0] > numbers[1] { return false }
        }
        return true
    }

    // MARK: - 显示

    /// 列表里显示的内容：应用显示名字，其余显示整理后的内容。
    var displayValue: String {
        switch kind {
        case .app:
            let name = (pattern as NSString).lastPathComponent
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        default:
            return pattern
        }
    }

    /// 从连接里的程序路径找到它所在的 .app（辅助进程也算进去）；不在 .app 里时返回 nil。
    static func appBundlePath(forProcessPath path: String) -> String? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else {
            return path.lowercased().hasSuffix(".app") ? path : nil
        }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: - 内核规则

    /// 内核规则行；认不出来的返回 nil。groups 是现有的策略组名，去向指向已删除的组时退回「节点」。
    func line(groups: [String]) -> String? {
        let value = CustomRule.normalize(pattern, kind: kind)
        guard CustomRule.validate(value, kind: kind) == nil else { return nil }
        let target = policy.resolved(groups: groups)
        switch kind {
        case .auto:
            if let prefix = IPPrefix.normalize(value) {
                return "\(prefix.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\(prefix),\(target),no-resolve"
            }
            return "DOMAIN-SUFFIX,\(value),\(target)"
        case .domain: return "DOMAIN,\(value),\(target)"
        case .suffix: return "DOMAIN-SUFFIX,\(value),\(target)"
        case .keyword: return "DOMAIN-KEYWORD,\(value),\(target)"
        case .wildcard: return "DOMAIN-WILDCARD,\(value),\(target)"
        case .regex: return "DOMAIN-REGEX,\(value),\(target)"
        case .ip:
            guard let prefix = IPPrefix.normalize(value) else { return nil }
            return "\(prefix.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\(prefix),\(target),no-resolve"
        case .geoip: return "GEOIP,\(value),\(target)"
        case .device:
            guard let prefix = IPPrefix.normalize(value) else { return nil }
            return "SRC-IP-CIDR,\(prefix),\(target)"
        case .port: return "DST-PORT,\(value),\(target)"
        case .app:
            // .app 里的主程序和各种 Helper 都在包里，按路径通配（不区分大小写）一起匹配。
            if value.lowercased().hasSuffix(".app") {
                return "PROCESS-PATH-WILDCARD,\(value)/*,\(target)"
            }
            return "PROCESS-PATH,\(value),\(target)"
        case .process: return "PROCESS-NAME,\(value),\(target)"
        case .network: return "NETWORK,\(value),\(target)"
        case .logic: return "\(value),\(target)"
        }
    }

    var line: String? { line(groups: []) }

    /// 同一种类、同样内容的规则算重复。
    func sameMatch(as other: CustomRule) -> Bool {
        kind == other.kind && pattern == other.pattern
    }
}
