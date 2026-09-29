import Foundation
import SystemConfiguration

/// 这台 Mac 在局域网里的地址：其他设备填代理服务器时用。
enum LocalNetwork {
    struct Address: Identifiable, Equatable {
        /// 网卡的 BSD 名，比如 en0。
        var interface: String
        var ip: String
        /// 网络服务名（Wi‑Fi、以太网），找不到时就是网卡名。
        var serviceName: String

        var id: String { interface }
    }

    /// 有 IPv4 地址的网卡，主网卡（默认路由所在）排在最前，其余按名字排。
    static func addresses() -> [Address] {
        let ips = ipv4Addresses()
        guard !ips.isEmpty else { return [] }
        let services = NetworkServices.all()
        let primary = primaryInterface()
        let names = ips.keys.sorted { lhs, rhs in
            if lhs == primary { return true }
            if rhs == primary { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return names.compactMap { name in
            guard let ip = ips[name] else { return nil }
            let service = services.first { $0.bsdName == name }?.name ?? name
            return Address(interface: name, ip: ip, serviceName: service)
        }
    }

    /// 默认路由所在的网卡（State:/Network/Global/IPv4 里的 PrimaryInterface）。
    static func primaryInterface() -> String? {
        guard let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return value["PrimaryInterface"] as? String
    }

    /// 每个网卡的第一个 IPv4 地址。只看有线、Wi‑Fi 和网桥（en*、bridge*），不算回环、VPN 隧道和 169.254 的链路本地地址。
    static func ipv4Addresses() -> [String: String] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return [:] }
        defer { freeifaddrs(start) }
        var result: [String: String] = [:]
        var pointer: UnsafeMutablePointer<ifaddrs>? = start
        while let current = pointer {
            let interface = current.pointee
            pointer = interface.ifa_next
            guard let address = interface.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  interface.ifa_flags & UInt32(IFF_UP) != 0,
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge"), result[name] == nil else { continue }
            var ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let ip = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if ip.isEmpty || ip.hasPrefix("169.254.") { continue }
            result[name] = ip
        }
        return result
    }
}
