import AppKit
import SwiftUI

// MARK: - 特权助手

/// 特权助手的状态和安装、卸载按钮（增强模式和网关模式共用）。
struct HelperRow: View {
    @ObservedObject var helper: HelperManager

    var body: some View {
        LabeledContent(L("特权助手")) {
            HStack(spacing: 8) {
                if helper.busy {
                    ProgressView()
                        .controlSize(.small)
                }
                statusText
                switch helper.state {
                case .unknown:
                    EmptyView()
                case .notInstalled:
                    Button(L("安装…")) { Task { await helper.install() } }
                        .disabled(helper.busy)
                case .notRunning, .outdated:
                    Button(L("重新安装…")) { Task { await helper.install() } }
                        .disabled(helper.busy)
                case .ready:
                    Menu(L("管理")) {
                        Button(L("重新安装（更新内核）…")) { Task { await helper.install() } }
                        Button(L("卸载…"), role: .destructive) { Task { await helper.uninstall() } }
                    }
                    .fixedSize()
                    .disabled(helper.busy)
                }
            }
        }
        if let error = helper.lastError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        switch helper.state {
        case .ready:
            Label(helper.summary, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .multilineTextAlignment(.trailing)
        case .unknown:
            Text(helper.summary)
                .foregroundStyle(.secondary)
        default:
            Text(helper.summary)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 增强模式

/// 高级页里的增强模式：不认系统代理的程序也经过代理引擎。
struct TunSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var helper: HelperManager

    var body: some View {
        Section(L("增强模式（虚拟网卡）")) {
            Toggle(L("所有程序的流量都经过代理引擎"), isOn: Binding(get: { state.tun.enabled }, set: { state.setTunEnabled($0) }))
            HelperRow(helper: helper)
            if state.tun.enabled || state.tun.gateway {
                LabeledContent(L("状态")) { TunStatusView(state: state, engine: engine, helper: helper) }
            }
            Picker(L("协议栈"), selection: Binding(get: { state.tun.stack }, set: { value in
                var tun = state.tun
                tun.stack = value
                state.setTun(tun)
            })) {
                ForEach(TunStack.allCases) { stack in
                    Text(stack.title).tag(stack)
                }
            }
            Picker("DNS", selection: Binding(get: { state.tun.dnsMode }, set: { value in
                var tun = state.tun
                tun.dnsMode = value
                state.setTun(tun)
            })) {
                ForEach(TunDNSMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            Text(L("系统代理只管认它的程序；终端里的命令、游戏和一些应用不认，照样直连。增强模式开一块虚拟网卡接管这台 Mac 的全部流量（DNS 查询也交给内核），按同样的规则和节点走。只在本机开着代理引擎时生效，关掉代理或者换成别的配置就自动停。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("虚拟网卡要管理员权限：第一次用时装一个特权助手（输一次密码），它只听你这个账户的话，只运行自己那份内核。「虚拟 IP」模式下 DNS 先回一个 198.18 开头的地址、连接时再按域名分流，不依赖本地 DNS 的解析结果；个别程序不适应时换成「真实 IP」。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// 虚拟网卡现在的情况。
struct TunStatusView: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var helper: HelperManager

    var body: some View {
        switch engine.tunStatus {
        case .on:
            Label(state.tunSummary, systemImage: "checkmark.circle")
                .foregroundStyle(.green)
                .multilineTextAlignment(.trailing)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text(state.tunSummary)
                    .foregroundStyle(.secondary)
            }
        case .failed:
            Label(state.tunSummary, systemImage: "xmark.circle")
                .foregroundStyle(.red)
                .multilineTextAlignment(.trailing)
        case .off:
            Text(state.tunSummary)
                .foregroundStyle(helper.isReady ? Color.secondary : Color.orange)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 网关模式

/// 共享页里的网关模式：设备不用填代理，把路由器和 DNS 设成这台 Mac。
struct GatewaySection: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var helper: HelperManager
    @State private var copied = false

    var body: some View {
        Section(L("网关模式")) {
            Toggle(L("让设备把这台 Mac 当路由器"), isOn: Binding(get: { state.tun.gateway }, set: { state.setGatewayEnabled($0) }))
            HelperRow(helper: helper)
            if state.tun.gateway {
                LabeledContent(L("状态")) { TunStatusView(state: state, engine: engine, helper: helper) }
                if let address = state.lanAddress {
                    LabeledContent(L("路由器（网关）")) { addressView(address.ip) }
                    LabeledContent("DNS") { addressView(address.ip) }
                } else {
                    Text(L("这台 Mac 现在没有局域网地址"))
                        .foregroundStyle(.orange)
                }
            }
            Text(L("电视、游戏机、智能设备这类不能填代理、或者填了也有程序不走的设备，在网络设置里把 IP 改成手动（同一网段里一个空闲的地址，子网掩码和原来一样），「路由器」和 DNS 都填上面的地址，就经这台 Mac 上网。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(L("设备跟着本机走：本机开着代理引擎就用同样的节点和分流规则，本机用别的代理就转发给它，没开代理就直接上网；设备规则同样生效。这台 Mac 的地址最好在路由器里固定下来；开着 macOS 防火墙时要允许内核接受传入连接。要用到特权助手，和增强模式是同一个。"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func addressView(_ ip: String) -> some View {
        HStack(spacing: 6) {
            Text(ip)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
            Button {
                TerminalCommands.copy(ip)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L("复制"))
        }
    }
}
