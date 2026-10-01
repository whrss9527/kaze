import Foundation

/// 本机控制接口（命令行、MCP、系统里的 AI 助手）能做到哪一步。
enum ControlPermission: String, Codable, CaseIterable, Identifiable {
    /// 关闭接口。
    case off
    /// 只能查看状态和代理配置。
    case readOnly
    /// 还能开关代理、切换配置、测试连接。
    case operate

    var id: String { rawValue }

    /// 以前版本还有「完全控制」（full），现在按「日常操作」算。
    init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = ControlPermission(rawValue: text) ?? .operate
    }

    var title: String {
        switch self {
        case .off: return L("关闭")
        case .readOnly: return L("只能查看")
        case .operate: return L("开关和切换")
        }
    }

    var detail: String {
        switch self {
        case .off: return L("命令行和 AI 助手都连不上")
        case .readOnly: return L("查看状态和代理配置，不能改动任何东西")
        case .operate: return L("另外可以开关代理、切换配置、测试连接")
        }
    }

    var level: Int {
        switch self {
        case .off: return 0
        case .readOnly: return 1
        case .operate: return 2
        }
    }

    func allows(_ required: ControlPermission) -> Bool { level >= required.level }
}

/// 现在连着的网络：Wi‑Fi 名字（要有定位权限才读得到）、路由器的 IP 和 MAC、网卡。
struct NetworkIdentity: Equatable {
    var ssid: String?
    var routerIP: String?
    var routerMAC: String?
    var interface: String?

    var isEmpty: Bool { ssid == nil && routerIP == nil && routerMAC == nil }

    /// 一句话：Wi‑Fi「Home」· 路由器 192.168.1.1。
    var summary: String {
        var parts: [String] = []
        if let ssid { parts.append(L("Wi‑Fi「%@」", ssid)) }
        if let routerIP { parts.append(L("路由器 %@", routerIP)) }
        if let routerMAC { parts.append(routerMAC) }
        return parts.isEmpty ? L("没有连接网络") : parts.joined(separator: " · ")
    }
}

/// 按网络自动切换的一条规则：连上某个 Wi‑Fi 或路由器时开某个配置或者关代理。
struct NetworkRule: Codable, Identifiable, Equatable, Hashable {
    enum Match: Equatable, Hashable {
        /// Wi‑Fi 名字（区分大小写）。
        case ssid(String)
        /// 路由器的 IP 或 MAC 地址。
        case router(String)
        /// 其他网络：上面的规则都不符合时。
        case other

        var rawValue: String {
            switch self {
            case .ssid(let name): return "ssid:" + name
            case .router(let address): return "router:" + address
            case .other: return "other"
            }
        }

        init?(rawValue: String) {
            if rawValue == "other" {
                self = .other
            } else if rawValue.hasPrefix("ssid:"), rawValue.count > 5 {
                self = .ssid(String(rawValue.dropFirst(5)))
            } else if rawValue.hasPrefix("router:"), rawValue.count > 7 {
                self = .router(String(rawValue.dropFirst(7)))
            } else {
                return nil
            }
        }

        var title: String {
            switch self {
            case .ssid(let name): return L("连上 Wi‑Fi「%@」", name)
            case .router(let address): return L("路由器是 %@", address)
            case .other: return L("其他网络")
            }
        }
    }

    enum Action: Equatable, Hashable {
        /// 开启某个代理配置。
        case profile(UUID)
        /// 关闭代理。
        case off

        var rawValue: String {
            switch self {
            case .profile(let id): return "profile:" + id.uuidString
            case .off: return "off"
            }
        }

        init?(rawValue: String) {
            if rawValue == "off" {
                self = .off
            } else if rawValue.hasPrefix("profile:"), let id = UUID(uuidString: String(rawValue.dropFirst(8))) {
                self = .profile(id)
            } else {
                return nil
            }
        }

        func title(profiles: [Profile]) -> String {
            switch self {
            case .profile(let id): return L("开启「%@」", profiles.first { $0.id == id }?.name ?? L("已删除的配置"))
            case .off: return L("关闭代理")
            }
        }
    }

    var id: UUID = UUID()
    var match: Match
    var action: Action
    var enabled: Bool = true

    init(match: Match, action: Action) {
        self.match = match
        self.action = action
    }

    private enum CodingKeys: String, CodingKey {
        case id, match, action, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let matchText = try container.decode(String.self, forKey: .match)
        let actionText = try container.decode(String.self, forKey: .action)
        guard let match = Match(rawValue: matchText) else {
            throw DecodingError.dataCorruptedError(forKey: .match, in: container, debugDescription: L("认不出网络条件 %@", matchText))
        }
        guard let action = Action(rawValue: actionText) else {
            throw DecodingError.dataCorruptedError(forKey: .action, in: container, debugDescription: L("认不出动作 %@", actionText))
        }
        self.match = match
        self.action = action
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(match.rawValue, forKey: .match)
        try container.encode(action.rawValue, forKey: .action)
        try container.encode(enabled, forKey: .enabled)
    }

    /// 这个网络符不符合（「其他网络」单独处理）。路由器按 IP 或 MAC 比较，MAC 不区分大小写。
    func matches(_ identity: NetworkIdentity) -> Bool {
        switch match {
        case .ssid(let name):
            return identity.ssid == name
        case .router(let address):
            let value = address.trimmingCharacters(in: .whitespaces)
            if value.contains(":") || value.contains("-"), let mac = identity.routerMAC {
                return NetworkRule.normalizeMAC(value) == NetworkRule.normalizeMAC(mac)
            }
            return identity.routerIP == value
        case .other:
            return false
        }
    }

    /// aa:bb:cc:dd:ee:ff 的统一写法：小写、冒号分隔、每段两位。
    static func normalizeMAC(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0 == ":" || $0 == "-" })
            .map { $0.count == 1 ? "0" + $0 : String($0) }
            .joined(separator: ":")
    }

    /// 符合的第一条启用的规则：先看具体的网络，都不符合时用「其他网络」。没连网络时不切换。
    static func firstMatch(_ rules: [NetworkRule], identity: NetworkIdentity) -> NetworkRule? {
        guard !identity.isEmpty else { return nil }
        let enabled = rules.filter(\.enabled)
        if let specific = enabled.first(where: { $0.matches(identity) }) { return specific }
        return enabled.first { $0.match == .other }
    }
}

/// 自动化的设置：本机控制接口的权限、按网络自动切换。
struct AutomationConfig: Codable, Equatable {
    var permission: ControlPermission = .operate
    /// 按网络自动切换的总开关。
    var networkSwitching: Bool = true
    var networkRules: [NetworkRule] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case permission, networkSwitching, networkRules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        permission = (try? container.decodeIfPresent(ControlPermission.self, forKey: .permission)) ?? .operate
        networkSwitching = try container.decodeIfPresent(Bool.self, forKey: .networkSwitching) ?? true
        // 一条一条读：以前版本里的规则（比如切换模式）认不出来时只跳过那一条，别的照常保留。
        let items = (try? container.decodeIfPresent([LenientRule].self, forKey: .networkRules)) ?? []
        networkRules = items.compactMap(\.rule)
    }
}

/// 读不出来的规则不让整个列表失败。
private struct LenientRule: Decodable {
    var rule: NetworkRule?

    init(from decoder: Decoder) throws {
        rule = try? NetworkRule(from: decoder)
    }
}
