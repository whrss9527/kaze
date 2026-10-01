import Foundation

/// 左键点击菜单栏图标的动作。
enum ClickAction: String, Codable, CaseIterable, Identifiable {
    case panel
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panel: return L("打开面板")
        case .toggle: return L("直接开关代理")
        }
    }
}

/// 关闭代理时系统代理怎么处理。
enum OffMode: String, Codable, CaseIterable, Identifiable {
    case direct
    case restore

    var id: String { rawValue }

    var title: String {
        switch self {
        case .direct: return L("直接连接")
        case .restore: return L("恢复开启前的设置")
        }
    }
}

enum NotifyLevel: String, Codable, CaseIterable, Identifiable {
    case all
    case problems
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L("全部显示")
        case .problems: return L("只显示问题")
        case .none: return L("不显示")
        }
    }
}

/// 全局快捷键：Carbon 的键码和修饰键位，display 是显示用的文字（⌃⌥P）。
struct HotkeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String

    /// 默认 ⌃⌥P（P 的 Carbon 键码 0x23）。
    static let defaultToggle = HotkeyBinding(keyCode: 0x23, modifiers: KeyNames.controlKey | KeyNames.optionKey, display: "⌃⌥P")
}

/// 菜单栏图标旁边的实时网速。
enum SpeedDisplay: String, Codable, CaseIterable, Identifiable {
    case none
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L("不显示")
        case .system: return L("系统网络总速度")
        }
    }
}

/// 网速显示在菜单栏图标的哪一边。
enum SpeedSide: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    /// 代理关着时只显示网速；开启后开关出现在网速左边。
    case speedOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return L("图标左边")
        case .right: return L("图标右边")
        case .speedOnly: return L("关代理时只显示网速")
        }
    }
}

struct AppConfig: Codable, Equatable {
    /// 测速默认访问的地址：苹果用来检测网络连通的页面，返回很小，哪里都能访问。
    static let defaultTestURL = "https://www.apple.com/library/test/success.html"
    /// 以前版本的默认测速地址；还是它时换成新的默认值。
    static let legacyTestURLs = ["https://cp.cloudflare.com/generate_204", "http://cp.cloudflare.com/generate_204"]

    var profiles: [Profile] = []
    var clickAction: ClickAction = .panel
    var toggleHotkey: HotkeyBinding? = HotkeyBinding.defaultToggle
    var offMode: OffMode = .direct
    var notifyLevel: NotifyLevel = .all
    var healthCheck: Bool = true
    var disableOnExit: Bool = false
    var testURL: String = AppConfig.defaultTestURL
    var autoCheckUpdates: Bool = true
    var speedDisplay: SpeedDisplay = .system
    /// 网速在图标的左边还是右边；默认在左边，开关在右边。
    var speedSide: SpeedSide = .left
    /// 网速文字跟着代理状态变色：开着时用开关的颜色，关着时是普通的菜单栏文字颜色。
    var speedColorFollowsStatus: Bool = true
    /// 自动化：本机控制接口的权限、按网络自动切换。
    var automation = AutomationConfig()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case profiles, clickAction, toggleHotkey, offMode, notifyLevel, healthCheck, disableOnExit, testURL, autoCheckUpdates, speedDisplay, speedSide, speedColorFollowsStatus, automation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // 以前版本里由内置代理自动生成的配置不再支持，直接去掉。
        profiles = (try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []).filter { !$0.legacyBuiltIn }
        clickAction = try container.decodeIfPresent(ClickAction.self, forKey: .clickAction) ?? .panel
        if container.contains(.toggleHotkey) {
            toggleHotkey = try container.decodeIfPresent(HotkeyBinding.self, forKey: .toggleHotkey)
        } else {
            toggleHotkey = HotkeyBinding.defaultToggle
        }
        offMode = try container.decodeIfPresent(OffMode.self, forKey: .offMode) ?? .direct
        notifyLevel = try container.decodeIfPresent(NotifyLevel.self, forKey: .notifyLevel) ?? .all
        healthCheck = try container.decodeIfPresent(Bool.self, forKey: .healthCheck) ?? true
        disableOnExit = try container.decodeIfPresent(Bool.self, forKey: .disableOnExit) ?? false
        testURL = try container.decodeIfPresent(String.self, forKey: .testURL) ?? AppConfig.defaultTestURL
        if AppConfig.legacyTestURLs.contains(testURL) {
            testURL = AppConfig.defaultTestURL
        }
        autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        // 以前版本里的其他设置（已经去掉的功能）直接忽略；认不出的网速显示方式按系统网络总速度算。
        speedDisplay = (try? container.decodeIfPresent(SpeedDisplay.self, forKey: .speedDisplay)) ?? .system
        speedSide = try container.decodeIfPresent(SpeedSide.self, forKey: .speedSide) ?? .left
        speedColorFollowsStatus = try container.decodeIfPresent(Bool.self, forKey: .speedColorFollowsStatus) ?? true
        automation = try container.decodeIfPresent(AutomationConfig.self, forKey: .automation) ?? AutomationConfig()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(profiles, forKey: .profiles)
        try container.encode(clickAction, forKey: .clickAction)
        // 明确写出 null，表示用户关掉了快捷键（缺少这个键时用默认值）。
        try container.encode(toggleHotkey, forKey: .toggleHotkey)
        try container.encode(offMode, forKey: .offMode)
        try container.encode(notifyLevel, forKey: .notifyLevel)
        try container.encode(healthCheck, forKey: .healthCheck)
        try container.encode(disableOnExit, forKey: .disableOnExit)
        try container.encode(testURL, forKey: .testURL)
        try container.encode(autoCheckUpdates, forKey: .autoCheckUpdates)
        try container.encode(speedDisplay, forKey: .speedDisplay)
        try container.encode(speedSide, forKey: .speedSide)
        try container.encode(speedColorFollowsStatus, forKey: .speedColorFollowsStatus)
        try container.encode(automation, forKey: .automation)
    }

    func profile(id: UUID?) -> Profile? {
        guard let id else { return nil }
        return profiles.first { $0.id == id }
    }
}

/// 运行状态：上次使用的配置、是否由本程序开启、开启前的系统代理快照（关闭时恢复用）。
struct PersistedState: Codable, Equatable {
    var lastProfileID: UUID?
    var enabledByUs: Bool = false
    var original: ProxySnapshot?
    /// iCloud 同步的开关是本机的，不跟着配置同步。
    var syncEnabled: Bool = false
    /// 已经显示过 0.13.0 的「Proxi 现在只切换代理」提示。
    var noticeShown: Bool = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lastProfileID, enabledByUs, original, syncEnabled, noticeShown
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastProfileID = try container.decodeIfPresent(UUID.self, forKey: .lastProfileID)
        enabledByUs = try container.decodeIfPresent(Bool.self, forKey: .enabledByUs) ?? false
        original = try container.decodeIfPresent(ProxySnapshot.self, forKey: .original)
        syncEnabled = try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        noticeShown = try container.decodeIfPresent(Bool.self, forKey: .noticeShown) ?? false
    }
}
