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
        var sourceIP: String?
        var destinationIP: String?
        var destinationPort: String?
        var host: String?
        /// 从哪个入口进来的；共享入口是 CoreConfigBuilder.shareListener。
        var inboundName: String?

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
    var chains: [String]?
}

/// 正在经共享入口上网的一台设备（按来源 IP 归并的连接）。
struct ShareClient: Identifiable, Equatable {
    var ip: String
    var connections: Int
    var upload: Int64
    var download: Int64
    /// 最近一个连接访问的主机。
    var lastHost: String

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
                byIP[ip] = client
            } else {
                order.append(ip)
                byIP[ip] = ShareClient(ip: ip, connections: 1, upload: connection.upload, download: connection.download, lastHost: host)
            }
        }
        return order.compactMap { byIP[$0] }
    }
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
        let data = try await requestData("GET", "/connections")
        struct Envelope: Decodable { var connections: [CoreConnection]? }
        return try JSONDecoder().decode(Envelope.self, from: data).connections ?? []
    }

    /// 让内核重新下载一条订阅。
    func updateProvider(_ name: String) async throws {
        _ = try await requestData("PUT", "/providers/proxies/\(encode(name))", timeout: 60)
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
