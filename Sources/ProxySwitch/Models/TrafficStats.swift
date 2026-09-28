import Foundation

/// 上行、下行的字节数。
struct TrafficTotal: Codable, Equatable {
    var upload: Int64 = 0
    var download: Int64 = 0

    init(upload: Int64 = 0, download: Int64 = 0) {
        self.upload = upload
        self.download = download
    }

    var total: Int64 { upload + download }
    var isZero: Bool { upload == 0 && download == 0 }

    static func + (lhs: TrafficTotal, rhs: TrafficTotal) -> TrafficTotal {
        TrafficTotal(upload: lhs.upload + rhs.upload, download: lhs.download + rhs.download)
    }
}

/// 按出口（节点名、DIRECT、上游代理）累计的流量。存在本机状态里，内核重启后接着累计，可以清零。
struct TrafficStats: Codable, Equatable {
    var outbounds: [String: TrafficTotal] = [:]
    /// 从什么时候开始统计的。
    var since: Date = Date()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case outbounds, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outbounds = try container.decodeIfPresent([String: TrafficTotal].self, forKey: .outbounds) ?? [:]
        since = try container.decodeIfPresent(Date.self, forKey: .since) ?? Date()
    }

    mutating func add(_ delta: [String: TrafficTotal]) {
        for (name, traffic) in delta where !traffic.isZero {
            outbounds[name] = (outbounds[name] ?? TrafficTotal()) + traffic
        }
    }

    mutating func reset() {
        outbounds = [:]
        since = Date()
    }

    var total: TrafficTotal {
        outbounds.values.reduce(TrafficTotal(), +)
    }

    /// 按总量从大到小；一样时按名字。
    var ranked: [TrafficEntry] {
        outbounds.map { TrafficEntry(name: $0.key, traffic: $0.value) }.sorted {
            if $0.traffic.total != $1.traffic.total { return $0.traffic.total > $1.traffic.total }
            return $0.name < $1.name
        }
    }
}

/// 一个出口和它的累计流量，列表显示用。
struct TrafficEntry: Identifiable, Equatable {
    var name: String
    var traffic: TrafficTotal

    var id: String { name }
}

/// 把 /connections 的一次次快照变成每个出口新增的字节数：记住每条连接上次的累计值，只算差。
/// 连接关掉后它最后一次轮询之后的几个字节就丢了，统计是近似的，看趋势够用。
struct TrafficAccumulator: Equatable {
    private(set) var seen: [String: TrafficTotal] = [:]

    init() {}

    mutating func ingest(_ connections: [CoreConnection]) -> [String: TrafficTotal] {
        var delta: [String: TrafficTotal] = [:]
        var next: [String: TrafficTotal] = [:]
        for connection in connections {
            let previous = seen[connection.id] ?? TrafficTotal()
            let current = TrafficTotal(upload: connection.upload, download: connection.download)
            next[connection.id] = current
            let up = max(0, current.upload - previous.upload)
            let down = max(0, current.download - previous.download)
            guard up > 0 || down > 0 else { continue }
            let outbound = connection.outbound.isEmpty ? "DIRECT" : connection.outbound
            delta[outbound] = (delta[outbound] ?? TrafficTotal()) + TrafficTotal(upload: up, download: down)
        }
        seen = next
        return delta
    }
}
