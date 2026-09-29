import Foundation

/// 服务可用性检测里的服务：经某个节点能不能打开、有没有地区限制。
enum ServiceKind: String, CaseIterable, Identifiable, Codable {
    case google
    case youtube
    case netflix
    case chatgpt
    case claude
    case gemini
    case github
    case telegram

    var id: String { rawValue }

    var title: String {
        switch self {
        case .google: return "Google"
        case .youtube: return "YouTube Premium"
        case .netflix: return "Netflix"
        case .chatgpt: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .github: return "GitHub"
        case .telegram: return "Telegram"
        }
    }

    /// 检测时依次请求的地址。
    var urls: [String] {
        switch self {
        case .google: return ["https://www.google.com/generate_204"]
        case .youtube: return ["https://www.youtube.com/premium"]
        // 一部授权剧（能看说明完整解锁）和一部自制剧（能看说明至少有自制剧）。
        case .netflix: return ["https://www.netflix.com/title/70143836", "https://www.netflix.com/title/80018499"]
        case .chatgpt: return ["https://api.openai.com/compliance/cookie_requirements", "https://ios.chat.openai.com/", "https://chatgpt.com/cdn-cgi/trace"]
        case .claude: return ["https://claude.ai/", "https://claude.ai/cdn-cgi/trace"]
        case .gemini: return ["https://gemini.google.com/"]
        case .github: return ["https://github.com/"]
        case .telegram: return ["https://web.telegram.org/"]
        }
    }
}

/// 一次 HTTP 请求的结果（检测用）。
struct ServiceResponse: Equatable {
    var status: Int
    /// 跟随跳转后的最终地址。
    var url: String
    var body: String
    /// 毫秒。
    var latency: Int
}

/// 一个服务的检测结果。
struct ServiceCheckResult: Identifiable, Equatable {
    enum Status: Equatable {
        /// 可用。
        case available
        /// 部分可用，比如 Netflix 只能看自制剧。
        case limited(String)
        /// 打得开但不给用：地区不支持、被识别为代理。
        case blocked(String)
        /// 连不上、超时。
        case failed(String)
    }

    var service: ServiceKind
    var status: Status
    /// 服务看到的国家 / 地区代码（知道的话）。
    var region: String?
    var latency: Int?
    var checkedAt: Date = Date()

    var id: String { service.rawValue }

    var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    /// 一句话：可用 · JP · 230 ms。
    var summary: String {
        var parts: [String] = []
        switch status {
        case .available: parts.append("可用")
        case .limited(let text): parts.append(text)
        case .blocked(let text): parts.append(text)
        case .failed(let text): parts.append(text)
        }
        if let region, !region.isEmpty { parts.append(region) }
        if case .failed = status {
            // 连不上时的耗时没有意义。
        } else if let latency {
            parts.append("\(latency) ms")
        }
        return parts.joined(separator: " · ")
    }
}

/// 按请求结果判断服务是否可用。检测方式是公开的经验做法，服务那边一改就可能不准，结果仅供参考。
enum ServiceClassifier {
    /// responses 和 ServiceKind.urls 一一对应；请求失败的是 nil。
    static func classify(_ service: ServiceKind, responses: [ServiceResponse?]) -> ServiceCheckResult {
        func result(_ status: ServiceCheckResult.Status, region: String? = nil, latency: Int? = nil) -> ServiceCheckResult {
            ServiceCheckResult(service: service, status: status, region: region, latency: latency ?? responses.first??.latency)
        }
        guard let first = responses.first ?? nil else {
            return result(.failed("连不上"), latency: nil)
        }
        switch service {
        case .google, .github, .telegram:
            return (200..<400).contains(first.status) ? result(.available) : result(.failed("返回 \(first.status)"))
        case .youtube:
            let body = first.body
            if body.contains("Premium is not available in your country") || body.contains("YouTube Premium 在您所在的国家/地区尚未推出") {
                return result(.blocked("所在地区没有 Premium"), region: youtubeRegion(body))
            }
            guard first.status == 200 else { return result(.failed("返回 \(first.status)")) }
            return result(.available, region: youtubeRegion(body))
        case .netflix:
            let licensed = first
            let original = responses.count > 1 ? responses[1] : nil
            let region = netflixRegion(licensed) ?? original.flatMap(netflixRegion)
            if licensed.status == 200 { return result(.available, region: region) }
            if original?.status == 200 { return result(.limited("仅自制剧"), region: region) }
            if licensed.status == 403 || original?.status == 403 { return result(.blocked("不提供服务")) }
            return result(.failed("返回 \(licensed.status)"))
        case .chatgpt:
            let region = responses.count > 2 ? responses[2].flatMap { traceLocation($0.body) } : nil
            if first.body.contains("unsupported_country") { return result(.blocked("地区不支持"), region: region) }
            if responses.count > 1, let ios = responses[1], ios.body.contains("VPN") { return result(.blocked("识别为代理"), region: region) }
            return result(.available, region: region)
        case .claude:
            let region = responses.count > 1 ? responses[1].flatMap { traceLocation($0.body) } : nil
            if first.url.contains("app-unavailable-in-region") || first.url.contains("unavailable") { return result(.blocked("地区不支持"), region: region) }
            if first.status == 403 { return result(.blocked("拒绝访问"), region: region) }
            return (200..<400).contains(first.status) ? result(.available, region: region) : result(.failed("返回 \(first.status)"), region: region)
        case .gemini:
            if !first.url.contains("gemini.google.com") || first.url.contains("/faq") { return result(.blocked("地区不支持")) }
            return first.status == 200 ? result(.available) : result(.failed("返回 \(first.status)"))
        }
    }

    /// Cloudflare 的 /cdn-cgi/trace 里的 loc=XX。
    static func traceLocation(_ body: String) -> String? {
        for line in body.split(whereSeparator: \.isNewline) where line.hasPrefix("loc=") {
            let code = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return code.isEmpty ? nil : code
        }
        return nil
    }

    static func youtubeRegion(_ body: String) -> String? {
        firstMatch(in: body, pattern: "\"INNERTUBE_CONTEXT_GL\":\"([A-Z]{2})\"") ?? firstMatch(in: body, pattern: "\"countryCode\":\"([A-Z]{2})\"")
    }

    static func netflixRegion(_ response: ServiceResponse) -> String? {
        if let code = firstMatch(in: response.body, pattern: "\"requestCountry\":\\{\"id\":\"([A-Z]{2})\"") { return code }
        // 跳转后的地址里带地区：netflix.com/jp/title/…、netflix.com/jp-en/title/…
        if let code = firstMatch(in: response.url, pattern: "netflix\\.com/([a-z]{2})(?:-[a-z]{2})?/title") { return code.uppercased() }
        return nil
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
