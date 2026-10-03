import Foundation

/// 导入的内容是什么格式。
enum ImportFormat: String, Equatable, Codable {
    /// Proxi 的配置描述（JSON），也是 AI 助手生成配置时用的格式。
    case proxi
    /// Proxi 导出的完整备份。
    case backup
    /// Clash / mihomo 的 YAML 配置。
    case clash
    /// Surge / 小火箭的 .conf。
    case surge
    /// Quantumult X 的配置。
    case quantumult
    /// 节点分享链接。
    case links
    /// 纯规则列表。
    case ruleList

    var title: String {
        switch self {
        case .proxi: return L("Proxi 配置")
        case .backup: return L("Proxi 备份")
        case .clash: return L("mihomo 配置")
        case .surge: return L("Surge 格式的配置")
        case .quantumult: return L("Quantumult X 配置")
        case .links: return L("节点链接")
        case .ruleList: return L("规则列表")
        }
    }
}

/// 合并还是替换。
enum ImportMode: String, Codable, CaseIterable, Identifiable {
    /// 加进现有的设置，同名的更新。
    case merge
    /// 导入的内容替换同类的现有设置（没导入的类别不动）。
    case replace

    var id: String { rawValue }

    var title: String {
        switch self {
        case .merge: return L("合并到现有设置")
        case .replace: return L("替换同类设置")
        }
    }
}

/// 导入时要写到本机的文件（Clash 配置里的节点、转换后的规则）。
struct ImportFile: Equatable {
    var name: String
    var content: String
}

/// 一次导入的计划：先给用户（或 AI 助手）预览，确认后再应用。
struct ImportPlan: Equatable {
    var format: ImportFormat
    var sourceName: String
    var subscriptions: [Subscription] = []
    var manualNodes: [ManualNode] = []
    /// 配置里直接写的节点：存成本机文件，当作一条订阅。
    var nodeFile: ImportFile?
    /// 转换好的规则：存成本机文件，当作一个跟随文件策略的规则集。
    var ruleFile: ImportFile?
    var groups: [PolicyGroup] = []
    var ruleSets: [RuleSet] = []
    var customRules: [CustomRule] = []
    var finalPolicy: RuleTarget?
    var mode: EngineMode?
    var dns: DNSSettings?
    var hosts: [HostEntry] = []
    var ipv6: Bool?
    var profiles: [Profile] = []
    var networkRules: [NetworkRule] = []
    var patch: String?
    /// 完整备份：替换时整个换掉。
    var backup: AppConfig?
    var warnings: [String] = []

    init(format: ImportFormat, sourceName: String) {
        self.format = format
        self.sourceName = sourceName
    }

    var isEmpty: Bool {
        backup == nil && subscriptions.isEmpty && manualNodes.isEmpty && nodeFile == nil && ruleFile == nil && groups.isEmpty && ruleSets.isEmpty
            && customRules.isEmpty && finalPolicy == nil && mode == nil && dns == nil && hosts.isEmpty && ipv6 == nil && profiles.isEmpty
            && networkRules.isEmpty && patch == nil
    }

    /// 预览里的一行行说明。
    var summaryLines: [String] {
        if let backup {
            return [L("完整备份：%@ 个代理配置、%@ 条订阅、%@ 个策略组、%@ 个规则集、%@ 条自定义规则", backup.profiles.count, backup.engine.subscriptions.count, backup.engine.groups.count, backup.engine.ruleSets.count, backup.engine.customRules.count)]
        }
        var lines: [String] = []
        if !subscriptions.isEmpty { lines.append(L("订阅：") + subscriptions.map(\.name).joined(separator: L("、"))) }
        if let nodeFile { lines.append(L("节点：%@ 个，存成一条本机订阅", ConfigImporter.countProxies(in: nodeFile.content))) }
        if !manualNodes.isEmpty { lines.append(L("手动节点：%@ 个", manualNodes.count)) }
        if !groups.isEmpty { lines.append(L("策略组：") + groups.map(\.name).joined(separator: L("、"))) }
        if !ruleSets.isEmpty { lines.append(L("规则集：") + ruleSets.map(\.name).joined(separator: L("、"))) }
        if let ruleFile { lines.append(L("分流规则：%@ 条，按文件里的策略走", ConfigImporter.countRules(in: ruleFile.content))) }
        if !customRules.isEmpty { lines.append(L("自定义规则：%@ 条", customRules.count)) }
        if let finalPolicy { lines.append(L("其余流量：%@", finalPolicy.title)) }
        if let mode { lines.append(L("模式：%@", mode.title)) }
        if let dns { lines.append(dns.enabled ? L("DNS：%@", dns.nameservers.joined(separator: L("、"))) : L("DNS：用系统的")) }
        if !hosts.isEmpty { lines.append(L("Hosts：%@ 条", hosts.count)) }
        if let ipv6 { lines.append(L("IPv6：%@", ipv6 ? L("开") : L("关"))) }
        if !profiles.isEmpty { lines.append(L("代理配置：") + profiles.map(\.name).joined(separator: L("、"))) }
        if !networkRules.isEmpty { lines.append(L("按网络自动切换：%@ 条", networkRules.count)) }
        if patch != nil { lines.append(L("内核配置补丁")) }
        return lines
    }
}

/// 应用导入后的结果：新的配置和要写的文件。
struct ImportResult {
    var config: AppConfig
    var files: [(url: URL, content: String)]
    var summary: String
}

enum ImportError: LocalizedError, Equatable {
    case unrecognized
    case empty
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .unrecognized: return L("认不出这是什么配置：支持代理引擎的 JSON、mihomo 的 YAML、Surge / Quantumult X 格式的配置、节点链接和规则列表")
        case .empty: return L("里面没有能导入的内容")
        case .invalid(let text): return text
        }
    }
}

/// 把各种格式的配置变成导入计划，再合并进现有的设置。只做转换，不联网、不写文件（文件由调用方按结果写）。
enum ConfigImporter {
    /// 隐藏了的订阅地址的结尾（控制接口导出配置时用，免得把订阅的令牌交给 AI 助手）。
    static let hiddenURLSuffix = "__hidden__"
    /// 隐藏了的手动节点链接的开头（链接里有密码），后面跟节点名。
    static let hiddenNodePrefix = "hidden://"

    // MARK: - 识别

    static func detect(_ text: String) -> ImportFormat? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("{") {
            guard let data = trimmed.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if json["config"] is [String: Any] && (json["kind"] as? String == "backup" || markers.contains(where: { json[$0] != nil })) { return .backup }
            if json["profiles"] != nil && json["engine"] != nil { return .backup }
            return .proxi
        }
        let lowered = trimmed.lowercased()
        let sections = Set(lowered.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("[") && $0.hasSuffix("]") })
        if !sections.intersection(["[server_local]", "[server_remote]", "[filter_local]", "[filter_remote]", "[policy]"]).isEmpty { return .quantumult }
        if !sections.intersection(["[general]", "[proxy]", "[proxy group]", "[rule]", "[host]"]).isEmpty { return .surge }
        if !NodeLink.extract(trimmed).isEmpty { return .links }
        if let node = try? YAMLParser.parse(trimmed), case .mapping = node {
            let keys = Set(node.keys)
            if !keys.intersection(["proxies", "proxy-groups", "proxy-providers", "rules", "rule-providers", "dns", "mixed-port", "port", "socks-port"]).isEmpty && !keys.contains("payload") {
                return .clash
            }
            if keys.contains("payload") { return .ruleList }
        }
        // 一行一条的规则或域名。
        let converted = RuleConverter.convert(trimmed)
        if !converted.rules.isEmpty && converted.rules.count >= converted.skipped { return .ruleList }
        return nil
    }

    /// 内容看起来是不是一条订阅（节点列表，或者只有节点的 Clash 配置）：从网址导入时默认直接加成订阅，保持自动更新。
    static func looksLikeSubscription(_ text: String) -> Bool {
        switch detect(text) {
        case .links: return true
        case .clash:
            guard let node = try? YAMLParser.parse(text) else { return false }
            return node["proxies"]?.array?.isEmpty == false
        default:
            return false
        }
    }

    // MARK: - 计划

    /// 把内容变成导入计划。sourceURL 是内容来自的网址（从网址导入时），用来把远程配置加成订阅和规则集，保持自动更新。
    static func plan(_ text: String, sourceName: String, sourceURL: String? = nil, existing: AppConfig = AppConfig()) throws -> ImportPlan {
        guard let format = detect(text) else { throw ImportError.unrecognized }
        var plan: ImportPlan
        switch format {
        case .proxi: plan = try planProxi(text, sourceName: sourceName, existing: existing)
        case .backup: plan = try planBackup(text, sourceName: sourceName)
        case .clash: plan = try planClash(text, sourceName: sourceName, sourceURL: sourceURL, existing: existing)
        case .surge: plan = planSurge(text, sourceName: sourceName, sourceURL: sourceURL, existing: existing)
        case .quantumult: plan = planQuantumult(text, sourceName: sourceName, existing: existing)
        case .links:
            plan = ImportPlan(format: .links, sourceName: sourceName)
            if let sourceURL {
                plan.subscriptions = [Subscription(name: subscriptionName(for: sourceURL, fallback: sourceName), url: sourceURL)]
            } else {
                plan.manualNodes = NodeLink.extract(text).map { ManualNode(link: $0) }
            }
        case .ruleList:
            plan = ImportPlan(format: .ruleList, sourceName: sourceName)
            if let sourceURL {
                plan.ruleSets = [RuleSet(name: RuleSet.defaultName(for: sourceURL), url: sourceURL, policy: .proxy)]
            } else {
                plan.ruleFile = ImportFile(name: fileName(sourceName, suffix: L("规则"), extension: "list"), content: text)
            }
        }
        if plan.isEmpty { throw ImportError.empty }
        return plan
    }

    // MARK: Proxi

    /// 配置描述和备份开头的格式标记：proxi，改名前导出的是 proxyswitch。
    static let markers = ["proxi", "proxyswitch"]

    /// Proxi 的配置描述（JSON）。字段都可以省略，写了哪些就导入哪些；格式见 docs/automation.md。
    static func planProxi(_ text: String, sourceName: String, existing: AppConfig) throws -> ImportPlan {
        guard let data = text.data(using: .utf8), let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalid(L("不是正确的 JSON"))
        }
        var plan = ImportPlan(format: .proxi, sourceName: sourceName)
        let knownKeys: Set<String> = Set(markers).union(["mode", "subscriptions", "nodes", "groups", "rules", "ruleSets", "final", "dns", "hosts", "ipv6", "profiles", "networkRules", "patch", "comment", "description"])
        let unknown = json.keys.filter { !knownKeys.contains($0) }.sorted()
        if !unknown.isEmpty {
            plan.warnings.append(L("不认识这些字段，已忽略：%@", unknown.joined(separator: L("、"))))
        }
        if let mode = json["mode"] as? String {
            if let value = EngineMode(rawValue: mode.lowercased()) {
                plan.mode = value
            } else {
                plan.warnings.append(L("模式只能是 rule 或 global"))
            }
        }
        for item in json["subscriptions"] as? [Any] ?? [] {
            var subscription: Subscription
            if let url = item as? String {
                subscription = Subscription(name: subscriptionName(for: url, fallback: L("订阅")), url: url)
            } else if let object = item as? [String: Any], let url = object["url"] as? String {
                subscription = Subscription(name: (object["name"] as? String) ?? subscriptionName(for: url, fallback: L("订阅")), url: url)
                subscription.filter = (object["filter"] as? String) ?? ""
                subscription.exclude = (object["exclude"] as? String) ?? ""
                subscription.prefix = (object["prefix"] as? String) ?? ""
                subscription.dialer = object["dialer"] as? String
                if let enabled = object["enabled"] as? Bool { subscription.enabled = enabled }
            } else {
                plan.warnings.append(L("有一条订阅没有写 url"))
                continue
            }
            if isHidden(url: subscription.url) {
                // 从控制接口导出的描述：地址被隐藏了，用现有的同名订阅的地址（同名的有几个时按顺序对应）。
                guard let original = existing.engine.subscriptions.first(where: { candidate in
                    candidate.name == subscription.name && !plan.subscriptions.contains { $0.url == candidate.url }
                }) else {
                    plan.warnings.append(L("订阅「%@」的地址被隐藏了，现有设置里没有同名的订阅，跳过", subscription.name))
                    continue
                }
                subscription.url = original.url
            }
            if let problem = Subscription.validate(url: subscription.url) ?? Subscription.validateOptions(filter: subscription.filter, exclude: subscription.exclude, prefix: subscription.prefix) {
                plan.warnings.append(L("订阅「%@」：%@", subscription.name, problem))
                continue
            }
            plan.subscriptions.append(subscription)
        }
        for item in json["nodes"] as? [Any] ?? [] {
            guard let link = item as? String else { continue }
            if let name = hiddenNodeName(link) {
                // 隐藏了的节点：用现有的同名手动节点（同名的有几个时按顺序对应）。
                if let original = existing.engine.manualNodes.first(where: { $0.name == name && !plan.manualNodes.contains($0) }) {
                    plan.manualNodes.append(original)
                } else {
                    plan.warnings.append(L("节点「%@」的链接被隐藏了，现有设置里没有同名的手动节点，跳过", name))
                }
                continue
            }
            let links = NodeLink.extract(link)
            if links.isEmpty {
                plan.warnings.append(L("认不出节点链接：%@", String(link.prefix(40))))
            }
            plan.manualNodes += links.map { ManualNode(link: $0) }
        }
        let subscriptionNames = existing.engine.subscriptions + plan.subscriptions
        var groupNames = Set(existing.engine.groupNames)
        for item in json["groups"] as? [[String: Any]] ?? [] {
            guard let rawName = item["name"] as? String else {
                plan.warnings.append(L("有一个策略组没有写 name"))
                continue
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            // 名字和筛选要和设置页里一样校验（只和这次导入的别的组比，和现有的同名是要合并）：
            // 叫「节点」「DIRECT」、带逗号、重名或者筛选不是正则的话，生成的内核配置通不过，内核起不来。
            if let problem = PolicyGroup.validate(name: name, filter: (item["filter"] as? String) ?? "", others: plan.groups) {
                plan.warnings.append(L("策略组「%@」没有导入：%@", rawName, problem))
                continue
            }
            groupNames.insert(name)
            var group = PolicyGroup(name: name, kind: groupKind(item["type"] as? String) ?? .select, filter: (item["filter"] as? String) ?? "")
            group.exclude = (item["exclude"] as? String) ?? ""
            group.includeGroups = (item["groups"] as? [String]) ?? []
            if let sources = item["subscriptions"] as? [String] {
                group.sources = sources.compactMap { name in
                    if name == "手动节点" || name == L("手动节点") || name == "manual" { return ManualNode.sourceID }  // l10n-ignore：中文和界面语言的写法都认
                    return subscriptionNames.first { $0.name == name || $0.url == name }?.id
                }
            }
            group.testURL = (item["url"] as? String) ?? ""
            group.interval = (item["interval"] as? Int) ?? 0
            group.tolerance = (item["tolerance"] as? Int) ?? 0
            if let strategy = item["strategy"] as? String {
                group.strategy = loadBalanceStrategy(strategy)
            }
            plan.groups.append(group)
        }
        let allGroups = Array(groupNames)
        for item in json["rules"] as? [Any] ?? [] {
            if let line = item as? String {
                if let rule = customRule(fromLine: line, groups: allGroups) {
                    plan.customRules.append(rule)
                } else {
                    plan.warnings.append(L("认不出规则：%@", line))
                }
                continue
            }
            guard let object = item as? [String: Any], let value = (object["value"] ?? object["pattern"]) as? String else {
                plan.warnings.append(L("有一条规则没有写 value"))
                continue
            }
            let kind = ruleKind(object["type"] as? String) ?? .auto
            let policy = target((object["policy"] as? String) ?? "proxy", groups: allGroups)
            if let problem = CustomRule.validate(value, kind: kind) {
                plan.warnings.append(L("规则「%@」：%@", value, problem))
                continue
            }
            var rule = CustomRule(pattern: value, policy: policy, kind: kind)
            if let enabled = object["enabled"] as? Bool { rule.enabled = enabled }
            plan.customRules.append(rule)
        }
        for item in json["ruleSets"] as? [Any] ?? [] {
            if let object = item as? [String: Any] {
                if let libraryName = object["library"] as? String {
                    guard let entry = RuleLibrary.entry(named: libraryName) else {
                        plan.warnings.append(L("规则库里没有「%@」", libraryName))
                        continue
                    }
                    let policy = (object["policy"] as? String).map { target($0, groups: allGroups) } ?? entry.policy
                    plan.ruleSets.append(RuleSet(name: entry.name, url: entry.url, policy: policy, behavior: entry.behavior))
                    continue
                }
                guard var url = object["url"] as? String else {
                    plan.warnings.append(L("有一个规则集没有写 url"))
                    continue
                }
                if isHidden(url: url) {
                    let name = (object["name"] as? String) ?? ""
                    guard let original = existing.engine.ruleSets.first(where: { candidate in
                        candidate.name == name && !plan.ruleSets.contains { $0.url == candidate.url }
                    }) else {
                        plan.warnings.append(L("规则集「%@」的地址被隐藏了，现有设置里没有同名的规则集，跳过", name))
                        continue
                    }
                    url = original.url
                }
                if let problem = RuleSet.validate(url: url) {
                    plan.warnings.append(L("规则集 %@：%@", url, problem))
                    continue
                }
                let policy = (object["policy"] as? String).map { target($0, groups: allGroups) }
                let name = (object["name"] as? String) ?? RuleSet.defaultName(for: url)
                plan.ruleSets.append(RuleSet(name: name, url: url, policy: policy ?? (RuleSet(name: "", url: url, policy: nil).kind == .inline ? nil : .proxy)))
            } else if let url = item as? String {
                if isHidden(url: url) {
                    plan.warnings.append(L("有一个规则集的地址被隐藏了，又没有写名字，跳过"))
                    continue
                }
                plan.ruleSets.append(RuleSet(name: RuleSet.defaultName(for: url), url: url, policy: .proxy))
            }
        }
        if let final = json["final"] as? String {
            plan.finalPolicy = target(final, groups: allGroups)
        }
        if let dns = json["dns"] as? [String: Any] {
            var settings = existing.engine.dns
            settings.enabled = (dns["enabled"] as? Bool) ?? true
            if let servers = stringList(dns["nameservers"] ?? dns["nameserver"]) { settings.nameservers = servers }
            if let servers = stringList(dns["fallback"]) { settings.fallback = servers }
            if let via = dns["fallbackViaProxy"] as? Bool { settings.fallbackViaProxy = via }
            if let servers = stringList(dns["bootstrap"]) { settings.bootstrap = servers }
            if let policies = dns["policies"] as? [String: Any] {
                settings.policies = policies.keys.sorted().compactMap { domain in
                    stringList(policies[domain]).map { DNSPolicy(domain: domain, servers: $0) }
                }
            }
            if let problem = settings.validate() {
                plan.warnings.append(L("DNS：%@，没有导入", problem))
            } else {
                plan.dns = settings
            }
        }
        if let hosts = json["hosts"] as? [String: Any] {
            for domain in hosts.keys.sorted() {
                guard let values = stringList(hosts[domain]) else { continue }
                let entry = HostEntry(domain: domain, value: values.joined(separator: ", "))
                if let problem = entry.validate() {
                    plan.warnings.append(L("Hosts：%@", problem))
                } else {
                    plan.hosts.append(entry)
                }
            }
        }
        if let ipv6 = json["ipv6"] as? Bool { plan.ipv6 = ipv6 }
        let profileNames = existing.profiles
        for item in json["profiles"] as? [[String: Any]] ?? [] {
            guard let name = item["name"] as? String else { continue }
            var profile = Profile(name: name, color: ProfilePalette.color(at: profileNames.count + plan.profiles.count))
            let type = ((item["type"] as? String) ?? "http").lowercased()
            profile.kind = type.hasPrefix("socks") ? .socks5 : (type == "pac" ? .pac : .http)
            profile.host = (item["host"] as? String) ?? profile.host
            profile.port = (item["port"] as? Int) ?? profile.port
            profile.pacURL = (item["pac"] as? String) ?? ""
            if let bypass = item["bypass"] as? String { profile.bypass = bypass }
            if let targets = item["targets"] as? [String] {
                let parsed = Set(targets.compactMap { ProxyTarget(rawValue: $0) })
                if !parsed.isEmpty { profile.targets = parsed }
            }
            if let problem = profile.validate() {
                plan.warnings.append(L("代理配置「%@」：%@", name, problem))
                continue
            }
            plan.profiles.append(profile)
        }
        let knownProfiles = existing.profiles + plan.profiles
        for item in json["networkRules"] as? [[String: Any]] ?? [] {
            let match: NetworkRule.Match
            if let ssid = item["ssid"] as? String {
                match = .ssid(ssid)
            } else if let router = item["router"] as? String {
                match = .router(router)
            } else if item["other"] as? Bool == true {
                match = .other
            } else {
                plan.warnings.append(L("按网络切换的规则要写 ssid、router 或 other"))
                continue
            }
            let actionText = (item["action"] as? String) ?? ""
            var action: NetworkRule.Action?
            if actionText == "off" {
                action = .off
            } else if actionText.hasPrefix("mode:"), let mode = EngineMode(rawValue: String(actionText.dropFirst(5))) {
                action = .mode(mode)
            } else if actionText.hasPrefix("profile:") {
                let name = String(actionText.dropFirst(8))
                action = knownProfiles.first { $0.name == name || $0.id.uuidString == name }.map { .profile($0.id) }
            }
            guard let action else {
                plan.warnings.append(L("按网络切换：认不出动作「%@」（off、mode:rule、mode:global、profile:配置名）", actionText))
                continue
            }
            plan.networkRules.append(NetworkRule(match: match, action: action))
        }
        if let patch = json["patch"] as? String {
            plan.patch = patch
        }
        return plan
    }

    static func planBackup(_ text: String, sourceName: String) throws -> ImportPlan {
        guard let data = text.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.invalid(L("不是正确的 JSON"))
        }
        let configObject = (json["config"] as? [String: Any]) ?? json
        let configData = try JSONSerialization.data(withJSONObject: configObject)
        let config: AppConfig
        do {
            config = try JSONDecoder().decode(AppConfig.self, from: configData)
        } catch {
            throw ImportError.invalid(L("备份读不出来：%@", error.localizedDescription))
        }
        var plan = ImportPlan(format: .backup, sourceName: sourceName)
        plan.backup = config
        return plan
    }

    // MARK: Clash

    static func planClash(_ text: String, sourceName: String, sourceURL: String?, existing: AppConfig) throws -> ImportPlan {
        let root: YAMLNode
        do {
            root = try YAMLParser.parse(text)
        } catch {
            throw ImportError.invalid(L("YAML 有问题：%@", error.localizedDescription))
        }
        var plan = ImportPlan(format: .clash, sourceName: sourceName)
        // 节点：来自网址的配置直接加成订阅（内核能读 Clash 配置里的节点，会自动更新）；粘贴的存成本机文件。
        let proxies = root["proxies"]?.array ?? []
        if !proxies.isEmpty {
            if let sourceURL {
                plan.subscriptions.append(Subscription(name: subscriptionName(for: sourceURL, fallback: sourceName), url: sourceURL))
            } else {
                plan.nodeFile = ImportFile(name: fileName(sourceName, suffix: L("节点"), extension: "yaml"), content: YAMLWriter.write(.mapping([YAMLPair(key: "proxies", value: .sequence(proxies))])))
            }
        }
        // 节点来源（proxy-providers）：网络上的加成订阅。
        var providerIDs: [String: UUID] = [:]
        for pair in root["proxy-providers"]?.pairs ?? [] {
            let provider = pair.value
            guard provider["type"]?.string?.lowercased() != "file", let url = provider["url"]?.string, Subscription.validate(url: url) == nil else {
                plan.warnings.append(L("节点来源「%@」不是网络订阅，没有导入", pair.key))
                continue
            }
            var subscription = Subscription(name: pair.key, url: url)
            subscription.filter = provider["filter"]?.string ?? ""
            subscription.exclude = provider["exclude-filter"]?.string ?? ""
            subscription.prefix = provider["override"]?["additional-prefix"]?.string ?? ""
            if Subscription.validateOptions(filter: subscription.filter, exclude: subscription.exclude, prefix: subscription.prefix) != nil {
                subscription.filter = ""
                subscription.exclude = ""
                subscription.prefix = ""
                plan.warnings.append(L("节点来源「%@」的筛选写法不支持，已去掉", pair.key))
            }
            providerIDs[pair.key] = subscription.id
            plan.subscriptions.append(subscription)
        }
        // 策略组：名字按规则整理，成员里的节点名变成筛选。
        let rawGroups = root["proxy-groups"]?.array ?? []
        var renames = groupRenames(rawGroups.compactMap { $0["name"]?.string })
        // 第一个成员（默认用的那个）就是直连或拦截的组（「全球直连」「广告拦截」这类）：不建成组，用到它的规则直接直连、拦截。
        // 建成组的话默认跟随「节点」，这些流量反而走了代理，拦截也选不到。
        var builtinGroups: [String: String] = [:]
        for raw in rawGroups {
            guard let original = raw["name"]?.string, let first = raw["proxies"]?.stringArray?.first?.uppercased() else { continue }
            if first == "DIRECT" {
                builtinGroups[original] = "DIRECT"
            } else if first == "REJECT" || first == "REJECT-DROP" {
                builtinGroups[original] = "REJECT"
            }
        }
        let groupNames = Set(renames.filter { builtinGroups[$0.key] == nil }.values)
        for (original, target) in builtinGroups {
            renames[original] = target
        }
        if !builtinGroups.isEmpty {
            plan.warnings.append(L("这些策略组默认就是直连或拦截，没有建成组，用到它们的规则直接直连或拦截：%@", builtinGroups.keys.sorted().joined(separator: L("、"))))
        }
        for raw in rawGroups {
            guard let original = raw["name"]?.string, builtinGroups[original] == nil, let name = renames[original] else { continue }
            guard let kind = clashGroupKind(raw["type"]?.string) else {
                plan.warnings.append(L("策略组「%@」的类型 %@ 不支持，没有导入", original, raw["type"]?.string ?? "?"))
                continue
            }
            var group = PolicyGroup(name: name, kind: kind)
            var nodes: [String] = []
            for member in raw["proxies"]?.stringArray ?? [] {
                if let renamed = renames[member], groupNames.contains(renamed) {
                    group.includeGroups.append(renamed)
                } else if ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "COMPATIBLE"].contains(member.uppercased()) {
                    continue
                } else if !member.isEmpty {
                    nodes.append(member)
                }
            }
            let includeAll = raw["include-all"]?.bool == true || raw["include-all-proxies"]?.bool == true || raw["include-all-providers"]?.bool == true
            if let filter = raw["filter"]?.string, PolicyGroup.validateFilter(filter) == nil {
                group.filter = filter
            } else if !nodes.isEmpty && !includeAll {
                group.filter = exactNamesFilter(nodes)
            } else if raw["use"] == nil && !includeAll {
                // 只有别的组（或者只有直连、拦截）、没有节点：筛选一个不会匹配的名字，免得把全部节点都放进来。
                group.filter = "^$"
            }
            if let exclude = raw["exclude-filter"]?.string, PolicyGroup.validateFilter(exclude) == nil {
                group.exclude = exclude
            }
            if let uses = raw["use"]?.stringArray {
                group.sources = uses.compactMap { providerIDs[$0] }
            }
            group.testURL = validTestURL(raw["url"]?.string)
            group.interval = min(86400, max(0, raw["interval"]?.int ?? 0))
            if group.interval != 0 && group.interval < 30 { group.interval = 30 }
            group.tolerance = min(5000, max(0, raw["tolerance"]?.int ?? 0))
            if let strategy = raw["strategy"]?.string { group.strategy = loadBalanceStrategy(strategy) }
            plan.groups.append(group)
        }
        // 去掉指向没导入的组的包含关系，再查一遍互相包含。
        let importedNames = Set(plan.groups.map(\.name))
        for index in plan.groups.indices {
            plan.groups[index].includeGroups = plan.groups[index].includeGroups.filter { importedNames.contains($0) && $0 != plan.groups[index].name }
        }
        if let cycle = PolicyGroup.cycle(in: plan.groups) {
            plan.warnings.append(L("策略组互相包含（%@），去掉了包含关系", cycle.joined(separator: " → ")))
            for index in plan.groups.indices { plan.groups[index].includeGroups = [] }
        }
        // 规则：写成本机的规则文件（来自网址时直接用网址），按文件里的策略走，FINAL 也跟着文件。
        let rules = root["rules"]?.stringArray ?? []
        if !rules.isEmpty {
            let providers = root["rule-providers"]
            var lines: [String] = []
            var dropped: [String] = []
            var mrs: [RuleSet] = []
            for rule in rules {
                let fields = rule.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                let type = fields.first?.uppercased() ?? ""
                if type == "RULE-SET", fields.count >= 3 {
                    let policy = renames[fields[2]] ?? fields[2]
                    guard let provider = providers?[fields[1]] else {
                        dropped.append(rule)
                        continue
                    }
                    let behavior = RuleSetBehavior(rawValue: provider["behavior"]?.string?.lowercased() ?? "") ?? .classical
                    if provider["type"]?.string == "inline", let payload = provider["payload"]?.stringArray {
                        lines += payload.compactMap { inlineProviderRule($0, behavior: behavior, policy: policy) }
                    } else if let url = provider["url"]?.string, RuleSet.validate(url: url) == nil {
                        if provider["format"]?.string == "mrs" || url.lowercased().hasSuffix(".mrs") {
                            mrs.append(RuleSet(name: fields[1], url: url, policy: target(policy, groups: Array(groupNames)), behavior: behavior))
                        } else {
                            lines.append("RULE-SET,\(url),\(policy)")
                        }
                    } else {
                        dropped.append(rule)
                    }
                    continue
                }
                if ["GEOSITE", "SUB-RULE", "IN-TYPE", "IN-USER", "IN-NAME", "UID", "DSCP", "SRC-GEOIP", "IP-ASN", "SRC-IP-ASN"].contains(type) {
                    dropped.append(rule)
                    continue
                }
                lines.append(rewritePolicy(rule, renames: renames))
            }
            if !dropped.isEmpty {
                plan.warnings.append(L("%@ 条规则没有导入（GEOSITE、SUB-RULE 等，或者引用的规则集不是网络上的）：%@%@", dropped.count, dropped.prefix(3).joined(separator: L("；")), dropped.count > 3 ? L("…") : ""))
            }
            if !mrs.isEmpty {
                plan.warnings.append(L("%@ 个 .mrs 规则集单独加进了规则集列表，排在导入的规则前面", mrs.count))
                plan.ruleSets += mrs
            }
            if let sourceURL, lines == rules.map({ $0.trimmingCharacters(in: .whitespaces) }) {
                // 规则原样可用（一条都没改写：没有展开规则集、没有改组名）：直接用远程配置当规则集，跟着它更新。
                var set = RuleSet(name: L("%@ 的规则", subscriptionName(for: sourceURL, fallback: sourceName)), url: sourceURL, policy: nil)
                set.converted = true
                plan.ruleSets.append(set)
            } else if !lines.isEmpty {
                let content = YAMLWriter.write(.mapping([YAMLPair(key: "rules", value: .strings(lines))]))
                plan.ruleFile = ImportFile(name: fileName(sourceName, suffix: L("规则"), extension: "yaml"), content: content)
            }
        }
        if let dns = root["dns"] {
            plan.dns = clashDNS(dns, base: existing.engine.dns, warnings: &plan.warnings)
        }
        for pair in root["hosts"]?.pairs ?? [] {
            guard let values = pair.value.stringArray else { continue }
            let entry = HostEntry(domain: pair.key, value: values.joined(separator: ", "))
            if entry.validate() == nil { plan.hosts.append(entry) }
        }
        if let ipv6 = root["ipv6"]?.bool { plan.ipv6 = ipv6 }
        if let mode = root["mode"]?.string?.lowercased() {
            if let value = EngineMode(rawValue: mode) { plan.mode = value } else if mode == "direct" { plan.warnings.append(L("直连模式没有导入：想直连就关掉代理")) }
        }
        let ignored = ["port", "socks-port", "mixed-port", "redir-port", "tproxy-port", "tun", "external-controller", "listeners", "sniffer", "profile", "sub-rules"].filter { root[$0] != nil }
        if !ignored.isEmpty {
            plan.warnings.append(L("这些设置由 Proxi 管理，没有导入：%@", ignored.joined(separator: L("、"))))
        }
        return plan
    }

    /// Clash 的 DNS 设置。
    static func clashDNS(_ dns: YAMLNode, base: DNSSettings, warnings: inout [String]) -> DNSSettings? {
        var settings = base
        settings.enabled = dns["enable"]?.bool ?? true
        if let servers = dns["nameserver"]?.stringArray, !servers.isEmpty { settings.nameservers = servers }
        if let fallback = dns["fallback"]?.stringArray {
            settings.fallbackViaProxy = fallback.contains { $0.contains("#") }
            settings.fallback = fallback.map { $0.split(separator: "#").first.map(String.init) ?? $0 }
        }
        if let bootstrap = dns["default-nameserver"]?.stringArray?.filter({ IPPrefix.isIPv4Address(DNSSettings.plainHost($0)) || IPPrefix.isIPv6Address(DNSSettings.plainHost($0)) }), !bootstrap.isEmpty {
            settings.bootstrap = bootstrap
        }
        var policies: [DNSPolicy] = []
        for pair in dns["nameserver-policy"]?.pairs ?? [] where !pair.key.contains(":") {
            guard let servers = pair.value.stringArray else { continue }
            for domain in pair.key.split(separator: ",") {
                policies.append(DNSPolicy(domain: String(domain), servers: servers))
            }
        }
        settings.policies = policies.filter { $0.validate() == nil }
        if dns["enhanced-mode"]?.string == "fake-ip" {
            warnings.append(L("fake-ip 模式没有导入：Proxi 走系统代理，用不上"))
        }
        if let problem = settings.validate() {
            warnings.append(L("DNS：%@，没有导入", problem))
            return nil
        }
        return settings
    }

    /// inline 规则集里的一条变成完整规则。
    static func inlineProviderRule(_ entry: String, behavior: RuleSetBehavior, policy: String) -> String? {
        let value = entry.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        switch behavior {
        case .classical:
            let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2 else { return nil }
            let options = fields.dropFirst(2).filter { $0.lowercased() == "no-resolve" }
            return ([fields[0], fields[1], policy] + options).joined(separator: ",")
        case .domain:
            if value.hasPrefix("+.") { return "DOMAIN-SUFFIX,\(value.dropFirst(2)),\(policy)" }
            if value.hasPrefix(".") { return "DOMAIN-SUFFIX,\(value.dropFirst()),\(policy)" }
            return "DOMAIN,\(value),\(policy)"
        case .ipcidr:
            guard let prefix = IPPrefix.normalize(value) else { return nil }
            return "\(prefix.contains(":") ? "IP-CIDR6" : "IP-CIDR"),\(prefix),\(policy),no-resolve"
        }
    }

    /// 规则行里的策略名换成改过的组名。
    static func rewritePolicy(_ rule: String, renames: [String: String]) -> String {
        let trimmed = rule.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("AND,") || upper.hasPrefix("OR,") || upper.hasPrefix("NOT,") {
            guard let close = trimmed.lastIndex(of: ")") else { return trimmed }
            let head = trimmed[...close]
            var tail = trimmed[trimmed.index(after: close)...].split(separator: ",", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
            if let first = tail.first, let renamed = renames[first] { tail[0] = renamed }
            return ([String(head)] + tail).joined(separator: ",")
        }
        var fields = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let index = ["MATCH", "FINAL"].contains(fields.first?.uppercased() ?? "") ? 1 : 2
        if fields.count > index, let renamed = renames[fields[index]] {
            fields[index] = renamed
        }
        return fields.joined(separator: ",")
    }

    // MARK: Surge / 小火箭

    static func planSurge(_ text: String, sourceName: String, sourceURL: String?, existing: AppConfig) -> ImportPlan {
        var plan = ImportPlan(format: .surge, sourceName: sourceName)
        let sections = iniSections(text)
        // [General]：DNS 和 IPv6。
        let general = keyValues(sections["general"] ?? [])
        var servers: [String] = []
        if let encrypted = general["encrypted-dns-server"] {
            servers += DNSSettings.parseList(encrypted)
        }
        if let plain = general["dns-server"] {
            servers += DNSSettings.parseList(plain).filter { $0 != "system" }
        }
        if !servers.isEmpty {
            var dns = existing.engine.dns
            dns.enabled = true
            dns.nameservers = servers.filter { DNSSettings.validateServer($0) == nil }
            if dns.validate() == nil { plan.dns = dns }
        }
        if let ipv6 = general["ipv6"] { plan.ipv6 = ["true", "yes", "1", "on"].contains(ipv6.lowercased()) }
        // [Proxy]：认得出的协议转成节点。
        var proxies: [YAMLNode] = []
        var skipped: [String] = []
        for line in sections["proxy"] ?? [] {
            guard let (name, value) = splitAssignment(line) else { continue }
            if let node = surgeProxy(name: name, value) {
                proxies.append(node)
            } else if !["direct", "reject", "reject-tinygif", "reject-drop"].contains(value.split(separator: ",").first?.trimmingCharacters(in: .whitespaces).lowercased() ?? "") {
                skipped.append(name)
            }
        }
        if !proxies.isEmpty {
            plan.nodeFile = ImportFile(name: fileName(sourceName, suffix: L("节点"), extension: "yaml"), content: YAMLWriter.write(.mapping([YAMLPair(key: "proxies", value: .sequence(proxies))])))
        }
        if !skipped.isEmpty {
            plan.warnings.append(L("%@ 个节点的协议不支持，没有导入：%@%@", skipped.count, skipped.prefix(3).joined(separator: L("、")), skipped.count > 3 ? L("…") : ""))
        }
        let proxyNames = Set(proxies.compactMap { $0["name"]?.string })
        // [Proxy Group]。
        let groupLines = (sections["proxy group"] ?? []).compactMap(splitAssignment)
        let renames = groupRenames(groupLines.map(\.0))
        let groupNames = Set(renames.values)
        for (original, value) in groupLines {
            guard let name = renames[original] else { continue }
            let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let type = fields.first, let kind = surgeGroupKind(type) else {
                plan.warnings.append(L("策略组「%@」的类型不支持，没有导入", original))
                continue
            }
            var group = PolicyGroup(name: name, kind: kind)
            var nodes: [String] = []
            var hasPolicyPath = false
            for field in fields.dropFirst() {
                if let (key, option) = splitAssignment(field) {
                    switch key.lowercased() {
                    case "policy-regex-filter": if PolicyGroup.validateFilter(option) == nil { group.filter = option }
                    case "url": group.testURL = validTestURL(option)
                    case "interval": group.interval = min(86400, max(30, Int(option) ?? 0))
                    case "tolerance": group.tolerance = min(5000, max(0, Int(option) ?? 0))
                    case "policy-path": hasPolicyPath = true
                    default: break
                    }
                    continue
                }
                if let renamed = renames[field], groupNames.contains(renamed) {
                    group.includeGroups.append(renamed)
                } else if ["DIRECT", "REJECT"].contains(field.uppercased()) {
                    continue
                } else {
                    nodes.append(field)
                }
            }
            if hasPolicyPath {
                plan.warnings.append(L("策略组「%@」用了 policy-path（外部节点列表），这部分没有导入", original))
            }
            if group.filter.isEmpty && !nodes.isEmpty {
                group.filter = exactNamesFilter(nodes)
                if !nodes.allSatisfy(proxyNames.contains) && proxyNames.isEmpty == false {
                    plan.warnings.append(L("策略组「%@」里有的节点不在配置里，按名字筛选", original))
                }
            }
            plan.groups.append(group)
        }
        let importedNames = Set(plan.groups.map(\.name))
        for index in plan.groups.indices {
            plan.groups[index].includeGroups = plan.groups[index].includeGroups.filter { importedNames.contains($0) && $0 != plan.groups[index].name }
        }
        if PolicyGroup.cycle(in: plan.groups) != nil {
            for index in plan.groups.indices { plan.groups[index].includeGroups = [] }
        }
        // [Rule]：来自网址时直接当规则集（跟着更新）；粘贴的存成本机文件。规则里的组名改过的换掉。
        if let rules = sections["rule"], !rules.isEmpty {
            let changed = renames.contains { $0.key != $0.value }
            if let sourceURL, !changed {
                plan.ruleSets.append(RuleSet(name: L("%@ 的规则", subscriptionName(for: sourceURL, fallback: sourceName)), url: sourceURL, policy: nil))
            } else {
                let body = rules.map { rewritePolicy($0, renames: renames) }.joined(separator: "\n")
                plan.ruleFile = ImportFile(name: fileName(sourceName, suffix: L("规则"), extension: "conf"), content: "[Rule]\n" + body + "\n")
            }
        }
        // [Host]。
        for (domain, value) in (sections["host"] ?? []).compactMap(splitAssignment) {
            let entry = HostEntry(domain: domain, value: value)
            if entry.validate() == nil { plan.hosts.append(entry) }
        }
        let ignored = ["url rewrite", "header rewrite", "mitm", "script", "map local", "body rewrite"].filter { sections[$0] != nil }
        if !ignored.isEmpty {
            plan.warnings.append(L("这些段没有导入（Proxi 不做改写和脚本）：%@", ignored.map { "[\($0)]" }.joined(separator: L("、"))))
        }
        return plan
    }

    /// Surge 的一行节点变成内核（Clash 格式）的节点；不支持的协议返回 nil。
    static func surgeProxy(name: String, _ value: String) -> YAMLNode? {
        let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 3, let port = Int(fields[2]) else { return nil }
        let type = fields[0].lowercased()
        let server = fields[1]
        var options: [String: String] = [:]
        var positional: [String] = []
        for field in fields.dropFirst(3) {
            if let (key, option) = splitAssignment(field) {
                options[key.lowercased()] = option
            } else {
                positional.append(field)
            }
        }
        func flag(_ key: String) -> Bool { ["true", "1", "yes", "on"].contains(options[key]?.lowercased() ?? "") }
        var pairs: [YAMLPair] = [
            YAMLPair(key: "name", value: .string(name)),
            YAMLPair(key: "server", value: .string(server)),
            YAMLPair(key: "port", value: .int(port)),
        ]
        func add(_ key: String, _ node: YAMLNode) { pairs.append(YAMLPair(key: key, value: node)) }
        switch type {
        case "ss", "shadowsocks":
            guard let cipher = options["encrypt-method"], let password = options["password"] else { return nil }
            pairs.insert(YAMLPair(key: "type", value: .plain("ss")), at: 1)
            add("cipher", .string(cipher))
            add("password", .string(password))
            if flag("udp-relay") { add("udp", .bool(true)) }
            if let obfs = options["obfs"] {
                add("plugin", .plain("obfs"))
                var opts = [YAMLPair(key: "mode", value: .string(obfs))]
                if let host = options["obfs-host"] { opts.append(YAMLPair(key: "host", value: .string(host))) }
                add("plugin-opts", .mapping(opts))
            }
        case "vmess":
            guard let uuid = options["username"] else { return nil }
            pairs.insert(YAMLPair(key: "type", value: .plain("vmess")), at: 1)
            add("uuid", .string(uuid))
            add("alterId", .int(0))
            add("cipher", .plain("auto"))
            if flag("tls") { add("tls", .bool(true)) }
            if let sni = options["sni"] { add("servername", .string(sni)) }
            if flag("skip-cert-verify") { add("skip-cert-verify", .bool(true)) }
            appendWebSocket(options, flag: flag("ws"), into: &pairs)
        case "trojan":
            guard let password = options["password"] else { return nil }
            pairs.insert(YAMLPair(key: "type", value: .plain("trojan")), at: 1)
            add("password", .string(password))
            if let sni = options["sni"] { add("sni", .string(sni)) }
            if flag("skip-cert-verify") { add("skip-cert-verify", .bool(true)) }
            if flag("udp-relay") { add("udp", .bool(true)) }
            appendWebSocket(options, flag: flag("ws"), into: &pairs)
        case "http", "https":
            pairs.insert(YAMLPair(key: "type", value: .plain("http")), at: 1)
            if let user = options["username"] ?? positional.first { add("username", .string(user)) }
            if let pass = options["password"] ?? (positional.count > 1 ? positional[1] : nil) { add("password", .string(pass)) }
            if type == "https" { add("tls", .bool(true)) }
            if let sni = options["sni"] { add("sni", .string(sni)) }
        case "socks5", "socks5-tls":
            pairs.insert(YAMLPair(key: "type", value: .plain("socks5")), at: 1)
            if let user = options["username"] ?? positional.first { add("username", .string(user)) }
            if let pass = options["password"] ?? (positional.count > 1 ? positional[1] : nil) { add("password", .string(pass)) }
            if type == "socks5-tls" { add("tls", .bool(true)) }
            if flag("udp-relay") { add("udp", .bool(true)) }
        case "hysteria2", "hy2":
            guard let password = options["password"] else { return nil }
            pairs.insert(YAMLPair(key: "type", value: .plain("hysteria2")), at: 1)
            add("password", .string(password))
            if let sni = options["sni"] { add("sni", .string(sni)) }
            if flag("skip-cert-verify") { add("skip-cert-verify", .bool(true)) }
            if let down = options["download-bandwidth"] { add("down", .string("\(down) Mbps")) }
        case "snell":
            guard let psk = options["psk"] else { return nil }
            pairs.insert(YAMLPair(key: "type", value: .plain("snell")), at: 1)
            add("psk", .string(psk))
            if let version = options["version"], let number = Int(version) { add("version", .int(number)) }
            if let obfs = options["obfs"] {
                var opts = [YAMLPair(key: "mode", value: .string(obfs))]
                if let host = options["obfs-host"] { opts.append(YAMLPair(key: "host", value: .string(host))) }
                add("obfs-opts", .mapping(opts))
            }
        case "tuic", "tuic-v5":
            guard let uuid = options["uuid"], let password = options["password"] else { return nil }
            pairs.insert(YAMLPair(key: "type", value: .plain("tuic")), at: 1)
            add("uuid", .string(uuid))
            add("password", .string(password))
            if let sni = options["sni"] { add("sni", .string(sni)) }
            if let alpn = options["alpn"] { add("alpn", .strings(alpn.split(separator: ";").map(String.init))) }
            if flag("skip-cert-verify") { add("skip-cert-verify", .bool(true)) }
        default:
            return nil
        }
        return .mapping(pairs)
    }

    private static func appendWebSocket(_ options: [String: String], flag: Bool, into pairs: inout [YAMLPair]) {
        guard flag else { return }
        pairs.append(YAMLPair(key: "network", value: .plain("ws")))
        var opts: [YAMLPair] = []
        if let path = options["ws-path"] { opts.append(YAMLPair(key: "path", value: .string(path))) }
        if let headers = options["ws-headers"] {
            var values: [YAMLPair] = []
            for header in headers.split(separator: "|") {
                let parts = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { values.append(YAMLPair(key: parts[0], value: .string(parts[1]))) }
            }
            if !values.isEmpty { opts.append(YAMLPair(key: "headers", value: .mapping(values))) }
        }
        if !opts.isEmpty { pairs.append(YAMLPair(key: "ws-opts", value: .mapping(opts))) }
    }

    // MARK: Quantumult X

    static func planQuantumult(_ text: String, sourceName: String, existing: AppConfig) -> ImportPlan {
        var plan = ImportPlan(format: .quantumult, sourceName: sourceName)
        let sections = iniSections(text)
        // [dns]：server=、doh-server=，server=/域名/服务器 是按域名指定。
        var servers: [String] = []
        var policies: [DNSPolicy] = []
        for line in sections["dns"] ?? [] {
            guard let (key, value) = splitAssignment(line) else { continue }
            switch key.lowercased() {
            case "server":
                if value.hasPrefix("/") {
                    let parts = value.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                    if parts.count == 2 { policies.append(DNSPolicy(domain: parts[0].replacingOccurrences(of: "*.", with: "+."), servers: [parts[1]])) }
                } else if value != "system" {
                    servers.append(value)
                }
            case "doh-server":
                servers.insert(contentsOf: DNSSettings.parseList(value), at: 0)
            default: break
            }
        }
        if !servers.isEmpty || !policies.isEmpty {
            var dns = existing.engine.dns
            dns.enabled = true
            let valid = servers.filter { DNSSettings.validateServer($0) == nil }
            if !valid.isEmpty { dns.nameservers = valid }
            dns.policies = policies.filter { $0.validate() == nil }
            if dns.validate() == nil { plan.dns = dns }
        }
        // [server_remote]：订阅。
        for line in sections["server_remote"] ?? [] {
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let url = fields.first, Subscription.validate(url: url) == nil else { continue }
            let options = keyValues(Array(fields.dropFirst()))
            var subscription = Subscription(name: options["tag"] ?? subscriptionName(for: url, fallback: L("订阅")), url: url)
            if options["enabled"]?.lowercased() == "false" { subscription.enabled = false }
            plan.subscriptions.append(subscription)
        }
        // [server_local]：常见协议转成节点。
        var proxies: [YAMLNode] = []
        var skipped = 0
        for line in sections["server_local"] ?? [] {
            if let node = quantumultProxy(line) { proxies.append(node) } else { skipped += 1 }
        }
        if !proxies.isEmpty {
            plan.nodeFile = ImportFile(name: fileName(sourceName, suffix: L("节点"), extension: "yaml"), content: YAMLWriter.write(.mapping([YAMLPair(key: "proxies", value: .sequence(proxies))])))
        }
        if skipped > 0 {
            plan.warnings.append(L("%@ 个节点的协议不支持，没有导入", skipped))
        }
        // [policy]：策略组。
        let policyLines = (sections["policy"] ?? []).compactMap { line -> (String, String, [String])? in
            guard let (type, value) = splitAssignment(line) else { return nil }
            let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = fields.first else { return nil }
            return (type.lowercased(), name, Array(fields.dropFirst()))
        }
        let renames = groupRenames(policyLines.map(\.1))
        let groupNames = Set(renames.values)
        for (type, original, fields) in policyLines {
            guard let name = renames[original] else { continue }
            let kind: PolicyGroupKind
            var strategy = LoadBalanceStrategy.roundRobin
            switch type {
            case "static": kind = .select
            case "url-latency-benchmark": kind = .urlTest
            case "available": kind = .fallback
            case "round-robin": kind = .loadBalance
            case "dest-hash": kind = .loadBalance; strategy = .consistentHashing
            default:
                plan.warnings.append(L("策略组「%@」的类型 %@ 不支持，没有导入", original, type))
                continue
            }
            var group = PolicyGroup(name: name, kind: kind)
            group.strategy = strategy
            var nodes: [String] = []
            for field in fields {
                if let (key, option) = splitAssignment(field) {
                    switch key.lowercased() {
                    case "server-tag-regex", "resource-tag-regex": if PolicyGroup.validateFilter(option) == nil { group.filter = option }
                    case "check-interval": group.interval = min(86400, max(30, Int(option) ?? 0))
                    case "tolerance": group.tolerance = min(5000, max(0, Int(option) ?? 0))
                    default: break
                    }
                    continue
                }
                if let renamed = renames[field], groupNames.contains(renamed) {
                    group.includeGroups.append(renamed)
                } else if ["direct", "reject", "proxy"].contains(field.lowercased()) {
                    continue
                } else {
                    nodes.append(field)
                }
            }
            if group.filter.isEmpty && !nodes.isEmpty { group.filter = exactNamesFilter(nodes) }
            plan.groups.append(group)
        }
        let importedNames = Set(plan.groups.map(\.name))
        for index in plan.groups.indices {
            plan.groups[index].includeGroups = plan.groups[index].includeGroups.filter { importedNames.contains($0) && $0 != plan.groups[index].name }
        }
        if PolicyGroup.cycle(in: plan.groups) != nil {
            for index in plan.groups.indices { plan.groups[index].includeGroups = [] }
        }
        // [filter_remote]：规则集，force-policy 是统一的去向。
        for line in sections["filter_remote"] ?? [] {
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let url = fields.first, RuleSet.validate(url: url) == nil else { continue }
            let options = keyValues(Array(fields.dropFirst()))
            if options["enabled"]?.lowercased() == "false" { continue }
            let policy = options["force-policy"].map { target(renames[$0] ?? $0, groups: Array(groupNames)) }
            var set = RuleSet(name: options["tag"] ?? RuleSet.defaultName(for: url), url: url, policy: policy ?? .proxy)
            // Quantumult X 的规则列表每行自带策略，没有统一去向时按文件里的走。
            if policy == nil {
                set.policy = nil
                set.converted = true
            }
            plan.ruleSets.append(set)
        }
        // [filter_local]：本机规则存成文件。
        if let rules = sections["filter_local"], !rules.isEmpty {
            let body = rules.map { rewritePolicy($0, renames: renames) }.joined(separator: "\n")
            plan.ruleFile = ImportFile(name: fileName(sourceName, suffix: L("规则"), extension: "conf"), content: "[filter_local]\n" + body + "\n")
        }
        let ignored = ["rewrite_local", "rewrite_remote", "mitm", "task_local", "http_backend"].filter { sections[$0] != nil }
        if !ignored.isEmpty {
            plan.warnings.append(L("这些段没有导入（Proxi 不做改写和脚本）：%@", ignored.map { "[\($0)]" }.joined(separator: L("、"))))
        }
        return plan
    }

    /// Quantumult X 的一行节点：shadowsocks=host:port, method=…, password=…, tag=名字。
    static func quantumultProxy(_ line: String) -> YAMLNode? {
        guard let (type, value) = splitAssignment(line) else { return nil }
        let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let address = fields.first, let colon = address.lastIndex(of: ":"), let port = Int(address[address.index(after: colon)...]) else { return nil }
        let server = String(address[..<colon])
        let options = keyValues(Array(fields.dropFirst()))
        guard let name = options["tag"] else { return nil }
        var pairs: [YAMLPair] = [YAMLPair(key: "name", value: .string(name))]
        func add(_ key: String, _ node: YAMLNode) { pairs.append(YAMLPair(key: key, value: node)) }
        let tls = options["over-tls"]?.lowercased() == "true" || ["wss", "over-tls"].contains(options["obfs"]?.lowercased() ?? "")
        switch type.lowercased() {
        case "shadowsocks":
            guard let cipher = options["method"], let password = options["password"] else { return nil }
            add("type", .plain("ss"))
            add("server", .string(server))
            add("port", .int(port))
            add("cipher", .string(cipher))
            add("password", .string(password))
            if options["udp-relay"]?.lowercased() == "true" { add("udp", .bool(true)) }
            if let obfs = options["obfs"], ["http", "tls"].contains(obfs.lowercased()) {
                add("plugin", .plain("obfs"))
                var opts = [YAMLPair(key: "mode", value: .string(obfs))]
                if let host = options["obfs-host"] { opts.append(YAMLPair(key: "host", value: .string(host))) }
                add("plugin-opts", .mapping(opts))
            }
        case "vmess":
            guard let uuid = options["password"] else { return nil }
            add("type", .plain("vmess"))
            add("server", .string(server))
            add("port", .int(port))
            add("uuid", .string(uuid))
            add("alterId", .int(0))
            add("cipher", .plain("auto"))
            if tls { add("tls", .bool(true)) }
            if let host = options["tls-host"] ?? options["obfs-host"] { add("servername", .string(host)) }
            if ["ws", "wss"].contains(options["obfs"]?.lowercased() ?? "") {
                add("network", .plain("ws"))
                var opts: [YAMLPair] = []
                if let path = options["obfs-uri"] { opts.append(YAMLPair(key: "path", value: .string(path))) }
                if let host = options["obfs-host"] { opts.append(YAMLPair(key: "headers", value: .mapping([YAMLPair(key: "Host", value: .string(host))]))) }
                if !opts.isEmpty { add("ws-opts", .mapping(opts)) }
            }
        case "trojan":
            guard let password = options["password"] else { return nil }
            add("type", .plain("trojan"))
            add("server", .string(server))
            add("port", .int(port))
            add("password", .string(password))
            if let host = options["tls-host"] { add("sni", .string(host)) }
            if options["tls-verification"]?.lowercased() == "false" { add("skip-cert-verify", .bool(true)) }
        case "http":
            add("type", .plain("http"))
            add("server", .string(server))
            add("port", .int(port))
            if let user = options["username"] { add("username", .string(user)) }
            if let pass = options["password"] { add("password", .string(pass)) }
            if tls { add("tls", .bool(true)) }
        case "socks5":
            add("type", .plain("socks5"))
            add("server", .string(server))
            add("port", .int(port))
            if let user = options["username"] { add("username", .string(user)) }
            if let pass = options["password"] { add("password", .string(pass)) }
            if tls { add("tls", .bool(true)) }
        default:
            return nil
        }
        return .mapping(pairs)
    }

    // MARK: - 应用

    /// 把计划合并进现有的设置。directory 是导入文件存放的目录（Clash 配置里的节点、转换后的规则）。
    static func apply(_ plan: ImportPlan, to current: AppConfig, mode: ImportMode, directory: URL) -> ImportResult {
        if let stored = plan.backup {
            let backup = restoringSecrets(stored, from: current)
            if mode == .replace {
                var config = backup
                // 本机的端口和开关保持不变。
                config.engine.mixedPort = current.engine.mixedPort
                config.engine.apiPort = current.engine.apiPort
                return ImportResult(config: config, files: [], summary: L("已从备份恢复全部设置"))
            }
            var partial = ImportPlan(format: .backup, sourceName: plan.sourceName)
            partial.subscriptions = backup.engine.subscriptions
            partial.manualNodes = backup.engine.manualNodes
            partial.groups = backup.engine.groups
            partial.ruleSets = backup.engine.ruleSets
            partial.customRules = backup.engine.customRules
            partial.hosts = backup.engine.hosts
            partial.profiles = backup.profiles.filter { !$0.engine }
            partial.networkRules = backup.automation.networkRules
            return apply(partial, to: current, mode: .merge, directory: directory)
        }
        var config = current
        var engine = config.engine
        var files: [(url: URL, content: String)] = []
        var added: [String] = []

        // 节点。
        var subscriptions = plan.subscriptions
        if let nodeFile = plan.nodeFile {
            let url = directory.appendingPathComponent(nodeFile.name)
            files.append((url, nodeFile.content))
            subscriptions.append(Subscription(name: L("%@ 的节点", plan.sourceName), url: url.absoluteString))
        }
        // 替换时地址相同的沿用原来的 id：策略组里记的来源、下载好的节点和规则都还能用。
        let previousSubscriptions = engine.subscriptions
        if mode == .replace && !subscriptions.isEmpty {
            engine.subscriptions = []
        }
        // 策略组里「只用某几个订阅」记的是导入计划里订阅的 id；和已有订阅重复时换成已有的那个。
        var idMap: [UUID: UUID] = [:]
        for var subscription in subscriptions {
            if let index = engine.subscriptions.firstIndex(where: { $0.url == subscription.url }) {
                idMap[subscription.id] = engine.subscriptions[index].id
                subscription.id = engine.subscriptions[index].id
                engine.subscriptions[index] = subscription
            } else {
                if let previous = previousSubscriptions.first(where: { $0.url == subscription.url }) {
                    idMap[subscription.id] = previous.id
                    subscription.id = previous.id
                }
                engine.subscriptions.append(subscription)
            }
        }
        if !subscriptions.isEmpty { added.append(L("%@ 条订阅", subscriptions.count)) }
        let previousNodes = engine.manualNodes
        if mode == .replace && !plan.manualNodes.isEmpty {
            engine.manualNodes = []
        }
        var newNodes: [ManualNode] = []
        for node in plan.manualNodes where !engine.manualNodes.contains(where: { $0.link == node.link }) && !newNodes.contains(where: { $0.link == node.link }) {
            newNodes.append(previousNodes.first { $0.link == node.link } ?? node)
        }
        engine.manualNodes += newNodes
        if !newNodes.isEmpty { added.append(L("%@ 个节点", newNodes.count)) }

        // 策略组。
        if mode == .replace && !plan.groups.isEmpty {
            let removed = engine.groups.map(\.name)
            engine.groups = []
            for name in removed where !plan.groups.contains(where: { $0.name == name }) {
                engine.retarget(from: name, to: .proxy)
            }
        }
        for var group in plan.groups {
            group.sources = group.sources.map { idMap[$0] ?? $0 }
            if let index = engine.groups.firstIndex(where: { $0.name == group.name }) {
                group.id = engine.groups[index].id
                engine.groups[index] = group
            } else {
                engine.groups.append(group)
            }
        }
        if let cycle = PolicyGroup.cycle(in: engine.groups) {
            for index in engine.groups.indices where cycle.contains(engine.groups[index].name) {
                engine.groups[index].includeGroups = []
            }
        }
        if !plan.groups.isEmpty { added.append(L("%@ 个策略组", plan.groups.count)) }

        // 规则集和规则文件。
        var ruleSets = plan.ruleSets
        if let ruleFile = plan.ruleFile {
            let url = directory.appendingPathComponent(ruleFile.name)
            files.append((url, ruleFile.content))
            var set = RuleSet(name: L("%@ 的规则", plan.sourceName), url: url.absoluteString, policy: plan.format == .ruleList ? .proxy : nil)
            if plan.format != .ruleList {
                set.converted = true
            }
            ruleSets.append(set)
        }
        let previousSets = engine.ruleSets
        if mode == .replace && !ruleSets.isEmpty {
            engine.ruleSets = []
        }
        for var set in ruleSets {
            if let index = engine.ruleSets.firstIndex(where: { $0.url == set.url }) {
                engine.ruleSets[index].policy = set.policy
                engine.ruleSets[index].enabled = true
                if set.converted != nil { engine.ruleSets[index].converted = set.converted }
            } else {
                if let previous = previousSets.first(where: { $0.url == set.url }) {
                    set.id = previous.id
                }
                engine.ruleSets.append(set)
            }
        }
        if !ruleSets.isEmpty { added.append(L("%@ 个规则集", ruleSets.count)) }

        // 自定义规则。
        if mode == .replace && !plan.customRules.isEmpty {
            engine.customRules = []
        }
        for rule in plan.customRules {
            if let index = engine.customRules.firstIndex(where: { $0.sameMatch(as: rule) }) {
                engine.customRules[index].policy = rule.policy
                engine.customRules[index].enabled = rule.enabled
            } else {
                engine.customRules.append(rule)
            }
        }
        if !plan.customRules.isEmpty { added.append(L("%@ 条自定义规则", plan.customRules.count)) }

        if let final = plan.finalPolicy { engine.finalPolicy = final }
        if [.clash, .surge, .quantumult].contains(plan.format), plan.ruleFile != nil || plan.ruleSets.contains(where: { $0.policy == nil }) {
            // 导入的规则自带 FINAL：跟随它。
            engine.finalPolicy = plan.finalPolicy
        }
        if let mode = plan.mode { engine.mode = mode }
        if let dns = plan.dns { engine.dns = dns }
        if mode == .replace && !plan.hosts.isEmpty {
            engine.hosts = []
        }
        for entry in plan.hosts {
            if let index = engine.hosts.firstIndex(where: { $0.domain == entry.domain }) {
                engine.hosts[index].value = entry.value
                engine.hosts[index].enabled = true
            } else {
                engine.hosts.append(entry)
            }
        }
        if let ipv6 = plan.ipv6 { engine.ipv6 = ipv6 }
        if let patch = plan.patch { engine.patch = patch }
        config.engine = engine

        // 代理配置和按网络切换。
        for profile in plan.profiles {
            if let index = config.profiles.firstIndex(where: { $0.name == profile.name && !$0.engine }) {
                var updated = profile
                updated.id = config.profiles[index].id
                updated.color = config.profiles[index].color
                config.profiles[index] = updated
            } else {
                config.profiles.append(profile)
            }
        }
        if !plan.profiles.isEmpty { added.append(L("%@ 个代理配置", plan.profiles.count)) }
        if mode == .replace && !plan.networkRules.isEmpty {
            config.automation.networkRules = []
        }
        config.automation.networkRules += plan.networkRules
        let summary = added.isEmpty ? L("已导入") : L("已导入") + added.joined(separator: L("、"))
        return ImportResult(config: config, files: files, summary: summary)
    }

    // MARK: - 导出

    /// 完整备份（JSON）：导入时选「替换」就能原样恢复。
    static func backupJSON(_ config: AppConfig) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let configData = try encoder.encode(config)
        let configObject = try JSONSerialization.jsonObject(with: configData)
        let document: [String: Any] = [
            "proxi": 1,
            "kind": "backup",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "config": configObject,
        ]
        let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// 配置描述（JSON）：只有订阅、节点、策略组、规则这些能跨设备用的部分，也是给 AI 助手看的格式。
    static func describe(_ config: AppConfig) -> [String: Any] {
        let engine = config.engine
        var document: [String: Any] = ["proxi": 1, "mode": engine.mode.rawValue]
        document["subscriptions"] = engine.subscriptions.map { subscription -> [String: Any] in
            var object: [String: Any] = ["name": subscription.name, "url": subscription.url]
            if !subscription.enabled { object["enabled"] = false }
            if !subscription.filter.isEmpty { object["filter"] = subscription.filter }
            if !subscription.exclude.isEmpty { object["exclude"] = subscription.exclude }
            if !subscription.prefix.isEmpty { object["prefix"] = subscription.prefix }
            if let dialer = subscription.dialer { object["dialer"] = dialer }
            return object
        }
        if !engine.manualNodes.isEmpty { document["nodes"] = engine.manualNodes.map(\.link) }
        document["groups"] = engine.groups.map { group -> [String: Any] in
            var object: [String: Any] = ["name": group.name, "type": group.kind.coreType]
            if !group.filter.isEmpty { object["filter"] = group.filter }
            if !group.exclude.isEmpty { object["exclude"] = group.exclude }
            if !group.includeGroups.isEmpty { object["groups"] = group.includeGroups }
            if !group.sources.isEmpty {
                object["subscriptions"] = group.sources.compactMap { id in
                    id == ManualNode.sourceID ? L("手动节点") : engine.subscriptions.first { $0.id == id }?.name
                }
            }
            if !group.testURL.isEmpty { object["url"] = group.testURL }
            if group.interval != 0 { object["interval"] = group.interval }
            if group.tolerance != 0 { object["tolerance"] = group.tolerance }
            if group.kind == .loadBalance { object["strategy"] = group.strategy.coreValue }
            return object
        }
        document["rules"] = engine.customRules.map { rule -> [String: Any] in
            var object: [String: Any] = ["type": rule.kind.rawValue, "value": rule.pattern, "policy": policyText(rule.policy)]
            if !rule.enabled { object["enabled"] = false }
            return object
        }
        document["ruleSets"] = engine.ruleSets.map { set -> [String: Any] in
            var object: [String: Any] = ["name": set.name, "url": set.url]
            if let policy = set.policy { object["policy"] = policyText(policy) }
            if !set.enabled { object["enabled"] = false }
            return object
        }
        if let final = engine.finalPolicy { document["final"] = policyText(final) }
        if engine.dns.enabled {
            var dns: [String: Any] = ["enabled": true, "nameservers": engine.dns.nameservers, "fallback": engine.dns.fallback, "fallbackViaProxy": engine.dns.fallbackViaProxy, "bootstrap": engine.dns.bootstrap]
            if !engine.dns.policies.isEmpty {
                dns["policies"] = Dictionary(engine.dns.policies.map { ($0.domain, $0.servers) }, uniquingKeysWith: { first, _ in first })
            }
            document["dns"] = dns
        }
        if !engine.hosts.isEmpty {
            document["hosts"] = Dictionary(engine.hosts.map { ($0.domain, $0.values.count == 1 ? $0.values[0] as Any : $0.values as Any) }, uniquingKeysWith: { first, _ in first })
        }
        if engine.ipv6 { document["ipv6"] = true }
        let profiles = config.profiles.filter { !$0.engine }
        if !profiles.isEmpty {
            document["profiles"] = profiles.map { profile -> [String: Any] in
                var object: [String: Any] = ["name": profile.name, "type": profile.kind.rawValue]
                if profile.kind == .pac { object["pac"] = profile.pacURL } else {
                    object["host"] = profile.host
                    object["port"] = profile.port
                }
                return object
            }
        }
        if !config.automation.networkRules.isEmpty {
            document["networkRules"] = config.automation.networkRules.map { rule -> [String: Any] in
                var object: [String: Any] = [:]
                switch rule.match {
                case .ssid(let name): object["ssid"] = name
                case .router(let address): object["router"] = address
                case .other: object["other"] = true
                }
                switch rule.action {
                case .off: object["action"] = "off"
                case .mode(let mode): object["action"] = "mode:" + mode.rawValue
                case .profile(let id): object["action"] = "profile:" + (config.profiles.first { $0.id == id }?.name ?? id.uuidString)
                }
                return object
            }
        }
        if !engine.patch.isEmpty { document["patch"] = engine.patch }
        return document
    }

    static func describeJSON(_ config: AppConfig) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: describe(config), options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 隐藏

    /// 地址里常带着令牌：只留协议和主机名。本机文件不用隐藏。
    static func hiddenURL(_ text: String) -> String {
        let components = URLComponents(string: text)
        let scheme = components?.scheme?.lowercased() ?? "https"
        if scheme == "file" { return text }
        let host = components?.host.flatMap { $0.isEmpty ? nil : $0 } ?? "hidden"
        return "\(scheme)://\(host)/\(hiddenURLSuffix)"
    }

    static func isHidden(url: String) -> Bool {
        url.hasSuffix("/" + hiddenURLSuffix)
    }

    /// 放规则的公开网站：地址里没有查询参数和账号时不用隐藏（规则库里的都在这些网站上）。
    static let publicRuleHosts: Set<String> = ["raw.githubusercontent.com", "gist.githubusercontent.com", "cdn.jsdelivr.net", "fastly.jsdelivr.net", "testingcf.jsdelivr.net"]

    /// 规则集的地址：内置的、本机的和公开网站上的照原样，别的只留主机名。
    static func hiddenRuleSetURL(_ text: String) -> String {
        if text.lowercased().hasPrefix(RuleSet.builtinScheme) { return text }
        if let components = URLComponents(string: text), components.query == nil, components.user == nil,
           let host = components.host?.lowercased(), publicRuleHosts.contains(host) {
            return text
        }
        return hiddenURL(text)
    }

    /// 手动节点的链接里有密码：只留名字。
    static func hiddenLink(for node: ManualNode) -> String {
        hiddenNodePrefix + node.name
    }

    /// 隐藏了的手动节点的名字；不是隐藏的写法时返回 nil。
    static func hiddenNodeName(_ link: String) -> String? {
        guard link.hasPrefix(hiddenNodePrefix) else { return nil }
        return String(link.dropFirst(hiddenNodePrefix.count))
    }

    /// 交给控制接口的配置：订阅和规则集的地址只留主机名，手动节点的链接只留名字。
    static func hidingSecrets(_ config: AppConfig) -> AppConfig {
        var copy = config
        for index in copy.engine.subscriptions.indices {
            copy.engine.subscriptions[index].url = hiddenURL(copy.engine.subscriptions[index].url)
        }
        for index in copy.engine.ruleSets.indices {
            copy.engine.ruleSets[index].url = hiddenRuleSetURL(copy.engine.ruleSets[index].url)
        }
        for index in copy.engine.manualNodes.indices {
            copy.engine.manualNodes[index].link = hiddenLink(for: copy.engine.manualNodes[index])
        }
        return copy
    }

    /// 从控制接口导出的备份再导入时：隐藏了的地址和链接按 id 或名字换回现有的，现有设置里找不到的去掉。
    static func restoringSecrets(_ config: AppConfig, from current: AppConfig) -> AppConfig {
        var restored = config
        let subscriptions = current.engine.subscriptions
        restored.engine.subscriptions = config.engine.subscriptions.compactMap { subscription in
            guard isHidden(url: subscription.url) else { return subscription }
            guard let original = subscriptions.first(where: { $0.id == subscription.id }) ?? subscriptions.first(where: { $0.name == subscription.name }) else { return nil }
            var kept = subscription
            kept.url = original.url
            return kept
        }
        let sets = current.engine.ruleSets
        restored.engine.ruleSets = config.engine.ruleSets.compactMap { set in
            guard isHidden(url: set.url) else { return set }
            guard let original = sets.first(where: { $0.id == set.id }) ?? sets.first(where: { $0.name == set.name }) else { return nil }
            var kept = set
            kept.url = original.url
            return kept
        }
        let nodes = current.engine.manualNodes
        restored.engine.manualNodes = config.engine.manualNodes.compactMap { node in
            guard let name = hiddenNodeName(node.link) else { return node }
            guard let original = nodes.first(where: { $0.id == node.id }) ?? nodes.first(where: { $0.name == name }) else { return nil }
            var kept = node
            kept.link = original.link
            return kept
        }
        return restored
    }

    /// 去向的文字写法：proxy、direct、reject，策略组写名字。
    static func policyText(_ target: RuleTarget) -> String {
        switch target {
        case .proxy: return "proxy"
        case .direct: return "direct"
        case .reject: return "reject"
        case .group(let name): return name
        }
    }

    // MARK: - 小工具

    /// 去向的各种写法：proxy / 节点 / 走节点、direct / 直连、reject / 拦截、group:名字，或者直接写策略组的名字。
    static func target(_ text: String, groups: [String]) -> RuleTarget {
        let value = text.trimmingCharacters(in: .whitespaces)
        if value.lowercased().hasPrefix("group:") { return .group(String(value.dropFirst(6))) }
        if let group = groups.first(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) { return .group(group) }
        switch value.lowercased() {
        case "direct", "直连", "直接连接": return .direct  // l10n-ignore：配置里的写法
        case "reject", "拦截", "拒绝", "block", "reject-drop", "reject-tinygif": return .reject  // l10n-ignore：配置里的写法
        default: return .proxy
        }
    }

    /// 规则类型的各种写法。
    static func ruleKind(_ text: String?) -> CustomRuleKind? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if let kind = CustomRuleKind(rawValue: text) { return kind }
        switch text.lowercased() {
        case "domain-suffix", "后缀", "域名后缀": return .suffix  // l10n-ignore：配置里的写法
        case "domain-keyword", "关键词": return .keyword  // l10n-ignore：配置里的写法
        case "domain-wildcard", "通配": return .wildcard  // l10n-ignore：配置里的写法
        case "domain-regex", "正则": return .regex  // l10n-ignore：配置里的写法
        case "ip-cidr", "ip-cidr6", "cidr": return .ip
        case "src-ip", "src-ip-cidr", "设备": return .device  // l10n-ignore：配置里的写法
        case "dst-port", "端口": return .port  // l10n-ignore：配置里的写法
        case "process-name", "进程": return .process  // l10n-ignore：配置里的写法
        case "process-path", "应用": return .app  // l10n-ignore：配置里的写法
        case "域名": return .domain  // l10n-ignore：配置里的写法
        default: return CustomRuleKind.from(coreType: text)
        }
    }

    /// 「DOMAIN-SUFFIX,x.com,直连」这样一行变成自定义规则。
    static func customRule(fromLine line: String, groups: [String]) -> CustomRule? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let upper = trimmed.uppercased()
        if upper.hasPrefix("AND,") || upper.hasPrefix("OR,") || upper.hasPrefix("NOT,") {
            guard let close = trimmed.lastIndex(of: ")") else { return nil }
            let body = String(trimmed[...close])
            let tail = trimmed[trimmed.index(after: close)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard CustomRule.validate(body, kind: .logic) == nil else { return nil }
            return CustomRule(pattern: body, policy: target(tail.first ?? "proxy", groups: groups), kind: .logic)
        }
        let fields = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 2 else { return nil }
        let coreType = RuleConverter.coreType(fields[0])
        let kind: CustomRuleKind
        if coreType == "PROCESS-PATH" {
            kind = .app
        } else if let known = CustomRuleKind.from(coreType: coreType) {
            kind = known
        } else {
            return nil
        }
        guard CustomRule.validate(fields[1], kind: kind) == nil else { return nil }
        let policy = fields.count > 2 ? target(fields[2], groups: groups) : .proxy
        return CustomRule(pattern: fields[1], policy: policy, kind: kind)
    }

    static func groupKind(_ text: String?) -> PolicyGroupKind? {
        guard let text = text?.lowercased() else { return nil }
        if let kind = PolicyGroupKind(rawValue: text) { return kind }
        return clashGroupKind(text)
    }

    static func clashGroupKind(_ text: String?) -> PolicyGroupKind? {
        switch text?.lowercased() {
        case "select": return .select
        case "url-test": return .urlTest
        case "fallback": return .fallback
        case "load-balance": return .loadBalance
        default: return nil
        }
    }

    static func surgeGroupKind(_ text: String) -> PolicyGroupKind? {
        switch text.lowercased() {
        case "select": return .select
        case "url-test", "smart": return .urlTest
        case "fallback": return .fallback
        case "load-balance": return .loadBalance
        default: return nil
        }
    }

    static func loadBalanceStrategy(_ text: String) -> LoadBalanceStrategy {
        switch text.lowercased() {
        case "consistent-hashing", "consistenthashing", "dest-hash": return .consistentHashing
        case "sticky-sessions", "stickysessions": return .stickySessions
        default: return .roundRobin
        }
    }

    /// 导入的组名整理成能用的名字：去掉逗号引号、截到 20 个字、避开保留名和已有的组。
    static func groupRenames(_ names: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var taken: [PolicyGroup] = []
        for original in names {
            var base = original.filter { $0 != "," && $0 != "，" && $0 != "\"" && $0 != "`" && $0 != "#" && !$0.isNewline }  // l10n-ignore：全角逗号
                .trimmingCharacters(in: .whitespaces)
            if base.count > PolicyGroup.maxNameLength { base = String(base.prefix(PolicyGroup.maxNameLength)) }
            if base.isEmpty { base = L("策略组") }
            var candidate = base
            var index = 2
            while PolicyGroup.validate(name: candidate, filter: "", others: taken) != nil {
                let suffix = index == 2 && PolicyGroup.reservedNames.contains(where: { $0.caseInsensitiveCompare(base) == .orderedSame }) ? L("组") : " \(index)"
                candidate = String(base.prefix(PolicyGroup.maxNameLength - suffix.count)) + suffix
                index += 1
                if index > 50 { break }
            }
            guard PolicyGroup.validate(name: candidate, filter: "", others: taken) == nil else { continue }
            result[original] = candidate
            taken.append(PolicyGroup(name: candidate))
        }
        return result
    }

    /// 测速地址：http(s) 的才用，否则留空（用通用设置里的）。
    static func validTestURL(_ text: String?) -> String {
        guard let text = text?.trimmingCharacters(in: .whitespaces), let url = URL(string: text),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return "" }
        return text
    }

    /// 只匹配这些名字的正则（整个名字相同）。
    static func exactNamesFilter(_ names: [String]) -> String {
        "^(" + names.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")$"
    }

    /// 按 [段名] 拆开，段名小写；注释（# ; //）和空行去掉。
    static func iniSections(_ text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("//") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                current = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces).lowercased()
                if result[current!] == nil { result[current!] = [] }
                continue
            }
            if let current {
                result[current, default: []].append(line)
            }
        }
        return result
    }

    /// 「键 = 值」拆开（只在第一个等号处拆）。
    static func splitAssignment(_ line: String) -> (String, String)? {
        guard let equals = line.firstIndex(of: "=") else { return nil }
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    static func keyValues(_ lines: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            if let (key, value) = splitAssignment(line) {
                result[key.lowercased()] = value
            }
        }
        return result
    }

    static func stringList(_ value: Any?) -> [String]? {
        if let list = value as? [String] { return list }
        if let text = value as? String { return DNSSettings.parseList(text) }
        return nil
    }

    /// 订阅的默认名字：网址的主机名。
    static func subscriptionName(for url: String, fallback: String) -> String {
        URL(string: url)?.host ?? fallback
    }

    /// 导入文件的名字：来源名去掉不适合做文件名的字符，加上后缀和随机的一段。
    static func fileName(_ source: String, suffix: String, extension ext: String) -> String {
        let allowed = source.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" }
        let base = String(allowed.prefix(40)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let id = UUID().uuidString.prefix(6).lowercased()
        return "\(base.isEmpty ? "导入" : base)-\(suffix)-\(id).\(ext)"  // l10n-ignore：文件名
    }

    static func countProxies(in yaml: String) -> Int {
        ((try? YAMLParser.parse(yaml))?["proxies"]?.array?.count) ?? 0
    }

    static func countRules(in text: String) -> Int {
        let converted = RuleConverter.convert(text)
        return converted.rules.count + converted.ruleSets.count
    }
}
