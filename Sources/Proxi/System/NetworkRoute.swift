import Foundation

/// 更新时访问 GitHub 的线路，按顺序尝试：内置代理（内核在跑时）、系统代理（开着且不是内核时）、直连。
/// 这样没开系统代理、或者系统代理坏了的时候，更新也能下载下来。
enum NetworkRoute: Equatable {
    case core(Int)
    case system
    case direct

    var title: String {
        switch self {
        case .core: return "内置代理"
        case .system: return "系统代理"
        case .direct: return "直连"
        }
    }

    func apply(to configuration: URLSessionConfiguration) {
        switch self {
        case .core(let port):
            configuration.connectionProxyDictionary = [
                kCFNetworkProxiesHTTPEnable as String: 1,
                kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPPort as String: port,
                kCFNetworkProxiesHTTPSEnable as String: 1,
                kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
                kCFNetworkProxiesHTTPSPort as String: port,
            ]
        case .system:
            configuration.connectionProxyDictionary = nil
        case .direct:
            // 空字典表示不用任何代理（nil 才是跟随系统设置）。
            configuration.connectionProxyDictionary = [:]
        }
    }

    /// 访问 url 时依次尝试的线路。
    static func routes(for url: URL, corePort: Int?, system: ProxySnapshot) -> [NetworkRoute] {
        let host = (url.host ?? "").lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(host) {
            return [.direct]
        }
        var routes: [NetworkRoute] = []
        if let corePort {
            routes.append(.core(corePort))
        }
        let systemIsCore = corePort.map { system.pointsAtLocalhost(port: $0) } ?? false
        if system.isActive && !systemIsCore {
            routes.append(.system)
        }
        routes.append(.direct)
        return routes
    }
}

extension ProxySnapshot {
    /// 系统代理是不是指向本机的这个端口（也就是内置代理）。
    func pointsAtLocalhost(port: Int) -> Bool {
        func local(_ host: String) -> Bool { ["127.0.0.1", "localhost", "::1"].contains(host.lowercased()) }
        guard !pacActive else { return false }
        let https = httpsActive && local(httpsHost) && httpsPort == port
        let http = httpActive && local(httpHost) && httpPort == port
        return https || http
    }
}
