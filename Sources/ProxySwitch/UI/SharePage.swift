import AppKit
import SwiftUI

/// 局域网共享页：开关和状态、PS5 上要填的地址、现在转发到哪、谁能用、端口、正在使用的设备。
struct SharePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var sleepGuard: SleepGuard
    @State private var portText = ""
    @State private var clientsText = ""
    @State private var clients: [ShareClient] = []
    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "局域网共享", subtitle: "让 PS5、Switch、手机这些同一局域网里的设备把这台 Mac 当代理服务器，享受和本机一样的网络")
            Form {
                shareSection
                sleepSection
                addressSection
                accessSection
                clientsSection
                recentSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            portText = String(state.share.port)
            clientsText = state.share.allowedClients
        }
        .task {
            // 页面开着时每两秒读一次连接列表：能看到 PS5 连上来了没有，短连接也会记进「最近的连接」。
            while !Task.isCancelled {
                clients = await engine.shareClients()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var isListening: Bool {
        if case .listening = engine.shareStatus { return true }
        return false
    }

    // MARK: - 共享

    private var shareSection: some View {
        Section("共享") {
            Toggle("允许局域网里的设备经这台 Mac 上网", isOn: Binding(get: { state.share.enabled }, set: { state.setShareEnabled($0) }))
            LabeledContent("状态") { statusView }
            LabeledContent("现在转发到") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.shareUpstream.title)
                    if let warning = state.shareUpstream.warning {
                        Text(warning)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Text("跟着本机走：本机开着内置代理，共享的设备就用同样的节点和分流规则；本机用公司代理或者别的代理软件，就转发给它；本机没开代理，就经这台 Mac 直接上网。本机切换配置时，共享的设备几秒内跟着变。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !engine.coreAvailable {
                Label("共享由内置的内核完成，这个 ProxySwitch 里没有打包内核，请到发布页重新下载完整版本", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch engine.shareStatus {
        case .off:
            Text(state.share.enabled ? "未运行" : "未开启")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("正在启动…")
                    .foregroundStyle(.secondary)
            }
        case .listening(let port):
            Label("正在监听端口 \(String(port))，局域网里的设备可以连接", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 保持唤醒

    private var sleepSection: some View {
        Section("保持唤醒") {
            Toggle("共享期间不让 Mac 睡眠（显示器可以关）", isOn: Binding(
                get: { state.share.keepAwake },
                set: { value in
                    var share = state.share
                    share.keepAwake = value
                    state.setShare(share)
                }
            ))
            if state.share.keepAwake {
                Toggle("电池供电时也保持", isOn: Binding(
                    get: { state.share.keepAwakeOnBattery },
                    set: { value in
                        var share = state.share
                        share.keepAwakeOnBattery = value
                        state.setShare(share)
                    }
                ))
            }
            LabeledContent("状态") { sleepStatusView }
            Text("Mac 一睡，设备的网就断了，所以共享开着时阻止空闲睡眠；默认只在接电源时保持，免得忘了关把电用光。合盖仍然会睡眠：接上电源和外接显示器（合盖模式）可以合着盖子用。程序退出或关掉共享后恢复正常，「活动监视器 → 能耗」里能看到是 ProxySwitch 在阻止睡眠。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sleepStatusView: some View {
        switch sleepGuard.status {
        case .holding:
            Label("正在保持唤醒", systemImage: "cup.and.saucer")
                .foregroundStyle(.green)
        case .pausedOnBattery:
            Label("电池供电，已暂停保持唤醒", systemImage: "battery.50")
                .foregroundStyle(.orange)
        case .off:
            Text(state.share.enabled && state.share.keepAwake ? "未保持" : "共享开启后生效")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 设备上填的地址

    private var addressSection: some View {
        Section("在 PS5 / Switch 上填写") {
            if let address = state.lanAddress {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(address.ip) : \(String(state.share.port))")
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Text("代理服务器地址填 \(address.ip)（这台 Mac 的 \(address.serviceName)），端口填 \(String(state.share.port))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copied ? "已复制" : "复制") { copy("\(address.ip):\(state.share.port)") }
                }
                .padding(.vertical, 4)
                let others = state.lanAddresses.dropFirst()
                if !others.isEmpty {
                    Text("这台 Mac 还有别的网卡：" + others.map { "\($0.serviceName) \($0.ip)" }.joined(separator: "、") + "。设备要和 Mac 在同一个网络里才连得上，按实际情况选。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("这台 Mac 现在没有连上局域网", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            }
            Text("PS5：设置 → 网络 → 设置 → 设置互联网连接 → 选中正在用的网络 → 高级设置 → 代理服务器 → 「使用」，填上面的地址和端口。Switch：设置 → 互联网 → 互联网设置 → 选中网络 → 更改设置 → 代理服务器设置。手机、电脑在 Wi‑Fi 的手动代理里填同样的地址。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Mac 的 IP 变了设备就连不上了：建议在路由器里给这台 Mac 分配固定 IP，或者在 Mac 的网络设置里手动指定。PS5 只把 HTTP / HTTPS 流量（商店、下载、登录、浏览器）交给代理，游戏联机的 UDP 流量仍然直连。开着 macOS 防火墙时，第一次会询问是否允许 mihomo 接受传入连接，要允许。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 谁能用、端口

    private var clientsProblem: String? {
        let invalid = ShareConfig.parseClients(clientsText).invalid
        return invalid.isEmpty ? nil : "认不出这些地址：\(invalid.joined(separator: "、"))"
    }

    /// 1024~65535，而且不能和内核自己的代理端口、API 端口撞上（撞上时本机自测会误以为通了）。
    private var portValid: Bool {
        guard let port = Int(portText) else { return false }
        return (1024...65535).contains(port) && port != state.config.engine.mixedPort && port != state.config.engine.apiPort
    }

    private var accessSection: some View {
        Section("谁能用、用哪个端口") {
            HStack {
                TextField("", text: $clientsText, prompt: Text("留空：局域网里的所有设备。或者填 192.168.1.20, 192.168.1.0/24"))
                    .labelsHidden()
                    .onSubmit { applyClients() }
                Button("应用") { applyClients() }
                    .disabled(clientsProblem != nil || clientsText.trimmingCharacters(in: .whitespacesAndNewlines) == state.share.allowedClients)
            }
            if let clientsProblem {
                Text(clientsProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("留空时同一局域网（10.x、172.16–31.x、192.168.x）里的任何设备都能用。在公共 Wi‑Fi 上最好填上 PS5 的 IP 只让它用，或者干脆关掉共享。本机自己总是允许的。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("端口", text: $portText)
                    .onChange(of: portText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { portText = digits }
                    }
                Button("应用") { applyPort() }
                    .disabled(!portValid || Int(portText) == state.share.port)
                Button(testing ? "正在测试…" : "经共享端口测试") { test() }
                    .disabled(testing || !isListening)
            }
            if let testResult {
                Label(testResult.ok ? "\(testResult.latencyText) · \(testResult.message)" : testResult.message, systemImage: testResult.ok ? "checkmark.circle" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(testResult.ok ? Color.green : Color.red)
            }
            Text("默认 7892；不能用内置代理自己的端口（\(String(state.config.engine.mixedPort)) 和 \(String(state.config.engine.apiPort))）。改了端口，设备上也要跟着改。「经共享端口测试」从本机经这个端口访问测速地址，能确认入口和上游都通。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 正在使用的设备

    private var clientsSection: some View {
        Section("正在使用的设备") {
            if clients.isEmpty {
                Text(isListening ? "还没有设备经这台 Mac 上网。PS5 上设置好后，打开商店或者测试互联网连接就能在这里看到它。" : "共享开启后，这里会列出正在使用的设备。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(clients) { client in
                    HStack(spacing: 10) {
                        Image(systemName: "gamecontroller")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(client.ip)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                            Text(clientDetail(client))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                    }
                }
                Text("按来源 IP 归并，只统计现在还开着的连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func clientDetail(_ client: ShareClient) -> String {
        var text = "\(client.connections) 个连接 · ↑ \(Engine.bytesText(client.upload)) ↓ \(Engine.bytesText(client.download))"
        if !client.lastHost.isEmpty {
            text += " · 最近 \(client.lastHost)"
        }
        if !client.lastOutbound.isEmpty {
            text += " → \(client.lastOutbound)"
        }
        return text
    }

    // MARK: - 最近的连接

    private var recentSection: some View {
        Section("最近的连接") {
            if engine.shareConnections.isEmpty {
                Text("设备经共享入口发起的连接会按时间列在这里：访问了哪个域名、走的是哪个节点还是直连、命中了哪条规则。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(engine.shareConnections.prefix(20)) { connection in
                    HStack(spacing: 8) {
                        Text(connection.target)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(connection.rule)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(connection.outbound)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(connection.outbound == "DIRECT" ? Color.secondary : Color.accentColor)
                            .lineLimit(1)
                            .frame(minWidth: 60, alignment: .trailing)
                    }
                }
                HStack(alignment: .top) {
                    Text("PS5 的代理设置只对系统流量（联网测试、PSN、商店）和浏览器生效。如果打开 YouTube 这类应用时这里没有出现 youtube.com、googlevideo.com 的连接，说明那个应用用的是自己的网络栈、没走代理；用 PS5 的浏览器打开同一个网站可以对照。域名一栏如果是 IP，说明设备自己解析的 DNS 被污染了，内核会从 TLS 握手里取回域名再分流。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("清空") { engine.clearShareHistory() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 操作

    private func applyClients() {
        guard clientsProblem == nil else { return }
        var share = state.share
        share.allowedClients = clientsText.trimmingCharacters(in: .whitespacesAndNewlines)
        state.setShare(share)
        clientsText = share.allowedClients
    }

    private func applyPort() {
        guard let port = Int(portText), portValid else { return }
        var share = state.share
        share.port = port
        state.setShare(share)
        testResult = nil
    }

    private func test() {
        testing = true
        testResult = nil
        Task { @MainActor in
            // 经 127.0.0.1 上的共享端口访问测速地址：回环总在允许名单里，测的是入口和上游是否都通。
            let profile = Profile(name: "局域网共享", color: "", kind: .http, host: "127.0.0.1", port: state.share.port)
            testResult = await ProxyTester.test(profile: profile, testURL: state.config.testURL)
            testing = false
        }
    }

    private func copy(_ text: String) {
        TerminalCommands.copy(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }
}
