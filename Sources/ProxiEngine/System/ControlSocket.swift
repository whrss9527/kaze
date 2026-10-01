import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// 本机控制接口的 Unix 套接字：只有同一个用户能连（文件权限 600），一行一条 JSON-RPC 消息。
enum UnixSocket {
    /// 默认的位置：~/Library/Application Support/Proxi/control.sock。
    static var defaultPath: String {
        Store.directory.appendingPathComponent("control.sock").path
    }

    static func makeSocket() -> Int32 {
        #if canImport(Darwin)
        return socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        return socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    static func address(_ path: String) throws -> (sockaddr_un, socklen_t) {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else { throw ControlError.failed(L("套接字路径太长：%@", path)) }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: capacity) { buffer in
                for (index, byte) in bytes.enumerated() {
                    buffer[index] = byte
                }
                buffer[bytes.count] = 0
            }
        }
        #if canImport(Darwin)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        #endif
        return (address, socklen_t(MemoryLayout<sockaddr_un>.size))
    }

    /// 写端断开时不要收到 SIGPIPE（默认会让进程退出）。
    static func disableSigpipe(_ fd: Int32) {
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    static func setTimeout(_ fd: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { buffer -> Int in
                #if canImport(Darwin)
                return write(fd, buffer.baseAddress, buffer.count)
                #else
                return send(fd, buffer.baseAddress, buffer.count, Int32(MSG_NOSIGNAL))
                #endif
            }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// 读到换行为止（不含换行）；对方关了或超时返回 nil。
    static func readLine(_ fd: Int32, buffer: inout Data, limit: Int = 32 << 20) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                return line
            }
            if buffer.count > limit { return nil }
            let count = read(fd, &chunk, chunk.count)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}

/// 套接字服务端：每个连接一个线程，一行请求一行回应。handler 在后台线程上调用，可以阻塞。
final class ControlSocketServer: @unchecked Sendable {
    let path: String
    private let handler: @Sendable (Data) -> Data
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.whrss9527.proxyswitch.control")

    init(path: String = UnixSocket.defaultPath, handler: @escaping @Sendable (Data) -> Data) {
        self.path = path
        self.handler = handler
    }

    var isRunning: Bool { source != nil }

    func start() throws {
        stop()
        signal(SIGPIPE, SIG_IGN)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        unlink(path)
        let fd = UnixSocket.makeSocket()
        guard fd >= 0 else { throw ControlError.failed(L("建不了套接字：%@", String(cString: strerror(errno)))) }
        var (address, length) = try UnixSocket.address(path)
        // 先把权限收紧再绑定，文件一出现就只有自己能连。
        let oldMask = umask(0o077)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        umask(oldMask)
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw ControlError.failed(L("绑定 %@ 失败：%@", path, message))
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw ControlError.failed(L("监听失败：%@", String(cString: strerror(errno))))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { break }
                guard let self else {
                    close(client)
                    continue
                }
                self.serve(client)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        guard let source else { return }
        source.cancel()
        self.source = nil
        unlink(path)
    }

    private func serve(_ client: Int32) {
        // 接进来的连接改回阻塞模式，交给单独的线程。
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        UnixSocket.disableSigpipe(client)
        guard ControlSocketServer.sameUser(client) else {
            close(client)
            return
        }
        let handler = self.handler
        Thread.detachNewThread {
            defer { close(client) }
            var buffer = Data()
            while let line = UnixSocket.readLine(client, buffer: &buffer) {
                if line.isEmpty { continue }
                var response = handler(line)
                response.append(0x0A)
                if !UnixSocket.writeAll(client, response) { return }
            }
        }
    }

    /// 只接受同一个用户的连接（文件权限之外再确认一次）。
    static func sameUser(_ fd: Int32) -> Bool {
        #if canImport(Darwin)
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return false }
        return uid == getuid()
        #else
        return true
        #endif
    }
}

/// 套接字客户端（命令行和 MCP 用）。
enum ControlSocketClient {
    /// 发一条请求，等一行回应。连不上时抛出 notRunning。
    static func send(_ request: Data, path: String = UnixSocket.defaultPath, timeout: TimeInterval = 180) throws -> Data {
        let fd = UnixSocket.makeSocket()
        guard fd >= 0 else { throw ControlError.failed(L("建不了套接字")) }
        defer { close(fd) }
        UnixSocket.disableSigpipe(fd)
        var (address, length) = try UnixSocket.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        guard connected == 0 else {
            throw ControlError(code: JSONRPC.notRunning, message: L("代理引擎没有在运行，或者「通用」里关掉了本机控制接口"))
        }
        UnixSocket.setTimeout(fd, seconds: timeout)
        var line = request
        line.append(0x0A)
        guard UnixSocket.writeAll(fd, line) else { throw ControlError.failed(L("发送请求失败")) }
        var buffer = Data()
        guard let response = UnixSocket.readLine(fd, buffer: &buffer) else {
            throw ControlError.failed(L("代理引擎没有回应（可能超时了）"))
        }
        return response
    }

    /// 调用一个工具，返回结果；接口返回错误时抛出。
    static func call(_ method: String, params: [String: Any] = [:], client: String, path: String = UnixSocket.defaultPath, timeout: TimeInterval = 180) throws -> [String: Any] {
        var request = JSONRPC.request(id: 1, method: method, params: params)
        request["client"] = client
        let data = try send(JSONRPC.encode(request), path: path, timeout: timeout)
        guard let response = JSONRPC.decode(data) else { throw ControlError.failed(L("读不懂代理引擎的回应")) }
        if let error = response["error"] as? [String: Any] {
            throw ControlError(code: (error["code"] as? Int) ?? JSONRPC.internalError, message: (error["message"] as? String) ?? L("出错了"))
        }
        return (response["result"] as? [String: Any]) ?? [:]
    }
}
