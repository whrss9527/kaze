import AppKit

/// Proxi 和代理引擎的设置窗口当成同一个窗口用：同一时间只显示一个，从一边切到另一边时在同一个位置、同样大小。
/// 一边的设置窗口显示出来就发一个分布式通知，另一边收到后关掉自己的；窗口位置存在两边共用的偏好设置里。
/// 代理引擎那边有一份一样的（Sources/ProxiEngine/UI/SettingsWindowSync.swift），改的时候一起改。
@MainActor
enum SettingsWindowSync {
    nonisolated private static let notification = Notification.Name("com.whrss9527.proxyswitch.settingsWindowShown")
    private static let defaults = UserDefaults(suiteName: "com.whrss9527.proxyswitch.shared")
    private static let frameKey = "settingsWindowFrame"
    /// 通知里标明是哪一边发的，自己发的不理。
    nonisolated private static let me = "proxi"

    /// 上次两边设置窗口的位置和大小；已经不在任何屏幕上（换了显示器）时不用。
    static func savedFrame() -> NSRect? {
        guard let text = defaults?.string(forKey: frameKey) else { return nil }
        let frame = NSRectFromString(text)
        guard frame.width >= 300, frame.height >= 200,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return nil }
        return frame
    }

    static func save(_ frame: NSRect) {
        defaults?.set(NSStringFromRect(frame), forKey: frameKey)
    }

    /// 这边的设置窗口显示出来了：让另一边关掉它的。
    static func announceShown() {
        DistributedNotificationCenter.default().postNotificationName(notification, object: me, userInfo: nil, deliverImmediately: true)
    }

    /// 另一边的设置窗口显示出来时调用 handler。
    static func observeOtherShown(_ handler: @escaping @MainActor () -> Void) -> NSObjectProtocol {
        DistributedNotificationCenter.default().addObserver(forName: notification, object: nil, queue: .main) { note in
            guard let sender = note.object as? String, sender != me else { return }
            MainActor.assumeIsolated { handler() }
        }
    }
}
