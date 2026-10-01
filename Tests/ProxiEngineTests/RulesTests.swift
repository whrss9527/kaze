import XCTest
@testable import ProxiEngine

/// 策略组、规则集、规则库、流量统计、出口 IP：纯逻辑部分。
final class RulesTests: XCTestCase {
    func testRuleTarget() throws {
        XCTAssertEqual(RuleTarget.proxy.resolved(groups: []), "节点")
        XCTAssertEqual(RuleTarget.direct.resolved(groups: []), "DIRECT")
        XCTAssertEqual(RuleTarget.reject.resolved(groups: []), "REJECT")
        XCTAssertEqual(RuleTarget.group("组B").resolved(groups: ["组B"]), "组B")
        // 指向已删除的组时退回「节点」，内核不会因为找不到策略起不来。
        XCTAssertEqual(RuleTarget.group("没了").resolved(groups: ["组B"]), "节点")
        XCTAssertEqual(RuleTarget.group("组B").title, "组B")
        XCTAssertEqual(RuleTarget.group("组B").actionTitle, "走「组B」")
        XCTAssertEqual(RuleTarget.direct.actionTitle, "直连")
        XCTAssertEqual(RuleTarget.options(groups: [PolicyGroup(name: "A"), PolicyGroup(name: "B")]), [.proxy, .direct, .reject, .group("A"), .group("B")])
        // 存成字符串，旧配置里的 proxy / direct / reject 照读，认不出的当走节点。
        let encoded = try JSONEncoder().encode([RuleTarget.proxy, .direct, .reject, .group("组B")])
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: encoded), ["proxy", "direct", "reject", "group:组B"])
        XCTAssertEqual(try JSONDecoder().decode([RuleTarget].self, from: Data(#"["proxy","direct","reject","group:组B","nonsense"]"#.utf8)), [.proxy, .direct, .reject, .group("组B"), .proxy])
        XCTAssertEqual(RuleTarget.title(forCorePolicy: "DIRECT"), "直连")
        XCTAssertEqual(RuleTarget.title(forCorePolicy: "REJECT"), "拦截")
        XCTAssertEqual(RuleTarget.title(forCorePolicy: "节点"), "走节点")
        XCTAssertEqual(RuleTarget.title(forCorePolicy: "组B"), "走「组B」")
        // 自定义规则的去向可以是策略组。
        let rule = CustomRule(pattern: "media.example", policy: .group("组B"))
        XCTAssertEqual(rule.line(groups: ["组B"]), "DOMAIN-SUFFIX,media.example,组B")
        XCTAssertEqual(rule.line, "DOMAIN-SUFFIX,media.example,节点")
        let decoded = try JSONDecoder().decode(CustomRule.self, from: Data(#"{"pattern":"a.com","policy":"reject"}"#.utf8))
        XCTAssertEqual(decoded.policy, .reject)
        XCTAssertEqual(try JSONDecoder().decode(CustomRule.self, from: try JSONEncoder().encode(rule)).policy, .group("组B"))
    }

    func testPolicyGroup() throws {
        XCTAssertNil(PolicyGroup.validate(name: "组B", filter: "港|HK", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "", filter: "", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "节点", filter: "", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "direct", filter: "", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "sub-1234", filter: "", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "组B", filter: "", others: [PolicyGroup(name: "组B")]))
        XCTAssertNotNil(PolicyGroup.validate(name: "ok", filter: "(", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: String(repeating: "长", count: 21), filter: "", others: []))
        // 规则行用逗号分隔：名字里有逗号会被拆开。
        XCTAssertNotNil(PolicyGroup.validate(name: "A,B", filter: "", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "A，B", filter: "", others: []))
        XCTAssertNotNil(PolicyGroup.validate(name: "A\"B", filter: "", others: []))
        let group = PolicyGroup(name: " 组B ", kind: .urlTest, filter: " 港|HK ")
        XCTAssertEqual(group.name, "组B")
        XCTAssertEqual(group.filter, "港|HK")
        XCTAssertEqual(group.coreFilter, "(?i)港|HK")
        XCTAssertEqual(PolicyGroup(name: "x", filter: "(?i)hk").coreFilter, "(?i)hk")
        XCTAssertNil(PolicyGroup(name: "x").coreFilter)
        let nodes = ["香港 01", "HK 02", "hk-03", "日本 01", "US 01"]
        XCTAssertEqual(group.matches(nodes), ["香港 01", "HK 02", "hk-03"])
        XCTAssertEqual(PolicyGroup(name: "全部").matches(nodes), nodes)
        XCTAssertEqual(PolicyGroup(name: "坏", filter: "(").matches(nodes), [])
        XCTAssertEqual(PolicyGroupKind.urlTest.coreType, "url-test")
        XCTAssertEqual(PolicyGroupKind.loadBalance.coreType, "load-balance")
        // 存取，旧字段缺省。
        let decoded = try JSONDecoder().decode(PolicyGroup.self, from: Data(#"{"name":"组B"}"#.utf8))
        XCTAssertEqual(decoded.kind, .select)
        XCTAssertEqual(decoded.filter, "")
        let roundTrip = try JSONDecoder().decode(PolicyGroup.self, from: try JSONEncoder().encode(group))
        XCTAssertEqual(roundTrip, group)
        // 删组、改名后指向它的规则跟着改。
        var engine = EngineConfig()
        engine.groups = [group]
        engine.customRules = [CustomRule(pattern: "media.example", policy: .group("组B"))]
        engine.ruleSets = [RuleSet(name: "N", url: "https://x/Media.list", policy: .group("组B"))]
        engine.finalPolicy = .group("组B")
        XCTAssertEqual(engine.customRuleLines, ["DOMAIN-SUFFIX,media.example,组B"])
        engine.retarget(from: "组B", to: .group("影视"))
        XCTAssertEqual(engine.customRules[0].policy, .group("影视"))
        XCTAssertEqual(engine.ruleSets[0].policy, .group("影视"))
        XCTAssertEqual(engine.finalPolicy, .group("影视"))
        engine.retarget(from: "影视", to: .proxy)
        XCTAssertEqual(engine.finalPolicy, .proxy)
        XCTAssertEqual(engine.customRuleLines, ["DOMAIN-SUFFIX,media.example,节点"])
        // 组已经不在配置里时，规则行退回「节点」。
        engine.customRules[0].policy = .group("不存在")
        XCTAssertEqual(engine.customRuleLines, ["DOMAIN-SUFFIX,media.example,节点"])
    }

    func testRuleSet() throws {
        let list = RuleSet(name: "Apple", url: "https://example.com/rule/Apple/Apple.list", policy: .direct)
        XCTAssertEqual(list.kind, .provider)
        XCTAssertEqual(list.format, "text")
        XCTAssertEqual(list.storedExtension, "txt")
        XCTAssertEqual(list.guessedBehavior, .classical)
        XCTAssertTrue(list.providerName.hasPrefix("rs-"))
        XCTAssertEqual(list.providerName.count, 11)
        let mrs = RuleSet(name: "cn", url: RuleLibrary.metaGeo + "geosite/cn.mrs", policy: .direct)
        XCTAssertEqual(mrs.kind, .provider)
        XCTAssertEqual(mrs.format, "mrs")
        XCTAssertEqual(mrs.storedExtension, "mrs")
        XCTAssertEqual(mrs.guessedBehavior, .domain)
        XCTAssertEqual(RuleSet(name: "ip", url: RuleLibrary.metaGeo + "geoip/cn.mrs", policy: .direct).guessedBehavior, .ipcidr)
        let yaml = RuleSet(name: "y", url: "https://x/Apple_Domain.yaml?token=1", policy: nil)
        XCTAssertEqual(yaml.kind, .provider)
        XCTAssertEqual(yaml.format, "yaml")
        XCTAssertEqual(yaml.storedExtension, "yaml")
        XCTAssertEqual(yaml.guessedBehavior, .domain)
        let conf = RuleSet(name: "完整配置", url: "https://example.com/rules.conf", policy: nil)
        XCTAssertEqual(conf.kind, .inline)
        XCTAssertEqual(conf.storedExtension, "conf")
        XCTAssertEqual(RuleSet(name: "x", url: "https://example.com/rules", policy: .proxy).kind, .inline)
        let builtin = RuleSet.chinaDirect()
        XCTAssertEqual(builtin.kind, .builtin)
        XCTAssertTrue(builtin.isBuiltin)
        XCTAssertEqual(builtin.policy, .direct)
        XCTAssertEqual(RuleSet.chinaDirect(), RuleSet.chinaDirect())
        XCTAssertEqual(RuleSet(name: "f", url: "file:///Users/me/rules.list", policy: .proxy).filePath, "/Users/me/rules.list")
        XCTAssertNil(list.filePath)
        XCTAssertNil(RuleSet.validate(url: "https://x/a.list"))
        XCTAssertNil(RuleSet.validate(url: RuleSet.chinaDirectURL))
        XCTAssertNil(RuleSet.validate(url: "file:///tmp/a.list"))
        XCTAssertNotNil(RuleSet.validate(url: "builtin://nope"))
        XCTAssertNotNil(RuleSet.validate(url: "ftp://x/a"))
        XCTAssertNotNil(RuleSet.validate(url: ""))
        XCTAssertEqual(RuleSet.defaultName(for: "https://raw.githubusercontent.com/x/y/master/Clash/MyList.list"), "MyList")
        XCTAssertEqual(RuleSet.defaultName(for: "https://example.com"), "example.com")
        XCTAssertEqual(RuleSet.defaultName(for: "https://example.com/rule/Apple/Apple.list"), "Apple")
        // 迁移。
        XCTAssertEqual(RuleSet.migrated(from: .chinaDirect), [RuleSet.chinaDirect()])
        let migrated = RuleSet.migrated(from: .url("https://example.com/my.conf"))
        XCTAssertEqual(migrated.count, 1)
        XCTAssertEqual(migrated[0].name, "my")
        XCTAssertNil(migrated[0].policy)
        // 存取：policy 缺省是 nil，behavior 可选。
        let decoded = try JSONDecoder().decode(RuleSet.self, from: Data(#"{"name":"a","url":"https://x/a.list","policy":"reject","behavior":"domain"}"#.utf8))
        XCTAssertEqual(decoded.policy, .reject)
        XCTAssertEqual(decoded.behavior, .domain)
        XCTAssertEqual(decoded.effectiveBehavior, .domain)
        XCTAssertTrue(decoded.enabled)
        XCTAssertNil(try JSONDecoder().decode(RuleSet.self, from: Data(#"{"name":"a","url":"https://x/a.conf"}"#.utf8)).policy)
        let roundTrip = try JSONDecoder().decode(RuleSet.self, from: try JSONEncoder().encode(list))
        XCTAssertEqual(roundTrip, list)
        // 内置规则展开。
        XCTAssertEqual(RuleConverter.builtinRules(url: RuleSet.chinaDirectURL, policy: "DIRECT"), ["DOMAIN-SUFFIX,cn,DIRECT", "GEOIP,CN,DIRECT"])
        XCTAssertNil(RuleConverter.builtinRules(url: "https://x", policy: "DIRECT"))
        // 下载后发现是完整配置（Clash 的 rules:）：改成转换并入；存取时带着这个标记。
        var clash = RuleSet(name: "clash", url: "https://x/config.yaml", policy: nil)
        XCTAssertEqual(clash.kind, .provider)
        clash.converted = true
        XCTAssertEqual(clash.kind, .inline)
        XCTAssertEqual(clash.storedExtension, "yaml")
        XCTAssertEqual(try JSONDecoder().decode(RuleSet.self, from: try JSONEncoder().encode(clash)).converted, true)
        clash.converted = false
        XCTAssertEqual(clash.kind, .provider)
        XCTAssertNil(try JSONDecoder().decode(RuleSet.self, from: Data(#"{"name":"a","url":"https://x/a.list"}"#.utf8)).converted)
    }

    func testNeedsConversion() {
        // Clash 顶格的 rules:、小火箭的 [Rule] 段要转换；payload: 列表和纯文本列表交给内核。
        XCTAssertTrue(RuleConverter.needsConversion("port: 7890\nproxies: []\nrules:\n  - DOMAIN-SUFFIX,x.com,Proxy\n  - MATCH,DIRECT\n"))
        XCTAssertTrue(RuleConverter.needsConversion("[General]\nbypass-system = true\n[Rule]\nDOMAIN-SUFFIX,x.com,Proxy\nFINAL,DIRECT\n"))
        XCTAssertFalse(RuleConverter.needsConversion("payload:\n  - DOMAIN-SUFFIX,x.com\n  - '+.y.com'\n"))
        XCTAssertFalse(RuleConverter.needsConversion("# NAME: Apple\nDOMAIN-SUFFIX,apple.com\nIP-CIDR,17.0.0.0/8,no-resolve\n"))
        XCTAssertFalse(RuleConverter.needsConversion("+.google.com\n1.0.1.0/24\n"))
        // 缩进的 rules:（别的键下面的）不算。
        XCTAssertFalse(RuleConverter.needsConversion("payload:\n  rules:\n  - DOMAIN,x.com\n"))
        XCTAssertFalse(RuleConverter.needsConversion(""))
        // 完整配置里引用的远程列表。
        XCTAssertEqual(RuleConverter.referencedRuleSets("[Rule]\nRULE-SET,https://x/a.list,DIRECT\nRULE-SET,https://x/b.list,Proxy\nRULE-SET,https://x/a.list,REJECT\nRULE-SET,local,DIRECT\nFINAL,DIRECT\n"), ["https://x/a.list", "https://x/b.list"])
        XCTAssertEqual(RuleConverter.referencedRuleSets("DOMAIN-SUFFIX,x.com\n"), [])
    }

    func testRuleLibraryAndStore() {
        let urls = RuleLibrary.all.map(\.url)
        XCTAssertEqual(Set(urls).count, urls.count)
        XCTAssertEqual(RuleLibrary.categories, [RuleLibrary.ads])
        XCTAssertTrue(RulePresets.all.isEmpty)
        for entry in RuleLibrary.all {
            XCTAssertNil(RuleSet.validate(url: entry.url), entry.url)
            let set = entry.makeRuleSet()
            XCTAssertEqual(set.name, entry.name)
            XCTAssertEqual(set.policy, entry.policy)
            if set.kind == .provider {
                XCTAssertNotNil(entry.behavior, "\(entry.name) 要标明类型")
                if set.format == "mrs" {
                    XCTAssertNotEqual(entry.behavior, .classical, "\(entry.name)：mrs 不能是完整规则")
                }
            } else {
                XCTAssertEqual(set.kind, .inline)
                XCTAssertNil(entry.policy)
            }
        }
        XCTAssertNil(RuleLibrary.entry(for: RuleSet.chinaDirectURL))
        // GitHub 原始地址换成 jsDelivr 镜像。
        XCTAssertEqual(RuleStore.mirrorURL(for: "https://raw.githubusercontent.com/blackmatrix7/ios_rule_script/master/rule/Clash/Apple/Apple.list"), "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule/Clash/Apple/Apple.list")
        XCTAssertEqual(RuleStore.mirrorURL(for: "https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/meta/geo/geosite/cn.mrs"), "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/geosite/cn.mrs")
        XCTAssertNil(RuleStore.mirrorURL(for: "https://example.com/a.list"))
        XCTAssertNil(RuleStore.mirrorURL(for: "https://raw.githubusercontent.com/a/b"))
        XCTAssertNil(RuleStore.mirrorURL(for: "nope"))
        let directory = URL(fileURLWithPath: "/tmp/core")
        let set = RuleSet(name: "a", url: "https://x/a.mrs", policy: .proxy)
        XCTAssertEqual(RuleStore.fileURL(for: set, in: directory).path, "/tmp/core/rules/\(set.providerName).mrs")
        XCTAssertTrue(RuleStore.referenceURL(for: "https://x/a.list", in: directory).lastPathComponent.hasPrefix("ref-"))
        XCTAssertEqual(RuleStore.referenceURL(for: "https://x/a.list", in: directory), RuleStore.referenceURL(for: "https://x/a.list", in: directory))
        XCTAssertNil(RuleStore.age(of: directory.appendingPathComponent("nope")))
    }

    func testDetectBehavior() {
        XCTAssertEqual(RuleConverter.detectBehavior("# NAME: Apple\nDOMAIN,apple-events.akamaized.net\nDOMAIN-SUFFIX,apple.com\nIP-CIDR,17.0.0.0/8,no-resolve\n"), .classical)
        XCTAssertEqual(RuleConverter.detectBehavior("payload:\n  - '+.google.com'\n  - 'video.example'\n"), .domain)
        XCTAssertEqual(RuleConverter.detectBehavior("+.google.com\n.video.example\nexample.org\n"), .domain)
        XCTAssertEqual(RuleConverter.detectBehavior("payload:\n  - '1.0.1.0/24'\n  - '2001:db8::/32'\n"), .ipcidr)
        XCTAssertEqual(RuleConverter.detectBehavior("# 注释\n1.0.1.0/24\n8.8.8.8\n"), .ipcidr)
        XCTAssertEqual(RuleConverter.detectBehavior("payload:\n  - DOMAIN-SUFFIX,x.com\n  - 'IP-CIDR,1.1.1.1/32'\n"), .classical)
        XCTAssertEqual(RuleConverter.detectBehavior("USER-AGENT,Foo*,PROXY\n"), .classical)
        XCTAssertEqual(RuleConverter.detectBehavior(""), .domain)
    }

    private func connection(_ id: String, up: Int64, down: Int64, chains: [String], process: String = "Safari") -> CoreConnection {
        let chainsJSON = "[" + chains.map { "\"\($0)\"" }.joined(separator: ",") + "]"
        let json = """
        {"id":"\(id)","metadata":{"network":"tcp","type":"Mixed","sourceIP":"127.0.0.1","destinationIP":"","sourcePort":"1","destinationPort":"443","host":"x.com","inboundName":"","process":"\(process)"},"upload":\(up),"download":\(down),"start":"2026-09-28T10:00:00Z","chains":\(chainsJSON),"rule":"Match","rulePayload":""}
        """
        return try! JSONDecoder().decode(CoreConnection.self, from: Data(json.utf8))
    }

    func testTrafficStats() throws {
        var accumulator = TrafficAccumulator()
        let first = accumulator.ingest([connection("a", up: 100, down: 1000, chains: ["香港 01", "节点"]), connection("b", up: 10, down: 20, chains: ["DIRECT"])])
        XCTAssertEqual(first["香港 01"], TrafficTotal(upload: 100, download: 1000))
        XCTAssertEqual(first["DIRECT"], TrafficTotal(upload: 10, download: 20))
        // 第二次只算增量；消失的连接不再算；没有链的按直连算；计数回退（不该发生）不算负数。
        let second = accumulator.ingest([connection("a", up: 150, down: 1000, chains: ["香港 01", "节点"]), connection("c", up: 5, down: 0, chains: [])])
        XCTAssertEqual(second["香港 01"], TrafficTotal(upload: 50, download: 0))
        XCTAssertEqual(second["DIRECT"], TrafficTotal(upload: 5, download: 0))
        XCTAssertEqual(second.count, 2)
        let third = accumulator.ingest([connection("a", up: 120, down: 900, chains: ["香港 01", "节点"])])
        XCTAssertTrue(third.isEmpty)
        var stats = TrafficStats()
        stats.add(first)
        stats.add(second)
        XCTAssertEqual(stats.outbounds["香港 01"], TrafficTotal(upload: 150, download: 1000))
        XCTAssertEqual(stats.outbounds["DIRECT"], TrafficTotal(upload: 15, download: 20))
        XCTAssertEqual(stats.total, TrafficTotal(upload: 165, download: 1020))
        XCTAssertEqual(stats.ranked.map(\.name), ["香港 01", "DIRECT"])
        stats.add(["空": TrafficTotal()])
        XCTAssertNil(stats.outbounds["空"])
        // 存进本机状态；旧文件没有这一项时是空的。
        var persisted = PersistedState()
        persisted.traffic = stats
        let decoded = try JSONDecoder().decode(PersistedState.self, from: try JSONEncoder().encode(persisted))
        XCTAssertEqual(decoded.traffic.outbounds, stats.outbounds)
        XCTAssertEqual(decoded.traffic.since.timeIntervalSince1970, stats.since.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(try JSONDecoder().decode(PersistedState.self, from: Data(#"{"syncEnabled":true}"#.utf8)).traffic.outbounds.isEmpty)
        stats.reset()
        XCTAssertTrue(stats.outbounds.isEmpty)
        XCTAssertEqual(stats.total, TrafficTotal())
        // 连接记录：程序名、策略组、出口。
        let record = ConnectionRecord(connection("a", up: 1, down: 2, chains: ["香港 01", "组B"]))
        XCTAssertEqual(record.source, "Safari")
        XCTAssertEqual(record.group, "组B")
        XCTAssertEqual(record.outbound, "香港 01")
        XCTAssertEqual(record.route, "组B → 香港 01")
        XCTAssertEqual(record.network, "TCP")
        XCTAssertEqual(record.target, "x.com:443")
        XCTAssertFalse(record.isShare)
        XCTAssertNotNil(record.startDate)
        XCTAssertEqual(ConnectionRecord(connection("d", up: 0, down: 0, chains: ["DIRECT"])).route, "DIRECT")
        XCTAssertEqual(ConnectionRecord(connection("e", up: 0, down: 0, chains: ["DIRECT"], process: "")).source, "本机")
        XCTAssertEqual(Engine.durationText(since: Date().addingTimeInterval(-90)), "1 分钟")
        XCTAssertEqual(Engine.durationText(since: Date().addingTimeInterval(-3700)), "1 小时 1 分")
        XCTAssertEqual(Engine.durationText(since: nil), "")
    }

    func testExitInfo() {
        let sb = ExitInfo.parse(Data(#"{"ip":"1.2.3.4","country_code":"JP","country":"Japan","city":"Tokyo","isp":"Example ISP","organization":"Example Org"}"#.utf8))
        XCTAssertEqual(sb?.ip, "1.2.3.4")
        XCTAssertEqual(sb?.flag, "🇯🇵")
        XCTAssertEqual(sb?.place, "Japan Tokyo")
        XCTAssertEqual(sb?.organization, "Example ISP")
        XCTAssertEqual(sb?.short, "🇯🇵 Tokyo")
        XCTAssertEqual(sb?.summary, "🇯🇵 Japan Tokyo · 1.2.3.4 · Example ISP")
        let ipinfo = ExitInfo.parse(Data(#"{"ip":"5.6.7.8","city":"Los Angeles","region":"California","country":"US","org":"AS15169 Google LLC"}"#.utf8))
        XCTAssertEqual(ipinfo?.countryCode, "US")
        XCTAssertEqual(ipinfo?.country, "")
        XCTAssertEqual(ipinfo?.flag, "🇺🇸")
        XCTAssertEqual(ipinfo?.short, "🇺🇸 Los Angeles")
        XCTAssertEqual(ipinfo?.organization, "AS15169 Google LLC")
        let ipapi = ExitInfo.parse(Data(#"{"query":"9.9.9.9","countryCode":"DE","country":"Germany","city":"Berlin","isp":"ISP"}"#.utf8))
        XCTAssertEqual(ipapi?.flag, "🇩🇪")
        XCTAssertEqual(ipapi?.country, "Germany")
        XCTAssertNil(ExitInfo.parse(Data("{}".utf8)))
        XCTAssertNil(ExitInfo.parse(Data("nope".utf8)))
        let bare = ExitInfo(ip: "1.1.1.1", countryCode: "", country: "", city: "", organization: "")
        XCTAssertEqual(bare.short, "1.1.1.1")
        XCTAssertEqual(bare.flag, "")
        XCTAssertEqual(bare.summary, "1.1.1.1")
        XCTAssertEqual(ExitIPChecker.endpoints.count, 3)
    }
}
