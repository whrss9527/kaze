import Foundation

/// 更新时访问 GitHub 的线路，按顺序尝试：系统代理（开着时）、直连。
/// 这样没开系统代理、或者系统代理坏了的时候，更新也能下载下来。
enum NetworkRoute: Equatable {
    case system
    case direct

    var title: String {
        switch self {
        case .system: return L("系统代理")
        case .direct: return L("直连")
        }
    }

    func apply(to configuration: URLSessionConfiguration) {
        switch self {
        case .system:
            configuration.connectionProxyDictionary = nil
        case .direct:
            // 空字典表示不用任何代理（nil 才是跟随系统设置）。
            configuration.connectionProxyDictionary = [:]
        }
    }

    /// 访问 url 时依次尝试的线路。
    static func routes(for url: URL, system: ProxySnapshot) -> [NetworkRoute] {
        let host = (url.host ?? "").lowercased()
        if ["localhost", "127.0.0.1", "::1"].contains(host) {
            return [.direct]
        }
        var routes: [NetworkRoute] = []
        if system.isActive {
            routes.append(.system)
        }
        routes.append(.direct)
        return routes
    }
}
