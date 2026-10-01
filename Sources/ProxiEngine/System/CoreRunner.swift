import Foundation

/// 打包在 app 里的内核和数据文件。
enum CoreBinary {
    static let name = "mihomo"

    /// 内核程序：开启代理引擎时下载到数据目录的 bin/mihomo（见 CoreDownload.swift，校验过 SHA-256）。
    /// 开发时可以用环境变量 PROXI_CORE 指定。
    static var executableURL: URL? {
        if let override = ProcessInfo.processInfo.environment["PROXI_CORE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return installedPath.map { URL(fileURLWithPath: $0) }
    }

    /// 下载好的那份内核（不看环境变量）：装特权助手时复制它，助手那边再校验一遍。
    static var installedPath: String? {
        let url = CoreDownload.coreURL
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    /// GeoIP 数据库（按 IP 归属地分流的规则要用），和内核一起下载。
    static var geoIPURL: URL? {
        let url = CoreDownload.geoIPURL
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

enum CoreRunnerError: LocalizedError {
    case missingBinary
    case launchFailed(String)
    case notReady(String)

    var errorDescription: String? {
        switch self {
        case .missingBinary: return L("还没有下载内核，到设置的「内核」页下载")
        case .launchFailed(let text): return L("内核启动失败：%@", text)
        case .notReady(let text): return L("内核没有正常启动：%@", text)
        }
    }
}

/// 内核进程：启动、停止、收日志。
final class CoreRunner {
    private let queue = DispatchQueue(label: "com.whrss9527.proxyswitch.core")
    private var process: Process?
    private var lines: [String] = []
    private var logHandle: FileHandle?
    private var pending = ""

    /// 进程退出时（主线程）。
    var onExit: (@MainActor (Int32) -> Void)?

    var isRunning: Bool { process?.isRunning ?? false }
    var pid: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }

    /// 最近的日志。
    var logTail: String {
        queue.sync { lines.suffix(200).joined(separator: "\n") }
    }

    func start(executable: URL, directory: URL, config: URL) throws {
        stop()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-d", directory.path, "-f", config.path]
        process.currentDirectoryURL = directory
        process.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "TMPDIR": NSTemporaryDirectory()]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        openLog(in: directory)
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.append(data)
        }
        process.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = finished.terminationStatus
            self?.append(Data("[Proxi] 内核退出，状态 \(status)\n".utf8))  // l10n-ignore：内核日志
            Task { @MainActor in self?.onExit?(status) }
        }
        do {
            try process.run()
        } catch {
            throw CoreRunnerError.launchFailed(error.localizedDescription)
        }
        self.process = process
    }

    func stop() {
        guard let process, process.isRunning else {
            self.process = nil
            return
        }
        process.terminationHandler = nil
        process.terminate()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
    }

    /// 上次没退干净的内核（比如程序被强杀）会占着端口，按配置文件路径把它们杀掉。
    /// 也找改名前的目录（ProxySwitch）里的：更新前的旧版本留下的。
    static func killStrays() {
        for pattern in ["Proxi/engine/core/config.yaml", "Proxi/core/config.yaml", "ProxySwitch/core/config.yaml"] {
            _ = try? Shell.runSync("/usr/bin/pkill", ["-f", pattern], timeout: 5)
        }
    }

    private func openLog(in directory: URL) {
        let url = directory.appendingPathComponent("core.log")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        logHandle = try? FileHandle(forWritingTo: url)
        try? logHandle?.truncate(atOffset: 0)
    }

    private func append(_ data: Data) {
        queue.async {
            self.logHandle?.write(data)
            self.pending += String(decoding: data, as: UTF8.self)
            var parts = self.pending.components(separatedBy: "\n")
            self.pending = parts.removeLast()
            self.lines.append(contentsOf: parts.filter { !$0.isEmpty })
            if self.lines.count > 400 {
                self.lines.removeFirst(self.lines.count - 400)
            }
        }
    }
}
