import AppKit
import SwiftUI

/// 自动化页：本机控制接口（命令行、AI 助手）、URL 命令、按网络自动切换和操作记录。
struct AutomationPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var control: ControlService
    @ObservedObject var network: NetworkAutomation
    @State private var cliInstalled = CommandLineInstaller.isInstalled
    @State private var cliNeedsUpdate = CommandLineInstaller.needsUpdate
    @State private var installing = false
    @State private var installProblem: String?
    @State private var showInstructions = false
    @State private var copied: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "自动化", subtitle: "让命令行、快捷指令和系统里的 AI 助手按规则操作 Proxi；换了网络自动切换")
            Form {
                interfaceSection
                cliSection
                mcpSection
                urlSection
                NetworkRulesSection(state: state, network: network)
                changesSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { refreshCLI() }
    }

    // MARK: - 接口

    private var interfaceSection: some View {
        Section("本机控制接口") {
            Picker("权限", selection: $state.config.automation.permission) {
                ForEach(ControlPermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            Text(state.config.automation.permission.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("状态") {
                if let problem = control.problem {
                    Label(problem, systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                } else if control.listening {
                    Label("在监听", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text("已关闭")
                        .foregroundStyle(.secondary)
                }
            }
            if let last = control.lastCall {
                LabeledContent("最近一次调用", value: "\(clientTitle(last.client)) · \(last.tool) · \(Engine.relative(last.date))")
            }
            Text("命令行和 AI 助手经本机的套接字（\(UnixSocket.defaultPath)）操作 Proxi，只有这台 Mac 上你自己的账户能连。改配置的操作都记在下面的操作记录里，可以撤销。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func clientTitle(_ client: String) -> String {
        ControlChange(client: client, tool: "", summary: "").clientTitle
    }

    // MARK: - 命令行

    private var cliSection: some View {
        Section("命令行") {
            HStack {
                if cliNeedsUpdate {
                    Label("命令行工具指向的程序已经不在了（比如改名前的 ProxySwitch.app），要更新", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if cliInstalled {
                    Label("已安装：\(CommandLineInstaller.path)" + (CommandLineInstaller.legacyInstalled ? "（改名前的 proxyswitch 也能用）" : ""), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text("安装后在终端里直接用 proxi 命令")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if installing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(cliNeedsUpdate ? "更新" : (cliInstalled ? "卸载" : "安装命令行工具")) { toggleCLI() }
                    .disabled(installing)
            }
            if let installProblem {
                Text(installProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(["proxi status", "proxi node 香港", "proxi rule add openai.com 美国", "proxi import ~/Downloads/config.yaml --preview", "proxi services"], id: \.self) { command in
                copyRow(command)
            }
            Text("会在 /usr/local/bin 放一个小脚本（要输一次管理员密码）。不装也可以直接运行 \(CommandLineInstaller.executablePath) status。proxi help 看全部命令，加 --json 输出 JSON。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func toggleCLI() {
        installing = true
        installProblem = nil
        let uninstalling = cliInstalled && !cliNeedsUpdate
        Task { @MainActor in
            do {
                if uninstalling {
                    try await CommandLineInstaller.uninstall()
                } else {
                    try await CommandLineInstaller.install()
                }
            } catch {
                installProblem = error.localizedDescription
            }
            refreshCLI()
            installing = false
        }
    }

    private func refreshCLI() {
        cliInstalled = CommandLineInstaller.isInstalled
        cliNeedsUpdate = CommandLineInstaller.needsUpdate
    }

    // MARK: - AI 助手

    private var mcpSection: some View {
        Section("AI 助手（MCP）") {
            Text("支持 MCP 的 AI 客户端（Claude Desktop、Claude Code、Cursor 等）加上下面的配置后，就能直接让 AI 查看状态、切节点、诊断网址、加规则、导入配置，不用自己动手。它能做到哪一步由上面的权限决定。")
                .font(.caption)
                .foregroundStyle(.secondary)
            codeBlock(CommandLineInstaller.mcpConfig, label: "配置文件里的 mcpServers")
            copyRow(CommandLineInstaller.mcpCommand)
            DisclosureGroup("给 AI 助手的规则（\(ControlCatalog.tools.count) 个工具）", isExpanded: $showInstructions) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(ControlCatalog.instructions)
                        .font(.system(size: 11))
                        .textSelection(.enabled)
                    Divider()
                    ForEach(ControlCatalog.tools, id: \.name) { tool in
                        HStack(alignment: .top) {
                            Text(tool.name)
                                .font(.system(size: 11, design: .monospaced))
                                .frame(width: 150, alignment: .leading)
                            Text(tool.title)
                                .font(.system(size: 11))
                            Spacer()
                            Text(tool.permission.title)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - URL 命令

    private var urlSection: some View {
        Section("URL 命令与快捷指令") {
            ForEach(["proxi://toggle", "proxi://node?name=香港", "proxi://mode?value=global", "proxi://tun/on", "proxi://group?name=流媒体&member=日本", "proxi://run?tool=check_services", "proxi://import?url=https://example.com/config.yaml"], id: \.self) { command in
                copyRow("open \"\(command)\"")
            }
            Text("快捷指令里用「打开 URL」执行这些命令，或者用「运行 Shell 脚本」调用 proxi 命令。URL 命令不能直接改配置：导入会先打开预览让你确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 操作记录

    private var changesSection: some View {
        Section("操作记录") {
            if control.changes.isEmpty {
                Text("命令行、AI 助手和导入做过的改动会记在这里，改配置的可以撤销。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(control.changes) { change in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.summary)
                                .font(.system(size: 12))
                                .strikethrough(change.undone)
                                .lineLimit(2)
                            Text("\(change.clientTitle) · \(Engine.relative(change.date))" + (change.undone ? " · 已撤销" : ""))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if change.canUndo {
                            Button("撤销") { control.undo(change.id) }
                                .controlSize(.small)
                                .help("回到这次改动之前的配置（之后的改动也会一起撤销）")
                        }
                    }
                }
                HStack {
                    Spacer()
                    Button("清空记录") { control.clearJournal() }
                        .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 小部件

    private func copyRow(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                TerminalCommands.copy(text)
                copied = text
            } label: {
                Image(systemName: copied == text ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("复制")
        }
    }

    private func codeBlock(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button(copied == text ? "已复制" : "复制") {
                    TerminalCommands.copy(text)
                    copied = text
                }
                .controlSize(.small)
            }
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
    }
}

// MARK: - 按网络自动切换

struct NetworkRulesSection: View {
    @ObservedObject var state: AppState
    @ObservedObject var network: NetworkAutomation
    @State private var matchKind = "current"
    @State private var ssid = ""
    @State private var action = "off"

    var body: some View {
        Section("按网络自动切换") {
            Toggle("换了网络时按规则自动切换", isOn: $state.config.automation.networkSwitching)
            LabeledContent("现在的网络") {
                Text(network.identity.summary)
                    .foregroundStyle(.secondary)
            }
            if !network.canReadWiFiName {
                HStack {
                    Label("读不到 Wi‑Fi 名字：macOS 要求定位权限", systemImage: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("允许读取") { network.requestLocation() }
                        .controlSize(.small)
                }
            }
            ForEach(state.config.automation.networkRules) { rule in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { rule.enabled }, set: { value in
                        update(rule.id) { $0.enabled = value }
                    }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    Text(rule.match.title)
                        .font(.system(size: 12))
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                    Text(rule.action.title(profiles: state.config.profiles))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button {
                        state.config.automation.networkRules.removeAll { $0.id == rule.id }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Picker("", selection: $matchKind) {
                    Text("现在的网络").tag("current")
                    Text("Wi‑Fi 名字").tag("ssid")
                    Text("其他网络").tag("other")
                }
                .labelsHidden()
                .frame(width: 120)
                if matchKind == "ssid" {
                    TextField("", text: $ssid, prompt: Text("Wi‑Fi 名字"))
                        .frame(minWidth: 80, maxWidth: 140)
                } else if matchKind == "current" {
                    Text(network.currentMatch?.title ?? "没有连接网络")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Picker("", selection: $action) {
                    Text("关闭代理").tag("off")
                    Text("规则分流").tag("mode:rule")
                    Text("全局代理").tag("mode:global")
                    ForEach(state.config.profiles) { profile in
                        Text("开启「\(profile.name)」").tag("profile:" + profile.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 110, maxWidth: 160)
                Spacer(minLength: 0)
                Button("添加") { add() }
                    .disabled(match == nil)
            }
            if let last = network.lastSwitch {
                Text("最近一次：\(last.summary)（\(Engine.relative(last.date))）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("比如在公司的 Wi‑Fi 自动开公司代理、回家自动关掉，或者连上手机热点时切到全局代理。同一个网络只切一次，之后你手动改了不会被改回去。认 Wi‑Fi 名字要定位权限；不给的话可以按路由器（MAC 地址）认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var match: NetworkRule.Match? {
        switch matchKind {
        case "ssid":
            let name = ssid.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .ssid(name)
        case "other":
            return .other
        default:
            return network.currentMatch
        }
    }

    private func add() {
        guard let match, let action = NetworkRule.Action(rawValue: action) else { return }
        state.config.automation.networkRules.removeAll { $0.match == match }
        state.config.automation.networkRules.append(NetworkRule(match: match, action: action))
        ssid = ""
    }

    private func update(_ id: UUID, _ change: (inout NetworkRule) -> Void) {
        guard let index = state.config.automation.networkRules.firstIndex(where: { $0.id == id }) else { return }
        change(&state.config.automation.networkRules[index])
    }
}
