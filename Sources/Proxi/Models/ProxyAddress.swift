import Foundation

/// 解析用户粘贴的整段代理地址：host:port、http://host:port、socks5://user:pass@host:port/、[::1]:1080 等，
/// 拆成类型、主机和端口，方便直接粘到「主机」框里。
struct ProxyAddress: Equatable {
    var kind: ProxyKind?
    var host: String
    var port: Int?
    /// 地址里带的用户名和密码（http://alice:secret@proxy:3128），已经按网址的规则解码；没带时是空的 / nil。
    var username: String = ""
    var password: String?

    static func parse(_ text: String) -> ProxyAddress? {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.isEmpty {
            return nil
        }
        var kind: ProxyKind?
        if let range = rest.range(of: "://") {
            switch rest[..<range.lowerBound].lowercased() {
            case "http", "https": kind = .http
            case "socks", "socks4", "socks5", "socks5h": kind = .socks5
            default: return nil
            }
            rest = String(rest[range.upperBound...])
        }
        if let slash = rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
            rest = String(rest[..<slash])
        }
        var username = ""
        var password: String?
        if let at = rest.lastIndex(of: "@") {
            let userInfo = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
            if let colon = userInfo.firstIndex(of: ":") {
                let user = String(userInfo[..<colon])
                let pass = String(userInfo[userInfo.index(after: colon)...])
                username = user.removingPercentEncoding ?? user
                password = pass.removingPercentEncoding ?? pass
            } else {
                username = userInfo.removingPercentEncoding ?? userInfo
            }
        }
        var host = rest
        var port: Int?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = String(rest[rest.index(after: rest.startIndex)..<close])
            let tail = rest[rest.index(after: close)...]
            if tail.hasPrefix(":") {
                guard let number = Int(tail.dropFirst()) else { return nil }
                port = number
            } else if !tail.isEmpty {
                return nil
            }
        } else if rest.filter({ $0 == ":" }).count == 1, let colon = rest.lastIndex(of: ":") {
            host = String(rest[..<colon])
            guard let number = Int(rest[rest.index(after: colon)...]) else { return nil }
            port = number
        }
        host = host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty || host.contains(where: { $0.isWhitespace }) {
            return nil
        }
        if let port, !(1...65535).contains(port) {
            return nil
        }
        return ProxyAddress(kind: kind, host: host, port: port, username: username, password: password)
    }

    /// 是否比单纯的主机名多带了信息（类型、端口或者用户名），需要拆到别的字段里。
    var splitsFields: Bool { kind != nil || port != nil || !username.isEmpty }
}
