import Foundation

/// 局域网共享的设置：让同一局域网里的设备（PS5、Switch、手机……）把这台 Mac 当代理服务器，享受和本机一样的网络。
/// 由哪台 Mac 来共享是本机的事，所以放在本机状态里，不跟着 iCloud 同步。
struct ShareConfig: Codable, Equatable {
    static let defaultPort = 7892
    /// 默认允许的来源：局域网里常见的私有网段。
    static let lanPrefixes = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "169.254.0.0/16"]
    /// 本机回环总是允许：内核自己的代理端口也受同一份名单限制。
    static let loopbackPrefixes = ["127.0.0.0/8", "::1/128"]

    var enabled: Bool = false
    var port: Int = ShareConfig.defaultPort
    /// 只允许这些设备使用（IP 或 CIDR，逗号分隔）；空表示局域网里的所有设备。
    var allowedClients: String = ""
    /// 共享期间不让 Mac 进入空闲睡眠（显示器照常可以关）。
    var keepAwake: Bool = true
    /// 电池供电时也保持；默认只在接电源时。
    var keepAwakeOnBattery: Bool = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, port, allowedClients, keepAwake, keepAwakeOnBattery
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? ShareConfig.defaultPort
        allowedClients = try container.decodeIfPresent(String.self, forKey: .allowedClients) ?? ""
        keepAwake = try container.decodeIfPresent(Bool.self, forKey: .keepAwake) ?? true
        keepAwakeOnBattery = try container.decodeIfPresent(Bool.self, forKey: .keepAwakeOnBattery) ?? false
    }

    /// 内核 lan-allowed-ips 里的网段：用户填的设备，或者默认的局域网网段；回环总在里面。
    var allowedPrefixes: [String] {
        let clients = ShareConfig.parseClients(allowedClients).prefixes
        return ShareConfig.loopbackPrefixes + (clients.isEmpty ? ShareConfig.lanPrefixes : clients)
    }

    /// 把「192.168.1.20, 192.168.2.0/24」这样的文字拆成 CIDR；认不出来的放在 invalid 里。
    static func parseClients(_ text: String) -> (prefixes: [String], invalid: [String]) {
        var prefixes: [String] = []
        var invalid: [String] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0.isNewline }) {
            let item = String(raw).trimmingCharacters(in: .whitespaces)
            if item.isEmpty { continue }
            guard let prefix = IPPrefix.normalize(item) else {
                invalid.append(item)
                continue
            }
            if seen.insert(prefix).inserted {
                prefixes.append(prefix)
            }
        }
        return (prefixes, invalid)
    }

    /// 校验，返回问题；没问题返回 nil。
    func validate() -> String? {
        if port < 1024 || port > 65535 {
            return L("端口需要是 1024~65535 之间的数字")
        }
        let invalid = ShareConfig.parseClients(allowedClients).invalid
        if !invalid.isEmpty {
            return L("认不出这些地址：%@", invalid.joined(separator: L("、")))
        }
        return nil
    }
}

/// IPv4 / IPv6 地址或 CIDR 的格式检查。
enum IPPrefix {
    /// "192.168.1.20" → "192.168.1.20/32"，"10.0.0.0/8" 原样，"fe80::1" → "fe80::1/128"；格式不对返回 nil。
    static func normalize(_ text: String) -> String? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count <= 2, let first = parts.first else { return nil }
        let address = String(first)
        guard !address.isEmpty else { return nil }
        let isIPv6 = address.contains(":")
        guard isIPv6 ? isIPv6Address(address) : isIPv4Address(address) else { return nil }
        let maxLength = isIPv6 ? 128 : 32
        if parts.count == 2 {
            guard let length = Int(parts[1]), (0...maxLength).contains(length) else { return nil }
            return "\(address)/\(length)"
        }
        return "\(address)/\(maxLength)"
    }

    static func isIPv4Address(_ text: String) -> Bool {
        var address = in_addr()
        return text.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }

    static func isIPv6Address(_ text: String) -> Bool {
        var address = in6_addr()
        return text.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
    }
}

/// 共享出去的流量往哪走：跟着本机当前的代理状态，本机用什么，共享的设备就用什么。
enum ShareUpstream: Equatable {
    /// 本机没开代理：经这台 Mac 直接上网。
    case direct
    /// 本机用的是代理引擎：走同样的节点和分流规则。
    case engine
    /// 本机用的是别的 HTTP 或 SOCKS5 代理（公司代理、其他代理软件）：转发给它。
    case proxy(kind: ProxyKind, host: String, port: Int)
    /// PAC 脚本这类没法转发的：先直连。
    case unsupported(String)

    init(status: ProxyStatus, snapshot: ProxySnapshot) {
        switch status {
        case .off:
            self = .direct
        case .on(let profile):
            if profile.engine {
                self = .engine
            } else {
                switch profile.kind {
                case .http, .socks5:
                    self = .proxy(kind: profile.kind, host: profile.host, port: profile.port)
                case .pac:
                    self = .unsupported(L("本机用的是 PAC 脚本，没法转发给其他设备，共享的设备暂时直连"))
                }
            }
        case .external:
            // 别的程序设置的系统代理：PAC 优先于手动代理，和浏览器一致。
            if snapshot.pacActive {
                self = .unsupported(L("系统代理是 PAC 脚本，没法转发给其他设备，共享的设备暂时直连"))
            } else if snapshot.httpActive {
                self = .proxy(kind: .http, host: snapshot.httpHost, port: snapshot.httpPort)
            } else if snapshot.httpsActive {
                self = .proxy(kind: .http, host: snapshot.httpsHost, port: snapshot.httpsPort)
            } else if snapshot.socksActive {
                self = .proxy(kind: .socks5, host: snapshot.socksHost, port: snapshot.socksPort)
            } else {
                self = .direct
            }
        }
    }

    /// 设置页里「现在转发到」的文字。
    var title: String {
        switch self {
        case .direct: return L("直接连接（本机没开代理）")
        case .engine: return L("代理引擎（和本机一样的节点和分流规则）")
        case .proxy(let kind, let host, let port): return kind == .socks5 ? "socks5://\(host):\(port)" : "\(host):\(port)"
        case .unsupported: return L("直接连接（PAC 没法转发）")
        }
    }

    /// 一句话的说明（诊断页和日志里用）。
    var summary: String {
        switch self {
        case .direct: return L("设备经这台 Mac 直连")
        case .engine: return L("设备和本机一样走节点")
        case .proxy(let kind, let host, let port): return L("设备的流量转发到 %@%@:%@", kind == .socks5 ? "socks5://" : "", host, port)
        case .unsupported: return L("PAC 没法转发，设备暂时直连")
        }
    }

    var warning: String? {
        if case .unsupported(let text) = self { return text }
        return nil
    }
}

/// 交给内核配置生成的共享参数：端口、允许的来源、上游。
struct ShareInputs: Equatable {
    var port: Int
    var allowedPrefixes: [String]
    var upstream: ShareUpstream
}
