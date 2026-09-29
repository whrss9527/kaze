import XCTest
@testable import Proxi

final class URLCommandTests: XCTestCase {
    func testNewCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://node?name=%E9%A6%99%E6%B8%AF")!), .node("香港"))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://node/auto")!), .node("auto"))
        XCTAssertNil(URLCommand.parse(URL(string: "proxi://node")!))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://mode?value=global")!), .mode(.global))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://mode/rule")!), .mode(.rule))
        XCTAssertNil(URLCommand.parse(URL(string: "proxi://mode?value=direct")!))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://group?name=A&member=B")!), .group(name: "A", member: "B"))
        XCTAssertNil(URLCommand.parse(URL(string: "proxi://group?name=A")!))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://import?url=https%3A%2F%2Fexample.com%2Fc.yaml")!), .importConfig("https://example.com/c.yaml"))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://run?tool=check_services&node=%E6%97%A5%E6%9C%AC")!), .tool(name: "check_services", params: ["node": "日本"]))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=automation")!), .settings(.automation))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://settings?page=advanced")!), .settings(.advanced))
    }

    func testTunAndGatewayCommands() {
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://tun")!), .tun(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://tun/on")!), .tun(true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://tun?value=off")!), .tun(false))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://enhanced/on")!), .tun(true))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://gateway")!), .gateway(nil))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://gateway/off")!), .gateway(false))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://gateway?state=on")!), .gateway(true))
        // 共享的写法不变。
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://share?state=off")!), .share(false))
        XCTAssertEqual(URLCommand.parse(URL(string: "proxi://share/on")!), .share(true))
    }

    func testTrafficSources() {
        var accumulator = TrafficAccumulator()
        func connection(_ id: String, process: String?, source: String, inbound: String?, up: Int64, down: Int64, outbound: String) -> CoreConnection {
            let metadata = CoreConnection.Metadata(network: "tcp", type: nil, sourceIP: source, sourcePort: nil, destinationIP: nil, destinationPort: "443", host: "a.com", inboundName: inbound, process: process, processPath: nil)
            return CoreConnection(id: id, metadata: metadata, upload: up, download: down, start: nil, chains: [outbound], rule: nil, rulePayload: nil)
        }
        let first = accumulator.ingestDetailed([
            connection("1", process: "Safari", source: "127.0.0.1", inbound: nil, up: 10, down: 100, outbound: "香港"),
            connection("2", process: nil, source: "192.168.1.20", inbound: CoreConfigBuilder.shareListener, up: 5, down: 50, outbound: "DIRECT"),
        ])
        XCTAssertEqual(first.sources["Safari"], TrafficTotal(upload: 10, download: 100))
        XCTAssertEqual(first.sources["设备 192.168.1.20"], TrafficTotal(upload: 5, download: 50))
        var stats = TrafficStats()
        let day = Date(timeIntervalSince1970: 1_790_000_000)
        stats.add(first, on: day)
        XCTAssertEqual(stats.total, TrafficTotal(upload: 15, download: 150))
        XCTAssertEqual(stats.rankedSources.first?.name, "Safari")
        XCTAssertEqual(stats.recentDays(3, until: day).last?.traffic, TrafficTotal(upload: 15, download: 150))
        XCTAssertEqual(stats.recentDays(3, until: day).count, 3)
        let second = accumulator.ingestDetailed([connection("1", process: "Safari", source: "127.0.0.1", inbound: nil, up: 30, down: 100, outbound: "香港")])
        XCTAssertEqual(second.sources["Safari"], TrafficTotal(upload: 20, download: 0))
        stats.reset()
        XCTAssertTrue(stats.days.isEmpty)
        XCTAssertTrue(stats.sources.isEmpty)
    }
}
