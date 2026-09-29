import Foundation

/// 需要下载后内联的 RULE-SET。
struct RuleSetReference: Equatable {
    var url: String
    var policy: String
}

/// 规则转换的结果。
struct ConvertedRules: Equatable {
    var rules: [String] = []
    var ruleSets: [RuleSetReference] = []
    /// 规则和引用的规则集按文件里的顺序排的，合并时引用的内容放回原来的位置。
    var sequence: [RuleConverter.Converted] = []
    var skipped = 0
    var warnings: [String] = []
}

/// 把小火箭 / Surge / Clash 的分流规则转成 mihomo 的 rules 列表。
/// 支持 [Rule] 段、Clash 的 rules: / payload: 列表，以及 Surge 的 .list 规则集（没有策略字段，用默认策略）。
enum RuleConverter {
    /// 所有「走代理」的策略都指到这个组。
    static let proxyGroup = "节点"

    /// 内置规则集展开成的规则；不是内置地址返回 nil。
    static func builtinRules(url: String, policy: String) -> [String]? {
        switch url {
        case RuleSet.chinaDirectURL:
            return ["DOMAIN-SUFFIX,cn,\(policy)", "GEOIP,CN,\(policy)"]
        default:
            return nil
        }
    }

    /// 是不是完整配置、要由本程序转换：小火箭 / Surge 的 [Rule] 段，或者 Clash 顶格的 rules: 列表（纯规则列表用的是 payload:）。
    static func needsConversion(_ text: String) -> Bool {
        for raw in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            if raw.first == " " || raw.first == "\t" { continue }
            let line = raw.trimmingCharacters(in: .whitespaces).lowercased()
            if ruleSections.contains(line) || line == "rules:" { return true }
            if line == "payload:" { return false }
        }
        return false
    }

    /// 完整配置里 RULE-SET 引用的远程列表地址。
    static func referencedRuleSets(_ text: String) -> [String] {
        var urls: [String] = []
        for reference in convert(text).ruleSets where !urls.contains(reference.url) {
            urls.append(reference.url)
        }
        return urls
    }

    /// 从内容判断一个规则列表的类型：有「类型,内容」这种完整规则的是完整规则；全是 IP 段的是 IP 段列表；其余当域名列表。
    static func detectBehavior(_ text: String) -> RuleSetBehavior {
        var sampled = 0
        var cidrs = 0
        for raw in relevantLines(text) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";") { continue }
            if line.hasPrefix("- ") {
                line = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if (line.hasPrefix("\"") && line.hasSuffix("\"")) || (line.hasPrefix("'") && line.hasSuffix("'")), line.count >= 2 {
                    line = String(line.dropFirst().dropLast())
                }
            }
            if line.isEmpty { continue }
            if let comma = line.firstIndex(of: ",") {
                let type = line[..<comma].trimmingCharacters(in: .whitespaces).uppercased()
                if supportedTypes.contains(coreType(type)) || ["RULE-SET", "DOMAIN-SET", "FINAL", "MATCH", "USER-AGENT", "URL-REGEX", "GEOSITE", "IP-ASN", "AND", "OR", "NOT"].contains(type) {
                    return .classical
                }
            }
            sampled += 1
            if IPPrefix.normalize(line) != nil {
                cidrs += 1
            }
            if sampled >= 200 { break }
        }
        if sampled > 0, cidrs == sampled { return .ipcidr }
        return .domain
    }

    /// 局域网和本机直连，两种模式都放在最前面。
    static let lanRules: [String] = [
        "DOMAIN-SUFFIX,local,DIRECT",
        "DOMAIN-SUFFIX,lan,DIRECT",
        "DOMAIN-SUFFIX,localhost,DIRECT",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
        "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
        "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,169.254.0.0/16,DIRECT,no-resolve",
        "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve",
        "IP-CIDR,224.0.0.0/4,DIRECT,no-resolve",
        "IP-CIDR6,::1/128,DIRECT,no-resolve",
        "IP-CIDR6,fc00::/7,DIRECT,no-resolve",
        "IP-CIDR6,fe80::/10,DIRECT,no-resolve",
    ]

    /// 内置规则：国内 IP 直连，其余走节点。
    static let chinaDirectRules: [String] = [
        "DOMAIN-SUFFIX,cn,DIRECT",
        "GEOIP,CN,DIRECT",
        "MATCH,\(proxyGroup)",
    ]

    /// 全局模式：全部走节点。
    static let globalRules: [String] = ["MATCH,\(proxyGroup)"]

    enum Converted: Equatable {
        case rule(String)
        case ruleSet(RuleSetReference)
        case skip
    }

    /// force 不为空时所有规则都改到这个去向（统一去向），FINAL 除外；groups 是现有的自定义策略组名，
    /// 规则文件里写的策略名和某个组同名时就指到那个组。
    static func convert(_ text: String, defaultPolicy: String = proxyGroup, force: String? = nil, groups: [String] = []) -> ConvertedRules {
        var result = ConvertedRules()
        var seen = Set<String>()
        for raw in relevantLines(text) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") || line.hasPrefix(";") {
                continue
            }
            // Clash 列表项：- "DOMAIN-SUFFIX,x,y" 或 - '+.x'
            if line.hasPrefix("- ") {
                line = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if (line.hasPrefix("\"") && line.hasSuffix("\"")) || (line.hasPrefix("'") && line.hasSuffix("'")), line.count >= 2 {
                    line = String(line.dropFirst().dropLast())
                }
            }
            // 行尾注释
            for marker in [" #", " //"] {
                if let range = line.range(of: marker) {
                    line = String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                }
            }
            if line.isEmpty { continue }
            switch convertLine(line, defaultPolicy: defaultPolicy, force: force, groups: groups) {
            case .rule(let rule):
                if seen.insert(rule).inserted {
                    result.rules.append(rule)
                    result.sequence.append(.rule(rule))
                }
            case .ruleSet(let reference):
                result.ruleSets.append(reference)
                result.sequence.append(.ruleSet(reference))
            case .skip:
                result.skipped += 1
                if result.warnings.count < 10 {
                    result.warnings.append(line)
                }
            }
        }
        return result
    }

    /// 找出文件里放规则的那部分。
    static func relevantLines(_ text: String) -> [Substring] {
        let all = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        if let start = all.firstIndex(where: { ruleSections.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) {
            var lines: [Substring] = []
            for line in all[(start + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") { break }
                lines.append(line)
            }
            return lines
        }
        if let start = all.firstIndex(where: { ["rules:", "payload:"].contains($0.trimmingCharacters(in: .whitespaces)) }) {
            var lines: [Substring] = []
            for line in all[(start + 1)...] {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") {
                    lines.append(line)
                } else if trimmed.isEmpty || trimmed.hasPrefix("#") {
                    continue
                } else {
                    break
                }
            }
            return lines
        }
        return all
    }

    static let supportedTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD",
        "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "GEOIP", "SRC-IP-CIDR", "SRC-IP-SUFFIX", "SRC-PORT", "DST-PORT", "IN-PORT",
        "PROCESS-NAME", "PROCESS-PATH", "PROCESS-NAME-REGEX", "PROCESS-PATH-REGEX", "PROCESS-NAME-WILDCARD", "PROCESS-PATH-WILDCARD",
        "NETWORK",
    ]
    /// Surge / 小火箭里名字不一样的规则类型。
    static let typeAliases: [String: String] = [
        "DEST-PORT": "DST-PORT",
        "SRC-IP": "SRC-IP-CIDR",
        "IP6-CIDR": "IP-CIDR6",
        "PROTOCOL": "NETWORK",
        // Quantumult X 的写法。
        "HOST": "DOMAIN",
        "HOST-SUFFIX": "DOMAIN-SUFFIX",
        "HOST-KEYWORD": "DOMAIN-KEYWORD",
        "HOST-WILDCARD": "DOMAIN-WILDCARD",
    ]
    /// 放规则的段：小火箭 / Surge 的 [Rule]，Quantumult X 的 [filter_local]。
    static let ruleSections: Set<String> = ["[rule]", "[filter_local]"]
    private static let ipTypes: Set<String> = ["IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "GEOIP"]
    private static let logicTypes: Set<String> = ["AND", "OR", "NOT"]
    private static let surgeOptions: Set<String> = ["NO-RESOLVE", "FORCE-REMOTE-DNS", "DNS-FAILED", "EXTENDED-MATCHING", "PRE-MATCHING", "NO-TRACK"]

    /// 规则类型的内核写法：别名换成内核的名字。
    static func coreType(_ raw: String) -> String {
        let upper = raw.uppercased()
        return typeAliases[upper] ?? upper
    }

    static func convertLine(_ line: String, defaultPolicy: String = proxyGroup, force: String? = nil, groups: [String] = []) -> Converted {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first, !first.isEmpty else { return .skip }
        let type = coreType(first)
        // 没有强制去向时，没写策略的行用默认策略。
        let fallback = force ?? defaultPolicy
        switch type {
        case "FINAL", "MATCH":
            let policy = fields.count > 1 && !fields[1].isEmpty ? policy(fields[1], groups: groups) : defaultPolicy
            return .rule("MATCH,\(policy)")
        case _ where logicTypes.contains(type):
            return convertLogic(line, fallback: fallback, force: force, groups: groups)
        case "NETWORK":
            // Surge 的 PROTOCOL 还有 HTTP、HTTPS、QUIC，内核只认 TCP 和 UDP。
            guard fields.count >= 2, ["TCP", "UDP"].contains(fields[1].uppercased()) else { return .skip }
            var policy = fallback
            if force == nil, fields.count > 2, !fields[2].isEmpty {
                policy = self.policy(fields[2], groups: groups)
            }
            return .rule("NETWORK,\(fields[1].uppercased()),\(policy)")
        case "RULE-SET", "DOMAIN-SET":
            guard fields.count >= 2, !fields[1].isEmpty else { return .skip }
            let target = fields[1]
            let lowered = target.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return .skip }
            var policy = fallback
            if force == nil, fields.count > 2, !fields[2].isEmpty, !surgeOptions.contains(fields[2].uppercased()) {
                policy = self.policy(fields[2], groups: groups)
            }
            return .ruleSet(RuleSetReference(url: target, policy: policy))
        case _ where supportedTypes.contains(type):
            guard fields.count >= 2, !fields[1].isEmpty else { return .skip }
            var value = fields[1]
            if type == "GEOIP" {
                value = value.uppercased()
            }
            // 内核的 IP 规则要写成网段；Surge 的 SRC-IP 这类只写了一个 IP。
            if ["IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR"].contains(type), !value.contains("/"), let prefix = IPPrefix.normalize(value) {
                value = prefix
            }
            var policy = fallback
            var noResolve = false
            for extra in fields.dropFirst(2) where !extra.isEmpty {
                let option = extra.uppercased()
                if option == "NO-RESOLVE" {
                    noResolve = true
                } else if surgeOptions.contains(option) {
                    continue
                } else if force == nil {
                    policy = self.policy(extra, groups: groups)
                }
            }
            var rule = "\(type),\(value),\(policy)"
            if noResolve && ipTypes.contains(type) {
                rule += ",no-resolve"
            }
            return .rule(rule)
        default:
            // Clash 的 domain / ipcidr 列表：没有逗号的一行一个。
            guard fields.count == 1 else { return .skip }
            if first.hasPrefix("+.") {
                return .rule("DOMAIN-SUFFIX,\(first.dropFirst(2)),\(fallback)")
            }
            if first.hasPrefix(".") {
                return .rule("DOMAIN-SUFFIX,\(first.dropFirst()),\(fallback)")
            }
            if first.contains("/"), let slash = first.firstIndex(of: "/"), Int(first[first.index(after: slash)...]) != nil {
                return .rule("\(first.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\(first),\(fallback),no-resolve")
            }
            if looksLikeDomain(first) {
                return .rule("DOMAIN,\(first),\(fallback)")
            }
            return .skip
        }
    }

    /// 组合规则：AND,((DOMAIN,a.com),(NETWORK,UDP)),策略。里面的每条规则类型都要内核认识（别名换成内核的名字），否则跳过。
    static func convertLogic(_ line: String, fallback: String, force: String?, groups: [String]) -> Converted {
        guard let comma = line.firstIndex(of: ",") else { return .skip }
        let type = line[..<comma].trimmingCharacters(in: .whitespaces).uppercased()
        let rest = line[line.index(after: comma)...].trimmingCharacters(in: .whitespaces)
        guard rest.hasPrefix("(") else { return .skip }
        // 找到和第一个括号配对的右括号。
        var depth = 0
        var end: String.Index?
        for index in rest.indices {
            if rest[index] == "(" { depth += 1 }
            if rest[index] == ")" {
                depth -= 1
                if depth == 0 {
                    end = index
                    break
                }
            }
        }
        guard let end else { return .skip }
        let body = String(rest[...end])
        let tail = rest[rest.index(after: end)...].split(separator: ",", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        // 里面的每条规则：去掉括号，按类型转换。
        let inner = body.dropFirst().dropLast()
        var parts: [String] = []
        var current = ""
        depth = 0
        for character in inner {
            if character == "(" {
                depth += 1
                if depth == 1 { current = ""; continue }
            }
            if character == ")" {
                depth -= 1
                if depth == 0 { parts.append(current); continue }
            }
            if depth >= 1 { current.append(character) }
        }
        guard !parts.isEmpty else { return .skip }
        var converted: [String] = []
        for part in parts {
            let fields = part.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let innerType = coreType(fields.first ?? "")
            if logicTypes.contains(innerType) {
                // 嵌套的组合规则原样保留。
                converted.append("(\(part))")
                continue
            }
            guard supportedTypes.contains(innerType), fields.count == 2, !fields[1].isEmpty else { return .skip }
            var value = innerType == "GEOIP" ? fields[1].uppercased() : fields[1]
            if ["IP-CIDR", "IP-CIDR6", "SRC-IP-CIDR"].contains(innerType), !value.contains("/"), let prefix = IPPrefix.normalize(value) {
                value = prefix
            }
            converted.append("(\(innerType),\(value))")
        }
        var policy = fallback
        if force == nil, let first = tail.first, !surgeOptions.contains(first.uppercased()) {
            policy = self.policy(first, groups: groups)
        }
        return .rule("\(type),(\(converted.joined(separator: ","))),\(policy)")
    }

    /// 小火箭 / Surge 里的策略名转成内核里的：直连、拒绝各归各，和某个自定义策略组同名的指到那个组，其余走代理的都指到「节点」组。
    static func policy(_ raw: String, groups: [String] = []) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let group = groups.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return group
        }
        switch trimmed.uppercased() {
        case "DIRECT", "直连", "直接连接":
            return "DIRECT"
        case "REJECT", "REJECT-DROP", "REJECT-NO-DROP", "REJECT-TINYGIF", "REJECT-IMG", "REJECT-DICT", "REJECT-ARRAY", "REJECT-200", "BLOCK", "拒绝", "广告", "AD", "ADBLOCK":
            return "REJECT"
        default:
            return proxyGroup
        }
    }

    static func looksLikeDomain(_ text: String) -> Bool {
        guard text.contains("."), !text.contains(" "), !text.contains(":") else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// 把内联的规则集合并进去：RULE-SET / DOMAIN-SET 出现的位置换成规则集的内容，FINAL 放在最后。
    static func merge(_ converted: ConvertedRules, ruleSetRules: [String: [String]]) -> [String] {
        var rules: [String] = []
        var seen = Set<String>()
        func add(_ rule: String) {
            if seen.insert(rule).inserted {
                rules.append(rule)
            }
        }
        let finalRules = converted.rules.filter { $0.hasPrefix("MATCH,") }
        // 老的结果没有顺序信息时，规则集接在普通规则后面。
        let sequence = converted.sequence.isEmpty ? converted.rules.map(Converted.rule) + converted.ruleSets.map(Converted.ruleSet) : converted.sequence
        for item in sequence {
            switch item {
            case .rule(let rule):
                if !rule.hasPrefix("MATCH,") {
                    add(rule)
                }
            case .ruleSet(let reference):
                for rule in ruleSetRules[reference.url] ?? [] where !rule.hasPrefix("MATCH,") {
                    add(rule)
                }
            case .skip:
                break
            }
        }
        if let final = finalRules.last {
            rules.append(final)
        }
        return rules
    }
}
