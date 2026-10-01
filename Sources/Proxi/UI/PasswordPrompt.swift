import AppKit

/// 开启一个要登录的配置、这台 Mac 的钥匙串里却还没有它的密码时（比如配置是从别的 Mac 经 iCloud 同步来的），请用户输入一次。
@MainActor
enum PasswordPrompt {
    static func ask(for profile: Profile) -> String? {
        let alert = NSAlert()
        alert.messageText = L("输入「%@」的代理密码", profile.name)
        alert.informativeText = L("用户名：%@。密码只保存在这台 Mac 的钥匙串里，不会写进配置文件，也不会跟 iCloud 同步。", profile.username)
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: L("保存并开启"))
        alert.addButton(withTitle: L("取消"))
        NSApp.activate(ignoringOtherApps: true)
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }
}
