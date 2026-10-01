import Foundation

/// 网址检测：经某个节点访问一个用户自己填的网址，看能不能打开、返回了什么、花了多久。
/// 不内置任何网站，填什么测什么。
struct ServiceResponse: Equatable {
    var status: Int
    /// 跟随跳转后的最终地址。
    var url: String
    /// 毫秒。
    var latency: Int
}

/// 一个网址的检测结果。
struct ServiceCheckResult: Identifiable, Equatable {
    enum Status: Equatable {
        /// 打开了（HTTP 状态 200~399）。
        case available
        /// 打开了，但服务器返回了错误状态（4xx、5xx）。
        case blocked(String)
        /// 连不上、超时。
        case failed(String)
    }

    /// 检测的网址。
    var url: String
    var status: Status
    var latency: Int?
    var checkedAt: Date = Date()

    var id: String { url }

    /// 列表里显示的名字：网址的主机名。
    var title: String { URL(string: url)?.host ?? url }

    var isAvailable: Bool {
        if case .available = status { return true }
        return false
    }

    /// 一句话：能打开 · 230 ms。
    var summary: String {
        var parts: [String] = []
        switch status {
        case .available: parts.append(L("能打开"))
        case .blocked(let text): parts.append(text)
        case .failed(let text): parts.append(text)
        }
        if case .failed = status {
            // 连不上时的耗时没有意义。
        } else if let latency {
            parts.append("\(latency) ms")
        }
        return parts.joined(separator: " · ")
    }
}

/// 按请求结果判断。
enum ServiceClassifier {
    static func classify(url: String, response: ServiceResponse?) -> ServiceCheckResult {
        guard let response else {
            return ServiceCheckResult(url: url, status: .failed(L("连不上")))
        }
        if (200..<400).contains(response.status) {
            return ServiceCheckResult(url: url, status: .available, latency: response.latency)
        }
        return ServiceCheckResult(url: url, status: .blocked(L("HTTP %@", String(response.status))), latency: response.latency)
    }

    /// 把用户填的「example.com」「https://example.com/path」整理成完整网址；认不出来返回 nil。
    static func normalize(_ text: String) -> String? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://" + trimmed
        }
        guard let url = URL(string: trimmed), let host = url.host, !host.isEmpty else { return nil }
        return trimmed
    }
}
