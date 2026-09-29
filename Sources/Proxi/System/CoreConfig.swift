import Foundation

/// 交给内核加载的一个规则集文件（rule-provider）。
struct RuleProviderSpec: Equatable {
    var name: String
    var path: String
    var behavior: RuleSetBehavior
    var format: String
}

/// 生成内核（mihomo）的配置文件。
enum CoreConfigBuilder {
    struct Input {
        var engine: EngineConfig
        var secret: String
        var directory: URL
        var testURL: String
        /// 已经转换好的分流规则（不含局域网前缀，最后一条应是 MATCH）。
        var rules: [String]
        /// 局域网共享；nil 表示没开。
        var share: ShareInputs? = nil
        /// 规则里 RULE-SET 引用的规则集文件。
        var ruleProviders: [RuleProviderSpec] = []
        /// 配置列表：订阅的前置代理可以是其中的 HTTP / SOCKS5 代理。
        var profiles: [Profile] = []
        /// 服务检测用的本机入口端口；nil 表示不开。
        var probePort: Int? = nil
        /// 增强模式 / 网关模式（虚拟网卡）；nil 表示不开。只有经特权助手以 root 运行的内核才能开。
        var tun: TunInputs? = nil
    }

    static let selectorGroup = RuleConverter.proxyGroup
    static let autoGroup = "自动选择"
    static let providerUserAgent = "clash.meta"
    /// 局域网共享的入口（listener）和它专用的规则组同名。
    static let shareListener = "lan-share"
    /// 本机用别的代理时，共享的流量转发给它：内核里叫这个名字。
    static let upstreamProxy = "上游代理"
    /// 服务检测：一个隐藏的手动选择组和只走它的本机入口，测某个节点时只切这个组，不影响正在用的节点。
    static let probeGroup = "ps-probe"
    /// 网关模式下局域网设备的流量专用的规则组（本机不用内置代理时，设备跟着本机的上游走）。
    static let gatewayRules = "lan-gateway"
    /// 内核给虚拟网卡收到的连接起的入口名。
    static let tunInbound = "DEFAULT-TUN"

    /// 生成配置，再合并高级设置里的配置补丁。补丁有问题时用没打补丁的配置，问题放在 patchProblem 里。
    static func build(_ input: Input) -> (text: String, patchProblem: String?, patchNotes: [String]) {
        let base = yaml(input)
        let patch = input.engine.patch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !patch.isEmpty else { return (base, nil, []) }
        do {
            let merged = try ConfigPatch.apply(patch, to: base)
            return ("# 由 Proxi 生成，改动会被覆盖；已合并配置补丁。\n" + merged.text, nil, merged.notes)
        } catch {
            return (base, error.localizedDescription, [])
        }
    }

    static func yaml(_ input: Input) -> String {
        let engine = input.engine
        // 只为共享而运行时不加载订阅，本机的代理端口也关掉（0 表示不监听），省得和别的代理软件抢端口。
        let providers = engine.wantsCore ? engine.activeSubscriptions : []
        let manual = engine.wantsCore ? engine.activeManualNodes : []
        let providerNames = engine.wantsCore ? engine.providerNames : []
        var lines: [String] = []
        lines.append("# 由 Proxi 生成，改动会被覆盖。")
        lines.append("mixed-port: \(engine.wantsCore ? engine.mixedPort : 0)")
        lines.append("allow-lan: false")
        lines.append("bind-address: \"127.0.0.1\"")
        lines.append("mode: rule")
        lines.append("log-level: warning")
        lines.append("ipv6: \(engine.ipv6)")
        // 连接页里显示是哪个程序发起的连接，应用规则也靠它。
        lines.append("find-process-mode: always")
        lines.append("external-controller: \"127.0.0.1:\(engine.apiPort)\"")
        lines.append("secret: \(quote(input.secret))")
        lines.append("unified-delay: true")
        lines.append("tcp-concurrent: true")
        lines.append("geodata-mode: false")
        lines.append("geo-auto-update: false")
        lines.append("profile:")
        lines.append("  store-selected: true")
        lines.append("  store-fake-ip: false")
        // 域名嗅探：设备自己解析 DNS 被污染后会按（假）IP 来连（PS5 这类设备常见），从 TLS / HTTP 握手里取回域名，
        // 按域名分流，并把域名而不是假 IP 交给节点去解析。本机的流量同样受益。
        lines.append("sniffer:")
        lines.append("  enable: true")
        lines.append("  parse-pure-ip: true")
        lines.append("  override-destination: true")
        lines.append("  force-dns-mapping: true")
        lines.append("  sniff:")
        lines.append("    HTTP:")
        lines.append("      ports: [80, 8080-8880]")
        lines.append("    TLS:")
        lines.append("      ports: [443, 8443]")
        if let tun = input.tun {
            // 虚拟网卡收到的 UDP 里有 QUIC（HTTP/3），同样取回域名。
            lines.append("    QUIC:")
            lines.append("      ports: [443, 8443]")
            lines += tunLines(tun)
        }
        lines += hostsLines(engine)
        lines += dnsLines(engine, tun: input.tun)
        var listeners: [String] = []
        var proxies: [String] = []
        if let share = input.share {
            // 谁能连进来：这份名单对所有入口生效，所以本机回环也在里面。
            lines.append("lan-allowed-ips:")
            for prefix in share.allowedPrefixes {
                lines.append("  - \(quote(prefix))")
            }
            // 共享入口监听所有网卡，流量按 sub-rules 里同名的规则组分流；入口本身不随本机状态变，切换上游时只改规则、不断开连接。
            listeners.append("  - name: \(quote(shareListener))")
            listeners.append("    type: mixed")
            listeners.append("    listen: \"0.0.0.0\"")
            listeners.append("    port: \(share.port)")
            listeners.append("    rule: \(quote(shareListener))")
            if case .proxy(let kind, let host, let port) = share.upstream {
                proxies.append("  - name: \(quote(upstreamProxy))")
                proxies.append("    type: \(kind == .socks5 ? "socks5" : "http")")
                proxies.append("    server: \(quote(host))")
                proxies.append("    port: \(port)")
            }
        }
        if let port = input.probePort, !providerNames.isEmpty {
            listeners.append("  - name: \(quote(probeGroup))")
            listeners.append("    type: mixed")
            listeners.append("    listen: \"127.0.0.1\"")
            listeners.append("    port: \(port)")
            listeners.append("    proxy: \(quote(probeGroup))")
        }
        // 前置代理用到的配置列表里的代理。
        for profile in frontProfiles(engine, profiles: input.profiles) {
            proxies.append("  - name: \(quote(DialerReference.coreName(for: profile)))")
            proxies.append("    type: \(profile.kind == .socks5 ? "socks5" : "http")")
            proxies.append("    server: \(quote(profile.host))")
            proxies.append("    port: \(profile.port)")
        }
        if !listeners.isEmpty {
            lines.append("listeners:")
            lines += listeners
        }
        if !proxies.isEmpty {
            lines.append("proxies:")
            lines += proxies
        }
        if !providerNames.isEmpty {
            lines.append("proxy-providers:")
            for subscription in providers {
                lines.append("  \(subscription.providerName):")
                // 内核只读它自己目录下的文件：file:// 订阅由 Engine 先复制到 providers/ 里。
                let path = providerPath(for: subscription, directory: input.directory).path
                if subscription.filePath != nil {
                    lines.append("    type: file")
                    lines.append("    path: \(quote(path))")
                } else {
                    lines.append("    type: http")
                    lines.append("    url: \(quote(subscription.url))")
                    lines.append("    path: \(quote(path))")
                    lines.append("    interval: \(max(1, engine.updateIntervalHours) * 3600)")
                    lines.append("    header:")
                    lines.append("      User-Agent: [\(quote(providerUserAgent))]")
                }
                if Subscription.validateOptions(filter: subscription.filter, exclude: subscription.exclude, prefix: subscription.prefix) == nil {
                    if let filter = PolicyGroup.coreRegex(subscription.filter) {
                        lines.append("    filter: \(quote(filter))")
                    }
                    if let exclude = PolicyGroup.coreRegex(subscription.exclude) {
                        lines.append("    exclude-filter: \(quote(exclude))")
                    }
                    if !subscription.prefix.isEmpty {
                        lines.append("    override:")
                        lines.append("      additional-prefix: \(quote(subscription.prefix))")
                    }
                }
                if let dialer = dialerName(subscription.dialer, provider: subscription.providerName, engine: engine, profiles: input.profiles) {
                    lines.append("    dialer-proxy: \(quote(dialer))")
                }
                lines += healthCheckLines(input.testURL)
            }
            if !manual.isEmpty {
                lines.append("  \(ManualNode.providerName):")
                lines.append("    type: file")
                lines.append("    path: \(quote(manualNodesPath(directory: input.directory).path))")
                if let dialer = dialerName(engine.manualDialer, provider: ManualNode.providerName, engine: engine, profiles: input.profiles) {
                    lines.append("    dialer-proxy: \(quote(dialer))")
                }
                lines += healthCheckLines(input.testURL)
            }
        }
        let useLine = providerNames.isEmpty ? "" : "    use: [\(providerNames.joined(separator: ", "))]"
        lines.append("proxy-groups:")
        lines.append("  - name: \(quote(selectorGroup))")
        lines.append("    type: select")
        lines.append("    proxies: [\(quote(autoGroup)), \"DIRECT\"]")
        if !useLine.isEmpty { lines.append(useLine) }
        lines.append("  - name: \(quote(autoGroup))")
        lines.append("    type: url-test")
        lines.append("    url: \(quote(input.testURL))")
        lines.append("    interval: \(PolicyGroup.defaultInterval)")
        lines.append("    tolerance: \(PolicyGroup.defaultTolerance)")
        lines.append("    lazy: true")
        lines.append("    proxies: [\"DIRECT\"]")
        if !useLine.isEmpty { lines.append(useLine) }
        lines += groupLines(engine, testURL: input.testURL)
        if input.probePort != nil, !useLine.isEmpty {
            lines.append("  - name: \(quote(probeGroup))")
            lines.append("    type: select")
            lines.append("    hidden: true")
            lines.append("    proxies: [\(quote(selectorGroup)), \"DIRECT\"]")
            lines.append(useLine)
        }
        if !input.ruleProviders.isEmpty {
            // 规则集文件由本程序下载到内核目录里，内核只管读；更新时本程序换文件再让内核重读。
            lines.append("rule-providers:")
            for provider in input.ruleProviders {
                lines.append("  \(provider.name):")
                lines.append("    type: file")
                lines.append("    behavior: \(provider.behavior.rawValue)")
                lines.append("    format: \(provider.format)")
                lines.append("    path: \(quote(provider.path))")
            }
        }
        // 局域网直连 → 用户自定义 → 预设规则；自定义规则在全局模式下也生效（全局 = 除局域网和你的例外之外都走节点）。
        var rules = RuleConverter.lanRules + engine.customRuleLines + input.rules
        if !(rules.last?.hasPrefix("MATCH,") ?? false) {
            rules.append("MATCH,\(selectorGroup)")
        }
        var subRules: [(name: String, rules: [String])] = []
        if let share = input.share {
            subRules.append((shareListener, shareRules(upstream: share.upstream, mainRules: rules, deviceRules: deviceRuleLines(engine))))
        }
        var leading: [String] = []
        if let tun = input.tun {
            let gateway = tunRules(tun, mainRules: rules, deviceRules: deviceRuleLines(engine))
            leading = gateway.leading
            if let deviceRules = gateway.deviceRules {
                subRules.append((gatewayRules, deviceRules))
            }
        }
        lines.append("rules:")
        for rule in leading + rules {
            lines.append("  - \(quote(rule))")
        }
        if !subRules.isEmpty {
            lines.append("sub-rules:")
            for group in subRules {
                lines.append("  \(quote(group.name)):")
                for rule in group.rules {
                    lines.append("    - \(quote(rule))")
                }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 各部分

    private static func healthCheckLines(_ testURL: String) -> [String] {
        [
            "    health-check:",
            "      enable: true",
            "      url: \(quote(testURL))",
            "      interval: 600",
            "      lazy: true",
        ]
    }

    /// 自定义策略组。成员是按名字筛选出来的节点（可以限定来源、排除一部分），再加上包含的组；
    /// 手动选择的组多了「节点」「自动选择」和直连三个候选，默认跟随「节点」；自动类的组只在自己的成员里挑，筛不到时内核退回直连。
    /// 没加载订阅（只做共享）时组照样要有，规则里引用了它们，这时自动类的组只有直连一个成员。
    private static func groupLines(_ engine: EngineConfig, testURL: String) -> [String] {
        var lines: [String] = []
        let names = Set(engine.groupNames)
        for group in engine.groups {
            let groupProviders = engine.wantsCore ? engine.providerNames(for: group) : []
            var members: [String] = group.kind == .select ? [selectorGroup, autoGroup, "DIRECT"] : []
            for member in group.includeGroups where member != group.name && (names.contains(member) || PolicyGroup.builtinMembers.contains(member)) && !members.contains(member) {
                members.append(member)
            }
            if groupProviders.isEmpty && members.isEmpty {
                members = ["DIRECT"]
            }
            let url = group.testURL.trimmingCharacters(in: .whitespaces).isEmpty ? testURL : group.testURL.trimmingCharacters(in: .whitespaces)
            lines.append("  - name: \(quote(group.name))")
            lines.append("    type: \(group.kind.coreType)")
            switch group.kind {
            case .select:
                break
            case .urlTest:
                lines.append("    url: \(quote(url))")
                lines.append("    interval: \(group.effectiveInterval)")
                lines.append("    tolerance: \(group.effectiveTolerance)")
                lines.append("    lazy: true")
            case .fallback:
                lines.append("    url: \(quote(url))")
                lines.append("    interval: \(group.effectiveInterval)")
                lines.append("    lazy: true")
            case .loadBalance:
                lines.append("    url: \(quote(url))")
                lines.append("    interval: \(group.effectiveInterval)")
                lines.append("    strategy: \(group.strategy.coreValue)")
                lines.append("    lazy: true")
            }
            if !members.isEmpty {
                lines.append("    proxies: [\(members.map(quote).joined(separator: ", "))]")
            }
            if !groupProviders.isEmpty {
                lines.append("    use: [\(groupProviders.joined(separator: ", "))]")
                if PolicyGroup.validateFilter(group.filter) == nil, let filter = group.coreFilter {
                    lines.append("    filter: \(quote(filter))")
                }
                if PolicyGroup.validateFilter(group.exclude) == nil, let exclude = group.coreExclude {
                    lines.append("    exclude-filter: \(quote(exclude))")
                }
            }
        }
        return lines
    }

    /// Hosts：启用而且写对了的条目。
    static func hostsLines(_ engine: EngineConfig) -> [String] {
        let entries = engine.hosts.filter { $0.enabled && $0.validate() == nil }
        guard !entries.isEmpty else { return [] }
        var lines = ["hosts:"]
        var seen = Set<String>()
        for entry in entries where seen.insert(entry.domain).inserted {
            let values = entry.values
            if values.count == 1 {
                lines.append("  \(quote(entry.domain)): \(quote(values[0]))")
            } else {
                lines.append("  \(quote(entry.domain)): [\(values.map(quote).joined(separator: ", "))]")
            }
        }
        return lines
    }

    /// 内核的 DNS：没开或者设置有问题时不写（内核用系统的 DNS），免得起不来。
    /// 开着虚拟网卡时一定要有：本机和网关设备的 DNS 查询都被截下来交给内核回答；这时没设置过就用默认的服务器。
    static func dnsLines(_ engine: EngineConfig, tun: TunInputs? = nil) -> [String] {
        var dns = engine.dns
        if tun != nil && (!dns.enabled || dns.validate() != nil) {
            dns = DNSSettings()
            dns.enabled = true
        }
        guard dns.enabled, dns.validate() == nil else { return [] }
        var lines = ["dns:"]
        lines.append("  enable: true")
        if let tun {
            if tun.gateway {
                // 网关设备把 DNS 设成这台 Mac 时由内核回答。
                lines.append("  listen: \"0.0.0.0:53\"")
            }
            lines.append("  enhanced-mode: \(tun.dnsMode.rawValue)")
            // 虚拟网卡的地址也从这个地址段里取，所以真实 IP 模式下也写上。
            lines.append("  fake-ip-range: \(quote(TunDefaults.fakeIPRange))")
            if tun.dnsMode == .fakeIP {
                lines.append("  fake-ip-filter: [\(TunDefaults.fakeIPFilter.map(quote).joined(separator: ", "))]")
            }
        }
        lines.append("  ipv6: \(engine.ipv6)")
        lines.append("  use-hosts: true")
        lines.append("  default-nameserver: [\(dns.bootstrap.map(quote).joined(separator: ", "))]")
        lines.append("  nameserver: [\(dns.nameservers.map(quote).joined(separator: ", "))]")
        if !dns.fallback.isEmpty {
            // 国内 DNS 给出的结果不在国内时（可能被污染）改用海外 DNS 的结果；海外 DNS 默认经「节点」查询。
            let fallback = dns.fallbackViaProxy ? dns.fallback.map { DNSSettings.routed($0, via: selectorGroup) } : dns.fallback
            lines.append("  fallback: [\(fallback.map(quote).joined(separator: ", "))]")
            lines.append("  fallback-filter:")
            lines.append("    geoip: true")
            lines.append("    geoip-code: CN")
            lines.append("    ipcidr: [\"240.0.0.0/4\", \"0.0.0.0/32\"]")
        }
        let policies = dns.policies.filter { $0.validate() == nil }
        if !policies.isEmpty {
            lines.append("  nameserver-policy:")
            for policy in policies {
                lines.append("    \(quote(policy.domain)): [\(policy.servers.map(quote).joined(separator: ", "))]")
            }
        }
        return lines
    }

    // MARK: - 虚拟网卡

    /// 虚拟网卡：接管路由，内核自己连出去时绑定真实网卡（不会绕回来），DNS 查询一律截下来交给内核。
    static func tunLines(_ tun: TunInputs) -> [String] {
        [
            "tun:",
            "  enable: true",
            "  stack: \(tun.stack.rawValue)",
            "  auto-route: true",
            "  auto-detect-interface: true",
            "  dns-hijack: [\"any:53\", \"tcp://any:53\"]",
        ]
    }

    /// 虚拟网卡带来的规则：放在最前面的几条，和网关设备专用的规则组（nil 表示设备和本机一样走主规则）。
    /// 本机的流量不接管时（只为网关开虚拟网卡），本机经虚拟网卡发出的流量直连，和没开时一样；
    /// 本机又没用内置代理时，网关设备和局域网共享一样跟着本机的上游走。
    static func tunRules(_ tun: TunInputs, mainRules: [String], deviceRules: [String]) -> (leading: [String], deviceRules: [String]?) {
        guard !tun.captureLocal else { return ([], nil) }
        var leading = ["AND,((IN-TYPE,TUN),(SRC-IP-CIDR,\(TunDefaults.interfaceNetwork))),DIRECT"]
        for address in tun.localAddresses {
            guard let prefix = IPPrefix.normalize(address) else { continue }
            leading.append("AND,((IN-TYPE,TUN),(SRC-IP-CIDR,\(prefix))),DIRECT")
        }
        guard tun.gateway, tun.upstream != .engine else { return (leading, nil) }
        leading.append("SUB-RULE,(IN-TYPE,TUN),\(gatewayRules)")
        return (leading, shareRules(upstream: tun.upstream, mainRules: mainRules, deviceRules: deviceRules))
    }

    // MARK: - 前置代理

    /// 前置代理在内核里的名字；指向的东西不存在、或者会绕回自己（前置组里有这个来源的节点）时返回 nil，不设前置。
    static func dialerName(_ reference: String?, provider: String, engine: EngineConfig, profiles: [Profile]) -> String? {
        guard let reference = reference?.trimmingCharacters(in: .whitespaces), !reference.isEmpty else { return nil }
        if let id = DialerReference.profileID(reference) {
            guard let profile = profiles.first(where: { $0.id == id }), DialerReference.usable(profile) else { return nil }
            return DialerReference.coreName(for: profile)
        }
        if dialerLoops(reference, provider: provider, engine: engine) { return nil }
        return reference
    }

    /// 前置代理会不会绕回这个来源自己：前置是「节点」「自动选择」，或者是用了这个来源的策略组（连同它包含的组）。
    static func dialerLoops(_ reference: String, provider: String, engine: EngineConfig) -> Bool {
        if PolicyGroup.builtinMembers.contains(reference) { return true }
        guard engine.groups.contains(where: { $0.name == reference }) else { return false }
        return transitiveProviders(of: reference, engine: engine).contains(provider)
    }

    /// 一个策略组（连同它包含的组）用到的全部节点来源。
    static func transitiveProviders(of name: String, engine: EngineConfig) -> Set<String> {
        var result = Set<String>()
        var visited = Set<String>()
        var pending = [name]
        while let current = pending.popLast() {
            guard visited.insert(current).inserted else { continue }
            if PolicyGroup.builtinMembers.contains(current) {
                result.formUnion(engine.providerNames)
                continue
            }
            guard let group = engine.groups.first(where: { $0.name == current }) else { continue }
            result.formUnion(engine.providerNames(for: group))
            if group.kind == .select {
                // 手动选择的组里有「节点」和「自动选择」。
                result.formUnion(engine.providerNames)
            }
            pending += group.includeGroups
        }
        return result
    }

    /// 前置代理用到的、配置列表里的 HTTP / SOCKS5 代理，按出现的顺序去重。
    static func frontProfiles(_ engine: EngineConfig, profiles: [Profile]) -> [Profile] {
        guard engine.wantsCore else { return [] }
        var references = engine.activeSubscriptions.compactMap(\.dialer)
        if !engine.activeManualNodes.isEmpty, let manual = engine.manualDialer {
            references.append(manual)
        }
        var result: [Profile] = []
        for reference in references {
            guard let id = DialerReference.profileID(reference), let profile = profiles.first(where: { $0.id == id }), DialerReference.usable(profile) else { continue }
            if !result.contains(where: { $0.id == profile.id }) {
                result.append(profile)
            }
        }
        return result
    }

    // MARK: - 共享

    /// 局域网设备规则里去向是直连或拦截的那些：本机没开内置代理时，共享入口也照样遵守。
    static func deviceRuleLines(_ engine: EngineConfig) -> [String] {
        engine.customRules
            .filter { $0.enabled && $0.kind == .device && ($0.policy == .direct || $0.policy == .reject) }
            .compactMap { $0.line(groups: engine.groupNames) }
    }

    /// 共享入口的分流：本机开着内置代理时和本机完全一样；本机用别的代理时局域网直连、其余转发给它；本机没开代理时全部直连。
    /// 设备规则里的直连和拦截在后两种情况下也生效。
    static func shareRules(upstream: ShareUpstream, mainRules: [String], deviceRules: [String] = []) -> [String] {
        switch upstream {
        case .engine: return mainRules
        case .proxy: return RuleConverter.lanRules + deviceRules + ["MATCH,\(upstreamProxy)"]
        case .direct, .unsupported: return deviceRules.filter { $0.hasSuffix(",REJECT") } + ["MATCH,DIRECT"]
        }
    }

    // MARK: - 文件

    /// 订阅在内核目录里的文件。
    static func providerPath(for subscription: Subscription, directory: URL) -> URL {
        directory.appendingPathComponent("providers/\(subscription.providerName).yaml")
    }

    /// 手动节点的文件：一行一条分享链接。
    static func manualNodesPath(directory: URL) -> URL {
        directory.appendingPathComponent("providers/\(ManualNode.providerName).txt")
    }

    /// 手动节点文件的内容。
    static func manualNodesText(_ engine: EngineConfig) -> String {
        engine.activeManualNodes.map(\.link).joined(separator: "\n") + "\n"
    }

    /// YAML 的双引号字符串。
    static func quote(_ text: String) -> String {
        YAMLWriter.quote(text)
    }

    /// 随机的 API 密钥。
    static func makeSecret() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }
}
