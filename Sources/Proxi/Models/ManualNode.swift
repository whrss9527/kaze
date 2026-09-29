import Foundation

/// 手动添加的节点：一条分享链接（ss://、vmess://、trojan://、vless://、hysteria2://……），交给内核解析。
/// 所有手动节点写进同一个文件，在内核里是一个叫 manual 的节点来源，和订阅一样能被策略组筛选。
struct ManualNode: Codable, Identifiable, Equatable, Hashable {
    /// 内核里的节点来源名。
    static let providerName = "manual"
    /// 策略组「只用哪些来源」里代表手动节点的固定 id。
    static let sourceID = UUID(uuidString: "0B1E6C7A-0000-4000-8000-00000000A11D")!

    var id: UUID = UUID()
    var link: String = ""
    var enabled: Bool = true

    init(link: String) {
        self.link = link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case id, link, enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        link = try container.decodeIfPresent(String.self, forKey: .link) ?? ""
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// 显示用的名字：链接里带的名字，没有就用「协议 服务器」。
    var name: String {
        if let name = NodeLink.name(of: link), !name.isEmpty { return name }
        let scheme = NodeLink.scheme(of: link)?.uppercased() ?? "节点"
        return [scheme, NodeLink.server(of: link) ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 协议，小写。
    var scheme: String { NodeLink.scheme(of: link) ?? "" }

    /// 服务器地址，host:port。
    var server: String { NodeLink.server(of: link) ?? "" }
}

/// 节点分享链接的识别和解析（只为显示和校验，真正的解析由内核做）。
enum NodeLink {
    /// 内核认识的链接协议。
    static let schemes: Set<String> = ["ss", "ssr", "vmess", "vless", "trojan", "hysteria", "hysteria2", "hy2", "tuic", "socks", "socks5", "socks5h", "http", "https", "anytls", "mierus"]

    /// 从一段文字里挑出节点链接：一行一个；整段是 base64（订阅常见的格式）时先解码。
    static func extract(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var lines = links(in: trimmed)
        if lines.isEmpty, !trimmed.contains("://"), let decoded = decodeBase64(trimmed) {
            lines = links(in: decoded)
        }
        return lines
    }

    private static func links(in text: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for raw in text.split(whereSeparator: { $0.isNewline || $0 == " " || $0 == "\t" }) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard isLink(line), seen.insert(line).inserted else { continue }
            result.append(line)
        }
        return result
    }

    /// 是不是节点链接。http(s) 只有带账号或端口、没有路径时才算（否则多半是订阅地址或网页）。
    static func isLink(_ text: String) -> Bool {
        guard let scheme = scheme(of: text), schemes.contains(scheme) else { return false }
        if scheme == "http" || scheme == "https" {
            guard let components = URLComponents(string: text), components.host != nil else { return false }
            let path = components.path
            let bare = (path.isEmpty || path == "/") && components.query == nil
            return bare && (components.user != nil || components.port != nil)
        }
        return text.count > scheme.count + 3
    }

    static func scheme(of text: String) -> String? {
        guard let range = text.range(of: "://") else { return nil }
        let scheme = text[..<range.lowerBound].lowercased()
        guard !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" }) else { return nil }
        return scheme
    }

    /// 链接里带的名字：大多数是 # 后面的部分；vmess 在 base64 的 JSON 里（ps），ssr 在 remarks 参数里。
    static func name(of link: String) -> String? {
        guard let scheme = scheme(of: link) else { return nil }
        let body = String(link.dropFirst(scheme.count + 3))
        switch scheme {
        case "vmess":
            if let json = vmessJSON(body) {
                return (json["ps"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            }
            return fragment(of: body)
        case "ssr":
            guard let decoded = decodeBase64(body), let query = decoded.range(of: "/?") else { return nil }
            let params = decoded[query.upperBound...].split(separator: "&")
            for param in params where param.hasPrefix("remarks=") {
                return decodeBase64(String(param.dropFirst("remarks=".count)))
            }
            return nil
        default:
            return fragment(of: body)
        }
    }

    /// 服务器地址 host:port。
    static func server(of link: String) -> String? {
        guard let scheme = scheme(of: link) else { return nil }
        let body = String(link.dropFirst(scheme.count + 3))
        switch scheme {
        case "vmess":
            if let json = vmessJSON(body), let address = json["add"] as? String {
                let port = (json["port"] as? String) ?? (json["port"] as? Int).map(String.init) ?? ""
                return port.isEmpty ? address : "\(address):\(port)"
            }
            return nil
        case "ss":
            var main = body
            if let hash = main.firstIndex(of: "#") { main = String(main[..<hash]) }
            if let query = main.firstIndex(of: "?") { main = String(main[..<query]) }
            if let at = main.lastIndex(of: "@") {
                return String(main[main.index(after: at)...]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
            // 旧格式：整个 method:password@host:port 是 base64。
            if let decoded = decodeBase64(main), let at = decoded.lastIndex(of: "@") {
                return String(decoded[decoded.index(after: at)...])
            }
            return nil
        case "ssr":
            guard let decoded = decodeBase64(body) else { return nil }
            let parts = decoded.split(separator: ":")
            return parts.count >= 2 ? "\(parts[0]):\(parts[1])" : nil
        default:
            guard let components = URLComponents(string: link), let host = components.host else { return nil }
            return components.port.map { "\(host):\($0)" } ?? host
        }
    }

    private static func fragment(of body: String) -> String? {
        guard let hash = body.lastIndex(of: "#") else { return nil }
        let raw = String(body[body.index(after: hash)...])
        let text = raw.removingPercentEncoding ?? raw
        return text.isEmpty ? nil : text
    }

    private static func vmessJSON(_ body: String) -> [String: Any]? {
        var main = body
        if let hash = main.firstIndex(of: "#") { main = String(main[..<hash]) }
        guard let decoded = decodeBase64(main), let data = decoded.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// 标准或 URL 安全的 base64，可以不带补齐的 =；解出来不是文字时返回 nil。
    static func decodeBase64(_ text: String) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+/=".contains($0)) }) else { return nil }
        while value.count % 4 != 0 {
            value += "="
        }
        guard let data = Data(base64Encoded: value), let decoded = String(data: data, encoding: .utf8) else { return nil }
        return decoded
    }
}
