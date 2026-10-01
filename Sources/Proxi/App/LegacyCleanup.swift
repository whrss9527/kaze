import Foundation

/// 0.13.0 起 Proxi 只负责切换代理：一键把系统代理、终端、git 和 npm 指向用户自己指定的代理服务器。
/// 从以前的版本更新过来后，第一次启动时在这里检查和清理以前版本留下的东西：
/// - 配置里以前版本才有的设置（读配置时已经忽略），以及由内置代理自动生成的那条配置；
/// - 这条配置开着时，代理要关掉（AppState.finishLegacyMigration 做），不然系统代理会指向一个已经不存在的本机端口；
/// - 数据目录里以前版本用的子目录和文件；
/// - 以前版本装的后台助手（要管理员密码才能删，由用户在提示里确认）。
enum LegacyCleanup {
    /// 启动时读出来的情况。
    struct Findings: Equatable {
        /// 配置里有以前版本才有的设置。
        var hadLegacySettings = false
        /// 由内置代理自动生成的配置（读配置时会去掉）。
        var builtInProfiles: [Profile] = []
        /// 上次开着的就是这样一条配置：要把它设置过的代理清掉。
        var activeBuiltIn: Profile?

        var needsNotice: Bool { hadLegacySettings || !builtInProfiles.isEmpty }
    }

    /// 现在的 config.json 和 state.json 里有的顶层键；别的键都是以前版本才有的设置。
    static let knownConfigKeys: Set<String> = [
        "profiles", "clickAction", "toggleHotkey", "offMode", "notifyLevel", "healthCheck", "disableOnExit", "testURL",
        "autoCheckUpdates", "speedDisplay", "speedSide", "speedColorFollowsStatus", "automation",
    ]
    static let knownStateKeys: Set<String> = ["lastProfileID", "enabledByUs", "original", "syncEnabled", "noticeShown"]
    /// 数据目录里以前版本用的子目录和文件。
    static let legacyDataItems = ["core", "imports", "journal.json"]

    /// 读 config.json 和 state.json 的原始内容，看有没有以前版本留下的东西。不改任何文件。
    static func inspect(configData: Data?, stateData: Data?) -> Findings {
        var findings = Findings()
        if let configData, let object = try? JSONSerialization.jsonObject(with: configData) as? [String: Any] {
            findings.hadLegacySettings = !Set(object.keys).isSubset(of: knownConfigKeys)
            if let profiles = object["profiles"] as? [Any] {
                for item in profiles where Profile.isLegacyBuiltIn(item) {
                    guard let data = try? JSONSerialization.data(withJSONObject: item),
                          let profile = try? JSONDecoder().decode(Profile.self, from: data) else { continue }
                    findings.builtInProfiles.append(profile)
                }
            }
        }
        if let stateData, let object = try? JSONSerialization.jsonObject(with: stateData) as? [String: Any] {
            if !Set(object.keys).isSubset(of: knownStateKeys) {
                findings.hadLegacySettings = true
            }
            let enabled = (object["enabledByUs"] as? Bool) ?? false
            if enabled, let text = object["lastProfileID"] as? String, let id = UUID(uuidString: text) {
                findings.activeBuiltIn = findings.builtInProfiles.first { $0.id == id }
            }
        }
        return findings
    }

    /// 读本机的文件。
    static func inspect() -> Findings {
        inspect(configData: try? Data(contentsOf: Store.configURL), stateData: try? Data(contentsOf: Store.stateURL))
    }

    /// 删掉数据目录里以前版本用的子目录和文件，返回删了哪些。
    @discardableResult
    static func removeLegacyData(in directory: URL = Store.directory) -> [String] {
        var removed: [String] = []
        for name in legacyDataItems {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if (try? FileManager.default.removeItem(at: url)) != nil {
                removed.append(name)
            }
        }
        return removed
    }

    // MARK: - 以前版本的后台助手

    /// 这些名字是以前版本定下的。
    enum Helper {
        static let label = "com.whrss9527.proxyswitch.helper"
        static let toolsDirectory = "/Library/PrivilegedHelperTools"
        static var executable: String { "\(toolsDirectory)/\(label)" }
        /// 助手目录里以前版本放的文件都以这个开头。
        static var filePrefix: String { "\(toolsDirectory)/com.whrss9527.proxyswitch." }
        static var plist: String { "/Library/LaunchDaemons/\(label).plist" }
        static var socket: String { "/var/run/\(label).sock" }
        static let dataDirectory = "/Library/Application Support/ProxySwitch"
        static let log = "/Library/Logs/ProxySwitch-helper.log"
    }

    /// 以前版本装的后台助手还在不在。
    static var helperInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: Helper.plist) || fm.fileExists(atPath: Helper.executable)
    }

    /// 以 root 运行、删掉后台助手的命令：先让 launchd 停掉它（它停下时会自己收尾），再删文件。
    static var helperRemovalScript: String {
        let quote = Shell.shellQuote
        let firewall = "/usr/libexec/ApplicationFirewall/socketfilterfw"
        return [
            "/bin/launchctl bootout system/\(Helper.label) >/dev/null 2>&1",
            "for f in \(quote(Helper.filePrefix))*; do [ -e \"$f\" ] && \(firewall) --remove \"$f\" >/dev/null 2>&1; rm -f \"$f\"; done",
            "rm -f \(quote(Helper.plist)) \(quote(Helper.socket)) \(quote(Helper.log))",
            "rm -rf \(quote(Helper.dataDirectory))",
            "true",
        ].joined(separator: "; ")
    }

    /// 删掉后台助手：系统会请用户输入一次管理员密码。
    static func removeHelper() async throws {
        try await CommandLineInstaller.runAsAdmin(helperRemovalScript, failure: L("后台助手没有移除"))
        Log.info("以前版本的后台助手已移除")
    }
}
