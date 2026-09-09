import AppKit

enum AppMenu {
    static func install(on application: NSApplication) {
        let mainMenu = NSMenu()

        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu()
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let about = NSMenuItem(
            title: "关于小红书链接修复",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        about.target = application
        applicationMenu.addItem(about)
        applicationMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "服务", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "服务")
        servicesItem.submenu = servicesMenu
        application.servicesMenu = servicesMenu
        applicationMenu.addItem(servicesItem)
        applicationMenu.addItem(.separator())

        let hide = NSMenuItem(
            title: "隐藏小红书链接修复",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = application
        applicationMenu.addItem(hide)

        let hideOthers = NSMenuItem(
            title: "隐藏其他应用",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        hideOthers.target = application
        applicationMenu.addItem(hideOthers)

        let showAll = NSMenuItem(
            title: "显示全部",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        showAll.target = application
        applicationMenu.addItem(showAll)
        applicationMenu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出小红书链接修复",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.target = application
        applicationMenu.addItem(quit)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        let close = NSMenuItem(
            title: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        close.target = nil
        fileMenu.addItem(close)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        editMenu.addItem(menuItem("撤销", action: Selector(("undo:")), key: "z"))
        let redo = menuItem("重做", action: Selector(("redo:")), key: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("剪切", action: #selector(NSText.cut(_:)), key: "x"))
        editMenu.addItem(menuItem("复制", action: #selector(NSText.copy(_:)), key: "c"))
        editMenu.addItem(menuItem("粘贴", action: #selector(NSText.paste(_:)), key: "v"))
        editMenu.addItem(menuItem("删除", action: #selector(NSText.delete(_:)), key: ""))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("全选", action: #selector(NSText.selectAll(_:)), key: "a"))

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        windowMenu.addItem(menuItem(
            "最小化",
            action: #selector(NSWindow.performMiniaturize(_:)),
            key: "m"
        ))
        windowMenu.addItem(menuItem(
            "缩放",
            action: #selector(NSWindow.performZoom(_:)),
            key: ""
        ))
        windowMenu.addItem(.separator())
        let front = NSMenuItem(
            title: "前置全部窗口",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: ""
        )
        front.target = application
        windowMenu.addItem(front)
        application.windowsMenu = windowMenu

        application.mainMenu = mainMenu
    }

    static func containsShortcut(
        in menu: NSMenu?,
        key: String,
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> Bool {
        guard let menu else { return false }
        for item in menu.items {
            if item.keyEquivalent == key,
               item.keyEquivalentModifierMask.intersection([.command, .option, .shift, .control]) == modifiers {
                return true
            }
            if containsShortcut(in: item.submenu, key: key, modifiers: modifiers) {
                return true
            }
        }
        return false
    }

    private static func menuItem(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        // nil target routes the command through the current first responder,
        // which is required for copy/paste/undo and window actions.
        item.target = nil
        return item
    }
}
