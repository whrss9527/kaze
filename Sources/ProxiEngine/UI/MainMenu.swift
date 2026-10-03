import AppKit

/// 主菜单。程序平时在后台运行，看不到主菜单，但 ⌘C / ⌘V / ⌘A / ⌘Z 这些快捷键要经它分发到文本框；
/// 设置窗口打开期间程序临时切成普通应用，这时菜单栏里也会显示它。
enum MainMenu {
    @MainActor
    static func install() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: L("代理引擎"))
        appMenu.addItem(withTitle: L("关于代理引擎"), action: #selector(MenuActions.showAbout(_:)), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("设置…"), action: #selector(MenuActions.showSettings(_:)), keyEquivalent: ",").target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("隐藏代理引擎"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        // 代理引擎由 Proxi 启动和退出：这里退出的话，Proxi 里开着的「代理引擎」配置就指向一个没人监听的端口（Proxi 过一会儿又会把它打开）。
        // 要停用就到 Proxi 的扩展页去关；⌘Q 只关窗口。
        appMenu.addItem(withTitle: L("在 Proxi 里停用代理引擎…"), action: #selector(MenuActions.openProxiExtensions(_:)), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: L("编辑"))
        editMenu.addItem(withTitle: L("撤销"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: L("重做"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: L("剪切"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: L("拷贝"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: L("粘贴"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: L("删除"), action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: L("全选"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: L("窗口"))
        windowMenu.addItem(withTitle: L("最小化"), action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: L("关闭窗口"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem()
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }
}

/// 主菜单里需要目标对象的动作。
@MainActor
final class MenuActions: NSObject {
    static let shared = MenuActions()

    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show(page: nil)
    }

    @objc func showAbout(_ sender: Any?) {
        // 版本和许可证在「内核」页的第一节。
        SettingsWindowController.shared.show(page: .core)
    }

    @objc func openProxiExtensions(_ sender: Any?) {
        SettingsWindowSync.yieldToOther()
        NSWorkspace.shared.open(URL(string: "proxi://settings?page=extensions")!)
    }
}
