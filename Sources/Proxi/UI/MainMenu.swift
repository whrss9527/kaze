import AppKit

/// 主菜单。程序只在菜单栏运行，平时看不到主菜单，但 ⌘C / ⌘V / ⌘A / ⌘Z 这些快捷键要经它分发到文本框；
/// 设置窗口打开期间程序临时切成普通应用，这时菜单栏里也会显示它。
enum MainMenu {
    @MainActor
    static func install() {
        let mainMenu = NSMenu()

        let appMenu = NSMenu(title: "Proxi")
        appMenu.addItem(withTitle: "关于 Proxi", action: #selector(MenuActions.showAbout(_:)), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(withTitle: "检查更新…", action: #selector(MenuActions.checkForUpdates(_:)), keyEquivalent: "").target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(MenuActions.showSettings(_:)), keyEquivalent: ",").target = MenuActions.shared
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 Proxi", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出 Proxi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "删除", action: #selector(NSText.delete(_:)), keyEquivalent: "")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "关闭窗口", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
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
        SettingsWindowController.shared.show(page: .about)
    }

    @objc func checkForUpdates(_ sender: Any?) {
        SettingsWindowController.shared.show(page: .about)
        Task { await AppState.shared.updater.check(manual: true) }
    }
}
