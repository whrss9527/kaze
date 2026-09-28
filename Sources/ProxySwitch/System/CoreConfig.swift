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
    }

    static let selectorGroup = RuleConverter.proxyGroup
    static let autoGroup = "自动选择"
    static let providerUserAgent = "clash.meta"
    /// 局域网共享的入口（listener）和它专用的规则组同名。
    static let shareListener = "lan-share"
    /// 本机用别的代理时，共享的流量转发给它：内核里叫这个名字。
    static let upstreamProxy = "上游代理"

    static func yaml(_ input: Input) -> String {
        let engine = input.engine
        // 只为共享而运行时不加载订阅，本机的代理端口也关掉（0 表示不监听），省得和别的代理软件抢端口。
        let providers = engine.wantsCore ? engine.activeSubscriptions : []
        let providerNames = providers.map(\.providerName)
        var lines: [String] = []
        lines.append("# 由 ProxySwitch 生成，改动会被覆盖。")
        lines.append("mixed-port: \(engine.wantsCore ? engine.mixedPort : 0)")
        lines.append("allow-lan: false")
        lines.append("bind-address: \"127.0.0.1\"")
        lines.append("mode: rule")
        lines.append("log-level: warning")
        lines.append("ipv6: false")
        // 连接页里显示是哪个程序发起的连接。
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
        if let share = input.share {
            // 谁能连进来：这份名单对所有入口生效，所以本机回环也在里面。
            lines.append("lan-allowed-ips:")
            for prefix in share.allowedPrefixes {
                lines.append("  - \(quote(prefix))")
            }
            // 共享入口监听所有网卡，流量按 sub-rules 里同名的规则组分流；入口本身不随本机状态变，切换上游时只改规则、不断开连接。
            lines.append("listeners:")
            lines.append("  - name: \(quote(shareListener))")
            lines.append("    type: mixed")
            lines.append("    listen: \"0.0.0.0\"")
            lines.append("    port: \(share.port)")
            lines.append("    rule: \(quote(shareListener))")
            if case .proxy(let kind, let host, let port) = share.upstream {
                lines.append("proxies:")
                lines.append("  - name: \(quote(upstreamProxy))")
                lines.append("    type: \(kind == .socks5 ? "socks5" : "http")")
                lines.append("    server: \(quote(host))")
                lines.append("    port: \(port)")
            }
        }
        if !providers.isEmpty {
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
                lines.append("    health-check:")
                lines.append("      enable: true")
                lines.append("      url: \(quote(input.testURL))")
                lines.append("      interval: 600")
                lines.append("      lazy: true")
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
        lines.append("    interval: 600")
        lines.append("    tolerance: 80")
        lines.append("    lazy: true")
        lines.append("    proxies: [\"DIRECT\"]")
        if !useLine.isEmpty { lines.append(useLine) }
        // 自定义策略组：成员是按名字筛选出来的订阅节点。手动选择的组多了「节点」「自动选择」和直连三个候选，默认跟随「节点」；
        // 自动类的组只有筛出来的节点，筛不到时内核退回直连。没加载订阅（只做共享）时组照样要有，规则里引用了它们，
        // 这时自动类的组只有直连一个成员。
        for group in engine.groups {
            lines.append("  - name: \(quote(group.name))")
            lines.append("    type: \(group.kind.coreType)")
            switch group.kind {
            case .select:
                lines.append("    proxies: [\(quote(selectorGroup)), \(quote(autoGroup)), \"DIRECT\"]")
            case .urlTest:
                lines.append("    url: \(quote(input.testURL))")
                lines.append("    interval: 600")
                lines.append("    tolerance: 80")
                lines.append("    lazy: true")
            case .fallback:
                lines.append("    url: \(quote(input.testURL))")
                lines.append("    interval: 600")
                lines.append("    lazy: true")
            case .loadBalance:
                lines.append("    url: \(quote(input.testURL))")
                lines.append("    interval: 600")
                lines.append("    strategy: round-robin")
                lines.append("    lazy: true")
            }
            if useLine.isEmpty {
                if group.kind != .select {
                    lines.append("    proxies: [\"DIRECT\"]")
                }
            } else {
                lines.append(useLine)
                if let filter = group.coreFilter {
                    lines.append("    filter: \(quote(filter))")
                }
            }
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
        lines.append("rules:")
        for rule in rules {
            lines.append("  - \(quote(rule))")
        }
        if let share = input.share {
            lines.append("sub-rules:")
            lines.append("  \(quote(shareListener)):")
            for rule in shareRules(upstream: share.upstream, mainRules: rules) {
                lines.append("    - \(quote(rule))")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 共享入口的分流：本机开着内置代理时和本机完全一样；本机用别的代理时局域网直连、其余转发给它；本机没开代理时全部直连。
    static func shareRules(upstream: ShareUpstream, mainRules: [String]) -> [String] {
        switch upstream {
        case .engine: return mainRules
        case .proxy: return RuleConverter.lanRules + ["MATCH,\(upstreamProxy)"]
        case .direct, .unsupported: return ["MATCH,DIRECT"]
        }
    }

    /// 订阅在内核目录里的文件。
    static func providerPath(for subscription: Subscription, directory: URL) -> URL {
        directory.appendingPathComponent("providers/\(subscription.providerName).yaml")
    }

    /// YAML 的双引号字符串。
    static func quote(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": escaped += "\\\""
            case "\\": escaped += "\\\\"
            case "\n": escaped += "\\n"
            case "\r": escaped += "\\r"
            case "\t": escaped += "\\t"
            default:
                if scalar.value < 0x20 {
                    escaped += String(format: "\\u%04x", scalar.value)
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "\"" + escaped + "\""
    }

    /// 随机的 API 密钥。
    static func makeSecret() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<32).map { _ in alphabet.randomElement()! })
    }
}
