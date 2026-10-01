import Foundation

/// 增强模式（TUN）和网关模式的设置。两者都要装特权助手，是这台 Mac 自己的事，放在本机状态里，不跟着 iCloud 同步。
struct TunConfig: Codable, Equatable {
    /// 增强模式：本机开着代理引擎时，不认系统代理的程序（终端、游戏、部分应用）的流量也经过内核。
    var enabled: Bool = false
    /// 网关模式：局域网里的设备把「路由器」和 DNS 设成这台 Mac，不用在设备上填代理。
    var gateway: Bool = false
    var stack: TunStack = .mixed
    var dnsMode: TunDNSMode = .fakeIP

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, gateway, stack, dnsMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        gateway = try container.decodeIfPresent(Bool.self, forKey: .gateway) ?? false
        stack = (try? container.decodeIfPresent(TunStack.self, forKey: .stack)) ?? .mixed
        dnsMode = (try? container.decodeIfPresent(TunDNSMode.self, forKey: .dnsMode)) ?? .fakeIP
    }
}

/// 虚拟网卡收到的包交给谁处理。
enum TunStack: String, Codable, CaseIterable, Identifiable {
    /// TCP 用系统的协议栈，UDP 用 gVisor：兼顾速度和兼容性。
    case mixed
    case system
    case gvisor

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mixed: return L("混合（推荐）")
        case .system: return L("系统")
        case .gvisor: return "gVisor"
        }
    }
}

/// 经内核的 DNS 查询怎么回答。
enum TunDNSMode: String, Codable, CaseIterable, Identifiable {
    /// 先回一个虚拟 IP，连接时再按域名分流：不依赖本地 DNS 的解析结果，也不用等真正的解析。
    case fakeIP = "fake-ip"
    /// 回真实的 IP，靠域名嗅探分流：兼容性最好。
    case realIP = "redir-host"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fakeIP: return L("虚拟 IP（推荐）")
        case .realIP: return L("真实 IP")
        }
    }
}

/// 交给内核的 TUN 参数：特权助手能用、而且确实要开时才有。
struct TunInputs: Equatable {
    var stack: TunStack
    var dnsMode: TunDNSMode
    /// 本机自己的流量也交给内核（开了增强模式，本机用的又是代理引擎）；否则虚拟网卡只是为网关模式开的，本机的流量照旧直连。
    var captureLocal: Bool
    /// 网关模式：开 DNS 服务，局域网设备经这台 Mac 上网。
    var gateway: Bool
    /// 网关设备的流量往哪走：和局域网共享一样，跟着本机现在的代理状态。
    var upstream: ShareUpstream
    /// 这台 Mac 在局域网里的地址：不接管本机流量时，从这些地址发出去的也直连。
    var localAddresses: [String] = []
}

/// TUN 相关的固定值。
enum TunDefaults {
    /// 虚拟 IP 的地址段；虚拟网卡自己的地址取它开头的 /30（内核的规矩），本机经虚拟网卡发出的流量都从这里来。
    static let fakeIPRange = "198.18.0.1/16"
    static let interfaceNetwork = "198.18.0.0/30"
    /// 不给虚拟 IP 的域名：局域网名字、对时、联网检测、游戏主机和 STUN（NAT 类型检测）等要真实地址的服务。
    static let fakeIPFilter = [
        "*.lan", "*.local", "*.localdomain", "*.home.arpa", "*.internal",
        "localhost.ptlogin2.qq.com", "+.msftconnecttest.com", "+.msftncsi.com",
        "time.*.com", "time.*.gov", "time.*.edu.cn", "time.*.apple.com", "time-ios.apple.com", "time-macos.apple.com",
        "ntp.*.com", "+.pool.ntp.org", "time1.cloud.tencent.com",
        "stun.*.*", "stun.*.*.*", "+.stun.*.*", "+.stun.*.*.*",
        "+.srv.nintendo.net", "+.stun.playstation.net", "xbox.*.microsoft.com", "+.xboxlive.com",
        "+.battlenet.com.cn", "+.wotgame.cn", "+.wggames.cn", "+.wowsgame.cn", "+.wargaming.net",
    ]
}
