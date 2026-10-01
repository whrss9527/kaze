import XCTest
@testable import ProxiEngine

final class YAMLTests: XCTestCase {
    func testBlockMappingsAndSequences() throws {
        let text = """
        # 注释
        mixed-port: 7890
        allow-lan: false
        name: "带 # 的字符串"
        plain: O'Reilly # 行尾注释
        proxies:
          - name: 香港 01
            type: ss
            server: hk.example.com
            port: 443
            udp: true
          - {name: "日本 02", type: trojan, server: jp.example.com, port: 443, sni: 'a''b'}
        rules:
        - DOMAIN-SUFFIX,google.com,Proxy
        - "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"
        empty:
        list: [a, "b, c", 3]
        """
        let node = try YAMLParser.parse(text)
        XCTAssertEqual(node["mixed-port"]?.int, 7890)
        XCTAssertEqual(node["allow-lan"]?.bool, false)
        XCTAssertEqual(node["name"]?.string, "带 # 的字符串")
        XCTAssertEqual(node["plain"]?.string, "O'Reilly")
        let proxies = try XCTUnwrap(node["proxies"]?.array)
        XCTAssertEqual(proxies.count, 2)
        XCTAssertEqual(proxies[0]["name"]?.string, "香港 01")
        XCTAssertEqual(proxies[0]["port"]?.int, 443)
        XCTAssertEqual(proxies[0]["udp"]?.bool, true)
        XCTAssertEqual(proxies[1]["name"]?.string, "日本 02")
        XCTAssertEqual(proxies[1]["sni"]?.string, "a'b")
        XCTAssertEqual(node["rules"]?.stringArray, ["DOMAIN-SUFFIX,google.com,Proxy", "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve"])
        XCTAssertEqual(node["empty"], .null)
        XCTAssertEqual(node["list"]?.stringArray, ["a", "b, c", "3"])
        XCTAssertEqual(node.keys, ["mixed-port", "allow-lan", "name", "plain", "proxies", "rules", "empty", "list"])
    }

    func testAnchorsMergeKeysAndBlockScalars() throws {
        let text = """
        base: &base
          type: http
          interval: 3600
        providers:
          a:
            <<: *base
            url: "https://a.example.com/sub"
            interval: 60
          b: *base
        script: |
          line one
          line two
        folded: >-
          one
          two
        multi: [
          x,
          y
        ]
        """
        let node = try YAMLParser.parse(text)
        let a = try XCTUnwrap(node["providers"]?["a"])
        XCTAssertEqual(a["type"]?.string, "http")
        XCTAssertEqual(a["url"]?.string, "https://a.example.com/sub")
        XCTAssertEqual(a["interval"]?.int, 60)
        XCTAssertEqual(node["providers"]?["b"]?["interval"]?.int, 3600)
        XCTAssertEqual(node["script"]?.string, "line one\nline two\n")
        XCTAssertEqual(node["folded"]?.string, "one two")
        XCTAssertEqual(node["multi"]?.stringArray, ["x", "y"])
    }

    func testNestedSequencesAndErrors() throws {
        let text = """
        groups:
          - name: A
            proxies:
              - x
              - y
            nested:
              - - 1
                - 2
          - name: B
        """
        let node = try YAMLParser.parse(text)
        let groups = try XCTUnwrap(node["groups"]?.array)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0]["proxies"]?.stringArray, ["x", "y"])
        XCTAssertEqual(groups[0]["nested"]?.array?.first?.stringArray, ["1", "2"])
        XCTAssertEqual(groups[1]["name"]?.string, "B")
        XCTAssertThrowsError(try YAMLParser.parse("a: [1, 2"))
        XCTAssertThrowsError(try YAMLParser.parse("a: \"open"))
        XCTAssertThrowsError(try YAMLParser.parse("a:\n\tb: 1"))
    }

    func testWriterRoundTrip() throws {
        let node = YAMLNode.mapping([
            YAMLPair(key: "port", value: .int(7890)),
            YAMLPair(key: "name", value: .string("节点: 香港 #1")),
            YAMLPair(key: "list", value: .strings(["a", "b"])),
            YAMLPair(key: "empty", value: .sequence([])),
            YAMLPair(key: "items", value: .sequence([
                .mapping([YAMLPair(key: "name", value: .string("x")), YAMLPair(key: "port", value: .int(1))]),
                .mapping([YAMLPair(key: "name", value: .string("y"))]),
            ])),
            YAMLPair(key: "nested", value: .mapping([YAMLPair(key: "enable", value: .bool(true))])),
        ])
        let text = YAMLWriter.write(node)
        XCTAssertTrue(text.contains("port: 7890\n"))
        XCTAssertTrue(text.contains("name: \"节点: 香港 #1\"\n"))
        XCTAssertTrue(text.contains("  - name: \"x\"\n    port: 1\n"))
        XCTAssertEqual(try YAMLParser.parse(text), node)
    }
}

final class CustomRuleKindTests: XCTestCase {
    func testLinesForEachKind() {
        func line(_ pattern: String, _ kind: CustomRuleKind, _ policy: RuleTarget = .direct) -> String? {
            CustomRule(pattern: pattern, policy: policy, kind: kind).line(groups: ["组B"])
        }
        XCTAssertEqual(line("https://www.Example.com/a", .domain), "DOMAIN,www.example.com,DIRECT")
        XCTAssertEqual(line("*.example.com", .suffix), "DOMAIN-SUFFIX,example.com,DIRECT")
        XCTAssertEqual(line("Google", .keyword), "DOMAIN-KEYWORD,google,DIRECT")
        XCTAssertEqual(line("*.example.com", .wildcard), "DOMAIN-WILDCARD,*.example.com,DIRECT")
        XCTAssertEqual(line("^ad\\d+\\.example\\.com$", .regex), "DOMAIN-REGEX,^ad\\d+\\.example\\.com$,DIRECT")
        XCTAssertEqual(line("1.1.1.1", .ip, .proxy), "IP-CIDR,1.1.1.1/32,节点,no-resolve")
        XCTAssertEqual(line("jp", .geoip, .group("组B")), "GEOIP,JP,组B")
        XCTAssertEqual(line("192.168.1.20", .device, .reject), "SRC-IP-CIDR,192.168.1.20/32,REJECT")
        XCTAssertEqual(line("80 / 443", .port), "DST-PORT,80/443,DIRECT")
        XCTAssertEqual(line("/Applications/Messages.app/", .app, .proxy), "PROCESS-PATH-WILDCARD,/Applications/Messages.app/*,节点")
        XCTAssertEqual(line("/usr/local/bin/aria2c", .app), "PROCESS-PATH,/usr/local/bin/aria2c,DIRECT")
        XCTAssertEqual(line("git", .process, .proxy), "PROCESS-NAME,git,节点")
        XCTAssertEqual(line("udp", .network, .reject), "NETWORK,UDP,REJECT")
        XCTAssertEqual(line("AND,((DOMAIN-SUFFIX,example.com),(NETWORK,UDP))", .logic, .reject), "AND,((DOMAIN-SUFFIX,example.com),(NETWORK,UDP)),REJECT")
        XCTAssertNil(line("a,b", .keyword))
        XCTAssertNil(line("[", .regex))
        XCTAssertNil(line("99999", .port))
        XCTAssertNil(line("CHN", .geoip))
        XCTAssertNil(line("AND,(DOMAIN,a.com", .logic))
    }

    func testValidationMessagesAndDecoding() throws {
        XCTAssertNil(CustomRule.validate("8000-9000", kind: .port))
        XCTAssertNotNil(CustomRule.validate("9000-8000", kind: .port))
        XCTAssertNotNil(CustomRule.validate("Messages", kind: .app))
        XCTAssertNotNil(CustomRule.validate("/usr/bin/git", kind: .process))
        XCTAssertNil(CustomRule.validate("LAN", kind: .geoip))
        // 旧配置没有 kind：按「域名或 IP」算。
        let old = try JSONDecoder().decode(CustomRule.self, from: Data(#"{"pattern":"a.com","policy":"direct"}"#.utf8))
        XCTAssertEqual(old.kind, .auto)
        XCTAssertEqual(old.line, "DOMAIN-SUFFIX,a.com,DIRECT")
        XCTAssertEqual(CustomRule.appBundlePath(forProcessPath: "/Applications/Google Chrome.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"), "/Applications/Google Chrome.app")
        XCTAssertNil(CustomRule.appBundlePath(forProcessPath: "/usr/bin/curl"))
        XCTAssertEqual(CustomRule(pattern: "/Applications/Messages.app", policy: .proxy, kind: .app).displayValue, "Messages")
    }
}

final class NodeLinkTests: XCTestCase {
    func testExtractAndNames() {
        let vmessJSON = #"{"v":"2","ps":"香港 VMess","add":"hk.example.com","port":"443","id":"uuid"}"#
        let vmess = "vmess://" + Data(vmessJSON.utf8).base64EncodedString()
        let text = """
        ss://YWVzLTEyOC1nY206cGFzcw@1.2.3.4:8388#%E6%97%A5%E6%9C%AC
        \(vmess)
        trojan://password@us.example.com:443?sni=a#US%20Trojan
        https://sub.example.com/api?token=1
        not a link
        """
        let links = NodeLink.extract(text)
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(ManualNode(link: links[0]).name, "日本")
        XCTAssertEqual(ManualNode(link: links[0]).server, "1.2.3.4:8388")
        XCTAssertEqual(ManualNode(link: links[1]).name, "香港 VMess")
        XCTAssertEqual(ManualNode(link: links[1]).server, "hk.example.com:443")
        XCTAssertEqual(ManualNode(link: links[2]).name, "US Trojan")
        // 订阅常见的 base64 整段。
        let blob = Data(links.joined(separator: "\n").utf8).base64EncodedString()
        XCTAssertEqual(NodeLink.extract(blob), links)
        XCTAssertTrue(NodeLink.isLink("http://user:pass@1.2.3.4:8080"))
        XCTAssertFalse(NodeLink.isLink("https://example.com/sub"))
        XCTAssertEqual(ManualNode(link: "hysteria2://pw@hy.example.com:443").name, "HYSTERIA2 hy.example.com:443")
    }
}

final class AdvancedGroupTests: XCTestCase {
    func testCycleDetectionAndValidation() {
        var a = PolicyGroup(name: "A")
        var b = PolicyGroup(name: "B", kind: .urlTest)
        a.includeGroups = ["B"]
        b.includeGroups = ["A"]
        XCTAssertEqual(PolicyGroup.cycle(in: [a, b]), ["A", "B", "A"])
        XCTAssertNotNil(PolicyGroup.validateAdvanced(b, all: [a, b]))
        b.includeGroups = ["节点"]
        XCTAssertNil(PolicyGroup.validateAdvanced(b, all: [a, b]))
        b.includeGroups = ["不存在"]
        XCTAssertNotNil(PolicyGroup.validateAdvanced(b, all: [a, b]))
        b.includeGroups = []
        b.testURL = "ftp://x"
        XCTAssertNotNil(PolicyGroup.validateAdvanced(b, all: [a, b]))
        b.testURL = ""
        b.interval = 5
        XCTAssertNotNil(PolicyGroup.validateAdvanced(b, all: [a, b]))
        XCTAssertNotNil(PolicyGroup.validate(name: "ps-x", filter: "", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "manual", filter: "", others: []))
    }

    func testExcludeAndEncoding() throws {
        var group = PolicyGroup(name: "香港", kind: .urlTest, filter: "港|HK")
        group.exclude = "过期|剩余"
        XCTAssertEqual(group.matches(["香港 01", "hk 02", "香港 过期", "日本"]), ["香港 01", "hk 02"])
        let plain = try JSONEncoder().encode(PolicyGroup(name: "A"))
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("exclude"))
        group.strategy = .consistentHashing
        let decoded = try JSONDecoder().decode(PolicyGroup.self, from: try JSONEncoder().encode(group))
        XCTAssertEqual(decoded, group)
    }
}

final class AdvancedConfigTests: XCTestCase {
    private func input(_ engine: EngineConfig, profiles: [Profile] = [], share: ShareInputs? = nil, probePort: Int? = nil) -> CoreConfigBuilder.Input {
        CoreConfigBuilder.Input(engine: engine, secret: "s", directory: URL(fileURLWithPath: "/tmp/ps-core"), testURL: "https://cp.cloudflare.com/generate_204", rules: ["MATCH,节点"], share: share, profiles: profiles, probePort: probePort)
    }

    func testDNSHostsIPv6AndManualNodes() throws {
        var engine = EngineConfig()
        engine.ipv6 = true
        engine.dns.enabled = true
        engine.dns.policies = [DNSPolicy(domain: "+.corp.example", servers: ["10.0.0.53"])]
        engine.hosts = [HostEntry(domain: "nas.lan", value: "192.168.1.5"), HostEntry(domain: "*.test", value: "1.1.1.1, 1.0.0.1"), HostEntry(domain: "bad", value: "x y")]
        engine.manualNodes = [ManualNode(link: "ss://YWVzLTEyOC1nY206cGFzcw@1.2.3.4:8388#JP")]
        XCTAssertTrue(engine.wantsCore)
        let yaml = CoreConfigBuilder.yaml(input(engine, probePort: 17999))
        XCTAssertTrue(yaml.contains("ipv6: true\n"))
        XCTAssertTrue(yaml.contains("dns:\n  enable: true\n  ipv6: true\n"))
        XCTAssertTrue(yaml.contains("fallback: [\"https://1.1.1.1/dns-query#节点\", \"https://dns.google/dns-query#节点\"]"))
        XCTAssertTrue(yaml.contains("\"+.corp.example\": [\"10.0.0.53\"]"))
        XCTAssertTrue(yaml.contains("hosts:\n  \"nas.lan\": \"192.168.1.5\"\n  \"*.test\": [\"1.1.1.1\", \"1.0.0.1\"]\n"))
        XCTAssertFalse(yaml.contains("\"bad\""))
        XCTAssertTrue(yaml.contains("  manual:\n    type: file\n    path: \"/tmp/ps-core/providers/manual.txt\"\n"))
        XCTAssertTrue(yaml.contains("use: [manual]"))
        XCTAssertTrue(yaml.contains("name: \"ps-probe\"\n    type: mixed\n    listen: \"127.0.0.1\"\n    port: 17999\n    proxy: \"ps-probe\""))
        XCTAssertTrue(yaml.contains("name: \"ps-probe\"\n    type: select\n    hidden: true"))
        XCTAssertEqual(CoreConfigBuilder.manualNodesText(engine), "ss://YWVzLTEyOC1nY206cGFzcw@1.2.3.4:8388#JP\n")
        // DNS 设置有问题时不写 dns，内核照样能起来。
        engine.dns.nameservers = ["ftp://x"]
        XCTAssertFalse(CoreConfigBuilder.yaml(input(engine)).contains("\ndns:"))
    }

    func testSubscriptionOptionsGroupsAndDialers() throws {
        var engine = EngineConfig()
        var first = Subscription(name: "甲", url: "https://a.example.com/sub")
        first.filter = "港|日"
        first.exclude = "过期"
        first.prefix = "甲 "
        var second = Subscription(name: "乙", url: "https://b.example.com/sub")
        let office = Profile(name: "公司", color: "#000000", kind: .http, host: "10.0.0.1", port: 3128)
        second.dialer = DialerReference.profile(office.id)
        engine.subscriptions = [first, second]
        var media = PolicyGroup(name: "组B", kind: .urlTest, filter: "港")
        media.sources = [first.id]
        media.exclude = "x"
        media.testURL = "https://www.gstatic.com/generate_204"
        media.interval = 300
        media.tolerance = 50
        var balance = PolicyGroup(name: "均衡", kind: .loadBalance)
        balance.strategy = .consistentHashing
        balance.includeGroups = ["组B", "节点", "不存在"]
        engine.groups = [media, balance]
        // 甲的前置是只用甲的组：会绕回自己，不写。
        engine.subscriptions[0].dialer = "组B"
        let yaml = CoreConfigBuilder.yaml(input(engine, profiles: [office]))
        let a = first.providerName
        let b = second.providerName
        XCTAssertTrue(yaml.contains("  \(a):\n    type: http\n"))
        XCTAssertTrue(yaml.contains("    filter: \"(?i)港|日\"\n    exclude-filter: \"(?i)过期\"\n    override:\n      additional-prefix: \"甲 \"\n    health-check:"))
        XCTAssertTrue(yaml.contains("    dialer-proxy: \"前置·公司\"\n"))
        XCTAssertEqual(yaml.components(separatedBy: "dialer-proxy").count, 2)
        XCTAssertTrue(yaml.contains("proxies:\n  - name: \"前置·公司\"\n    type: http\n    server: \"10.0.0.1\"\n    port: 3128\n"))
        XCTAssertTrue(yaml.contains("  - name: \"组B\"\n    type: url-test\n    url: \"https://www.gstatic.com/generate_204\"\n    interval: 300\n    tolerance: 50\n    lazy: true\n    use: [\(a)]\n    filter: \"(?i)港\"\n    exclude-filter: \"(?i)x\"\n"))
        XCTAssertTrue(yaml.contains("  - name: \"均衡\"\n    type: load-balance\n    url: \"https://cp.cloudflare.com/generate_204\"\n    interval: 600\n    strategy: consistent-hashing\n    lazy: true\n    proxies: [\"组B\", \"节点\"]\n    use: [\(a), \(b)]\n"))
        XCTAssertTrue(CoreConfigBuilder.dialerLoops("节点", provider: a, engine: engine))
        XCTAssertTrue(CoreConfigBuilder.dialerLoops("组B", provider: a, engine: engine))
        XCTAssertFalse(CoreConfigBuilder.dialerLoops("组B", provider: b, engine: engine))
        XCTAssertFalse(CoreConfigBuilder.dialerLoops("某个节点", provider: a, engine: engine))
    }

    func testDeviceRulesFollowShareWithoutEngine() {
        var engine = EngineConfig()
        engine.customRules = [
            CustomRule(pattern: "192.168.1.20", policy: .reject, kind: .device),
            CustomRule(pattern: "192.168.1.21", policy: .direct, kind: .device),
            CustomRule(pattern: "192.168.1.22", policy: .proxy, kind: .device),
        ]
        let devices = CoreConfigBuilder.deviceRuleLines(engine)
        XCTAssertEqual(devices, ["SRC-IP-CIDR,192.168.1.20/32,REJECT", "SRC-IP-CIDR,192.168.1.21/32,DIRECT"])
        XCTAssertEqual(CoreConfigBuilder.shareRules(upstream: .direct, mainRules: [], deviceRules: devices), ["SRC-IP-CIDR,192.168.1.20/32,REJECT", "MATCH,DIRECT"])
        let proxied = CoreConfigBuilder.shareRules(upstream: .proxy(kind: .http, host: "h", port: 1), mainRules: [], deviceRules: devices)
        XCTAssertEqual(Array(proxied.suffix(3)), ["SRC-IP-CIDR,192.168.1.20/32,REJECT", "SRC-IP-CIDR,192.168.1.21/32,DIRECT", "MATCH,上游代理"])
    }

    func testPatchMerge() throws {
        var engine = EngineConfig()
        engine.subscriptions = [Subscription(name: "甲", url: "https://a.example.com/sub")]
        engine.patch = """
        secret: hacked
        log-level: info
        rules:
          - DOMAIN-SUFFIX,example.org,DIRECT
        proxy-groups:
          - name: 节点
            type: select
            proxies: [DIRECT]
          - name: 额外
            type: select
            proxies: [DIRECT]
        sniffer:
          sniff:
            QUIC:
              ports: [443]
        tun:
          enable: false
        """
        let built = CoreConfigBuilder.build(input(engine))
        XCTAssertNil(built.patchProblem)
        XCTAssertEqual(built.patchNotes.count, 1)
        let node = try YAMLParser.parse(built.text)
        XCTAssertEqual(node["secret"]?.string, "s")
        XCTAssertEqual(node["log-level"]?.string, "info")
        XCTAssertEqual(node["rules"]?.stringArray?.first, "DOMAIN-SUFFIX,example.org,DIRECT")
        let groups = try XCTUnwrap(node["proxy-groups"]?.array)
        XCTAssertEqual(groups.first?["proxies"]?.stringArray, ["DIRECT"])
        XCTAssertEqual(groups.last?["name"]?.string, "额外")
        XCTAssertEqual(node["sniffer"]?["sniff"]?["TLS"]?["ports"]?.stringArray, ["443", "8443"])
        XCTAssertEqual(node["sniffer"]?["sniff"]?["QUIC"]?["ports"]?.stringArray, ["443"])
        XCTAssertEqual(node["tun"]?["enable"]?.bool, false)
        XCTAssertEqual(node["mixed-port"]?.int, 7890)
        engine.patch = "just text"
        XCTAssertNotNil(CoreConfigBuilder.build(input(engine)).patchProblem)
        engine.patch = "a: [1"
        let broken = CoreConfigBuilder.build(input(engine))
        XCTAssertNotNil(broken.patchProblem)
        XCTAssertEqual(broken.text, CoreConfigBuilder.yaml(input(engine)))
    }

    func testGeneratedConfigParsesWithOwnParser() throws {
        var engine = EngineConfig()
        engine.subscriptions = [Subscription(name: "甲", url: "https://a.example.com/sub?token=\"x\"")]
        engine.groups = [PolicyGroup(name: "组B", kind: .select, filter: "港")]
        engine.customRules = [CustomRule(pattern: "video.example", policy: .group("组B"))]
        engine.dns.enabled = true
        engine.hosts = [HostEntry(domain: "a.lan", value: "10.0.0.2")]
        let share = ShareInputs(port: 7892, allowedPrefixes: ShareConfig().allowedPrefixes, upstream: .engine)
        let text = CoreConfigBuilder.yaml(input(engine, share: share, probePort: 18000))
        let node = try YAMLParser.parse(text)
        XCTAssertEqual(node["proxy-providers"]?.keys.count, 1)
        XCTAssertEqual(node["listeners"]?.array?.count, 2)
        XCTAssertEqual(node["sub-rules"]?["lan-share"]?.array?.count, node["rules"]?.array?.count)
        // 写回再解析，内容不变。
        XCTAssertEqual(try YAMLParser.parse(YAMLWriter.write(node)), node)
    }
}

final class RuleConverterAdvancedTests: XCTestCase {
    func testLogicDomainSetAndAliases() {
        let text = """
        [Rule]
        DOMAIN-SUFFIX,a.com,DIRECT
        DOMAIN-SET,https://example.com/set.txt,Proxy
        AND,((DOMAIN-SUFFIX,b.com),(DEST-PORT,443)),REJECT
        OR,((PROTOCOL,UDP),(SRC-IP,192.168.1.2)),DIRECT
        AND,((USER-AGENT,x*),(DOMAIN,c.com)),REJECT
        SRC-IP,192.168.1.3,DIRECT
        DEST-PORT,22,Proxy
        PROTOCOL,QUIC,REJECT
        RULE-SET,https://example.com/list.txt,Media
        FINAL,DIRECT
        """
        let converted = RuleConverter.convert(text, groups: ["Media"])
        XCTAssertEqual(converted.rules, [
            "DOMAIN-SUFFIX,a.com,DIRECT",
            "AND,((DOMAIN-SUFFIX,b.com),(DST-PORT,443)),REJECT",
            "OR,((NETWORK,UDP),(SRC-IP-CIDR,192.168.1.2/32)),DIRECT",
            "SRC-IP-CIDR,192.168.1.3/32,DIRECT",
            "DST-PORT,22,节点",
            "MATCH,DIRECT",
        ])
        XCTAssertEqual(converted.ruleSets.map(\.url), ["https://example.com/set.txt", "https://example.com/list.txt"])
        XCTAssertEqual(converted.ruleSets.map(\.policy), ["节点", "Media"])
        XCTAssertEqual(converted.skipped, 2)
        // 引用的规则集放回原来的位置。
        let merged = RuleConverter.merge(converted, ruleSetRules: [
            "https://example.com/set.txt": RuleConverter.convert(".set.com\nexact.com", defaultPolicy: "节点").rules,
            "https://example.com/list.txt": ["DOMAIN,list.com,Media"],
        ])
        XCTAssertEqual(merged, [
            "DOMAIN-SUFFIX,a.com,DIRECT",
            "DOMAIN-SUFFIX,set.com,节点",
            "DOMAIN,exact.com,节点",
            "AND,((DOMAIN-SUFFIX,b.com),(DST-PORT,443)),REJECT",
            "OR,((NETWORK,UDP),(SRC-IP-CIDR,192.168.1.2/32)),DIRECT",
            "SRC-IP-CIDR,192.168.1.3/32,DIRECT",
            "DST-PORT,22,节点",
            "DOMAIN,list.com,Media",
            "MATCH,DIRECT",
        ])
    }
}

final class DNSSettingsTests: XCTestCase {
    func testServerValidation() {
        XCTAssertNil(DNSSettings.validateServer("223.5.5.5"))
        XCTAssertNil(DNSSettings.validateServer("1.1.1.1:53"))
        XCTAssertNil(DNSSettings.validateServer("[2606:4700::1111]:53"))
        XCTAssertNil(DNSSettings.validateServer("https://doh.pub/dns-query"))
        XCTAssertNil(DNSSettings.validateServer("tls://dns.alidns.com"))
        XCTAssertNil(DNSSettings.validateServer("quic://dns.adguard.com"))
        XCTAssertNil(DNSSettings.validateServer("system"))
        XCTAssertNotNil(DNSSettings.validateServer("dns.google"))
        XCTAssertNotNil(DNSSettings.validateServer("ftp://x"))
        XCTAssertNotNil(DNSSettings.validateServer("1.1.1.1, 8.8.8.8"))
        var dns = DNSSettings()
        dns.enabled = true
        XCTAssertNil(dns.validate())
        dns.bootstrap = ["dns.google"]
        XCTAssertNotNil(dns.validate())
        XCTAssertEqual(DNSSettings.parseList("1.1.1.1, 8.8.8.8\nhttps://x/dns-query"), ["1.1.1.1", "8.8.8.8", "https://x/dns-query"])
        XCTAssertNil(HostEntry(domain: "a.lan", value: "b.lan").validate())
        XCTAssertNotNil(HostEntry(domain: "a.lan", value: "1.2.3").validate())
        XCTAssertTrue(HostEntry.validDomainPattern("+.example.com"))
        XCTAssertTrue(HostEntry.validDomainPattern("router"))
        XCTAssertFalse(HostEntry.validDomainPattern("a b"))
    }
}
