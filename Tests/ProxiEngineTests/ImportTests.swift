import XCTest
@testable import ProxiEngine

final class ImportTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/ps-imports")

    func testDetectFormats() {
        XCTAssertEqual(ConfigImporter.detect(#"{"proxi":1,"rules":[]}"#), .proxi)
        XCTAssertEqual(ConfigImporter.detect(#"{"proxi":1,"kind":"backup","config":{}}"#), .backup)
        XCTAssertEqual(ConfigImporter.detect("proxies:\n  - {name: a, type: ss, server: x, port: 1, cipher: aes-128-gcm, password: p}\nrules:\n  - MATCH,DIRECT"), .clash)
        XCTAssertEqual(ConfigImporter.detect("[General]\ndns-server = 223.5.5.5\n[Rule]\nFINAL,DIRECT"), .surge)
        XCTAssertEqual(ConfigImporter.detect("[server_local]\n[filter_local]\nfinal, direct"), .quantumult)
        XCTAssertEqual(ConfigImporter.detect("trojan://pw@a.example.com:443#A"), .links)
        XCTAssertEqual(ConfigImporter.detect("payload:\n  - '+.google.com'"), .ruleList)
        XCTAssertEqual(ConfigImporter.detect("DOMAIN-SUFFIX,google.com\nDOMAIN,a.com"), .ruleList)
        XCTAssertNil(ConfigImporter.detect("hello world"))
        XCTAssertTrue(ConfigImporter.looksLikeSubscription("proxies:\n  - {name: a, type: ss, server: x, port: 1}"))
        XCTAssertFalse(ConfigImporter.looksLikeSubscription("rules:\n  - MATCH,DIRECT"))
    }

    func testProxiDocument() throws {
        let text = """
        {
          "proxi": 1,
          "mode": "rule",
          "subscriptions": [{"name": "订阅 A", "url": "https://sub.example.com/a", "exclude": "过期"}, "https://sub2.example.com/b", {"name": "坏的", "url": "ftp://x"}],
          "nodes": ["trojan://pw@a.example.com:443#A"],
          "groups": [{"name": "AI", "type": "url-test", "filter": "a|b", "subscriptions": ["订阅 A"]}, {"name": "组 B", "type": "select", "groups": ["AI"]}],
          "rules": [{"type": "suffix", "value": "example.org", "policy": "AI"}, "DOMAIN-SUFFIX,bank.example,直连", {"type": "app", "value": "/Applications/Safari.app", "policy": "proxy"}, "GEOSITE,cn,DIRECT"],
          "ruleSets": [{"url": "https://example.com/ad.list", "policy": "reject"}],
          "final": "proxy",
          "dns": {"nameservers": ["https://doh.pub/dns-query"], "policies": {"+.corp.example": "10.0.0.53"}},
          "hosts": {"nas.lan": "192.168.1.5"},
          "profiles": [{"name": "公司", "type": "http", "host": "10.0.0.1", "port": 8080}],
          "networkRules": [{"ssid": "Office", "action": "profile:公司"}, {"other": true, "action": "mode:rule"}, {"ssid": "x", "action": "bogus"}],
          "extra": 1
        }
        """
        let plan = try ConfigImporter.plan(text, sourceName: "AI")
        XCTAssertEqual(plan.format, .proxi)
        XCTAssertEqual(plan.subscriptions.map(\.name), ["订阅 A", "sub2.example.com"])
        XCTAssertEqual(plan.subscriptions[0].exclude, "过期")
        XCTAssertEqual(plan.manualNodes.count, 1)
        XCTAssertEqual(plan.groups.map(\.name), ["AI", "组 B"])
        XCTAssertEqual(plan.groups[0].sources, [plan.subscriptions[0].id])
        XCTAssertEqual(plan.groups[1].includeGroups, ["AI"])
        XCTAssertEqual(plan.customRules.map(\.policy), [.group("AI"), .direct, .proxy])
        XCTAssertEqual(plan.customRules.map(\.kind), [.suffix, .suffix, .app])
        XCTAssertEqual(plan.ruleSets.first?.policy, .reject)
        XCTAssertEqual(plan.finalPolicy, .proxy)
        XCTAssertEqual(plan.dns?.enabled, true)
        XCTAssertEqual(plan.dns?.policies.first?.servers, ["10.0.0.53"])
        XCTAssertEqual(plan.hosts.count, 1)
        XCTAssertEqual(plan.profiles.first?.port, 8080)
        XCTAssertEqual(plan.networkRules.count, 2)
        XCTAssertEqual(plan.networkRules[0].action, .profile(plan.profiles[0].id))
        XCTAssertTrue(plan.warnings.contains { $0.contains("extra") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("坏的") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("GEOSITE") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("bogus") })

        var current = AppConfig()
        current.engine.subscriptions = [Subscription(name: "旧的", url: "https://sub.example.com/a")]
        current.engine.customRules = [CustomRule(pattern: "example.org", policy: .proxy, kind: .suffix)]
        let merged = ConfigImporter.apply(plan, to: current, mode: .merge, directory: directory)
        XCTAssertEqual(merged.config.engine.subscriptions.count, 2)
        XCTAssertEqual(merged.config.engine.subscriptions[0].name, "订阅 A")
        // 策略组的来源换成已有订阅的 id。
        XCTAssertEqual(merged.config.engine.groups[0].sources, [current.engine.subscriptions[0].id])
        XCTAssertEqual(merged.config.engine.customRules.count, 3)
        XCTAssertEqual(merged.config.engine.customRules[0].policy, .group("AI"))
        XCTAssertEqual(merged.config.engine.ruleSets.count, 1)
        XCTAssertEqual(merged.config.profiles.count, 1)
        XCTAssertEqual(merged.config.automation.networkRules.count, 2)
        let replaced = ConfigImporter.apply(plan, to: current, mode: .replace, directory: directory)
        XCTAssertEqual(replaced.config.engine.ruleSets.map(\.url), ["https://example.com/ad.list"])
    }

    func testClashConfig() throws {
        let text = """
        mixed-port: 7890
        mode: rule
        ipv6: false
        dns:
          enable: true
          nameserver: [223.5.5.5, "https://doh.pub/dns-query"]
          fallback: ["https://1.1.1.1/dns-query#Proxy"]
          nameserver-policy:
            "geosite:cn": 223.5.5.5
            "+.corp.example,+.lan": 10.0.0.53
          enhanced-mode: fake-ip
        hosts:
          router.lan: 192.168.1.1
        proxies:
          - {name: 香港01, type: ss, server: hk.example.com, port: 8388, cipher: aes-128-gcm, password: p}
          - name: 日本01
            type: trojan
            server: jp.example.com
            port: 443
            password: p
        proxy-providers:
          airport:
            type: http
            url: https://sub.example.com/clash
            filter: 港|日
            override:
              additional-prefix: "A "
          local:
            type: file
            path: ./a.yaml
        proxy-groups:
          - name: Proxy
            type: select
            proxies: [自动选择, 香港01, 日本01, DIRECT]
          - name: 自动选择
            type: url-test
            use: [airport]
            url: http://www.gstatic.com/generate_204
            interval: 300
          - name: 广告
            type: select
            proxies: [REJECT, DIRECT]
          - name: 中继
            type: relay
            proxies: [香港01, 日本01]
        rule-providers:
          reject:
            type: http
            behavior: domain
            url: https://example.com/reject.yaml
          cn:
            type: http
            behavior: ipcidr
            format: mrs
            url: https://example.com/cn.mrs
          inline:
            type: inline
            behavior: domain
            payload: ['+.inline.example', exact.example]
        rules:
          - DOMAIN-SUFFIX,google.com,Proxy
          - RULE-SET,reject,广告
          - RULE-SET,inline,DIRECT
          - RULE-SET,cn,DIRECT
          - GEOSITE,cn,DIRECT
          - AND,((DOMAIN,a.com),(NETWORK,UDP)),自动选择
          - GEOIP,CN,DIRECT
          - MATCH,Proxy
        """
        let plan = try ConfigImporter.plan(text, sourceName: "订阅A配置")
        XCTAssertEqual(plan.format, .clash)
        XCTAssertEqual(ConfigImporter.countProxies(in: plan.nodeFile?.content ?? ""), 2)
        XCTAssertEqual(plan.subscriptions.map(\.name), ["airport"])
        XCTAssertEqual(plan.subscriptions[0].filter, "港|日")
        XCTAssertEqual(plan.subscriptions[0].prefix, "A ")
        // 「广告」默认就是拦截：不建成组，规则直接拦截（建成组的话默认跟随「节点」，广告反而走了代理）。
        XCTAssertEqual(plan.groups.map(\.name), ["Proxy", "自动选择组"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("广告") })
        XCTAssertEqual(plan.groups[0].includeGroups, ["自动选择组"])
        XCTAssertEqual(plan.groups[0].filter, "^(香港01|日本01)$")
        XCTAssertEqual(plan.groups[1].sources, [plan.subscriptions[0].id])
        XCTAssertEqual(plan.groups[1].testURL, "http://www.gstatic.com/generate_204")
        XCTAssertEqual(plan.groups[1].interval, 300)
        let rules = try YAMLParser.parse(plan.ruleFile?.content ?? "")["rules"]?.stringArray ?? []
        XCTAssertEqual(rules, [
            "DOMAIN-SUFFIX,google.com,Proxy",
            "RULE-SET,https://example.com/reject.yaml,REJECT",
            "DOMAIN-SUFFIX,inline.example,DIRECT",
            "DOMAIN,exact.example,DIRECT",
            "AND,((DOMAIN,a.com),(NETWORK,UDP)),自动选择组",
            "GEOIP,CN,DIRECT",
            "MATCH,Proxy",
        ])
        XCTAssertEqual(plan.ruleSets.map(\.url), ["https://example.com/cn.mrs"])
        XCTAssertEqual(plan.dns?.nameservers, ["223.5.5.5", "https://doh.pub/dns-query"])
        XCTAssertEqual(plan.dns?.fallback, ["https://1.1.1.1/dns-query"])
        XCTAssertEqual(plan.dns?.fallbackViaProxy, true)
        XCTAssertEqual(plan.dns?.policies.map(\.domain), ["+.corp.example", "+.lan"])
        XCTAssertEqual(plan.hosts.first?.domain, "router.lan")
        XCTAssertEqual(plan.mode, .rule)
        XCTAssertTrue(plan.warnings.contains { $0.contains("local") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("中继") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("fake-ip") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("GEOSITE") })

        let result = ConfigImporter.apply(plan, to: AppConfig(), mode: .merge, directory: directory)
        XCTAssertEqual(result.files.count, 2)
        let engine = result.config.engine
        XCTAssertEqual(engine.subscriptions.count, 2)
        XCTAssertTrue(engine.subscriptions[1].url.hasPrefix("file:///tmp/ps-imports/"))
        let imported = try XCTUnwrap(engine.ruleSets.last)
        XCTAssertEqual(imported.converted, true)
        XCTAssertNil(imported.policy)
        XCTAssertEqual(imported.kind, .inline)
        XCTAssertNil(engine.finalPolicy)
        // 转换后的规则：组名对上导入的组。
        let converted = RuleConverter.convert(result.files[1].content, groups: engine.groupNames)
        XCTAssertEqual(converted.rules.first, "DOMAIN-SUFFIX,google.com,Proxy")
        XCTAssertTrue(converted.rules.contains("AND,((DOMAIN,a.com),(NETWORK,UDP)),自动选择组"))
        XCTAssertEqual(converted.rules.last, "MATCH,Proxy")

        // 来自网址：节点直接当订阅，规则直接用网址当规则集。
        let remote = try ConfigImporter.plan("proxies:\n  - {name: a, type: ss, server: x, port: 1, cipher: aes-128-gcm, password: p}\nrules:\n  - DOMAIN,a.com,DIRECT\n  - MATCH,DIRECT", sourceName: "x", sourceURL: "https://sub.example.com/c")
        XCTAssertEqual(remote.subscriptions.map(\.url), ["https://sub.example.com/c"])
        XCTAssertNil(remote.nodeFile)
        XCTAssertEqual(remote.ruleSets.map(\.url), ["https://sub.example.com/c"])
        XCTAssertEqual(remote.ruleSets.first?.converted, true)

        // 来自网址、但规则要改写（规则集展开成网址、组名改了）：不能直接用远程配置，写成本机的规则文件。
        let rewritten = try ConfigImporter.plan("proxies:\n  - {name: a, type: ss, server: x, port: 1, cipher: aes-128-gcm, password: p}\nrule-providers:\n  ad:\n    type: http\n    behavior: domain\n    url: https://example.com/ad.yaml\nrules:\n  - RULE-SET,ad,REJECT\n  - MATCH,DIRECT", sourceName: "x", sourceURL: "https://sub.example.com/c")
        XCTAssertTrue(rewritten.ruleSets.isEmpty)
        let rewrittenRules = try YAMLParser.parse(rewritten.ruleFile?.content ?? "")["rules"]?.stringArray ?? []
        XCTAssertEqual(rewrittenRules, ["RULE-SET,https://example.com/ad.yaml,REJECT", "MATCH,DIRECT"])
    }

    func testSurgeConfig() throws {
        let text = """
        [General]
        dns-server = system, 223.5.5.5
        encrypted-dns-server = https://doh.pub/dns-query
        ipv6 = true

        [Proxy]
        香港 = ss, hk.example.com, 8388, encrypt-method=aes-128-gcm, password=p, obfs=http, obfs-host=a.com, udp-relay=true
        日本 = vmess, jp.example.com, 443, username=uuid-1, ws=true, ws-path=/ws, ws-headers=Host:jp.example.com, tls=true, sni=jp.example.com
        美国 = trojan, us.example.com, 443, password=p, sni=us.example.com
        公司 = http, 10.0.0.1, 8080, user, pass
        WG = wireguard, section-name=a
        直连 = direct

        [Proxy Group]
        Proxy = select, 自动, 香港, 日本, DIRECT
        自动 = url-test, 香港, 日本, 美国, url=http://www.gstatic.com/generate_204, interval=300
        外部 = select, policy-path=https://example.com/list.txt

        [Rule]
        DOMAIN-SUFFIX,google.com,Proxy
        RULE-SET,https://example.com/ad.list,REJECT
        GEOIP,CN,DIRECT
        FINAL,Proxy

        [Host]
        router.lan = 192.168.1.1
        a.com = server:syslib

        [URL Rewrite]
        ^http://a.com - reject
        """
        let plan = try ConfigImporter.plan(text, sourceName: "surge")
        XCTAssertEqual(plan.format, .surge)
        XCTAssertEqual(plan.dns?.nameservers, ["https://doh.pub/dns-query", "223.5.5.5"])
        XCTAssertEqual(plan.ipv6, true)
        let proxies = try YAMLParser.parse(plan.nodeFile?.content ?? "")["proxies"]?.array ?? []
        XCTAssertEqual(proxies.compactMap { $0["name"]?.string }, ["香港", "日本", "美国", "公司"])
        XCTAssertEqual(proxies[0]["plugin-opts"]?["host"]?.string, "a.com")
        XCTAssertEqual(proxies[1]["ws-opts"]?["headers"]?["Host"]?.string, "jp.example.com")
        XCTAssertEqual(proxies[3]["username"]?.string, "user")
        XCTAssertTrue(plan.warnings.contains { $0.contains("WG") })
        XCTAssertEqual(plan.groups.map(\.name), ["Proxy", "自动", "外部"])
        XCTAssertEqual(plan.groups[0].includeGroups, ["自动"])
        XCTAssertEqual(plan.groups[0].filter, "^(香港|日本)$")
        XCTAssertEqual(plan.groups[1].interval, 300)
        XCTAssertTrue(plan.warnings.contains { $0.contains("policy-path") })
        XCTAssertTrue(plan.ruleFile?.content.hasPrefix("[Rule]\n") ?? false)
        XCTAssertEqual(plan.hosts.map(\.domain), ["router.lan"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("[url rewrite]") })
        let converted = RuleConverter.convert(plan.ruleFile?.content ?? "", groups: plan.groups.map(\.name))
        XCTAssertEqual(converted.rules, ["DOMAIN-SUFFIX,google.com,Proxy", "GEOIP,CN,DIRECT", "MATCH,Proxy"])
        XCTAssertEqual(converted.ruleSets.map(\.url), ["https://example.com/ad.list"])
    }

    func testQuantumultConfig() throws {
        let text = """
        [dns]
        server=223.5.5.5
        server=/*.corp.example/10.0.0.53
        doh-server=https://doh.pub/dns-query

        [policy]
        static=节点选择, 自动, 香港, direct
        url-latency-benchmark=自动, 香港, 日本, check-interval=600
        dest-hash=均衡, server-tag-regex=港

        [server_remote]
        https://sub.example.com/qx, tag=订阅A, enabled=true

        [filter_remote]
        https://example.com/ad.list, tag=广告, force-policy=reject, enabled=true
        https://example.com/media.list, tag=组B, enabled=true

        [server_local]
        shadowsocks=hk.example.com:8388, method=aes-128-gcm, password=p, obfs=http, obfs-host=a.com, tag=香港
        vmess=jp.example.com:443, method=chacha20-ietf-poly1305, password=uuid-1, obfs=wss, obfs-uri=/ws, obfs-host=jp.example.com, tag=日本
        trojan=us.example.com:443, password=p, over-tls=true, tls-host=us.example.com, tag=美国

        [filter_local]
        host-suffix, google.com, 节点选择
        ip-cidr, 10.0.0.0/8, direct
        geoip, cn, direct
        final, 节点选择

        [rewrite_local]
        ^http://a.com url reject
        """
        let plan = try ConfigImporter.plan(text, sourceName: "qx")
        XCTAssertEqual(plan.format, .quantumult)
        XCTAssertEqual(plan.dns?.nameservers.first, "https://doh.pub/dns-query")
        XCTAssertEqual(plan.dns?.policies.first?.domain, "+.corp.example")
        XCTAssertEqual(plan.subscriptions.map(\.name), ["订阅A"])
        XCTAssertEqual(ConfigImporter.countProxies(in: plan.nodeFile?.content ?? ""), 3)
        XCTAssertEqual(plan.groups.map(\.name), ["节点选择", "自动", "均衡"])
        XCTAssertEqual(plan.groups[0].includeGroups, ["自动"])
        XCTAssertEqual(plan.groups[2].strategy, .consistentHashing)
        XCTAssertEqual(plan.groups[2].filter, "港")
        XCTAssertEqual(plan.ruleSets.map(\.policy), [.reject, nil])
        XCTAssertEqual(plan.ruleSets.last?.converted, true)
        let converted = RuleConverter.convert(plan.ruleFile?.content ?? "", groups: plan.groups.map(\.name))
        XCTAssertEqual(converted.rules, ["DOMAIN-SUFFIX,google.com,节点选择", "IP-CIDR,10.0.0.0/8,DIRECT", "GEOIP,CN,DIRECT", "MATCH,节点选择"])
        XCTAssertTrue(plan.warnings.contains { $0.contains("rewrite_local") })
    }

    func testLinksRuleListsAndBackup() throws {
        let links = try ConfigImporter.plan("trojan://pw@a.example.com:443#A\nss://YWVzLTEyOC1nY206cGFzcw@1.2.3.4:8388#B", sourceName: "粘贴")
        XCTAssertEqual(links.manualNodes.count, 2)
        let remoteLinks = try ConfigImporter.plan("trojan://pw@a.example.com:443#A", sourceName: "x", sourceURL: "https://sub.example.com/s")
        XCTAssertEqual(remoteLinks.subscriptions.count, 1)
        XCTAssertTrue(remoteLinks.manualNodes.isEmpty)
        let list = try ConfigImporter.plan("DOMAIN-SUFFIX,a.com\nDOMAIN,b.com", sourceName: "我的列表")
        XCTAssertNotNil(list.ruleFile)
        let applied = ConfigImporter.apply(list, to: AppConfig(), mode: .merge, directory: directory)
        XCTAssertEqual(applied.config.engine.ruleSets.last?.policy, .proxy)
        XCTAssertNil(applied.config.engine.ruleSets.last?.converted)
        XCTAssertThrowsError(try ConfigImporter.plan("not a config at all", sourceName: "x"))

        var config = AppConfig()
        config.profiles = [Profile(name: "公司", color: "#000000")]
        config.engine.customRules = [CustomRule(pattern: "a.com", policy: .direct)]
        config.engine.mixedPort = 7777
        let backup = try ConfigImporter.backupJSON(config)
        let plan = try ConfigImporter.plan(backup, sourceName: "备份")
        XCTAssertEqual(plan.format, .backup)
        var current = AppConfig()
        current.engine.mixedPort = 7890
        let restored = ConfigImporter.apply(plan, to: current, mode: .replace, directory: directory)
        XCTAssertEqual(restored.config.profiles.map(\.name), ["公司"])
        XCTAssertEqual(restored.config.engine.customRules.count, 1)
        XCTAssertEqual(restored.config.engine.mixedPort, 7890)
        let merged = ConfigImporter.apply(plan, to: current, mode: .merge, directory: directory)
        XCTAssertEqual(merged.config.engine.customRules.count, 1)
        XCTAssertEqual(merged.config.profiles.count, 1)
    }

    func testDescribeRoundTrip() throws {
        var config = AppConfig()
        var subscription = Subscription(name: "订阅A", url: "https://sub.example.com/a")
        subscription.filter = "港"
        config.engine.subscriptions = [subscription]
        var group = PolicyGroup(name: "组B", kind: .loadBalance, filter: "港")
        group.sources = [subscription.id]
        group.strategy = .stickySessions
        config.engine.groups = [group]
        config.engine.customRules = [CustomRule(pattern: "media.example", policy: .group("组B"), kind: .suffix)]
        config.engine.hosts = [HostEntry(domain: "nas.lan", value: "192.168.1.5")]
        config.profiles = [Profile(name: "公司", color: "#000000", host: "10.0.0.1", port: 8080)]
        config.automation.networkRules = [NetworkRule(match: .ssid("Office"), action: .profile(config.profiles[0].id))]
        let json = ConfigImporter.describeJSON(config)
        let plan = try ConfigImporter.plan(json, sourceName: "描述")
        XCTAssertEqual(plan.subscriptions.first?.filter, "港")
        XCTAssertEqual(plan.groups.first?.strategy, .stickySessions)
        XCTAssertEqual(plan.groups.first?.sources, [plan.subscriptions[0].id])
        XCTAssertEqual(plan.customRules.first?.policy, .group("组B"))
        XCTAssertEqual(plan.networkRules.first?.match, .ssid("Office"))
        XCTAssertEqual(plan.hosts.first?.value, "192.168.1.5")
    }

    func testHiddenSecretsRoundTrip() throws {
        var config = AppConfig()
        var subscription = Subscription(name: "订阅A", url: "https://sub.example.com/api/v1/sub?token=SECRET1")
        subscription.filter = "港"
        let local = Subscription(name: "本机", url: "file:///tmp/ps-imports/nodes.yaml")
        config.engine.subscriptions = [subscription, local]
        let node = ManualNode(link: "trojan://SECRET2@a.example.com:443#香港 01")
        config.engine.manualNodes = [node]
        let publicSet = RuleSet(name: "公开", url: "https://raw.githubusercontent.com/a/b/master/ad.list", policy: .reject)
        let privateSet = RuleSet(name: "私人", url: "https://rules.example.com/my.list?key=SECRET3", policy: .direct)
        config.engine.ruleSets = [publicSet, privateSet]
        var group = PolicyGroup(name: "香港", kind: .urlTest, filter: "港")
        group.sources = [subscription.id, ManualNode.sourceID]
        config.engine.groups = [group]

        // 导出的描述和备份里没有令牌和密码。
        let hidden = ConfigImporter.hidingSecrets(config)
        XCTAssertEqual(hidden.engine.subscriptions[0].url, "https://sub.example.com/__hidden__")
        XCTAssertEqual(hidden.engine.subscriptions[1].url, local.url)
        XCTAssertEqual(hidden.engine.ruleSets[0].url, publicSet.url)
        XCTAssertEqual(hidden.engine.ruleSets[1].url, "https://rules.example.com/__hidden__")
        XCTAssertEqual(hidden.engine.manualNodes[0].link, "hidden://香港 01")
        let json = ConfigImporter.describeJSON(hidden)
        let backup = try ConfigImporter.backupJSON(hidden)
        for text in [json, backup] {
            for secret in ["SECRET1", "SECRET2", "SECRET3"] {
                XCTAssertFalse(text.contains(secret), secret)
            }
        }

        // 改了隐藏的订阅的筛选再导入：地址用现有的，改动生效，id 不变。
        let edited = json.replacingOccurrences(of: "\"filter\" : \"港\"", with: "\"filter\" : \"港|HK\"")
        XCTAssertNotEqual(edited, json)
        let plan = try ConfigImporter.plan(edited, sourceName: "描述", existing: config)
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
        XCTAssertEqual(plan.subscriptions.map(\.url), [subscription.url, local.url])
        XCTAssertEqual(plan.manualNodes.map(\.link), [node.link])
        XCTAssertEqual(plan.ruleSets.map(\.url), [publicSet.url, privateSet.url])
        for mode in [ImportMode.merge, .replace] {
            let result = ConfigImporter.apply(plan, to: config, mode: mode, directory: directory).config.engine
            XCTAssertEqual(result.subscriptions.map(\.id), [subscription.id, local.id], "\(mode)")
            XCTAssertEqual(result.subscriptions.map(\.url), [subscription.url, local.url], "\(mode)")
            XCTAssertEqual(result.subscriptions[0].filter, "港|HK", "\(mode)")
            XCTAssertEqual(result.manualNodes, [node], "\(mode)")
            XCTAssertEqual(result.ruleSets.map(\.id), [publicSet.id, privateSet.id], "\(mode)")
            XCTAssertEqual(result.ruleSets.map(\.url), [publicSet.url, privateSet.url], "\(mode)")
            XCTAssertEqual(result.groups.first?.sources, [subscription.id, ManualNode.sourceID], "\(mode)")
        }

        // 现有设置里没有的隐藏项：提示并跳过。
        let orphan = try ConfigImporter.plan(json, sourceName: "描述", existing: AppConfig())
        XCTAssertEqual(orphan.subscriptions.map(\.url), [local.url])
        XCTAssertTrue(orphan.manualNodes.isEmpty)
        XCTAssertEqual(orphan.ruleSets.map(\.url), [publicSet.url])
        XCTAssertEqual(orphan.warnings.count, 3)

        // 隐藏了的备份：在这台机器上恢复时换回现有的地址和链接，找不到的去掉。
        let backupPlan = try ConfigImporter.plan(backup, sourceName: "备份")
        let restored = ConfigImporter.apply(backupPlan, to: config, mode: .replace, directory: directory).config.engine
        XCTAssertEqual(restored.subscriptions, config.engine.subscriptions)
        XCTAssertEqual(restored.manualNodes, config.engine.manualNodes)
        XCTAssertEqual(restored.ruleSets, config.engine.ruleSets)
        var other = config
        other.engine.manualNodes = []
        other.engine.subscriptions = [local]
        let partial = ConfigImporter.apply(backupPlan, to: other, mode: .replace, directory: directory).config.engine
        XCTAssertEqual(partial.subscriptions, [local])
        XCTAssertTrue(partial.manualNodes.isEmpty)
        let merged = ConfigImporter.apply(backupPlan, to: other, mode: .merge, directory: directory).config.engine
        XCTAssertFalse(merged.subscriptions.contains { ConfigImporter.isHidden(url: $0.url) })
        XCTAssertFalse(merged.manualNodes.contains { ConfigImporter.hiddenNodeName($0.link) != nil })
        XCTAssertFalse(merged.ruleSets.contains { ConfigImporter.isHidden(url: $0.url) })

        // 同名的手动节点按顺序对应，替换导入时一个都不少。
        var twins = AppConfig()
        twins.engine.manualNodes = [ManualNode(link: "trojan://p1@a.example.com:443#同名"), ManualNode(link: "trojan://p2@b.example.com:443#同名")]
        let twinsPlan = try ConfigImporter.plan(ConfigImporter.describeJSON(ConfigImporter.hidingSecrets(twins)), sourceName: "描述", existing: twins)
        XCTAssertEqual(ConfigImporter.apply(twinsPlan, to: twins, mode: .replace, directory: directory).config.engine.manualNodes, twins.engine.manualNodes)
    }

    func testNetworkRules() {
        let office = NetworkRule(match: .ssid("Office"), action: .off)
        let home = NetworkRule(match: .router("AA:BB:CC:0D:EE:FF"), action: .mode(.global))
        let other = NetworkRule(match: .other, action: .mode(.rule))
        let rules = [other, office, home]
        XCTAssertEqual(NetworkRule.firstMatch(rules, identity: NetworkIdentity(ssid: "Office")), office)
        XCTAssertEqual(NetworkRule.firstMatch(rules, identity: NetworkIdentity(ssid: "Cafe", routerIP: "192.168.1.1", routerMAC: "aa:bb:cc:d:ee:ff")), home)
        XCTAssertEqual(NetworkRule.firstMatch(rules, identity: NetworkIdentity(ssid: "Cafe")), other)
        XCTAssertNil(NetworkRule.firstMatch(rules, identity: NetworkIdentity()))
        XCTAssertEqual(NetworkRule.Match(rawValue: "router:192.168.1.1"), .router("192.168.1.1"))
        XCTAssertNil(NetworkRule.Action(rawValue: "mode:bogus"))
    }
}
