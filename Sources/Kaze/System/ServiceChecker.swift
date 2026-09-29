import Foundation

/// 经代理端口请求各个服务，交给 ServiceClassifier 判断能不能用。
enum ServiceChecker {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    static func run(_ services: [ServiceKind] = ServiceKind.allCases, proxyPort: Int, timeout: TimeInterval = 10) async -> [ServiceCheckResult] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        NetworkRoute.core(proxyPort).apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let results = await withTaskGroup(of: ServiceCheckResult.self) { group -> [ServiceCheckResult] in
            for service in services {
                group.addTask {
                    var responses: [ServiceResponse?] = []
                    for url in service.urls {
                        let response = await fetch(url, session: session)
                        responses.append(response)
                        // 第一个请求就连不上，后面的不用试了。
                        if responses.count == 1 && response == nil { break }
                    }
                    return ServiceClassifier.classify(service, responses: responses)
                }
            }
            var collected: [ServiceCheckResult] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
        return services.compactMap { service in results.first { $0.service == service } }
    }

    static func fetch(_ address: String, session: URLSession) async -> ServiceResponse? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if url.host == "api.openai.com" {
            request.setValue("Bearer null", forHTTPHeaderField: "Authorization")
        }
        let start = Date()
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(decoding: data.prefix(512 * 1024), as: UTF8.self)
            return ServiceResponse(status: status, url: response.url?.absoluteString ?? address, body: body, latency: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return nil
        }
    }
}
