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

/// 按出口（节点名、DIRECT、上游代理）、来源（程序、设备）和日期累计的流量。存在本机状态里，内核重启后接着累计，可以清零。
struct TrafficStats: Codable, Equatable {
    /// 最多保留多少天的按天统计。
    static let dayLimit = 31
    /// 来源最多记多少个（按流量留大的）。
    static let sourceLimit = 200

    var outbounds: [String: TrafficTotal] = [:]
    /// 按来源：本机的程序名，或者局域网设备的 IP。
    var sources: [String: TrafficTotal] = [:]
    /// 按天：yyyy-MM-dd。
    var days: [String: TrafficTotal] = [:]
    /// 从什么时候开始统计的。
    var since: Date = Date()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case outbounds, sources, days, since
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        outbounds = try container.decodeIfPresent([String: TrafficTotal].self, forKey: .outbounds) ?? [:]
        sources = try container.decodeIfPresent([String: TrafficTotal].self, forKey: .sources) ?? [:]
        days = try container.decodeIfPresent([String: TrafficTotal].self, forKey: .days) ?? [:]
        since = try container.decodeIfPresent(Date.self, forKey: .since) ?? Date()
    }

    mutating func add(_ delta: [String: TrafficTotal]) {
        for (name, traffic) in delta where !traffic.isZero {
            outbounds[name] = (outbounds[name] ?? TrafficTotal()) + traffic
        }
    }

    /// 一次采样的增量：按出口、按来源，并记到当天。
    mutating func add(_ delta: TrafficDelta, on date: Date = Date()) {
        add(delta.outbounds)
        for (name, traffic) in delta.sources where !traffic.isZero {
            sources[name] = (sources[name] ?? TrafficTotal()) + traffic
        }
        let total = delta.outbounds.values.reduce(TrafficTotal(), +)
        if !total.isZero {
            let day = TrafficStats.dayKey(date)
            days[day] = (days[day] ?? TrafficTotal()) + total
        }
        trim()
    }

    /// 去掉太旧的天和太多的来源。
    mutating func trim() {
        if days.count > TrafficStats.dayLimit {
            for key in days.keys.sorted().dropLast(TrafficStats.dayLimit) {
                days[key] = nil
            }
        }
        if sources.count > TrafficStats.sourceLimit {
            let keep = Set(sources.sorted { $0.value.total > $1.value.total }.prefix(TrafficStats.sourceLimit).map(\.key))
            sources = sources.filter { keep.contains($0.key) }
        }
    }

    mutating func reset() {
        outbounds = [:]
        sources = [:]
        days = [:]
        since = Date()
    }

    var total: TrafficTotal {
        outbounds.values.reduce(TrafficTotal(), +)
    }

    /// 按总量从大到小；一样时按名字。
    var ranked: [TrafficEntry] { TrafficStats.rank(outbounds) }

    /// 来源按流量排。
    var rankedSources: [TrafficEntry] { TrafficStats.rank(sources) }

    /// 最近几天，从早到晚，没有流量的天也列出来（0）。
    func recentDays(_ count: Int, until date: Date = Date()) -> [TrafficEntry] {
        (0..<count).reversed().map { offset in
            let day = TrafficStats.dayKey(date.addingTimeInterval(-Double(offset) * 86400))
            return TrafficEntry(name: day, traffic: days[day] ?? TrafficTotal())
        }
    }

    static func rank(_ values: [String: TrafficTotal]) -> [TrafficEntry] {
        values.map { TrafficEntry(name: $0.key, traffic: $0.value) }.sorted {
            if $0.traffic.total != $1.traffic.total { return $0.traffic.total > $1.traffic.total }
            return $0.name < $1.name
        }
    }

    static func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

/// 一次采样里新增的流量：按出口和按来源。
struct TrafficDelta: Equatable {
    var outbounds: [String: TrafficTotal] = [:]
    var sources: [String: TrafficTotal] = [:]

    var isEmpty: Bool { outbounds.isEmpty && sources.isEmpty }
}

/// 某一时刻经内核的网速（字节每秒）。
struct SpeedSample: Identifiable, Equatable {
    var date: Date
    var upload: Int64
    var download: Int64

    var id: Date { date }
}

/// 一个出口和它的累计流量，列表显示用。
struct TrafficEntry: Identifiable, Equatable {
    var name: String
    var traffic: TrafficTotal

    var id: String { name }

    /// 显示用的名字：内核里的组名、「本机其他」「设备 IP」这类统计的键换成界面语言。
    var displayName: String {
        if name == "本机其他" { return L("本机其他") }  // l10n-ignore
        if name.hasPrefix("设备 ") { return L("设备 %@", String(name.dropFirst(3))) }  // l10n-ignore
        return CoreConfigBuilder.displayName(name)
    }
}

/// 把 /connections 的一次次快照变成每个出口新增的字节数：记住每条连接上次的累计值，只算差。
/// 连接关掉后它最后一次轮询之后的几个字节就丢了，统计是近似的，看趋势够用。
struct TrafficAccumulator: Equatable {
    private(set) var seen: [String: TrafficTotal] = [:]

    init() {}

    mutating func ingest(_ connections: [CoreConnection]) -> [String: TrafficTotal] {
        ingestDetailed(connections).outbounds
    }

    /// 同时按出口和来源（程序名，或者共享设备的 IP）算增量。
    mutating func ingestDetailed(_ connections: [CoreConnection]) -> TrafficDelta {
        var delta = TrafficDelta()
        var next: [String: TrafficTotal] = [:]
        for connection in connections {
            let previous = seen[connection.id] ?? TrafficTotal()
            let current = TrafficTotal(upload: connection.upload, download: connection.download)
            next[connection.id] = current
            let up = max(0, current.upload - previous.upload)
            let down = max(0, current.download - previous.download)
            guard up > 0 || down > 0 else { continue }
            let traffic = TrafficTotal(upload: up, download: down)
            let outbound = connection.outbound.isEmpty ? "DIRECT" : connection.outbound
            delta.outbounds[outbound] = (delta.outbounds[outbound] ?? TrafficTotal()) + traffic
            let source = ConnectionRecord(connection).trafficSource
            delta.sources[source] = (delta.sources[source] ?? TrafficTotal()) + traffic
        }
        seen = next
        return delta
    }
}
