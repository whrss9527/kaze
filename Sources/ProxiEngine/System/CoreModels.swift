import Foundation

/// 内核 API 里的一个代理或策略组。
struct CoreProxy: Decodable, Equatable {
    struct History: Decodable, Equatable {
        var delay: Int
    }

    var name: String
    var type: String
    var now: String?
    var all: [String]?
    var history: [History]?
    var alive: Bool?

    /// 最近一次测的延迟；0 表示失败。
    var lastDelay: Int? {
        guard let delay = history?.last?.delay else { return nil }
        return delay
    }

    var isGroup: Bool { all != nil }
}

/// 订阅的流量和到期信息（服务提供方通过响应头给的）。
struct CoreSubscriptionInfo: Decodable, Equatable {
    var upload: Int64?
    var download: Int64?
    var total: Int64?
    var expire: Int64?

    private enum CodingKeys: String, CodingKey {
        case upload = "Upload"
        case download = "Download"
        case total = "Total"
        case expire = "Expire"
    }

    var used: Int64 { (upload ?? 0) + (download ?? 0) }
    var expireDate: Date? {
        guard let expire, expire > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(expire))
    }
}

struct CoreProvider: Decodable, Equatable {
    var name: String
    var type: String?
    var vehicleType: String?
    var proxies: [CoreProxy]
    var subscriptionInfo: CoreSubscriptionInfo?
    var updatedAt: String?
}

/// 内核里的一条连接（/connections）。
struct CoreConnection: Decodable, Equatable {
    struct Metadata: Decodable, Equatable {
        var network: String?
        var type: String?
        var sourceIP: String?
        var sourcePort: String?
        var destinationIP: String?
        var destinationPort: String?
        var host: String?
        /// 从哪个入口进来的；共享入口是 CoreConfigBuilder.shareListener。
        var inboundName: String?
        /// 发起连接的程序（本机的连接才有）。
        var process: String?
        var processPath: String?

        /// 显示用：域名，没有就目标 IP。
        var displayHost: String {
            if let host, !host.isEmpty { return host }
            return destinationIP ?? ""
        }
    }

    var id: String
    var metadata: Metadata
    var upload: Int64
    var download: Int64
    var start: String?
    /// 第一个是实际用的出口（节点名、DIRECT 或上游代理），最后一个是最外层的策略组。
    var chains: [String]?
    var rule: String?
    var rulePayload: String?

    var outbound: String { chains?.first ?? "" }

    /// 最外层的策略组；直接走出口（DIRECT、上游代理）时没有。
    var group: String? {
        guard let chains, chains.count > 1, let last = chains.last, last != chains.first else { return nil }
        return last
    }

    /// 命中的规则，比如「Match」「GeoIP CN」「DomainSuffix cn」。
    var ruleText: String {
        [rule ?? "", rulePayload ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var startDate: Date? { CoreDates.parse(start) }
}

/// /connections 的整体：连接列表和内核这次运行以来的总流量。
struct CoreConnectionsSnapshot: Decodable, Equatable {
    var connections: [CoreConnection]?
    var downloadTotal: Int64?
    var uploadTotal: Int64?
}

/// 内核里的一个规则集（/providers/rules）。
struct CoreRuleProvider: Decodable, Equatable {
    var name: String
    var behavior: String?
    var ruleCount: Int?
    var updatedAt: String?
    var vehicleType: String?
}

/// 正在经共享入口上网的一台设备（按来源 IP 归并的连接）。
struct ShareClient: Identifiable, Equatable {
    var ip: String
    var connections: Int
    var upload: Int64
    var download: Int64
    /// 最近一个连接访问的主机。
    var lastHost: String
    /// 最近一个连接走的出口。
    var lastOutbound: String

    var id: String { ip }

    /// 从连接列表里挑出某个入口的连接（网关模式下经虚拟网卡来的设备也算），按来源 IP 归并；先连上来的设备排前面。
    static func group(_ connections: [CoreConnection], listener: String) -> [ShareClient] {
        var byIP: [String: ShareClient] = [:]
        var order: [String] = []
        let sorted = connections.sorted { ($0.start ?? "") < ($1.start ?? "") }
        for connection in sorted where connection.metadata.inboundName == listener || isGatewayDevice(inbound: connection.metadata.inboundName, source: connection.metadata.sourceIP) {
            guard let ip = connection.metadata.sourceIP, !ip.isEmpty else { continue }
            let host = connection.metadata.displayHost
            if var client = byIP[ip] {
                client.connections += 1
                client.upload += connection.upload
                client.download += connection.download
                if !host.isEmpty { client.lastHost = host }
                if !connection.outbound.isEmpty { client.lastOutbound = connection.outbound }
                byIP[ip] = client
            } else {
                order.append(ip)
                byIP[ip] = ShareClient(ip: ip, connections: 1, upload: connection.upload, download: connection.download, lastHost: host, lastOutbound: connection.outbound)
            }
        }
        return order.compactMap { byIP[$0] }
    }

    /// 网关模式下经虚拟网卡来的局域网设备：入口是虚拟网卡，来源又不是本机（本机经虚拟网卡发出的来源是 198.18 开头的地址）。
    static func isGatewayDevice(inbound: String?, source: String?) -> Bool {
        guard inbound == CoreConfigBuilder.tunInbound, let source, !source.isEmpty else { return false }
        return !source.hasPrefix("198.18.") && !source.hasPrefix("127.") && source != "::1"
    }
}

/// 一条连接的摘要，「最近的连接」列表用：谁（哪个程序、哪台设备）访问了什么、走了哪里、命中了哪条规则、用了多少流量。
struct ConnectionRecord: Identifiable, Equatable {
    var id: String
    /// 来源 IP：本机是 127.0.0.1，共享的设备是它的局域网地址。
    var client: String
    /// 发起连接的程序名，本机的连接才有。
    var process: String
    var host: String
    var port: String
    var outbound: String
    /// 最外层的策略组，没有经过策略组时为空。
    var group: String
    var rule: String
    var start: String
    var inbound: String
    var upload: Int64
    var download: Int64
    var network: String
    /// 发起连接的程序的完整路径（本机的连接才有），「让这个应用走…」用。
    var processPath: String

    init(_ connection: CoreConnection) {
        id = connection.id
        client = connection.metadata.sourceIP ?? ""
        process = connection.metadata.process ?? ""
        processPath = connection.metadata.processPath ?? ""
        host = connection.metadata.displayHost
        port = connection.metadata.destinationPort ?? ""
        outbound = connection.outbound
        group = connection.group ?? ""
        rule = connection.ruleText
        start = connection.start ?? ""
        inbound = connection.metadata.inboundName ?? ""
        upload = connection.upload
        download = connection.download
        network = (connection.metadata.network ?? "").uppercased()
    }

    /// host:port。
    var target: String { port.isEmpty ? host : "\(host):\(port)" }

    /// 是不是局域网设备来的（PS5 等）：经共享入口，或者网关模式下经虚拟网卡。
    var isShare: Bool { inbound == CoreConfigBuilder.shareListener || ShareClient.isGatewayDevice(inbound: inbound, source: client) }

    /// 流量统计里的来源：程序名；共享的设备写「设备 IP」；认不出程序的本机连接算「本机其他」。
    var trafficSource: String {
        if !process.isEmpty { return process }
        // 存在流量统计里的键，不随界面语言变；显示时经 TrafficEntry.displayName 翻译。
        if isShare { return "设备 " + client }  // l10n-ignore
        return ["", "127.0.0.1", "::1", "localhost"].contains(client) ? "本机其他" : client  // l10n-ignore
    }

    /// 显示用的来源：程序名；没有程序名时，本机回环来的写「本机」，其余（共享的设备）显示来源 IP。
    var source: String {
        if !process.isEmpty { return process }
        if isShare { return client }
        return ["", "127.0.0.1", "::1", "localhost"].contains(client) ? L("本机") : client
    }

    /// 出口连同策略组：「组 A → 节点 01」；没经过组时只有出口。
    var route: String {
        let exit = CoreConfigBuilder.displayName(outbound)
        return group.isEmpty || group == outbound ? exit : "\(CoreConfigBuilder.displayName(group)) → \(exit)"
    }

    var startDate: Date? { CoreDates.parse(start) }
}

/// 内核给的时间：ISO 8601，有的带小数秒。
enum CoreDates {
    private static let formatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return [fractional, ISO8601DateFormatter()]
    }()

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: text) {
                // 内核还没更新过时给的是零时间（0001-01-01）。
                return date.timeIntervalSince1970 > 0 ? date : nil
            }
        }
        return nil
    }
}

/// 内核日志里的一行（实时日志用）。
struct LogLine: Identifiable, Equatable {
    var id: Int
    var date: Date
    /// debug、info、warning、error。
    var level: String
    var text: String
}

/// mihomo -t 的输出里挑出最能说明问题的一句。
enum CoreConfigCheck {
    static func problem(from output: String) -> String {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let candidates = lines.filter { $0.contains("level=error") || $0.contains("level=fatal") }
        let chosen = candidates.first ?? lines.last { !$0.contains("test failed") && !$0.isEmpty } ?? output
        if let range = chosen.range(of: "msg=") {
            return String(chosen[range.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        }
        return chosen.trimmingCharacters(in: .whitespaces)
    }
}
