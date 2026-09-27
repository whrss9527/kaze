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
    var skipped = 0
    var warnings: [String] = []
}

/// 把小火箭 / Surge / Clash 的分流规则转成 mihomo 的 rules 列表。
/// 支持 [Rule] 段、Clash 的 rules: / payload: 列表，以及 Surge 的 .list 规则集（没有策略字段，用默认策略）。
enum RuleConverter {
    /// 所有「走代理」的策略都指到这个组。
    static let proxyGroup = "节点"

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

    static func convert(_ text: String, defaultPolicy: String = proxyGroup) -> ConvertedRules {
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
            switch convertLine(line, defaultPolicy: defaultPolicy) {
            case .rule(let rule):
                if seen.insert(rule).inserted {
                    result.rules.append(rule)
                }
            case .ruleSet(let reference):
                result.ruleSets.append(reference)
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
        if let start = all.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "[rule]" }) {
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

    private static let supportedTypes: Set<String> = [
        "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD", "DOMAIN-REGEX", "DOMAIN-WILDCARD",
        "IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "GEOIP", "SRC-IP-CIDR", "SRC-PORT", "DST-PORT",
        "PROCESS-NAME", "PROCESS-PATH",
    ]
    private static let ipTypes: Set<String> = ["IP-CIDR", "IP-CIDR6", "IP-SUFFIX", "GEOIP"]
    private static let surgeOptions: Set<String> = ["NO-RESOLVE", "FORCE-REMOTE-DNS", "DNS-FAILED", "EXTENDED-MATCHING", "PRE-MATCHING"]

    static func convertLine(_ line: String, defaultPolicy: String = proxyGroup) -> Converted {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = fields.first, !first.isEmpty else { return .skip }
        let type = first.uppercased()
        switch type {
        case "FINAL", "MATCH":
            let policy = fields.count > 1 && !fields[1].isEmpty ? policy(fields[1]) : defaultPolicy
            return .rule("MATCH,\(policy)")
        case "RULE-SET":
            guard fields.count >= 2, !fields[1].isEmpty else { return .skip }
            let target = fields[1]
            let lowered = target.lowercased()
            guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return .skip }
            let policy = fields.count > 2 && !fields[2].isEmpty && !surgeOptions.contains(fields[2].uppercased()) ? policy(fields[2]) : defaultPolicy
            return .ruleSet(RuleSetReference(url: target, policy: policy))
        case _ where supportedTypes.contains(type):
            guard fields.count >= 2, !fields[1].isEmpty else { return .skip }
            var value = fields[1]
            if type == "GEOIP" {
                value = value.uppercased()
            }
            var policy = defaultPolicy
            var noResolve = false
            for extra in fields.dropFirst(2) where !extra.isEmpty {
                let option = extra.uppercased()
                if option == "NO-RESOLVE" {
                    noResolve = true
                } else if surgeOptions.contains(option) {
                    continue
                } else {
                    policy = self.policy(extra)
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
                return .rule("DOMAIN-SUFFIX,\(first.dropFirst(2)),\(defaultPolicy)")
            }
            if first.hasPrefix(".") {
                return .rule("DOMAIN-SUFFIX,\(first.dropFirst()),\(defaultPolicy)")
            }
            if first.contains("/"), let slash = first.firstIndex(of: "/"), Int(first[first.index(after: slash)...]) != nil {
                return .rule("\(first.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\(first),\(defaultPolicy),no-resolve")
            }
            if looksLikeDomain(first) {
                return .rule("DOMAIN,\(first),\(defaultPolicy)")
            }
            return .skip
        }
    }

    /// 小火箭 / Surge 里的策略名转成内核里的：走代理的都指到「节点」组，自定义的策略组也按走代理处理。
    static func policy(_ raw: String) -> String {
        switch raw.uppercased() {
        case "DIRECT", "直连", "直接连接":
            return "DIRECT"
        case "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "REJECT-IMG", "REJECT-DICT", "REJECT-ARRAY", "REJECT-200", "BLOCK", "拒绝", "广告", "AD", "ADBLOCK":
            return "REJECT"
        default:
            return proxyGroup
        }
    }

    static func looksLikeDomain(_ text: String) -> Bool {
        guard text.contains("."), !text.contains(" "), !text.contains(":") else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// 把内联的规则集合并进去：RULE-SET 出现的位置换成规则集的内容。
    static func merge(_ converted: ConvertedRules, ruleSetRules: [String: [String]]) -> [String] {
        // convert() 已经把 RULE-SET 从 rules 里拿走了，规则集的内容接在普通规则前面（它们通常在文件末尾、FINAL 之前）。
        var rules: [String] = []
        var seen = Set<String>()
        func add(_ rule: String) {
            if seen.insert(rule).inserted {
                rules.append(rule)
            }
        }
        let finalRules = converted.rules.filter { $0.hasPrefix("MATCH,") }
        for rule in converted.rules where !rule.hasPrefix("MATCH,") {
            add(rule)
        }
        for reference in converted.ruleSets {
            for rule in ruleSetRules[reference.url] ?? [] {
                add(rule)
            }
        }
        if let final = finalRules.last {
            rules.append(final)
        }
        return rules
    }
}
