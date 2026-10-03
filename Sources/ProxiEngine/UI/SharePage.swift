import AppKit
import SwiftUI

/// 局域网共享页：开关和状态、PS5 上要填的地址、现在转发到哪、谁能用、端口、网关模式、正在使用的设备。
struct SharePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var sleepGuard: SleepGuard
    @State private var portText = ""
    @State private var clientsText = ""
    @State private var testResult: TestResult?
    @State private var testing = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("局域网共享"), subtitle: L("让 PS5、Switch、手机这些同一局域网里的设备把这台 Mac 当代理服务器，享受和本机一样的网络"))
            Form {
                shareSection
                sleepSection
                addressSection
                accessSection
                GatewaySection(state: state, engine: engine, helper: state.helper)
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
    }

    /// 正在使用的设备：内核在跑时连接列表每两秒刷新一次，这里按来源 IP 归并。
    private var clients: [ShareClient] { engine.shareClients }

    private var isListening: Bool {
        if case .listening = engine.shareStatus { return true }
        return false
    }

    // MARK: - 共享

    private var shareSection: some View {
        Section(L("共享")) {
            Toggle(L("允许局域网里的设备经这台 Mac 上网"), isOn: Binding(get: { state.share.enabled }, set: { state.setShareEnabled($0) }))
            LabeledContent(L("状态")) { statusView }
            LabeledContent(L("现在转发到")) {
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
            Text(L("跟着本机走：本机开着代理引擎，共享的设备就用同样的节点和分流规则；本机用公司代理或者别的代理软件，就转发给它；本机没开代理，就经这台 Mac 直接上网。本机切换配置时，共享的设备几秒内跟着变。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !engine.coreAvailable {
                Label(L("共享由内核完成，还没有下载内核，到「内核」页下载"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch engine.shareStatus {
        case .off:
            Text(state.share.enabled ? L("未运行") : L("未开启"))
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(L("正在启动…"))
                    .foregroundStyle(.secondary)
            }
        case .listening(let port):
            Label(L("正在监听端口 %@，局域网里的设备可以连接", String(port)), systemImage: "checkmark.circle")
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - 保持唤醒

    private var sleepSection: some View {
        Section(L("保持唤醒")) {
            Toggle(L("共享期间不让 Mac 睡眠（显示器可以关）"), isOn: Binding(
                get: { state.share.keepAwake },
                set: { value in
                    var share = state.share
                    share.keepAwake = value
                    state.setShare(share)
                }
            ))
            if state.share.keepAwake {
                Toggle(L("电池供电时也保持"), isOn: Binding(
                    get: { state.share.keepAwakeOnBattery },
                    set: { value in
                        var share = state.share
                        share.keepAwakeOnBattery = value
                        state.setShare(share)
                    }
                ))
            }
            LabeledContent(L("状态")) { sleepStatusView }
            Text(L("Mac 一睡，设备的网就断了，所以共享开着时阻止空闲睡眠；默认只在接电源时保持，免得忘了关把电用光。合盖仍然会睡眠：接上电源和外接显示器（合盖模式）可以合着盖子用。程序退出或关掉共享后恢复正常，「活动监视器 → 能耗」里能看到是 Proxi Engine 在阻止睡眠。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var sleepStatusView: some View {
        switch sleepGuard.status {
        case .holding:
            Label(L("正在保持唤醒"), systemImage: "cup.and.saucer")
                .foregroundStyle(.green)
        case .pausedOnBattery:
            Label(L("电池供电，已暂停保持唤醒"), systemImage: "battery.50")
                .foregroundStyle(.orange)
        case .off:
            Text(state.share.enabled && state.share.keepAwake ? L("未保持") : L("共享开启后生效"))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 设备上填的地址

    private var addressSection: some View {
        Section(L("在 PS5 / Switch 上填写")) {
            if let address = state.lanAddress {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(address.ip) : \(String(state.share.port))")
                            .font(.system(size: 26, weight: .semibold, design: .monospaced))
                            .textSelection(.enabled)
                        Text(L("代理服务器地址填 %@（这台 Mac 的 %@），端口填 %@", address.ip, address.serviceName, String(state.share.port)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(copied ? L("已复制") : L("复制")) { copy("\(address.ip):\(state.share.port)") }
                }
                .padding(.vertical, 4)
                let others = state.lanAddresses.dropFirst()
                if !others.isEmpty {
                    Text(L("这台 Mac 还有别的网卡：") + others.map { "\($0.serviceName) \($0.ip)" }.joined(separator: L("、")) + L("。设备要和 Mac 在同一个网络里才连得上，按实际情况选。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(L("这台 Mac 现在没有连上局域网"), systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            }
            Text(L("PS5：设置 → 网络 → 设置 → 设置互联网连接 → 选中正在用的网络 → 高级设置 → 代理服务器 → 「使用」，填上面的地址和端口。Switch：设置 → 互联网 → 互联网设置 → 选中网络 → 更改设置 → 代理服务器设置。手机、电脑在 Wi‑Fi 的手动代理里填同样的地址。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("Mac 的 IP 变了设备就连不上了：建议在路由器里给这台 Mac 分配固定 IP，或者在 Mac 的网络设置里手动指定。PS5 只把 HTTP / HTTPS 流量（商店、下载、登录、浏览器）交给代理，游戏联机的 UDP 流量仍然直连。开着 macOS 防火墙时，第一次会询问是否允许 mihomo 接受传入连接，要允许。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 谁能用、端口

    private var clientsProblem: String? {
        let invalid = ShareConfig.parseClients(clientsText).invalid
        return invalid.isEmpty ? nil : L("认不出这些地址：%@", invalid.joined(separator: L("、")))
    }

    /// 1024~65535，而且不能和内核自己的代理端口、API 端口撞上（撞上时本机自测会误以为通了）。
    private var portValid: Bool {
        guard let port = Int(portText) else { return false }
        return (1024...65535).contains(port) && port != state.config.engine.mixedPort && port != state.config.engine.apiPort
    }

    private var accessSection: some View {
        Section(L("谁能用、用哪个端口")) {
            HStack {
                TextField("", text: $clientsText, prompt: Text(L("留空：局域网里的所有设备。或者填 192.168.1.20, 192.168.1.0/24")))
                    .labelsHidden()
                    .onSubmit { applyClients() }
                Button(L("应用")) { applyClients() }
                    .disabled(clientsProblem != nil || clientsText.trimmingCharacters(in: .whitespacesAndNewlines) == state.share.allowedClients)
            }
            if let clientsProblem {
                Text(clientsProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(L("留空时同一局域网（10.x、172.16–31.x、192.168.x）里的任何设备都能用。在公共 Wi‑Fi 上最好填上 PS5 的 IP 只让它用，或者干脆关掉共享。本机自己总是允许的。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField(L("端口"), text: $portText)
                    .onChange(of: portText) { _, value in
                        let digits = value.filter(\.isNumber)
                        if digits != value { portText = digits }
                    }
                Button(L("应用")) { applyPort() }
                    .disabled(!portValid || Int(portText) == state.share.port)
                Button(testing ? L("正在测试…") : L("经共享端口测试")) { test() }
                    .disabled(testing || !isListening)
            }
            if let testResult {
                Label(testResult.ok ? "\(testResult.latencyText) · \(testResult.message)" : testResult.message, systemImage: testResult.ok ? "checkmark.circle" : "xmark.circle")
                    .font(.caption)
                    .foregroundStyle(testResult.ok ? Color.green : Color.red)
            }
            Text(L("默认 7892；不能用代理引擎自己的端口（%@ 和 %@）。改了端口，设备上也要跟着改。「经共享端口测试」从本机经这个端口访问测速地址，能确认入口和上游都通。", String(state.config.engine.mixedPort), String(state.config.engine.apiPort)))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 正在使用的设备

    private var clientsSection: some View {
        Section(L("正在使用的设备")) {
            if clients.isEmpty {
                Text(isListening ? L("还没有设备经这台 Mac 上网。PS5 上设置好后，打开商店或者测试互联网连接就能在这里看到它。") : L("共享开启后，这里会列出正在使用的设备。"))
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
                        deviceMenu(client.ip)
                    }
                }
                Text(L("按来源 IP 归并，只统计现在还开着的连接。右边的菜单能让某台设备固定走某个节点组、直连或者断网（设备规则在「分流规则」页里也能改）。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 设备现在的设备规则（按来源 IP）。
    private func deviceRule(_ ip: String) -> CustomRule? {
        let prefix = IPPrefix.normalize(ip)
        return state.config.engine.customRules.first { $0.kind == .device && $0.enabled && ($0.pattern == ip || $0.pattern == prefix) }
    }

    private func deviceMenu(_ ip: String) -> some View {
        let current = deviceRule(ip)
        return Menu(current.map { L("走：%@", $0.policy.title) } ?? L("跟随规则")) {
            ForEach(RuleTarget.options(groups: state.config.engine.groups), id: \.self) { target in
                Button(L("这台设备的所有连接%@", target.actionTitle)) {
                    engine.addCustomRule(pattern: ip, policy: target, kind: .device)
                }
            }
            if let current {
                Divider()
                Button(L("恢复跟随分流规则")) { engine.removeCustomRule(current.id) }
            }
        }
        .fixedSize()
        .controlSize(.small)
        .help(L("本机用代理引擎时完全生效；本机用别的代理或直连时，只有「直连」「拦截」生效"))
    }

    private func clientDetail(_ client: ShareClient) -> String {
        var text = L("%@ 个连接 · ↑ %@ ↓ %@", client.connections, Engine.bytesText(client.upload), Engine.bytesText(client.download))
        if !client.lastHost.isEmpty {
            text += L(" · 最近 %@", client.lastHost)
        }
        if !client.lastOutbound.isEmpty {
            text += " → \(client.lastOutbound)"
        }
        return text
    }

    // MARK: - 最近的连接

    private var recentSection: some View {
        Section(L("最近的连接")) {
            if engine.shareConnections.isEmpty {
                Text(L("设备经共享入口发起的连接会按时间列在这里：访问了哪个域名、走的是哪个节点还是直连、命中了哪条规则。"))
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
                    .contentShape(Rectangle())
                    .contextMenu {
                        if !connection.host.isEmpty {
                            ForEach(RuleTarget.options(groups: state.config.engine.groups), id: \.self) { target in
                                Button(L("让 %@ %@", connection.host, target.actionTitle)) {
                                    engine.addCustomRule(pattern: connection.host, policy: target)
                                }
                            }
                        }
                        if !connection.client.isEmpty {
                            Divider()
                            Menu(L("让设备 %@ 的所有连接…", connection.client)) {
                                ForEach(RuleTarget.options(groups: state.config.engine.groups), id: \.self) { target in
                                    Button(target.actionTitle) {
                                        engine.addCustomRule(pattern: connection.client, policy: target, kind: .device)
                                    }
                                }
                            }
                        }
                    }
                }
                HStack(alignment: .top) {
                    Text(L("PS5 的代理设置只对系统流量（联网测试、PSN、商店）和浏览器生效。如果打开某个应用时这里没有出现它的连接，说明那个应用用的是自己的网络栈、没走代理；用 PS5 的浏览器打开同一个网站可以对照。域名一栏如果是 IP，说明设备自己解析了域名，内核会从 TLS 握手里取回域名再分流。本机和设备的全部连接在「连接」页。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L("清空")) { engine.clearHistory(shareOnly: true) }
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
            let profile = Profile(name: L("局域网共享"), color: "", kind: .http, host: "127.0.0.1", port: state.share.port)
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
