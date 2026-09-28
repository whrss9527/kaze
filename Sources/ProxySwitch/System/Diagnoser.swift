import AppKit
import Foundation

/// 要诊断的目标：网址，以及从谁的视角看（这台 Mac，还是经共享入口上网的局域网设备）。
struct DiagnoseTarget: Equatable {
    enum Perspective: String, CaseIterable, Identifiable {
        case mac
        case device

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mac: return "这台 Mac"
            case .device: return "局域网设备（PS5 等）"
            }
        }
    }

    var url: URL
    var perspective: Perspective

    var host: String { url.host ?? "" }
    var port: Int { url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443) }

    /// 「youtube.com」补成 https://youtube.com，带 scheme 的原样；认不出来返回 nil。
    static func normalize(_ text: String) -> URL? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(" ") else { return nil }
        if !value.contains("://") {
            value = "https://" + value
        }
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

/// 一次访问的结果：通了就有 HTTP 状态和耗时，没通就有失败的种类。
struct ProbeResult: Equatable {
    enum Failure: Equatable {
        case timeout
        case refused
        case reset
        case dns
        case tls
        case offline
        case other(String)

        init(_ error: Error) {
            let nsError = error as NSError
            switch nsError.code {
            case NSURLErrorTimedOut: self = .timeout
            case NSURLErrorCannotConnectToHost: self = .refused
            case NSURLErrorNetworkConnectionLost: self = .reset
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: self = .dns
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected:
                self = .tls
            case NSURLErrorNotConnectedToInternet: self = .offline
            default: self = .other(nsError.localizedDescription)
            }
        }

        var text: String {
            switch self {
            case .timeout: return "超时，没有响应"
            case .refused: return "连接被拒绝"
            case .reset: return "连接被中断（常见于被屏蔽）"
            case .dns: return "域名解析失败"
            case .tls: return "TLS 握手失败（可能被劫持或屏蔽）"
            case .offline: return "没有网络连接"
            case .other(let text): return text
            }
        }
    }

    var ok: Bool
    var status: Int?
    var latencyMs: Int?
    var failure: Failure?

    var summary: String {
        if ok {
            return "HTTP \(status ?? 0)" + (latencyMs.map { "，\($0) ms" } ?? "")
        }
        return failure?.text ?? "失败"
    }

    /// 访问一次。proxy 为 nil 跟随系统代理，空字典是直连，否则用给的代理设置。
    static func probe(url: URL, proxy: [AnyHashable: Any]?, timeout: TimeInterval = 8) async -> ProbeResult {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.connectionProxyDictionary = proxy
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let started = Date()
        do {
            let (_, response) = try await session.data(for: request)
            let millis = Int(Date().timeIntervalSince(started) * 1000)
            return ProbeResult(ok: true, status: (response as? HTTPURLResponse)?.statusCode ?? 0, latencyMs: millis, failure: nil)
        } catch {
            return ProbeResult(ok: false, status: nil, latencyMs: nil, failure: Failure(error))
        }
    }

    /// 经本机某个端口上的 HTTP 代理。
    static func proxyDictionary(port: Int) -> [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: port,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: port,
        ]
    }
}

/// 内核对一次连接的判定，从它的日志行里解析出来：
/// `[TCP] 来源 --> host:port match DomainSuffix(youtube.com) using 节点[香港 01]`
/// `[TCP] 来源 --> host:port using DIRECT`、`... doesn't match any rule using DIRECT`
/// `[TCP] dial 节点 (match Match/) 来源 --> host:port error: ...`
struct RouteTrace: Equatable {
    var host: String
    var port: Int
    /// 命中的规则，比如 DomainSuffix(youtube.com)、Match；模式直接决定时是空。
    var rule: String
    /// 内核给的链：节点[香港 01]、DIRECT、上游代理、GLOBAL。
    var chain: String
    var error: String?

    /// 实际出口：节点名（去掉组名）、DIRECT 或上游代理。
    var outbound: String {
        if let open = chain.firstIndex(of: "["), chain.hasSuffix("]") {
            return String(chain[chain.index(after: open)..<chain.index(before: chain.endIndex)])
        }
        return chain
    }

    var isDirect: Bool { outbound == "DIRECT" }

    static func parse(_ line: String) -> RouteTrace? {
        guard line.hasPrefix("[TCP] ") else { return nil }
        let body = Substring(line.dropFirst(6))
        guard let arrow = body.range(of: " --> ") else { return nil }
        if body.hasPrefix("dial ") {
            guard let errorRange = body.range(of: " error: ", range: arrow.upperBound..<body.endIndex) else { return nil }
            let head = body[body.index(body.startIndex, offsetBy: 5)..<arrow.lowerBound]
            // head 是「出口 (match 类型/内容) 来源」或「出口 来源」，来源里没有空格。
            guard let sourceSeparator = head.lastIndex(of: " ") else { return nil }
            var proxy = head[..<sourceSeparator]
            var rule = ""
            if let match = proxy.range(of: " (match "), let close = proxy.range(of: ")", range: match.upperBound..<proxy.endIndex) {
                rule = String(proxy[match.upperBound..<close.lowerBound])
                proxy = proxy[..<match.lowerBound]
            }
            guard let (host, port) = splitTarget(body[arrow.upperBound..<errorRange.lowerBound]) else { return nil }
            return RouteTrace(host: host, port: port, rule: rule, chain: String(proxy), error: String(body[errorRange.upperBound...]))
        }
        guard let using = body.range(of: " using ", range: arrow.upperBound..<body.endIndex) else { return nil }
        let middle = body[arrow.upperBound..<using.lowerBound]
        var target = middle
        var rule = ""
        // 「doesn't match any rule」里也含有「 match 」，先认它。
        if let none = middle.range(of: " doesn't match any rule") {
            target = middle[..<none.lowerBound]
            rule = "没有命中任何规则"
        } else if let match = middle.range(of: " match ") {
            target = middle[..<match.lowerBound]
            rule = String(middle[match.upperBound...])
        }
        guard let (host, port) = splitTarget(target) else { return nil }
        return RouteTrace(host: host, port: port, rule: rule, chain: String(body[using.upperBound...]).trimmingCharacters(in: .whitespaces), error: nil)
    }

    private static func splitTarget(_ text: Substring) -> (String, Int)? {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return (host, port)
    }
}

/// 域名解析：本机的系统解析（含 VPN 的分域 DNS），以及经内核到境外的 DoH 解析作对照。
enum DNSProbe {
    static func system(_ host: String) async -> [String] {
        await Task.detached(priority: .utility) { DNSProbe.resolve(host) }.value
    }

    static func resolve(_ host: String) -> [String] {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let start = result else { return [] }
        defer { freeaddrinfo(start) }
        var addresses: [String] = []
        var pointer: UnsafeMutablePointer<addrinfo>? = start
        while let current = pointer {
            pointer = current.pointee.ai_next
            guard let address = current.pointee.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
                if !addresses.contains(text) {
                    addresses.append(text)
                }
            }
        }
        return addresses
    }

    /// 经内核的代理端口用 Cloudflare 的 DoH 解析（内核会按规则把它送到节点，得到的是境外看到的结果）。失败返回 nil。
    static func remote(_ host: String, viaPort: Int) async -> [String]? {
        guard var components = URLComponents(string: "https://cloudflare-dns.com/dns-query") else { return nil }
        components.queryItems = [URLQueryItem(name: "name", value: host), URLQueryItem(name: "type", value: "A")]
        guard let url = components.url else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = ProbeResult.proxyDictionary(port: viaPort)
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
        guard let response = try? await session.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: response.0) as? [String: Any] else { return nil }
        let answers = (json["Answer"] as? [[String: Any]]) ?? []
        return answers.compactMap { answer in
            (answer["type"] as? Int) == 1 ? answer["data"] as? String : nil
        }
    }
}

/// 一项检查在页面上的一行。
struct CheckRow: Identifiable, Equatable {
    enum Outcome: Equatable {
        case pending
        case running
        case pass
        case warn
        case fail
        case skipped
    }

    var id: String
    var title: String
    var outcome: Outcome = .pending
    var summary: String = ""
    var detail: String = ""
}

/// 检查收集到的事实，结论引擎只看它（纯数据，便于测试）。
struct DiagnoseFacts: Equatable {
    /// 本机自己在用什么。
    enum MacRoute: Equatable {
        case off
        case engine
        /// 别的配置（公司代理等），带名字和地址。
        case profile(String)
        /// 别的程序设置的系统代理。
        case external(String)
    }

    var perspective: DiagnoseTarget.Perspective
    var host: String
    var macRoute: MacRoute = .off
    var engineHasNodes = false
    var shareListening = false
    var shareUpstream: ShareUpstream?
    var systemAddresses: [String] = []
    var remoteAddresses: [String]?
    var direct: ProbeResult?
    var proxied: ProbeResult?
    var trace: RouteTrace?
    /// 经代理访问时实际用的代理的说法（内核、公司代理……）。
    var proxiedVia = ""
    var nodeName: String?
    /// nil 没测；0 连不上。
    var nodeDelay: Int?
    var deviceRecentConnections: Int?
}

/// 结论：一句话、一段解释、可以直接点的动作。
struct Verdict: Equatable {
    enum Action: Equatable {
        case turnOnEngine
        case pinToProxy(String)
        case autoSelect
        case testNodes
        case openNodes
        case openShare
        case copyReport

        var title: String {
            switch self {
            case .turnOnEngine: return "开启节点代理"
            case .pinToProxy(let host): return "让 \(host) 走节点"
            case .autoSelect: return "自动选择节点"
            case .testNodes: return "测速全部节点"
            case .openNodes: return "去节点页"
            case .openShare: return "去共享页"
            case .copyReport: return "复制诊断报告"
            }
        }
    }

    var headline: String
    var explanation: String
    var actions: [Action]

    static func make(_ f: DiagnoseFacts) -> Verdict {
        let host = f.host
        if f.perspective == .device && !f.shareListening {
            return Verdict(headline: "共享入口没在监听", explanation: "设备是经这台 Mac 的共享入口上网的，入口没起来设备就连不上。到「局域网共享」页看状态和报错（常见是没开、端口被占用，或者内核没启动）。", actions: [.openShare])
        }
        guard let proxied = f.proxied else {
            // 没有经代理访问：本机没开代理。
            if let direct = f.direct, direct.ok {
                return Verdict(headline: "直连正常，本机没开代理", explanation: "这个网站直连就能打开（\(direct.summary)）。如果浏览器里仍然打不开，多半是网站本身或浏览器的问题，和代理无关。", actions: [.copyReport])
            }
            let reason = f.direct?.summary ?? "没有测"
            if f.engineHasNodes {
                return Verdict(headline: "本机没开代理，直连又打不开", explanation: "直连：\(reason)。这个网站直连访问不了，开启节点代理后再试。", actions: [.turnOnEngine, .copyReport])
            }
            return Verdict(headline: "本机没开代理，直连又打不开", explanation: "直连：\(reason)。还没有可用的节点，先在「节点与订阅」页添加订阅，或者在「代理配置」里选一个代理。", actions: [.openNodes, .copyReport])
        }
        if proxied.ok {
            var explanation = "经 \(f.proxiedVia) 访问成功：\(proxied.summary)。"
            if let trace = f.trace {
                explanation += trace.rule.isEmpty ? "内核让它走了 \(trace.chain)。" : "命中规则 \(trace.rule)，走 \(trace.chain)。"
            }
            if f.perspective == .device, f.deviceRecentConnections == 0 {
                return Verdict(headline: "从这台 Mac 看链路是通的，但设备最近没有对它的连接", explanation: explanation + "设备上打开那个应用时「最近的连接」里没有出现这个域名，说明应用没走 PS5 的代理设置——PS5 的代理只对系统流量和浏览器生效，不少应用只用自己的网络栈。用设备的浏览器打开同一个网站可以对照；要让所有应用都走 Mac，需要网关模式。", actions: [.openShare, .copyReport])
            }
            return Verdict(headline: "链路正常", explanation: explanation + "如果设备上仍然打不开，多半是那个应用自己的问题。", actions: [.copyReport])
        }
        // 经代理访问失败。
        if let trace = f.trace {
            if trace.isDirect {
                let directText = f.direct.map { $0.ok ? "但直接访问是通的（\($0.summary)），可能是内核解析到了不同的地址" : "直接访问也不通（\($0.summary)）" } ?? ""
                var explanation = "命中规则 \(trace.rule.isEmpty ? "（模式）" : trace.rule)，内核把它分到了直连，\(directText)。"
                if let error = trace.error {
                    explanation += "内核报错：\(error)。"
                }
                explanation += "常见原因是这个网站在国内访问不了，或者 DNS 被污染给了国内地址；让它固定走节点就好。"
                return Verdict(headline: "规则把它分到了直连，但直连不通", explanation: explanation, actions: f.engineHasNodes ? [.pinToProxy(host), .copyReport] : [.turnOnEngine, .copyReport])
            }
            if trace.outbound == CoreConfigBuilder.upstreamProxy {
                return Verdict(headline: "转发给上游代理失败", explanation: "本机用的是别的代理，共享的流量转发给它时失败：\(trace.error ?? proxied.summary)。检查那个代理现在能不能用（面板里可以测速）。", actions: [.copyReport])
            }
            if f.nodeDelay == 0 {
                return Verdict(headline: "当前节点连不上", explanation: "它走的是节点 \(trace.outbound)，但这个节点现在测不通：\(trace.error ?? proxied.summary)。换一个节点或者让程序自动选延迟最低的。", actions: [.autoSelect, .testNodes, .copyReport])
            }
            return Verdict(headline: "节点能通，但这个网站经它打不开", explanation: "走的是节点 \(trace.outbound)（延迟 \(f.nodeDelay.map { "\($0) ms" } ?? "未测")），访问结果：\(trace.error ?? proxied.summary)。可能是这个节点被目标网站屏蔽了，或者网站本身有问题；换个节点试试。", actions: [.openNodes, .copyReport])
        }
        if f.macRoute == .engine || f.perspective == .device {
            return Verdict(headline: "经代理访问失败", explanation: "结果：\(proxied.summary)。内核没有记录到这次连接的判定，可能是内核这时候重启了；再测一次。", actions: [.copyReport])
        }
        return Verdict(headline: "经 \(f.proxiedVia) 访问失败", explanation: "结果：\(proxied.summary)。检查那个代理现在能不能用（面板里可以测速），或者换成节点代理。", actions: f.engineHasNodes ? [.turnOnEngine, .copyReport] : [.copyReport])
    }
}

/// 把链路走一遍：本机 / 共享的状态、DNS、直连、经代理（同时从内核日志抓判定）、节点、设备的连接记录，最后给结论。只在主线程上用。
@MainActor
final class Diagnoser: ObservableObject {
    @Published private(set) var target: DiagnoseTarget?
    @Published private(set) var rows: [CheckRow] = []
    @Published private(set) var verdict: Verdict?
    @Published private(set) var running = false
    @Published private(set) var facts: DiagnoseFacts?

    private let state: AppState
    private let engine: Engine
    private var task: Task<Void, Never>?

    init(state: AppState, engine: Engine) {
        self.state = state
        self.engine = engine
    }

    func run(_ target: DiagnoseTarget) {
        task?.cancel()
        self.target = target
        verdict = nil
        facts = nil
        running = true
        rows = [
            CheckRow(id: "status", title: target.perspective == .device ? "共享状态" : "本机代理"),
            CheckRow(id: "dns", title: "域名解析"),
            CheckRow(id: "direct", title: "直接访问"),
            CheckRow(id: "proxied", title: "经代理访问"),
            CheckRow(id: "node", title: "节点"),
        ]
        if target.perspective == .device {
            rows.append(CheckRow(id: "device", title: "设备的连接"))
        }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let facts = await self.collect(target)
            guard !Task.isCancelled else { return }
            let verdict = Verdict.make(facts)
            self.facts = facts
            self.verdict = verdict
            self.running = false
            Log.info("诊断完成：\(target.host)（\(target.perspective.title)）→ \(verdict.headline)")
        }
    }

    /// 跑完一次诊断再返回结论（命令行和 AI 助手用）。
    func runAndWait(_ target: DiagnoseTarget) async -> Verdict? {
        run(target)
        await task?.value
        return verdict
    }

    func cancel() {
        task?.cancel()
        task = nil
        running = false
    }

    /// 可以复制给别人看的文字报告。
    var reportText: String {
        guard let target else { return "" }
        var lines = ["ProxySwitch 网址诊断：\(target.url.absoluteString)（\(target.perspective.title)）"]
        for row in rows {
            let mark: String
            switch row.outcome {
            case .pass: mark = "✓"
            case .warn: mark = "!"
            case .fail: mark = "✗"
            case .skipped: mark = "–"
            case .pending, .running: mark = "…"
            }
            lines.append("\(mark) \(row.title)：\(row.summary)" + (row.detail.isEmpty ? "" : "（\(row.detail)）"))
        }
        if let verdict {
            lines.append("结论：\(verdict.headline)")
            lines.append(verdict.explanation)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - 检查

    private func set(_ id: String, _ outcome: CheckRow.Outcome, _ summary: String, detail: String = "") {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[index].outcome = outcome
        rows[index].summary = summary
        rows[index].detail = detail
    }

    private func collect(_ target: DiagnoseTarget) async -> DiagnoseFacts {
        var facts = DiagnoseFacts(perspective: target.perspective, host: target.host)
        facts.engineHasNodes = state.config.engine.wantsCore && !engine.nodes.isEmpty
        let mixedPort = state.config.engine.mixedPort

        // 1. 本机 / 共享的状态。
        set("status", .running, "正在看…")
        switch state.status {
        case .off:
            facts.macRoute = .off
        case .on(let profile):
            facts.macRoute = profile.engine ? .engine : .profile("\(profile.name)（\(profile.summary)）")
        case .external(let description):
            facts.macRoute = .external(description)
        }
        if case .listening = engine.shareStatus {
            facts.shareListening = true
        }
        facts.shareUpstream = state.shareUpstream
        if target.perspective == .device {
            if facts.shareListening {
                set("status", .pass, "共享入口在监听端口 \(state.share.port)，\(state.shareUpstream.summary)")
            } else {
                set("status", .fail, state.share.enabled ? "共享入口没在监听" : "局域网共享没有开启")
            }
        } else {
            switch facts.macRoute {
            case .off: set("status", .warn, "本机没开代理，浏览器直连")
            case .engine: set("status", .pass, "用的是节点代理（\(state.config.engine.mode.title)）" + (engine.effectiveNode.map { "，当前节点 \($0)" } ?? ""))
            case .profile(let text): set("status", .pass, "用的是 \(text)")
            case .external(let text): set("status", .warn, "系统代理由别的程序设置：\(text)")
            }
        }
        if Task.isCancelled { return facts }

        // 2. DNS：系统解析，以及经内核到境外的解析作对照。
        set("dns", .running, "正在解析…")
        if IPPrefix.normalize(target.host) != nil {
            set("dns", .skipped, "填的是 IP，不用解析")
        } else {
            facts.systemAddresses = await DNSProbe.system(target.host)
            if engine.isRunning, state.config.engine.wantsCore {
                facts.remoteAddresses = await DNSProbe.remote(target.host, viaPort: mixedPort)
            }
            if facts.systemAddresses.isEmpty {
                set("dns", .fail, "本机解析不到这个域名", detail: facts.remoteAddresses.map { $0.isEmpty ? "境外也解析不到" : "境外解析：\($0.joined(separator: "、"))" } ?? "")
            } else {
                var summary = "本机解析：\(facts.systemAddresses.prefix(3).joined(separator: "、"))"
                var detail = ""
                if let remote = facts.remoteAddresses {
                    if remote.isEmpty {
                        detail = "境外解析失败"
                    } else {
                        summary += "；境外解析：\(remote.prefix(3).joined(separator: "、"))"
                        if Set(remote).isDisjoint(with: facts.systemAddresses) {
                            detail = "两边结果不同：CDN 常按地区给不同地址，不一定是污染；直连不通时才要怀疑"
                        }
                    }
                }
                set("dns", .pass, summary, detail: detail)
            }
        }
        if Task.isCancelled { return facts }

        // 3. 直连。
        set("direct", .running, "正在访问…")
        let direct = await ProbeResult.probe(url: target.url, proxy: [:])
        facts.direct = direct
        set("direct", direct.ok ? .pass : .fail, direct.ok ? "可以访问：\(direct.summary)" : "不通：\(direct.summary)")
        if Task.isCancelled { return facts }

        // 4. 经代理访问，能经内核的顺便抓判定。
        set("proxied", .running, "正在访问…")
        var proxied: ProbeResult?
        var trace: RouteTrace?
        switch (target.perspective, facts.macRoute) {
        case (.device, _):
            if facts.shareListening {
                facts.proxiedVia = "共享入口"
                let result = await engine.traceConnection(url: target.url, host: target.host, port: target.port, viaPort: state.share.port)
                proxied = result.probe
                trace = result.trace
            } else {
                set("proxied", .skipped, "共享入口没在监听，没法测")
            }
        case (.mac, .engine):
            facts.proxiedVia = "节点代理"
            let result = await engine.traceConnection(url: target.url, host: target.host, port: target.port, viaPort: mixedPort)
            proxied = result.probe
            trace = result.trace
        case (.mac, .profile(let text)):
            facts.proxiedVia = text
            if case .on(let profile) = state.status {
                proxied = await ProbeResult.probe(url: target.url, proxy: ProxyTester.proxyDictionary(for: profile))
            }
        case (.mac, .external(let text)):
            facts.proxiedVia = "系统代理 \(text)"
            proxied = await ProbeResult.probe(url: target.url, proxy: nil)
        case (.mac, .off):
            set("proxied", .skipped, "本机没开代理")
        }
        facts.proxied = proxied
        facts.trace = trace
        if let proxied {
            var summary = proxied.ok ? "可以访问：\(proxied.summary)" : "不通：\(proxied.summary)"
            var detail = ""
            if let trace {
                summary = (trace.rule.isEmpty ? "" : "命中 \(trace.rule)，") + "走 \(trace.chain)：" + proxied.summary
                if let error = trace.error { detail = "内核：\(error)" }
            } else if facts.macRoute == .engine || target.perspective == .device {
                detail = "内核没有记录到这次连接的判定"
            }
            set("proxied", proxied.ok ? .pass : .fail, summary, detail: detail)
        }
        if Task.isCancelled { return facts }

        // 5. 节点：走内核时看当前节点通不通。
        set("node", .running, "正在测…")
        let usesEngine = (target.perspective == .mac && facts.macRoute == .engine) || (target.perspective == .device && facts.shareUpstream == .engine)
        if usesEngine, engine.isRunning, let node = engine.effectiveNode {
            facts.nodeName = node
            let delay = await engine.delay(of: node)
            facts.nodeDelay = delay
            set("node", delay > 0 ? .pass : .fail, delay > 0 ? "\(node)：\(delay) ms" : "\(node) 连不上")
        } else if usesEngine {
            set("node", .warn, engine.isRunning ? "还没有选中的节点" : "内核没有运行")
        } else {
            set("node", .skipped, "这条链路不经节点")
        }
        if Task.isCancelled { return facts }

        // 6. 设备视角：最近有没有设备对这个域名的连接。
        if target.perspective == .device {
            let suffix = target.host.lowercased()
            let count = engine.shareConnections.filter { $0.host.lowercased() == suffix || $0.host.lowercased().hasSuffix("." + suffix) }.count
            facts.deviceRecentConnections = count
            set("device", count > 0 ? .pass : .warn, count > 0 ? "最近有 \(count) 条设备对它的连接" : "最近没有设备对这个域名的连接（在设备上打开它，再看「最近的连接」）")
        }
        return facts
    }
}
