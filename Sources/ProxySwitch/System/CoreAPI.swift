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

/// 订阅的流量和到期信息（机场通过响应头给的）。
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

    var startDate: Date? { Engine.parseDate(start) }
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

    /// 从连接列表里挑出某个入口的连接，按来源 IP 归并；先连上来的设备排前面。
    static func group(_ connections: [CoreConnection], listener: String) -> [ShareClient] {
        var byIP: [String: ShareClient] = [:]
        var order: [String] = []
        let sorted = connections.sorted { ($0.start ?? "") < ($1.start ?? "") }
        for connection in sorted where connection.metadata.inboundName == listener {
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

    init(_ connection: CoreConnection) {
        id = connection.id
        client = connection.metadata.sourceIP ?? ""
        process = connection.metadata.process ?? ""
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

    /// 是不是经共享入口来的（PS5 等设备）。
    var isShare: Bool { inbound == CoreConfigBuilder.shareListener }

    /// 显示用的来源：程序名；没有程序名时，本机回环来的写「本机」，其余（共享的设备）显示来源 IP。
    var source: String {
        if !process.isEmpty { return process }
        if isShare { return client }
        return ["", "127.0.0.1", "::1", "localhost"].contains(client) ? "本机" : client
    }

    /// 出口连同策略组：「流媒体 → 香港 01」；没经过组时只有出口。
    var route: String {
        group.isEmpty || group == outbound ? outbound : "\(group) → \(outbound)"
    }

    var startDate: Date? { Engine.parseDate(start) }
}

enum CoreAPIError: LocalizedError {
    case status(Int, String)
    case badResponse
    case delayFailed

    var errorDescription: String? {
        switch self {
        case .status(let code, let message): return message.isEmpty ? "内核返回了 \(code)" : "内核返回了 \(code)：\(message)"
        case .badResponse: return "读不懂内核返回的内容"
        case .delayFailed: return "测速失败"
        }
    }
}

/// 内核的 RESTful API（127.0.0.1:端口，Bearer 密钥）。请求不走系统代理。
final class CoreAPI {
    let baseURL: URL
    let secret: String
    private let session: URLSession
    private let streamSession: URLSession

    init(port: Int, secret: String) {
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
        self.secret = secret
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
        // 长连接的流（/traffic 每秒一行），不设总时长限制。
        let streaming = URLSessionConfiguration.ephemeral
        streaming.connectionProxyDictionary = [:]
        streaming.timeoutIntervalForRequest = 30
        streaming.timeoutIntervalForResource = .greatestFiniteMagnitude
        streamSession = URLSession(configuration: streaming)
    }

    /// 实时流量：每秒一行 {"up":字节数,"down":字节数}。
    func trafficBytes() async throws -> URLSession.AsyncBytes {
        var request = URLRequest(url: URL(string: "/traffic", relativeTo: baseURL)!.absoluteURL)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await streamSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CoreAPIError.status(http.statusCode, "")
        }
        return bytes
    }

    /// 内核日志流：每行 {"type":"info","payload":"..."}。级别在 API 侧过滤，不受配置里 log-level 的限制。
    func logBytes(level: String) async throws -> URLSession.AsyncBytes {
        var request = URLRequest(url: URL(string: "/logs?level=\(level)", relativeTo: baseURL)!.absoluteURL)
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (bytes, response) = try await streamSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw CoreAPIError.status(http.statusCode, "")
        }
        return bytes
    }

    func version() async throws -> String {
        let json = try await request("GET", "/version")
        return (json["version"] as? String) ?? "?"
    }

    func proxies() async throws -> [String: CoreProxy] {
        let data = try await requestData("GET", "/proxies")
        struct Envelope: Decodable { var proxies: [String: CoreProxy] }
        return try JSONDecoder().decode(Envelope.self, from: data).proxies
    }

    func proxy(named name: String) async throws -> CoreProxy {
        let data = try await requestData("GET", "/proxies/\(encode(name))")
        return try JSONDecoder().decode(CoreProxy.self, from: data)
    }

    func select(group: String, node: String) async throws {
        _ = try await requestData("PUT", "/proxies/\(encode(group))", body: ["name": node])
    }

    /// 测一个节点的延迟（毫秒），失败抛错。
    func delay(node: String, url: String, timeout: Int = 5000) async throws -> Int {
        let json = try await request("GET", "/proxies/\(encode(node))/delay?timeout=\(timeout)&url=\(encode(url))")
        guard let delay = json["delay"] as? Int, delay > 0 else { throw CoreAPIError.delayFailed }
        return delay
    }

    /// 测一个组里所有节点的延迟，返回成功的那些。
    func groupDelay(group: String, url: String, timeout: Int = 5000) async throws -> [String: Int] {
        let json = try await request("GET", "/group/\(encode(group))/delay?timeout=\(timeout)&url=\(encode(url))", timeout: TimeInterval(timeout) / 1000 + 10)
        var result: [String: Int] = [:]
        for (name, value) in json {
            if let delay = value as? Int, delay > 0 {
                result[name] = delay
            }
        }
        return result
    }

    func providers() async throws -> [String: CoreProvider] {
        let data = try await requestData("GET", "/providers/proxies")
        struct Envelope: Decodable { var providers: [String: CoreProvider] }
        return try JSONDecoder().decode(Envelope.self, from: data).providers
    }

    /// 当前所有连接。
    func connections() async throws -> [CoreConnection] {
        try await connectionsSnapshot().connections ?? []
    }

    /// 当前所有连接，连同内核这次运行以来的总流量。
    func connectionsSnapshot() async throws -> CoreConnectionsSnapshot {
        let data = try await requestData("GET", "/connections")
        return try JSONDecoder().decode(CoreConnectionsSnapshot.self, from: data)
    }

    /// 断开一条连接。
    func closeConnection(_ id: String) async throws {
        _ = try await requestData("DELETE", "/connections/\(encode(id))")
    }

    /// 断开全部连接。
    func closeAllConnections() async throws {
        _ = try await requestData("DELETE", "/connections")
    }

    /// 让内核重新下载一条订阅。
    func updateProvider(_ name: String) async throws {
        _ = try await requestData("PUT", "/providers/proxies/\(encode(name))", timeout: 60)
    }

    /// 内核加载的规则集。
    func ruleProviders() async throws -> [String: CoreRuleProvider] {
        let data = try await requestData("GET", "/providers/rules")
        struct Envelope: Decodable { var providers: [String: CoreRuleProvider] }
        return try JSONDecoder().decode(Envelope.self, from: data).providers
    }

    /// 让内核重读一个规则集的文件。
    func updateRuleProvider(_ name: String) async throws {
        _ = try await requestData("PUT", "/providers/rules/\(encode(name))", timeout: 60)
    }

    /// 重新读取配置文件（不重启内核）。
    func reload(configPath: String) async throws {
        _ = try await requestData("PUT", "/configs?force=true", body: ["path": configPath], timeout: 60)
    }

    // MARK: - 请求

    private func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        let data = try await requestData(method, path, body: body, timeout: timeout)
        if data.isEmpty { return [:] }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CoreAPIError.badResponse }
        return json
    }

    private func requestData(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: baseURL)!.absoluteURL)
        request.httpMethod = method
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        if let timeout {
            request.timeoutInterval = timeout
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String ?? ""
            throw CoreAPIError.status(http.statusCode, message)
        }
        return data
    }

    private func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? text
    }
}
