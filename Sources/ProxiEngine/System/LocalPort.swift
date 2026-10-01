import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 本机端口。
enum LocalPort {
    /// 让系统在 127.0.0.1 上分配一个空闲端口（绑定 0 号端口再关掉）；失败时在 20000~40000 里随便挑一个。
    static func pickFree() -> Int {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return Int.random(in: 20000...40000) }
        defer { close(fd) }
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return Int.random(in: 20000...40000) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else { return Int.random(in: 20000...40000) }
        let port = Int(UInt16(bigEndian: address.sin_port))
        return port > 0 ? port : Int.random(in: 20000...40000)
    }
}
