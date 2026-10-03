import AppKit
import SwiftUI

/// 设置里的「扩展」页：可选的附加功能，默认都关着。现在只有一个「代理引擎」。
struct ExtensionsPage: View {
    @ObservedObject var state: AppState
    @ObservedObject var extensions: ExtensionManager
    @State private var showingDisclaimer = false
    @State private var working = false

    private var enabled: Bool { state.persisted.extensionState.enabled }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: L("扩展"), subtitle: L("可选的附加功能，默认关闭；不开启时不会下载任何东西，也不会联网"))
            Form {
                Section {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.system(size: 22))
                            .foregroundStyle(enabled ? Color.accentColor : Color.secondary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("代理引擎（扩展）"))
                                .font(.system(size: 13, weight: .semibold))
                            Text(L("一个在本机运行的代理引擎，作为单独的程序下载安装，不包含在 Proxi 里。开启后配置列表里会多一条「代理引擎」，用同一个开关使用。它在后台运行，菜单栏上不另放图标；它自己的设置从 Proxi 的右键菜单或面板底部的「代理引擎设置」打开。"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { enabled }, set: { toggle($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .disabled(working)
                    }
                    if enabled {
                        statusRows
                    }
                    Button(L("了解更多")) { NSWorkspace.shared.open(AppInfo.extensionDocsURL) }
                        .buttonStyle(.link)
                }
                if enabled, let date = state.persisted.extensionState.acceptedAt {
                    Section {
                        Text(L("已于 %@ 同意使用说明。", date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale))))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showingDisclaimer) {
            ExtensionDisclaimerView(restoring: state.willRestoreEngineProfile, onEnable: {
                showingDisclaimer = false
                state.enableExtension()
            }, onCancel: {
                showingDisclaimer = false
            })
        }
        .onAppear { extensions.refreshInstalled() }
    }

    @ViewBuilder
    private var statusRows: some View {
        LabeledContent(L("状态")) {
            switch extensions.phase {
            case .checking:
                progress(L("正在获取下载地址…"), nil)
            case .downloading(let fraction):
                progress(L("正在下载…"), fraction)
            case .verifying:
                progress(L("正在校验…"), nil)
            case .installing:
                progress(L("正在安装…"), nil)
            case .failed(let message):
                VStack(alignment: .trailing, spacing: 4) {
                    Text(message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                    Button(L("重试")) { extensions.prepareAndLaunch() }
                }
            case .idle:
                Text(statusText)
                    .foregroundStyle(extensions.isRunning ? Color.green : Color.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        if let version = extensions.installedVersion {
            LabeledContent(L("版本"), value: version)
        }
        HStack {
            Button(L("代理引擎设置…")) { extensions.showSettings() }
                .disabled(!extensions.isInstalled || extensions.isBusy)
            Button(L("重新下载")) {
                Task { @MainActor in
                    try? FileManager.default.removeItem(at: ExtensionManager.appURL)
                    extensions.refreshInstalled()
                    extensions.prepareAndLaunch()
                }
            }
            .disabled(extensions.isBusy)
            Spacer()
            Button(L("关闭并移除…"), role: .destructive) {
                working = true
                Task { @MainActor in
                    await state.disableExtension(removeApp: true)
                    working = false
                }
            }
            .disabled(working || extensions.isBusy)
        }
        Text(L("关闭扩展会先关掉正在用的「代理引擎」配置、恢复系统设置，再退出代理引擎。「关闭并移除」还会删掉下载的程序；它的数据（%@）留着，以后再开启时还在。", ExtensionManager.dataDirectory.path))
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
    }

    private var statusText: String {
        if let status = extensions.status {
            return status.coreRunning ? L("运行中，本机端口 %@", String(status.mixedPort)) : status.summary
        }
        return extensions.isInstalled ? L("没在运行") : L("还没有安装")
    }

    private func progress(_ text: String, _ fraction: Double?) -> some View {
        HStack(spacing: 6) {
            if let fraction {
                ProgressView(value: fraction)
                    .frame(width: 120)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(text)
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ on: Bool) {
        if on {
            // 每次开启都要先看说明、勾选同意。
            showingDisclaimer = true
        } else {
            working = true
            Task { @MainActor in
                await state.disableExtension(removeApp: false)
                working = false
            }
        }
    }
}

/// 开启扩展前的说明：要勾选「我已阅读并同意」才能开启。只在扩展页里打开开关时显示。
struct ExtensionDisclaimerView: View {
    /// 从以前的版本更新过来时开着的是代理引擎那条配置：开启后会自动开回来。
    let restoring: Bool
    let onEnable: () -> Void
    let onCancel: () -> Void
    @State private var agreed = false

    /// 说明的正文（中文界面的；英文的在翻译表里）。改了意思要把 ExtensionManager.disclaimerVersion 加一。
    static var text: String {
        L("本功能仅供学习、研究网络技术及合法的开发调试使用，不得用于任何违反所在国家或地区法律法规的用途。\n\n1. 开发者不提供任何代理服务、服务器或订阅，也不对第三方提供的内容负责；\n2. 使用者应自行确认其使用行为符合当地法律法规，并独立承担因使用本功能产生的全部责任；\n3. 请在下载后 24 小时内自行评估是否继续使用；如不同意上述条款，请勿开启本功能。\n\n开启即表示你已阅读并同意以上条款。")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.accentColor)
                Text(L("开启代理引擎（扩展）"))
                    .font(.system(size: 16, weight: .semibold))
            }
            if restoring {
                Label(L("以前开着的「代理引擎」配置已经先关掉了，开启扩展后会自动开回来。"), systemImage: "power")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(L("使用说明"))
                .font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(Self.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            Toggle(L("我已阅读并同意"), isOn: $agreed)
                .toggleStyle(.checkbox)
            Text(L("开启后会从 GitHub 上这个版本的发布下载代理引擎（核对校验和与签名），它第一次运行时再下载内核。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("取消")) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button(L("开启")) { onEnable() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!agreed)
            }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 480)
    }
}
