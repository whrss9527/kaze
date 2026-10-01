import AppKit
import SwiftUI

/// 自动化页：本机控制接口（命令行、AI 助手）、URL 命令、按网络自动切换。
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
            PageHeader(title: L("自动化"), subtitle: L("让命令行、快捷指令和系统里的 AI 助手按规则操作 Proxi；换了网络自动切换"))
            Form {
                interfaceSection
                cliSection
                mcpSection
                urlSection
                NetworkRulesSection(state: state, network: network)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { refreshCLI() }
    }

    // MARK: - 接口

    private var interfaceSection: some View {
        Section(L("本机控制接口")) {
            Picker(L("权限"), selection: $state.config.automation.permission) {
                ForEach(ControlPermission.allCases) { permission in
                    Text(permission.title).tag(permission)
                }
            }
            Text(state.config.automation.permission.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent(L("状态")) {
                if let problem = control.problem {
                    Label(problem, systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                } else if control.listening {
                    Label(L("在监听"), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text(L("已关闭"))
                        .foregroundStyle(.secondary)
                }
            }
            if let last = control.lastCall {
                LabeledContent(L("最近一次调用"), value: "\(ControlService.clientTitle(last.client)) · \(last.tool) · \(Self.relative(last.date))")
            }
            Text(L("命令行和 AI 助手经本机的套接字（%@）操作 Proxi，只有这台 Mac 上你自己的账户能连。它们只能查看状态、开关代理和切换配置，不能改配置。", UnixSocket.defaultPath))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 「3 分钟前」这样的相对时间。
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = AppLanguage.locale
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - 命令行

    private var cliSection: some View {
        Section(L("命令行")) {
            HStack {
                if cliNeedsUpdate {
                    Label(L("命令行工具指向的程序已经不在了（比如改名前的 ProxySwitch.app），要更新"), systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else if cliInstalled {
                    Label(L("已安装：%@", CommandLineInstaller.path) + (CommandLineInstaller.legacyInstalled ? L("（改名前的 proxyswitch 也能用）") : ""), systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Text(L("安装后在终端里直接用 proxi 命令"))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if installing {
                    ProgressView()
                        .controlSize(.small)
                }
                Button(cliNeedsUpdate ? L("更新") : (cliInstalled ? L("卸载") : L("安装命令行工具"))) { toggleCLI() }
                    .disabled(installing)
            }
            if let installProblem {
                Text(installProblem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            ForEach(["proxi status", L("proxi use 公司代理"), "proxi off", "proxi test", "proxi profiles --json"], id: \.self) { command in
                copyRow(command)
            }
            Text(L("会在 /usr/local/bin 放一个小脚本（要输一次管理员密码）。不装也可以直接运行 %@ status。proxi help 看全部命令，加 --json 输出 JSON。", CommandLineInstaller.executablePath))
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
        Section(L("AI 助手（MCP）")) {
            Text(L("支持 MCP 的 AI 客户端（Claude Desktop、Claude Code、Cursor 等）加上下面的配置后，就能让 AI 查看代理状态、开关代理、切换配置和测试连接。它能做到哪一步由上面的权限决定。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            codeBlock(CommandLineInstaller.mcpConfig, label: L("配置文件里的 mcpServers"))
            copyRow(CommandLineInstaller.mcpCommand)
            DisclosureGroup(L("给 AI 助手的规则（%@ 个工具）", ControlCatalog.tools.count), isExpanded: $showInstructions) {
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
        Section(L("URL 命令与快捷指令")) {
            ForEach(["proxi://toggle", "proxi://on", "proxi://off", L("proxi://use?name=公司代理"), "proxi://run?tool=test_profiles"], id: \.self) { command in
                copyRow("open \"\(command)\"")
            }
            Text(L("快捷指令里用「打开 URL」执行这些命令，或者用「运行 Shell 脚本」调用 proxi 命令。"))
                .font(.caption)
                .foregroundStyle(.secondary)
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
            .help(L("复制"))
        }
    }

    private func codeBlock(_ text: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Button(copied == text ? L("已复制") : L("复制")) {
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
        Section(L("按网络自动切换")) {
            Toggle(L("换了网络时按规则自动切换"), isOn: $state.config.automation.networkSwitching)
            LabeledContent(L("现在的网络")) {
                Text(network.identity.summary)
                    .foregroundStyle(.secondary)
            }
            if !network.canReadWiFiName {
                HStack {
                    Label(L("读不到 Wi‑Fi 名字：macOS 要求定位权限"), systemImage: "location.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer()
                    Button(L("允许读取")) { network.requestLocation() }
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
                    Text(L("现在的网络")).tag("current")
                    Text(L("Wi‑Fi 名字")).tag("ssid")
                    Text(L("其他网络")).tag("other")
                }
                .labelsHidden()
                .frame(width: 120)
                if matchKind == "ssid" {
                    TextField("", text: $ssid, prompt: Text(L("Wi‑Fi 名字")))
                        .frame(minWidth: 80, maxWidth: 140)
                } else if matchKind == "current" {
                    Text(network.currentMatch?.title ?? L("没有连接网络"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Picker("", selection: $action) {
                    Text(L("关闭代理")).tag("off")
                    ForEach(state.config.profiles) { profile in
                        Text(L("开启「%@」", profile.name)).tag("profile:" + profile.id.uuidString)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 110, maxWidth: 160)
                Spacer(minLength: 0)
                Button(L("添加")) { add() }
                    .disabled(match == nil)
            }
            if let last = network.lastSwitch {
                Text(L("最近一次：%@（%@）", last.summary, AutomationPage.relative(last.date)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(L("比如在公司的 Wi‑Fi 自动开公司代理、回家自动关掉。同一个网络只切一次，之后你手动改了不会被改回去。认 Wi‑Fi 名字要定位权限；不给的话可以按路由器（MAC 地址）认。"))
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
