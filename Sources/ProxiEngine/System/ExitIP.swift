import Foundation

/// 出口 IP 和它的归属：从哪个国家、城市、运营商出去的。
struct ExitInfo: Equatable {
    var ip: String
    var countryCode: String
    var country: String
    var city: String
    var organization: String
    var checkedAt: Date = Date()

    /// 国旗：国家代码的两个字母换成区域指示符号。
    var flag: String {
        let code = countryCode.uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isLetter && $0.isASCII }) else { return "" }
        var flag = ""
        for scalar in code.unicodeScalars {
            guard let indicator = UnicodeScalar(0x1F1E6 + scalar.value - 65) else { return "" }
            flag.unicodeScalars.append(indicator)
        }
        return flag
    }

    /// 地点：城市加国家，去重。
    var place: String {
        var parts: [String] = []
        if !country.isEmpty { parts.append(country) }
        if !city.isEmpty, city.caseInsensitiveCompare(country) != .orderedSame { parts.append(city) }
        return parts.joined(separator: " ")
    }

    /// 一行摘要：🇯🇵 Japan Tokyo · 1.2.3.4 · ISP。
    var summary: String {
        var parts: [String] = []
        let where_ = [flag, place].filter { !$0.isEmpty }.joined(separator: " ")
        if !where_.isEmpty { parts.append(where_) }
        parts.append(ip)
        if !organization.isEmpty { parts.append(organization) }
        return parts.joined(separator: " · ")
    }

    /// 短的一句：🇯🇵 Tokyo。
    var short: String {
        let location = city.isEmpty ? country : city
        return [flag, location.isEmpty ? ip : location].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// 兼容几个常见接口的字段名：api.ip.sb（ip / country_code / country / city / isp / organization）、
    /// ipinfo.io（ip / country / city / org）、ipapi.co（ip / country_code / country_name / city / org）、ip-api.com（query / countryCode / country / city / isp）。
    static func parse(_ data: Data) -> ExitInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ keys: String...) -> String {
            for key in keys {
                if let value = json[key] as? String, !value.isEmpty { return value }
            }
            return ""
        }
        let ip = text("ip", "query")
        guard !ip.isEmpty else { return nil }
        var code = text("country_code", "countryCode")
        var country = text("country_name", "country")
        // ipinfo.io 的 country 字段就是两位代码。
        if code.isEmpty, country.count == 2, country.allSatisfy(\.isLetter) {
            code = country
            country = ""
        }
        if country.count == 2, country.uppercased() == code.uppercased() {
            country = ""
        }
        return ExitInfo(ip: ip, countryCode: code, country: country, city: text("city"), organization: text("isp", "organization", "org", "asn_organization"))
    }
}

/// 查出口 IP：经内核的代理端口（看节点的出口），或者直连（看本机的公网地址）。几个公开接口依次试。
enum ExitIPChecker {
    static let endpoints = [
        "https://api.ip.sb/geoip",
        "https://ipinfo.io/json",
        "https://ipapi.co/json/",
    ]
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    /// proxyPort 是内核的代理端口；nil 表示直连。
    static func check(proxyPort: Int?, timeout: TimeInterval = 10) async -> Result<ExitInfo, Error> {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let proxyPort {
            NetworkRoute.core(proxyPort).apply(to: configuration)
        } else {
            NetworkRoute.direct.apply(to: configuration)
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var lastError: Error = ExitIPError.unavailable
        for endpoint in endpoints {
            guard let url = URL(string: endpoint) else { continue }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    lastError = ExitIPError.status(http.statusCode)
                    continue
                }
                if let info = ExitInfo.parse(data) {
                    return .success(info)
                }
                lastError = ExitIPError.unreadable
            } catch {
                lastError = error
            }
        }
        return .failure(lastError)
    }
}

enum ExitIPError: LocalizedError {
    case unavailable
    case status(Int)
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("查不到出口 IP")
        case .status(let code): return L("查询出口 IP 的接口返回 %@", code)
        case .unreadable: return L("读不懂查询出口 IP 的结果")
        }
    }
}
