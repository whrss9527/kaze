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

    /// 程序改名（挪了位置）后重新登记一次，让登录项指向新位置。
    static func reregister() {
        try? SMAppService.mainApp.unregister()
        do {
            try SMAppService.mainApp.register()
            Log.info("登录项已改为新位置的程序")
        } catch {
            Log.error("登录项没能改到新位置：\(error.localizedDescription)，可以在设置里重新打开「登录时自动启动」")
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

/// kaze:// 命令（改名前的 proxyswitch:// 也认）：on、off、toggle、use?name=配置名、settings（可带 ?page=about 等）、panel、update、share、tun、gateway（可带 /on、/off，不带就是切换）、
/// node?name=节点名、mode?value=rule|global、group?name=组名&member=成员、import?url=配置地址（先预览再确认）、
/// run?tool=工具名&参数=值（只能用查看和日常操作类的工具，改配置要走导入）。
/// 可以在终端里 open "kaze://toggle"，也能接快捷指令。
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
    /// 增强模式（虚拟网卡）：开、关，nil 是切换。
    case tun(Bool?)
    /// 网关模式：开、关，nil 是切换。
    case gateway(Bool?)
    /// 网址诊断：url 可以为空（只打开页面），device 表示从局域网设备的视角。
    case diagnose(url: String?, device: Bool)
    /// 切换节点；auto 是自动选择。
    case node(String)
    /// 切换模式。
    case mode(EngineMode)
    /// 切换策略组。
    case group(name: String, member: String)
    /// 导入配置：打开设置里的导入，预览后由用户确认。
    case importConfig(String)
    /// 执行一个控制接口的工具（只允许查看和日常操作）。
    case tool(name: String, params: [String: String])

    /// 认的网址开头：kaze，和改名前的 proxyswitch。
    static let schemes = ["kaze", "proxyswitch"]

    static func parse(_ url: URL) -> URLCommand? {
        guard let scheme = url.scheme?.lowercased(), schemes.contains(scheme) else { return nil }
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
            return .share(switchValue(url, query))
        case "tun", "enhanced":
            return .tun(switchValue(url, query))
        case "gateway":
            return .gateway(switchValue(url, query))
        case "diagnose", "check":
            let target = query.first { $0.name == "url" }?.value
            let device = (query.first { $0.name == "from" }?.value ?? "").lowercased() == "device"
            return .diagnose(url: target?.isEmpty == false ? target : nil, device: device)
        case "use", "switch":
            var name = query.first { $0.name == "name" }?.value ?? ""
            if name.isEmpty {
                name = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
            }
            return name.isEmpty ? nil : .use(name)
        case "node":
            let name = value(query, "name") ?? pathValue(url)
            return name.isEmpty ? nil : .node(name)
        case "mode":
            let text = (value(query, "value") ?? value(query, "mode") ?? pathValue(url)).lowercased()
            return EngineMode(rawValue: text).map { .mode($0) }
        case "group":
            guard let name = value(query, "name"), let member = value(query, "member") else { return nil }
            return .group(name: name, member: member)
        case "import", "install-config", "add":
            guard let target = value(query, "url") ?? value(query, "config") else { return nil }
            return .importConfig(target)
        case "run", "tool":
            guard let name = value(query, "tool") ?? value(query, "name") else { return nil }
            var params: [String: String] = [:]
            for item in query where item.name != "tool" && item.name != "name" {
                params[item.name] = item.value ?? ""
            }
            return .tool(name: name, params: params)
        default: return nil
        }
    }

    /// 开关类命令的参数：/on、/off、?state=on、?value=off，不写就是切换。
    private static func switchValue(_ url: URL, _ query: [URLQueryItem]) -> Bool? {
        let argument = (value(query, "state") ?? value(query, "value") ?? pathValue(url)).lowercased()
        switch argument {
        case "on", "enable", "1", "true": return true
        case "off", "disable", "0", "false": return false
        default: return nil
        }
    }

    private static func value(_ query: [URLQueryItem], _ name: String) -> String? {
        guard let value = query.first(where: { $0.name == name })?.value, !value.isEmpty else { return nil }
        return value
    }

    private static func pathValue(_ url: URL) -> String {
        url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).removingPercentEncoding ?? ""
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
    static let repository = "whrss9527/kaze"
    static var repositoryURL: URL { URL(string: "https://github.com/\(repository)")! }
    static var issuesURL: URL { URL(string: "https://github.com/\(repository)/issues")! }
}
