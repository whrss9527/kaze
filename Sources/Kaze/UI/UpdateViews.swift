import AppKit
import SwiftUI

/// 面板里的更新条：有新版本时出现，一键更新，显示进度和结果。
struct UpdateBanner: View {
    @ObservedObject var updater: Updater
    var openDetails: () -> Void

    var body: some View {
        if let release = updater.release {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(iconColor)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title(release))
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    switch updater.phase {
                    case .downloading(_, let fraction):
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                    case .failed(_, let message):
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    default:
                        Text(subtitle(release))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { openDetails() }
                .help("查看更新内容")
                Spacer(minLength: 4)
                trailing
            }
            .padding(10)
            .glassCard()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch updater.phase {
        case .available:
            Button("更新") { updater.install() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .downloading(_, let fraction):
            HStack(spacing: 6) {
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Button {
                    updater.cancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("取消更新")
            }
        case .verifying, .installing, .relaunching:
            ProgressView()
                .controlSize(.small)
        case .failed:
            Button("重试") { updater.install() }
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private var symbol: String {
        switch updater.phase {
        case .failed: return "xmark.octagon.fill"
        case .relaunching: return "checkmark.circle.fill"
        default: return "sparkles"
        }
    }

    private var iconColor: Color {
        switch updater.phase {
        case .failed: return .red
        case .relaunching: return .green
        default: return .accentColor
        }
    }

    private func title(_ release: ReleaseInfo) -> String {
        switch updater.phase {
        case .downloading: return "正在下载 \(release.version)" + (updater.route.map { " · 经\($0.title)" } ?? "")
        case .verifying: return "正在校验 \(release.version)"
        case .installing: return "正在安装 \(release.version)"
        case .relaunching: return "已更新到 \(release.version)，正在重新启动"
        case .failed: return "更新到 \(release.version) 失败"
        default: return "有新版本 \(release.version)"
        }
    }

    private func subtitle(_ release: ReleaseInfo) -> String {
        switch updater.phase {
        case .verifying, .installing: return "马上就好，请不要退出"
        case .relaunching: return "程序会自动重新打开"
        default:
            if let size = release.archiveSize {
                return "下载 \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)) 后自动安装并重新启动"
            }
            return "点「更新」自动下载安装并重新启动"
        }
    }
}

/// 关于页里的更新区域：检查、版本说明、一键更新、进度和错误。
struct UpdateSection: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(spacing: 12) {
            switch updater.phase {
            case .idle, .upToDate:
                HStack(spacing: 10) {
                    if case .upToDate = updater.phase {
                        Label("已经是最新版本", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(lastCheckedText)
                            .foregroundStyle(.secondary)
                    }
                    checkButton
                }
                .font(.system(size: 12))
            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查更新…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            case .skipped(let release):
                HStack(spacing: 10) {
                    Text("已跳过 \(release.version)")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("仍然查看") { updater.showSkippedVersion() }
                    checkButton
                }
            case .available(let release):
                availableView(release)
            case .downloading(let release, let fraction):
                progressView(title: "正在下载 \(release.version)…" + (updater.route.map { "（经\($0.title)）" } ?? ""), fraction: fraction, cancellable: true)
            case .verifying(let release):
                progressView(title: "正在校验 \(release.version)…", fraction: nil, cancellable: false)
            case .installing(let release):
                progressView(title: "正在安装 \(release.version)…", fraction: nil, cancellable: false)
            case .relaunching(let release):
                progressView(title: "已更新到 \(release.version)，正在重新启动…", fraction: 1, cancellable: false)
            case .failed(let release, let message):
                failedView(release, message)
            }
            if let error = updater.checkError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var checkButton: some View {
        Button("检查更新") {
            Task { await updater.check(manual: true) }
        }
    }

    private var lastCheckedText: String {
        guard let date = updater.lastChecked else { return "还没有检查过更新" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return "上次检查：\(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private func availableView(_ release: ReleaseInfo) -> some View {
        VStack(spacing: 10) {
            Label("有新版本 \(release.version)", systemImage: "sparkles")
                .font(.system(size: 14, weight: .semibold))
            if let date = release.publishedAt {
                Text("发布于 \(Self.dateFormatter.string(from: date))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !release.notes.isEmpty {
                ReleaseNotes(text: release.notes)
                    .lineLimit(12)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            }
            let problem = updater.installProblem ?? (release.canInstall ? nil : UpdateError.noArchive.localizedDescription)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("到发布页下载") { NSWorkspace.shared.open(release.pageURL) }
                    Button("跳过这个版本") { updater.skipAvailableVersion() }
                }
            } else {
                HStack(spacing: 10) {
                    Button {
                        updater.install()
                    } label: {
                        Label("立即更新", systemImage: "arrow.down.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    Button("跳过这个版本") { updater.skipAvailableVersion() }
                }
                Text(installHint(release))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let note = updater.relocationNote {
                    Label(note, systemImage: "arrow.right.doc.on.clipboard")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                pageLink(release)
            }
        }
    }

    /// 发布页只作为不显眼的备用入口。
    private func pageLink(_ release: ReleaseInfo) -> some View {
        Button("在浏览器里查看发布页") { NSWorkspace.shared.open(release.pageURL) }
            .buttonStyle(.link)
            .font(.caption)
    }

    private func installHint(_ release: ReleaseInfo) -> String {
        var text = "点一下就行：下载"
        if let size = release.archiveSize {
            text += " \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))"
        }
        return text + "，校验后替换程序并自动重新启动，配置不会丢。内置代理在运行时经它下载。"
    }

    private func progressView(title: String, fraction: Double?, cancellable: Bool) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 260)
                if let fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if cancellable {
                    Button("取消") { updater.cancel() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func failedView(_ release: ReleaseInfo, _ message: String) -> some View {
        VStack(spacing: 10) {
            Label(message, systemImage: "xmark.octagon.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                if updater.lastFailure == .appManagement {
                    Button("打开「App 管理」设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                    }
                }
                if release.canInstall, updater.installProblem == nil {
                    Button("重试") { updater.install() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("到发布页下载") { NSWorkspace.shared.open(release.pageURL) }
                }
                checkButton
            }
            if release.canInstall, updater.installProblem == nil {
                pageLink(release)
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// 发布说明：GitHub 的 Markdown 简单渲染，列表项换成圆点。
struct ReleaseNotes: View {
    var text: String

    var body: some View {
        Text(Self.attributed(text))
            .font(.system(size: 12))
            .textSelection(.enabled)
    }

    static func cleaned(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.drop { $0 == " " }
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                    return "• " + trimmed.dropFirst(2)
                }
                if trimmed.hasPrefix("#") {
                    return String(trimmed.drop { $0 == "#" || $0 == " " })
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    static func attributed(_ text: String) -> AttributedString {
        let cleaned = cleaned(text)
        if let attributed = try? AttributedString(markdown: cleaned, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(cleaned)
    }
}
