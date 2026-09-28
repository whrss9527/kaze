import Foundation

/// 左键点击菜单栏图标的动作。
enum ClickAction: String, Codable, CaseIterable, Identifiable {
    case panel
    case toggle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .panel: return "打开面板"
        case .toggle: return "直接开关代理"
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
        case .direct: return "直接连接"
        case .restore: return "恢复开启前的设置"
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
        case .all: return "全部显示"
        case .problems: return "只显示问题"
        case .none: return "不显示"
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
    case engine

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不显示"
        case .system: return "系统网络总速度"
        case .engine: return "只算内置代理"
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
        case .left: return "图标左边"
        case .right: return "图标右边"
        case .speedOnly: return "关代理时只显示网速"
        }
    }
}

struct AppConfig: Codable, Equatable {
    static let defaultTestURL = "https://cp.cloudflare.com/generate_204"

    var profiles: [Profile] = []
    var clickAction: ClickAction = .panel
    var toggleHotkey: HotkeyBinding? = HotkeyBinding.defaultToggle
    var offMode: OffMode = .direct
    var notifyLevel: NotifyLevel = .all
    var healthCheck: Bool = true
    var disableOnExit: Bool = false
    var testURL: String = AppConfig.defaultTestURL
    var autoCheckUpdates: Bool = true
    /// 内置代理（订阅、节点、模式）。
    var engine = EngineConfig()
    var speedDisplay: SpeedDisplay = .system
    /// 网速在图标的左边还是右边；默认在左边，开关在右边。
    var speedSide: SpeedSide = .left
    /// 网速文字跟着代理状态变色：开着时用开关的颜色，关着时是普通的菜单栏文字颜色。
    var speedColorFollowsStatus: Bool = true

    init() {}

    private enum CodingKeys: String, CodingKey {
        case profiles, clickAction, toggleHotkey, offMode, notifyLevel, healthCheck, disableOnExit, testURL, autoCheckUpdates, engine, speedDisplay, speedSide, speedColorFollowsStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decodeIfPresent([Profile].self, forKey: .profiles) ?? []
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
        autoCheckUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoCheckUpdates) ?? true
        engine = try container.decodeIfPresent(EngineConfig.self, forKey: .engine) ?? EngineConfig()
        speedDisplay = try container.decodeIfPresent(SpeedDisplay.self, forKey: .speedDisplay) ?? .system
        speedSide = try container.decodeIfPresent(SpeedSide.self, forKey: .speedSide) ?? .left
        speedColorFollowsStatus = try container.decodeIfPresent(Bool.self, forKey: .speedColorFollowsStatus) ?? true
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
        try container.encode(engine, forKey: .engine)
        try container.encode(speedDisplay, forKey: .speedDisplay)
        try container.encode(speedSide, forKey: .speedSide)
        try container.encode(speedColorFollowsStatus, forKey: .speedColorFollowsStatus)
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
    /// 局域网共享也是本机的：由这台 Mac 共享给 PS5 等设备，不跟着配置同步。
    var share = ShareConfig()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case lastProfileID, enabledByUs, original, syncEnabled, share
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastProfileID = try container.decodeIfPresent(UUID.self, forKey: .lastProfileID)
        enabledByUs = try container.decodeIfPresent(Bool.self, forKey: .enabledByUs) ?? false
        original = try container.decodeIfPresent(ProxySnapshot.self, forKey: .original)
        syncEnabled = try container.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
        share = try container.decodeIfPresent(ShareConfig.self, forKey: .share) ?? ShareConfig()
    }
}
