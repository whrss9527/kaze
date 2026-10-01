import AppKit
import SwiftUI

/// 导入配置：粘贴内容、选文件或填网址，先预览会改动什么，确认后再导入。导入记在操作记录里，可以撤销。
struct ImportSheet: View {
    @ObservedObject var state: AppState
    /// 从外面带进来的网址或文件（proxi://import、拖进窗口的文件）。
    var initial: String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var address = ""
    @State private var sourceName = L("粘贴的内容")
    @State private var plan: ImportPlan?
    @State private var mode: ImportMode = .merge
    @State private var loading = false
    @State private var problem: String?
    @State private var done: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan == nil ? L("导入配置") : L("导入预览"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(L("支持代理引擎的 JSON、mihomo 的 YAML、Surge / Quantumult X 格式的配置、节点链接和规则列表"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            Group {
                if let done {
                    doneView(done)
                } else if let plan {
                    previewView(plan)
                } else {
                    inputView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(12)
        }
        .frame(width: 640, height: 540)
        .task {
            if let initial, !initial.isEmpty {
                await load(initial)
            }
        }
    }

    // MARK: - 输入

    private var inputView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("粘贴配置内容或节点链接"))
                .font(.system(size: 12, weight: .medium))
            TextEditor(text: $text)
                .font(.system(size: 11, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                .frame(minHeight: 200)
            HStack(spacing: 8) {
                Button(L("从剪贴板粘贴")) {
                    if let string = NSPasteboard.general.string(forType: .string) {
                        text = string
                        sourceName = L("剪贴板")
                    } else {
                        let codes = QRScanner.fromPasteboard()
                        if codes.isEmpty {
                            problem = L("剪贴板里没有文字，也没有二维码图片")
                        } else {
                            text = codes.joined(separator: "\n")
                            sourceName = L("剪贴板里的二维码")
                        }
                    }
                }
                Button(L("选择文件…")) { chooseFile() }
                Spacer()
            }
            Text(L("或者填配置的网址（订阅地址、远程配置、规则列表）"))
                .font(.system(size: 12, weight: .medium))
                .padding(.top, 4)
            TextField("", text: $address, prompt: Text(L("https://…")))
                .textFieldStyle(.roundedBorder)
            Text(L("来自网址的订阅和规则会加成订阅、规则集，以后跟着自动更新；粘贴的内容存成本机文件。导入前会先给你看要改动什么。"))
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = L("选择要导入的配置文件（.json、.yaml、.conf、.txt、.list）或者节点二维码图片")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url.absoluteString) }
    }

    /// 从网址或文件读进来：文件直接读内容（图片识别二维码），网址交给预览时下载。
    private func load(_ target: String) async {
        problem = nil
        if let url = URL(string: target), url.isFileURL {
            if ["png", "jpg", "jpeg", "gif", "heic", "tiff", "bmp"].contains(url.pathExtension.lowercased()) {
                let codes = QRScanner.fromFile(url)
                guard !codes.isEmpty else {
                    problem = L("图片里没有认出二维码")
                    return
                }
                text = codes.joined(separator: "\n")
            } else {
                do {
                    text = try String(contentsOf: url, encoding: .utf8)
                } catch {
                    problem = L("读不了这个文件：%@", error.localizedDescription)
                    return
                }
            }
            sourceName = url.deletingPathExtension().lastPathComponent
            address = ""
        } else {
            address = target
            text = ""
        }
        await preview()
    }

    // MARK: - 预览

    private func previewView(_ plan: ImportPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text(plan.format.title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                    Text(plan.sourceName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("会导入"))
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(plan.summaryLines, id: \.self) { line in
                        Label(line, systemImage: "plus.circle")
                            .font(.system(size: 12))
                    }
                }
                if !plan.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("注意"))
                            .font(.system(size: 12, weight: .semibold))
                        ForEach(plan.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Picker(L("方式"), selection: $mode) {
                        ForEach(ImportMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Text(modeDetail(plan))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let problem {
                    Label(problem, systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
    }

    private func modeDetail(_ plan: ImportPlan) -> String {
        if plan.backup != nil {
            return mode == .replace ? L("用备份替换全部设置（本机的端口不变）。") : L("把备份里的订阅、节点、策略组、规则、代理配置加进现有设置，同名的更新。")
        }
        switch mode {
        case .merge: return L("加进现有设置：同名的策略组、同地址的订阅和规则集会被更新，其余的保留。")
        case .replace: return L("导入的内容替换同一类的现有设置（比如导入了策略组，原来的策略组都换掉）；没导入的类别不动。")
        }
    }

    private func doneView(_ summary: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.green)
            Text(summary)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.center)
            Text(L("内核会自动重新加载。改错了可以到「自动化」页的操作记录里撤销。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 按钮

    private var footer: some View {
        HStack {
            if plan != nil && done == nil {
                Button(L("返回修改")) {
                    plan = nil
                    problem = nil
                }
            }
            Spacer()
            if loading {
                ProgressView()
                    .controlSize(.small)
            }
            Button(done == nil ? L("取消") : L("完成")) { dismiss() }
                .keyboardShortcut(done == nil ? .cancelAction : .defaultAction)
            if done == nil {
                if let plan {
                    Button(L("导入")) { apply(plan) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(loading)
                } else {
                    Button(L("预览")) { Task { await preview() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(loading || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && address.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
        }
    }

    private func preview() async {
        loading = true
        problem = nil
        defer { loading = false }
        do {
            let content = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let result = try await state.prepareImport(text: content.isEmpty ? nil : content, url: address.isEmpty ? nil : address, sourceName: sourceName)
            plan = result
            mode = result.format == .backup ? .replace : .merge
        } catch {
            problem = error.localizedDescription
        }
    }

    private func apply(_ plan: ImportPlan) {
        let before = state.config
        do {
            let summary = try state.applyImport(plan, mode: mode)
            state.control.recordImport(summary: L("导入「%@」：%@", plan.sourceName, summary), before: before)
            done = summary
        } catch {
            problem = L("导入失败：%@", error.localizedDescription)
        }
    }
}
