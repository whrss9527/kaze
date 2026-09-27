import AppKit
import SwiftUI

/// 从别处发起的诊断请求（proxyswitch://diagnose、面板按钮）。
struct DiagnoseRequest: Equatable {
    var url: String
    var device: Bool
}

/// 网址诊断页：填一个网址，把链路走一遍，逐项亮灯，最后给一句结论和修复按钮。
struct DiagnosePage: View {
    @ObservedObject var state: AppState
    @ObservedObject var engine: Engine
    @ObservedObject var navigation: SettingsNavigation
    @StateObject private var diagnoser: Diagnoser
    @State private var urlText = ""
    @State private var perspective: DiagnoseTarget.Perspective = .mac
    @State private var problem: String?
    @State private var copied = false

    init(state: AppState, engine: Engine, navigation: SettingsNavigation) {
        self.state = state
        self.engine = engine
        self.navigation = navigation
        _diagnoser = StateObject(wrappedValue: Diagnoser(state: state, engine: engine))
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "网址诊断", subtitle: "某个网站打不开？把链路走一遍，告诉你卡在哪、怎么修")
            Form {
                inputSection
                resultsSection
                verdictSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .onAppear { takeRequest() }
        .onChange(of: navigation.diagnoseRequest) { _, _ in takeRequest() }
    }

    // MARK: - 输入

    private var inputSection: some View {
        Section("要检查什么") {
            HStack {
                TextField("", text: $urlText, prompt: Text("网址或域名，比如 youtube.com"))
                    .labelsHidden()
                    .onSubmit { start() }
                Button(diagnoser.running ? "停止" : "开始诊断") {
                    if diagnoser.running { diagnoser.cancel() } else { start() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!diagnoser.running && urlText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("从谁的视角", selection: $perspective) {
                ForEach(DiagnoseTarget.Perspective.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text(perspective == .device ? "从共享入口走一遍，和 PS5 等设备走的路径完全一样：共享入口 → 规则 → 上游。" : "按这台 Mac 现在的代理状态走一遍：直连、经代理、DNS、节点，逐项对比。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 结果

    private var resultsSection: some View {
        Section("检查结果") {
            if diagnoser.rows.isEmpty {
                Text("填好网址点「开始诊断」。剪贴板里有网址的话会自动填上。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(diagnoser.rows) { row in
                HStack(alignment: .top, spacing: 10) {
                    outcomeIcon(row.outcome)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: 12, weight: .semibold))
                        if !row.summary.isEmpty {
                            Text(row.summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if !row.detail.isEmpty {
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private func outcomeIcon(_ outcome: CheckRow.Outcome) -> some View {
        switch outcome {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.tertiary)
        case .running:
            ProgressView().controlSize(.small)
        case .pass:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .warn:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .fail:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        }
    }

    // MARK: - 结论

    private var verdictSection: some View {
        Section("结论") {
            if let verdict = diagnoser.verdict {
                Text(verdict.headline)
                    .font(.system(size: 14, weight: .semibold))
                Text(verdict.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    ForEach(Array(verdict.actions.enumerated()), id: \.offset) { item in
                        Button(item.element == .copyReport && copied ? "已复制" : item.element.title) {
                            perform(item.element)
                        }
                    }
                    Button("再测一次") { start() }
                        .disabled(diagnoser.running)
                }
                .controlSize(.small)
            } else if diagnoser.running {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在检查…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("检查完会在这里告诉你原因和怎么修。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 动作

    private func takeRequest() {
        if let request = navigation.diagnoseRequest {
            navigation.diagnoseRequest = nil
            perspective = request.device ? .device : .mac
            if !request.url.isEmpty {
                urlText = request.url
                start()
            }
            return
        }
        // 剪贴板里有网址就先填上，省得再敲。
        if urlText.isEmpty, let pasted = NSPasteboard.general.string(forType: .string), pasted.count < 200, pasted.contains("."), DiagnoseTarget.normalize(pasted) != nil {
            urlText = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func start() {
        guard let url = DiagnoseTarget.normalize(urlText) else {
            problem = "认不出这个网址：填 youtube.com 或者 https://… 这样的地址"
            return
        }
        problem = nil
        urlText = url.absoluteString
        diagnoser.run(DiagnoseTarget(url: url, perspective: perspective))
    }

    private func perform(_ action: Verdict.Action) {
        switch action {
        case .turnOnEngine:
            state.selectEngineProfile()
            if let profile = state.engineProfile {
                state.turnOn(profile)
            } else {
                navigation.page = .nodes
            }
        case .pinToProxy(let host):
            engine.addCustomRule(pattern: host, policy: .proxy)
            // 内核热加载规则要一会儿，再测一次看效果。
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                start()
            }
        case .autoSelect:
            Task { await engine.select(nil) }
        case .testNodes:
            Task { await engine.testAll() }
        case .openNodes:
            navigation.page = .nodes
        case .openShare:
            navigation.page = .share
        case .copyReport:
            TerminalCommands.copy(diagnoser.reportText)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
    }
}
