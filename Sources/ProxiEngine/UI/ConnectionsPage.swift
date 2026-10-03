import AppKit
import Charts
import SwiftUI

/// 连接页：出口 IP、按出口累计的流量、现在开着的连接和最近的连接（谁访问了什么、走了哪里、命中了哪条规则）。
struct ConnectionsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @State private var filter = ""
    @State private var closingAll = false
    @State private var trafficView = "outbound"
    @State private var serviceNode = ""
    @State private var checkAddress = ""

    private var targets: [RuleTarget] { RuleTarget.options(groups: state.config.engine.groups) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("连接"), subtitle: L("谁在访问什么、走了哪个节点、命中了哪条规则；出口 IP 和按节点累计的流量"))
            Form {
                speedSection
                exitSection
                servicesSection
                trafficSection
                activeSection
                recentSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .task {
            if engine.directExit == nil {
                await engine.checkDirectExit()
            }
            if engine.exitInfo == nil, engine.isRunning {
                await engine.checkExit()
            }
        }
    }

    // MARK: - 出口

    private var exitSection: some View {
        Section(L("出口 IP")) {
            exitRow(title: L("经节点"), info: engine.exitInfo, problem: engine.exitProblem, checking: engine.checkingExit, available: engine.isRunning && state.config.engine.wantsCore, unavailableText: L("内核启动后查")) {
                Task { await engine.checkExit(force: true) }
            }
            exitRow(title: L("直连"), info: engine.directExit, problem: engine.directExitProblem, checking: engine.checkingDirectExit, available: true, unavailableText: "") {
                Task { await engine.checkDirectExit() }
            }
            Text(L("经节点的出口就是网站看到的你的地址，切换节点后自动重查；直连的是这台 Mac 自己的公网地址。通过 ip.sb、ipinfo.io 这些公开接口查询。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exitRow(title: String, info: ExitInfo?, problem: String?, checking: Bool, available: Bool, unavailableText: String, refresh: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: AppLanguage.width(48, english: 72), alignment: .leading)
            if let info {
                Text(info.flag.isEmpty ? "🌐" : info.flag)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 1) {
                    Text(info.ip)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .textSelection(.enabled)
                    Text([info.place, info.organization].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let problem, available {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(available ? (checking ? L("正在查…") : L("还没查")) : unavailableText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if checking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(L("刷新")) { refresh() }
                    .controlSize(.small)
                    .disabled(!available)
            }
        }
    }

    // MARK: - 网速

    private var speedSection: some View {
        Section(L("网速")) {
            if engine.speedHistory.count < 2 {
                Text(engine.isRunning ? L("正在采集，几秒后出现最近两分钟经内核的网速。") : L("内核运行时这里显示最近两分钟经内核的网速。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                SpeedChart(samples: engine.speedHistory)
                    .frame(height: 120)
                if let last = engine.speedHistory.last {
                    HStack(spacing: 16) {
                        Label("↑ \(Engine.bytesText(last.upload))/s", systemImage: "arrow.up")
                            .foregroundStyle(.orange)
                        Label("↓ \(Engine.bytesText(last.download))/s", systemImage: "arrow.down")
                            .foregroundStyle(Color.accentColor)
                        Spacer()
                        let peak = engine.speedHistory.map { max($0.upload, $0.download) }.max() ?? 0
                        Text(L("两分钟内最快 %@/s", Engine.bytesText(peak)))
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    .labelStyle(.titleOnly)
                }
            }
        }
    }

    // MARK: - 网址检测

    private var serviceKey: String { serviceNode }

    private var servicesSection: some View {
        Section(L("网址检测")) {
            HStack {
                TextField("", text: $checkAddress, prompt: Text(L("网址，比如 https://example.com")))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(runCheck)
                Picker(L("经"), selection: $serviceNode) {
                    Text(L("现在的节点") + (engine.effectiveNode.map { L("（%@）", $0) } ?? "")).tag("")
                    ForEach(engine.sortedNodes.prefix(200)) { node in
                        Text(node.name).tag(node.name)
                    }
                }
                .frame(maxWidth: 260)
                if engine.checkingServices != nil {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(engine.checkingServices != nil ? L("正在检测…") : L("检测")) { runCheck() }
                    .disabled(engine.checkingServices != nil || !engine.isRunning || !state.config.engine.wantsCore || ServiceClassifier.normalize(checkAddress) == nil)
            }
            if let results = engine.serviceResults[serviceKey], !results.isEmpty {
                ForEach(results) { result in
                    HStack(spacing: 10) {
                        Image(systemName: icon(result.status))
                            .foregroundStyle(color(result.status))
                            .frame(width: 16)
                        Text(result.title)
                            .frame(width: 180, alignment: .leading)
                            .lineLimit(1)
                            .help(result.url)
                        Text(result.summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(Engine.relative(result.checkedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Text(L("经某个节点访问一个你填的网址，看能不能打开、返回什么状态、花了多久。选别的节点检测时不会切换你正在用的节点。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func runCheck() {
        let node = serviceNode.isEmpty ? nil : serviceNode
        let address = checkAddress
        Task { await engine.checkURL(address, node: node) }
    }

    private func icon(_ status: ServiceCheckResult.Status) -> String {
        switch status {
        case .available: return "checkmark.circle.fill"
        case .blocked: return "nosign"
        case .failed: return "xmark.circle"
        }
    }

    private func color(_ status: ServiceCheckResult.Status) -> Color {
        switch status {
        case .available: return .green
        case .blocked: return .red
        case .failed: return .secondary
        }
    }

    // MARK: - 流量

    private var trafficEntries: [TrafficEntry] {
        switch trafficView {
        case "source": return engine.traffic.rankedSources
        case "day": return engine.traffic.recentDays(14).reversed()
        default: return engine.traffic.ranked
        }
    }

    private var trafficSection: some View {
        Section(L("流量统计")) {
            LabeledContent(L("内核这次运行")) {
                Text(L("↑ %@　↓ %@", Engine.bytesText(engine.sessionTraffic.upload), Engine.bytesText(engine.sessionTraffic.download)))
                    .monospacedDigit()
            }
            Picker("", selection: $trafficView) {
                Text(L("按节点")).tag("outbound")
                Text(L("按程序和设备")).tag("source")
                Text(L("按天")).tag("day")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            let ranked = trafficEntries
            if ranked.allSatisfy({ $0.traffic.isZero }) {
                Text(L("有流量经过内核后，这里按节点（以及直连、上游代理）、按发起连接的程序和设备、按天累计。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let top = ranked.map(\.traffic.total).max() ?? 1
                ForEach(ranked.prefix(14), id: \.name) { item in
                    HStack(spacing: 10) {
                        Text(item.displayName)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(width: 180, alignment: .leading)
                        GeometryReader { proxy in
                            Capsule()
                                .fill(item.name == "DIRECT" ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(0.6))
                                .frame(width: max(3, proxy.size.width * CGFloat(item.traffic.total) / CGFloat(max(top, 1))), height: 6)
                                .frame(maxHeight: .infinity, alignment: .center)
                        }
                        .frame(height: 12)
                        Text(L("↑ %@　↓ %@", Engine.bytesText(item.traffic.upload), Engine.bytesText(item.traffic.download)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 190, alignment: .trailing)
                    }
                }
            }
            HStack(alignment: .top) {
                Text(L("从 %@ 起累计，内核重启后接着算；每两秒采样一次，连接关掉前最后一点流量算不进来，看趋势够用。按天的统计保留一个月。", Self.dateFormatter.string(from: engine.traffic.since)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L("清零")) { engine.resetTraffic() }
                    .controlSize(.small)
                    .disabled(engine.traffic.outbounds.isEmpty)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = AppLanguage.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - 正在进行的连接

    private var activeRecords: [ConnectionRecord] {
        let records = engine.connections.map(ConnectionRecord.init).sorted { $0.start > $1.start }
        return filtered(records)
    }

    private func filtered(_ records: [ConnectionRecord]) -> [ConnectionRecord] {
        let text = filter.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return records }
        return records.filter { record in
            [record.host, record.process, record.client, record.rule, record.outbound, record.group].contains { $0.localizedCaseInsensitiveContains(text) }
        }
    }

    private var activeSection: some View {
        Section(L("正在进行的连接（%@）", engine.connections.count)) {
            HStack {
                TextField("", text: $filter, prompt: Text(L("按域名、程序、设备、规则或节点筛选")))
                    .labelsHidden()
                Button(closingAll ? L("正在断开…") : L("全部断开")) {
                    closingAll = true
                    Task { @MainActor in
                        await engine.closeAllConnections()
                        closingAll = false
                    }
                }
                .controlSize(.small)
                .disabled(closingAll || engine.connections.isEmpty)
            }
            if !engine.isRunning {
                Text(L("内核没有运行。在「节点与订阅」页启用代理引擎，或者打开局域网共享后，经内核的连接会列在这里。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if activeRecords.isEmpty {
                Text(filter.isEmpty ? L("现在没有开着的连接。") : L("没有匹配的连接。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeRecords.prefix(80)) { record in
                    ConnectionRow(record: record, targets: targets, showTraffic: true, onPin: { target in
                        engine.addCustomRule(pattern: record.host, policy: target)
                    }, onPinApp: { target in
                        pinApp(record, target)
                    }, onClose: {
                        Task { await engine.close(connection: record.id) }
                    })
                }
                if activeRecords.count > 80 {
                    Text(L("还有 %@ 条没有列出，用筛选缩小范围。", activeRecords.count - 80))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(L("来源是发起连接的程序，PS5 等设备显示它的 IP。右键一条连接可以让这个域名固定走某个去向，或者断开它。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 让发起这条连接的应用（或者设备）固定走某个去向。
    private func pinApp(_ record: ConnectionRecord, _ target: RuleTarget) {
        if record.isShare {
            engine.addCustomRule(pattern: record.client, policy: target, kind: .device)
        } else if let bundle = CustomRule.appBundlePath(forProcessPath: record.processPath) {
            engine.addCustomRule(pattern: bundle, policy: target, kind: .app)
        } else if !record.process.isEmpty {
            engine.addCustomRule(pattern: record.process, policy: target, kind: .process)
        }
    }

    // MARK: - 最近的连接

    private var recentSection: some View {
        let records = filtered(engine.history)
        return Section(L("最近的连接")) {
            if records.isEmpty {
                Text(engine.history.isEmpty ? L("经内核的连接会按时间记在这里，短连接也有，最多 %@ 条。", Engine.historyLimit) : L("没有匹配的连接。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records.prefix(60)) { record in
                    ConnectionRow(record: record, targets: targets, showTraffic: false, onPin: { target in
                        engine.addCustomRule(pattern: record.host, policy: target)
                    }, onPinApp: { target in
                        pinApp(record, target)
                    }, onClose: nil)
                }
                HStack {
                    Spacer()
                    Button(L("清空")) { engine.clearHistory() }
                        .controlSize(.small)
                }
            }
        }
    }
}

/// 一条连接：目标、来源和规则、出口（连同策略组）、流量。右键改去向或断开。
struct ConnectionRow: View {
    var record: ConnectionRecord
    var targets: [RuleTarget]
    var showTraffic: Bool
    var onPin: (RuleTarget) -> Void
    /// 让发起连接的应用（本机）或者设备（共享）固定走某个去向。
    var onPinApp: ((RuleTarget) -> Void)? = nil
    var onClose: (() -> Void)?

    /// 右键菜单里「让 xx 走…」的 xx：应用名、进程名或者设备。
    private var appTitle: String? {
        if record.isShare { return record.client.isEmpty ? nil : L("设备 %@", record.client) }
        if let bundle = CustomRule.appBundlePath(forProcessPath: record.processPath) {
            return (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        }
        return record.process.isEmpty ? nil : record.process
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.target)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !record.network.isEmpty, record.network != "TCP" {
                        Text(record.network)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(sourceLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(record.route)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(record.outbound == "DIRECT" ? Color.secondary : Color.accentColor)
                    .lineLimit(1)
                if showTraffic {
                    Text(trafficLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if !record.host.isEmpty {
                ForEach(targets, id: \.self) { target in
                    Button(L("让 %@ %@", record.host, target.actionTitle)) { onPin(target) }
                }
                Divider()
            }
            if let onPinApp, let appTitle {
                Menu(L("让 %@ 的所有连接…", appTitle)) {
                    ForEach(targets, id: \.self) { target in
                        Button(target.actionTitle) { onPinApp(target) }
                    }
                }
                Divider()
            }
            Button(L("复制目标")) { TerminalCommands.copy(record.target) }
            if let onClose {
                Button(L("断开这条连接"), role: .destructive) { onClose() }
            }
        }
    }

    private var sourceLine: String {
        var parts = [record.isShare ? L("%@（设备）", record.client) : record.source]
        if !record.rule.isEmpty {
            parts.append(record.rule)
        }
        return parts.joined(separator: " · ")
    }

    private var trafficLine: String {
        var text = "↑ \(Engine.bytesText(record.upload)) ↓ \(Engine.bytesText(record.download))"
        let duration = Engine.durationText(since: record.startDate)
        if !duration.isEmpty {
            text += " · \(duration)"
        }
        return text
    }
}

/// 最近两分钟的网速曲线：上行、下行两条线。
struct SpeedChart: View {
    var samples: [SpeedSample]

    var body: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value(L("时间"), sample.date), y: .value(L("字节每秒"), Double(sample.download)), series: .value(L("方向"), L("下行")))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                LineMark(x: .value(L("时间"), sample.date), y: .value(L("字节每秒"), Double(sample.upload)), series: .value(L("方向"), L("上行")))
                    .foregroundStyle(Color.orange)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let bytes = value.as(Double.self) {
                        Text(Engine.bytesText(Int64(bytes)) + "/s")
                            .font(.system(size: 9))
                    }
                }
            }
        }
    }
}
