import CryptoKit
import Foundation

/// 规则集的文件都放在内核目录的 rules/ 里：规则集按 provider 名存，小火箭配置里引用的规则集按地址的哈希存。
/// 下载按线路依次试（内置代理、系统代理、直连），GitHub 的原始地址连不上时换 jsDelivr 镜像。
enum RuleStore {
    static let maxBytes = 30 * 1024 * 1024
    static let timeout: TimeInterval = 25

    static func directory(in coreDirectory: URL) -> URL {
        coreDirectory.appendingPathComponent("rules", isDirectory: true)
    }

    /// 规则集在内核目录里的文件。
    static func fileURL(for set: RuleSet, in coreDirectory: URL) -> URL {
        directory(in: coreDirectory).appendingPathComponent("\(set.providerName).\(set.storedExtension)")
    }

    /// 小火箭配置里 RULE-SET 引用的列表：按地址存。
    static func referenceURL(for url: String, in coreDirectory: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return directory(in: coreDirectory).appendingPathComponent("ref-\(digest).txt")
    }

    /// 文件多久没更新了（秒）；没有文件是 nil。
    static func age(of file: URL) -> TimeInterval? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let date = attributes[.modificationDate] as? Date else { return nil }
        return Date().timeIntervalSince(date)
    }

    static func modificationDate(of file: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
    }

    /// raw.githubusercontent.com 的地址换成 jsDelivr 的镜像（国内也能直接访问）；不是 GitHub 原始地址时返回 nil。
    static func mirrorURL(for text: String) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host?.lowercased() == "raw.githubusercontent.com" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 4 else { return nil }
        let path = parts[3...].joined(separator: "/")
        return "https://cdn.jsdelivr.net/gh/\(parts[0])/\(parts[1])@\(parts[2])/\(path)"
    }

    /// 下载一个规则文件：按线路依次试，每条线路先原地址、再镜像。
    static func download(_ text: String, routes: [NetworkRoute]) async throws -> Data {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)), url.host != nil else { throw RuleStoreError.badURL(text) }
        var candidates = [url]
        if let mirror = mirrorURL(for: text).flatMap({ URL(string: $0) }) {
            candidates.append(mirror)
        }
        var lastError: Error = RuleStoreError.badURL(text)
        for route in routes.isEmpty ? [NetworkRoute.direct] : routes {
            for candidate in candidates {
                do {
                    return try await fetch(candidate, route: route)
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    private static func fetch(_ url: URL, route: NetworkRoute) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 3
        route.apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // 以 clash.meta 的身份下载：机场按这个返回 Clash 格式的配置（远程配置当规则集、从网址导入时要用），GitHub 这类静态文件不受影响。
        request.setValue(CoreConfigBuilder.providerUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RuleStoreError.status(http.statusCode)
        }
        guard data.count <= maxBytes else { throw RuleStoreError.tooLarge }
        guard !data.isEmpty else { throw RuleStoreError.empty }
        return data
    }

    static func save(_ data: Data, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    static func loadText(_ file: URL) -> String? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func exists(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }
}

enum RuleStoreError: LocalizedError {
    case badURL(String)
    case status(Int)
    case tooLarge
    case empty

    var errorDescription: String? {
        switch self {
        case .badURL(let text): return "规则地址不对：\(text)"
        case .status(let code): return "服务器返回 \(code)"
        case .tooLarge: return "规则文件太大"
        case .empty: return "规则文件是空的"
        }
    }
}
