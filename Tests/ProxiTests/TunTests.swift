import XCTest
@testable import Proxi

final class TunTests: XCTestCase {
    private func input(_ engine: EngineConfig, tun: TunInputs?, share: ShareInputs? = nil) -> CoreConfigBuilder.Input {
        CoreConfigBuilder.Input(engine: engine, secret: "s", directory: URL(fileURLWithPath: "/tmp/ps-core"), testURL: "https://cp.cloudflare.com/generate_204", rules: ["MATCH,节点"], share: share, tun: tun)
    }

    private func engineWithNodes() -> EngineConfig {
        var engine = EngineConfig()
        engine.subscriptions = [Subscription(name: "机场", url: "https://sub.example.com/a")]
        engine.customRules = [CustomRule(pattern: "192.168.1.20", policy: .reject, kind: .device)]
        return engine
    }

    func testSettingsDecodeWithDefaults() throws {
        let decoded = try JSONDecoder().decode(TunConfig.self, from: Data(#"{"gateway":true,"stack":"bogus"}"#.utf8))
        XCTAssertFalse(decoded.enabled)
        XCTAssertTrue(decoded.gateway)
        XCTAssertEqual(decoded.stack, .mixed)
        XCTAssertEqual(decoded.dnsMode, .fakeIP)
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(#"{"enabledByUs":true}"#.utf8))
        XCTAssertEqual(state.tun, TunConfig())
    }

    func testNoTunKeepsConfigUnchanged() {
        let yaml = CoreConfigBuilder.yaml(input(engineWithNodes(), tun: nil))
        XCTAssertFalse(yaml.contains("tun:"))
        XCTAssertFalse(yaml.contains("QUIC"))
        XCTAssertFalse(yaml.contains("enhanced-mode"))
        XCTAssertFalse(yaml.contains("IN-TYPE"))
    }

    func testEnhancedModeCapturesEverything() {
        let tun = TunInputs(stack: .mixed, dnsMode: .fakeIP, captureLocal: true, gateway: false, upstream: .engine, localAddresses: ["192.168.1.23"])
        let yaml = CoreConfigBuilder.yaml(input(engineWithNodes(), tun: tun))
        XCTAssertTrue(yaml.contains("tun:\n  enable: true\n  stack: mixed\n  auto-route: true\n  auto-detect-interface: true\n  dns-hijack: [\"any:53\", \"tcp://any:53\"]"))
        XCTAssertTrue(yaml.contains("    QUIC:\n      ports: [443, 8443]"))
        // DNS 没设置过也一定开，用默认的服务器。
        XCTAssertTrue(yaml.contains("dns:\n  enable: true\n  enhanced-mode: fake-ip\n  fake-ip-range: \"198.18.0.1/16\"\n  fake-ip-filter: ["))
        XCTAssertTrue(yaml.contains("nameserver: [\"https://doh.pub/dns-query\""))
        XCTAssertFalse(yaml.contains("listen:"))
        // 本机的流量也交给规则：没有额外的前置规则。
        XCTAssertFalse(yaml.contains("IN-TYPE"))
        XCTAssertFalse(yaml.contains(CoreConfigBuilder.gatewayRules))
    }

    func testRealIPModeAndUserDNS() {
        var engine = engineWithNodes()
        engine.dns.enabled = true
        engine.dns.nameservers = ["223.5.5.5"]
        let tun = TunInputs(stack: .gvisor, dnsMode: .realIP, captureLocal: true, gateway: false, upstream: .engine)
        let yaml = CoreConfigBuilder.yaml(input(engine, tun: tun))
        XCTAssertTrue(yaml.contains("  stack: gvisor"))
        XCTAssertTrue(yaml.contains("  enhanced-mode: redir-host\n  fake-ip-range: \"198.18.0.1/16\"\n  ipv6: false"))
        XCTAssertFalse(yaml.contains("fake-ip-filter"))
        XCTAssertTrue(yaml.contains("  nameserver: [\"223.5.5.5\"]"))
    }

    func testGatewayWhileTheMacIsOff() {
        let tun = TunInputs(stack: .mixed, dnsMode: .fakeIP, captureLocal: false, gateway: true, upstream: .direct, localAddresses: ["192.168.1.23", "bogus"])
        let yaml = CoreConfigBuilder.yaml(input(engineWithNodes(), tun: tun))
        XCTAssertTrue(yaml.contains("  listen: \"0.0.0.0:53\""))
        // 本机经虚拟网卡发出的流量直连，设备的流量按本机的上游（这里是直连，设备规则里的拦截照样生效）。
        XCTAssertTrue(yaml.contains("""
        rules:
          - "AND,((IN-TYPE,TUN),(SRC-IP-CIDR,198.18.0.0/30)),DIRECT"
          - "AND,((IN-TYPE,TUN),(SRC-IP-CIDR,192.168.1.23/32)),DIRECT"
          - "SUB-RULE,(IN-TYPE,TUN),lan-gateway"
          - "DOMAIN-SUFFIX,local,DIRECT"
        """))
        XCTAssertTrue(yaml.contains("sub-rules:\n  \"lan-gateway\":\n    - \"SRC-IP-CIDR,192.168.1.20/32,REJECT\"\n    - \"MATCH,DIRECT\"\n"))
    }

    func testGatewayFollowsUpstreamProxyAndShareTogether() {
        let tun = TunInputs(stack: .mixed, dnsMode: .fakeIP, captureLocal: false, gateway: true, upstream: .proxy(kind: .http, host: "10.0.0.1", port: 8080))
        let share = ShareInputs(port: 7892, allowedPrefixes: ShareConfig().allowedPrefixes, upstream: .proxy(kind: .http, host: "10.0.0.1", port: 8080))
        let yaml = CoreConfigBuilder.yaml(input(EngineConfig(), tun: tun, share: share))
        XCTAssertTrue(yaml.contains("sub-rules:\n  \"lan-share\":\n"))
        XCTAssertTrue(yaml.contains("  \"lan-gateway\":\n"))
        XCTAssertTrue(yaml.contains("    - \"MATCH,上游代理\""))
        XCTAssertEqual(yaml.components(separatedBy: "sub-rules:").count, 2)
    }

    func testGatewayDevicesAreRecognized() {
        func connection(_ id: String, source: String, inbound: String?, process: String? = nil) -> CoreConnection {
            let metadata = CoreConnection.Metadata(network: "tcp", type: "Tun", sourceIP: source, sourcePort: nil, destinationIP: nil, destinationPort: "443", host: "a.com", inboundName: inbound, process: process, processPath: nil)
            return CoreConnection(id: id, metadata: metadata, upload: 1, download: 2, start: id, chains: ["DIRECT"], rule: nil, rulePayload: nil)
        }
        let connections = [
            connection("1", source: "192.168.1.30", inbound: CoreConfigBuilder.tunInbound),
            connection("2", source: "198.18.0.1", inbound: CoreConfigBuilder.tunInbound, process: "curl"),
            connection("3", source: "192.168.1.20", inbound: CoreConfigBuilder.shareListener),
            connection("4", source: "127.0.0.1", inbound: "DEFAULT-MIXED"),
        ]
        XCTAssertEqual(ShareClient.group(connections, listener: CoreConfigBuilder.shareListener).map(\.ip), ["192.168.1.30", "192.168.1.20"])
        XCTAssertTrue(ConnectionRecord(connections[0]).isShare)
        XCTAssertEqual(ConnectionRecord(connections[0]).trafficSource, "设备 192.168.1.30")
        XCTAssertFalse(ConnectionRecord(connections[1]).isShare)
        XCTAssertEqual(ConnectionRecord(connections[1]).trafficSource, "curl")
        XCTAssertFalse(ConnectionRecord(connections[3]).isShare)
    }

    func testGatewayWithBuiltInProxyButNoEnhancedMode() {
        // 本机经系统代理用内置代理、没开增强模式：本机不认系统代理的流量照旧直连，设备和本机一样走主规则。
        let tun = TunInputs(stack: .mixed, dnsMode: .fakeIP, captureLocal: false, gateway: true, upstream: .engine)
        let yaml = CoreConfigBuilder.yaml(input(engineWithNodes(), tun: tun))
        XCTAssertTrue(yaml.contains("  - \"AND,((IN-TYPE,TUN),(SRC-IP-CIDR,198.18.0.0/30)),DIRECT\""))
        XCTAssertFalse(yaml.contains("SUB-RULE"))
        XCTAssertFalse(yaml.contains("lan-gateway"))
    }
}
