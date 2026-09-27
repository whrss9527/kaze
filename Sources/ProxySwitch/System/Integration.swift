import AppKit
import ServiceManagement
import UserNotifications

/// 登录时自动启动：macOS 13 起的 SMAppService，系统设置的「登录项」里可以看到和关闭。
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// 通知。只有从 .app 运行时才有通知中心（需要 bundle identifier），直接运行二进制时静默。
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private var available: Bool { Bundle.main.bundleIdentifier != nil }
    private var authorizationRequested = false
    /// 用户点了通知；参数是发通知时给的 route（比如 "about"），用来决定打开哪一页。
    var onOpen: (@MainActor (String?) -> Void)?
    /// 用户点了通知上的按钮（比如「立即更新」），参数是按钮的标识。
    var onAction: (@MainActor (String) -> Void)?

    /// 更新通知：带一个「立即更新」按钮。
    static let updateCategory = "update"
    static let installUpdateAction = "install-update"

    /// 启动时调用：先设好 delegate 和通知按钮，程序重启后点旧通知也能收到（不会弹权限请求）。
    func start() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let install = UNNotificationAction(identifier: Self.installUpdateAction, title: "立即更新", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.updateCategory, actions: [install], intentIdentifiers: [], options: []),
        ])
    }

    func prepare() {
        guard available, !authorizationRequested else { return }
        authorizationRequested = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.error("请求通知权限失败：\(error)")
            } else if !granted {
                Log.info("通知权限未授予，通知不会显示")
            }
        }
    }

    func show(title: String, body: String, route: String? = nil, category: String? = nil) {
        guard available else {
            Log.info("通知（没有 bundle，不显示）：\(title) \(body)")
            return
        }
        prepare()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let route {
            content.userInfo = ["route": route]
        }
        if let category {
            content.categoryIdentifier = category
        }
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("显示通知失败：\(error)")
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        if action == UNNotificationDefaultActionIdentifier {
            let route = response.notification.request.content.userInfo["route"] as? String
            Task { @MainActor in self.onOpen?(route) }
        } else if action != UNNotificationDismissActionIdentifier {
            Task { @MainActor in self.onAction?(action) }
        }
        completionHandler()
    }
}

/// proxyswitch:// 命令：on、off、toggle、use?name=配置名、settings（可带 ?page=about 等）、panel、update、share（可带 /on、/off，不带就是切换）。
/// 可以在终端里 open "proxyswitch://toggle"，也能接快捷指令。
enum URLCommand: Equatable {
    case turnOn
    case turnOff
    case toggle
    case use(String)
    case settings(SettingsPage?)
    case panel
    /// 检查更新，有新版本就直接下载安装。
    case update
    /// 局域网共享：开、关，nil 是切换。
    case share(Bool?)

    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "proxyswitch" else { return nil }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch command {
        case "on", "enable", "start": return .turnOn
        case "off", "disable", "stop": return .turnOff
        case "toggle": return .toggle
        case "settings", "preferences":
            let page = query.first { $0.name == "page" }?.value.flatMap { SettingsPage(rawValue: $0.lowercased()) }
            return .settings(page)
        case "panel", "menu": return .panel
        case "update", "upgrade": return .update
        case "share", "lan":
            let argument = (query.first { $0.name == "state" }?.value ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
            switch argument {
            case "on", "enable", "1", "true": return .share(true)
            case "off", "disable", "0", "false": return .share(false)
            default: return .share(nil)
            }
        case "use", "switch":
            var name = query.first { $0.name == "name" }?.value ?? ""
            if name.isEmpty {
                name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
            }
            return name.isEmpty ? nil : .use(name)
        default: return nil
        }
    }
}

/// 在已经打开的终端里使用代理的命令：复制后粘贴运行，当前终端窗口就会使用代理。
enum TerminalCommands {
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// zsh / bash 的 export 命令，大小写两种都设置。
    static func export(proxyURL: String, noProxy: String) -> String {
        let noProxyValue = noProxy.isEmpty ? Profile.defaultNoProxy : noProxy
        let pairs = [("http_proxy", proxyURL), ("https_proxy", proxyURL), ("no_proxy", noProxyValue)]
        let lower = pairs.map { "\($0.0)=\(shellQuote($0.1))" }
        let upper = pairs.map { "\($0.0.uppercased())=\(shellQuote($0.1))" }
        return "export " + (lower + upper).joined(separator: " ")
    }

    /// fish 的 set -gx 命令。
    static func fish(proxyURL: String, noProxy: String) -> String {
        let noProxyValue = noProxy.isEmpty ? Profile.defaultNoProxy : noProxy
        let pairs = [("http_proxy", proxyURL), ("https_proxy", proxyURL), ("no_proxy", noProxyValue)]
        return pairs.flatMap { ["set -gx \($0.0) \(shellQuote($0.1))", "set -gx \($0.0.uppercased()) \(shellQuote($0.1))"] }.joined(separator: "; ")
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// 项目地址；换仓库只需要改这里。
enum AppInfo {
    static let repository = "whrss9527/proxyswitch-mac"
    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
    static var issuesURL: URL { URL(string: "https://github.com/\(repository)/issues")! }
}
