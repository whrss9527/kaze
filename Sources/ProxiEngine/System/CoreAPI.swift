import Foundation

enum CoreAPIError: LocalizedError {
    case status(Int, String)
    case badResponse
    case delayFailed

    var errorDescription: String? {
        switch self {
        case .status(let code, let message): return message.isEmpty ? L("内核返回了 %@", code) : L("内核返回了 %@：%@", code, message)
        case .badResponse: return L("读不懂内核返回的内容")
        case .delayFailed: return L("测速失败")
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
