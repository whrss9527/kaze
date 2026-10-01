import Foundation

/// 经代理端口请求用户指定的网址，交给 ServiceClassifier 判断能不能打开。
enum ServiceChecker {
    static func run(_ urls: [String], proxyPort: Int, timeout: TimeInterval = 10) async -> [ServiceCheckResult] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 5
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        NetworkRoute.core(proxyPort).apply(to: configuration)
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var results: [ServiceCheckResult] = []
        for url in urls {
            let response = await fetch(url, session: session)
            results.append(ServiceClassifier.classify(url: url, response: response))
        }
        return results
    }

    static func fetch(_ address: String, session: URLSession) async -> ServiceResponse? {
        guard let url = URL(string: address) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Proxi-Engine/\(UpdateChecker.currentVersion)", forHTTPHeaderField: "User-Agent")
        let start = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return ServiceResponse(status: status, url: response.url?.absoluteString ?? address, latency: Int(Date().timeIntervalSince(start) * 1000))
        } catch {
            return nil
        }
    }
}
