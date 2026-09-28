import AppKit
import SwiftUI

/// 连接页：出口 IP、按出口累计的流量、现在开着的连接和最近的连接（谁访问了什么、走了哪里、命中了哪条规则）。
struct ConnectionsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @State private var filter = ""
    @State private var closingAll = false

    private var targets: [RuleTarget] { RuleTarget.options(groups: state.config.engine.groups) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "连接", subtitle: "谁在访问什么、走了哪个节点、命中了哪条规则；出口 IP 和按节点累计的流量")
            Form {
                exitSection
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
        Section("出口 IP") {
            exitRow(title: "经节点", info: engine.exitInfo, problem: engine.exitProblem, checking: engine.checkingExit, available: engine.isRunning && state.config.engine.wantsCore, unavailableText: "内核启动后查") {
                Task { await engine.checkExit(force: true) }
            }
            exitRow(title: "直连", info: engine.directExit, problem: engine.directExitProblem, checking: engine.checkingDirectExit, available: true, unavailableText: "") {
                Task { await engine.checkDirectExit() }
            }
            Text("经节点的出口就是网站看到的你的地址，切换节点后自动重查；直连的是这台 Mac 自己的公网地址。通过 ip.sb、ipinfo.io 这些公开接口查询。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func exitRow(title: String, info: ExitInfo?, problem: String?, checking: Bool, available: Bool, unavailableText: String, refresh: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .frame(width: 48, alignment: .leading)
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
                Text(available ? (checking ? "正在查…" : "还没查") : unavailableText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if checking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("刷新") { refresh() }
                    .controlSize(.small)
                    .disabled(!available)
            }
        }
    }

    // MARK: - 流量

    private var trafficSection: some View {
        Section("流量统计") {
            LabeledContent("内核这次运行") {
                Text("↑ \(Engine.bytesText(engine.sessionTraffic.upload))　↓ \(Engine.bytesText(engine.sessionTraffic.download))")
                    .monospacedDigit()
            }
            let ranked = engine.traffic.ranked
            if ranked.isEmpty {
                Text("有流量经过内核后，这里按节点（以及直连、上游代理）累计。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let top = ranked.first?.traffic.total ?? 1
                ForEach(ranked.prefix(12), id: \.name) { item in
                    HStack(spacing: 10) {
                        Text(item.name)
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
                        Text("↑ \(Engine.bytesText(item.traffic.upload))　↓ \(Engine.bytesText(item.traffic.download))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 190, alignment: .trailing)
                    }
                }
            }
            HStack(alignment: .top) {
                Text("从 \(Self.dateFormatter.string(from: engine.traffic.since)) 起累计，内核重启后接着算；每两秒采样一次，连接关掉前最后一点流量算不进来，看趋势够用。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("清零") { engine.resetTraffic() }
                    .controlSize(.small)
                    .disabled(ranked.isEmpty)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
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
        Section("正在进行的连接（\(engine.connections.count)）") {
            HStack {
                TextField("", text: $filter, prompt: Text("按域名、程序、设备、规则或节点筛选"))
                    .labelsHidden()
                Button(closingAll ? "正在断开…" : "全部断开") {
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
                Text("内核没有运行。开启节点代理或局域网共享后，经内核的连接会列在这里。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if activeRecords.isEmpty {
                Text(filter.isEmpty ? "现在没有开着的连接。" : "没有匹配的连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(activeRecords.prefix(80)) { record in
                    ConnectionRow(record: record, targets: targets, showTraffic: true, onPin: { target in
                        engine.addCustomRule(pattern: record.host, policy: target)
                    }, onClose: {
                        Task { await engine.close(connection: record.id) }
                    })
                }
                if activeRecords.count > 80 {
                    Text("还有 \(activeRecords.count - 80) 条没有列出，用筛选缩小范围。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("来源是发起连接的程序，PS5 等设备显示它的 IP。右键一条连接可以让这个域名固定走某个去向，或者断开它。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 最近的连接

    private var recentSection: some View {
        let records = filtered(engine.history)
        return Section("最近的连接") {
            if records.isEmpty {
                Text(engine.history.isEmpty ? "经内核的连接会按时间记在这里，短连接也有，最多 \(Engine.historyLimit) 条。" : "没有匹配的连接。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(records.prefix(60)) { record in
                    ConnectionRow(record: record, targets: targets, showTraffic: false, onPin: { target in
                        engine.addCustomRule(pattern: record.host, policy: target)
                    }, onClose: nil)
                }
                HStack {
                    Spacer()
                    Button("清空") { engine.clearHistory() }
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
    var onClose: (() -> Void)?

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
                    Button("让 \(record.host) \(target.actionTitle)") { onPin(target) }
                }
                Divider()
            }
            Button("复制目标") { TerminalCommands.copy(record.target) }
            if let onClose {
                Button("断开这条连接", role: .destructive) { onClose() }
            }
        }
    }

    private var sourceLine: String {
        var parts = [record.isShare ? "\(record.client)（设备）" : record.source]
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
