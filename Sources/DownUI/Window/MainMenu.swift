import AppKit
import DownCore

/// Selector every Command menu item sends up the responder chain.
@MainActor @objc protocol CommandResponder {
    func performCommand(_ sender: Any?)
}

/// Builds the menu bar from the keybinding table, so menus, shortcuts and tests share one source.
@MainActor
enum MainMenu {
    /// Commands that use standard AppKit selectors, so text fields keep handling them natively.
    static let standardSelectors: [Command: Selector] = [
        .copy: #selector(NSText.copy(_:)),
        .cut: #selector(NSText.cut(_:)),
        .paste: #selector(NSText.paste(_:)),
        .selectAll: #selector(NSResponder.selectAll(_:)),
        .undo: Selector(("undo:")),
        .redo: Selector(("redo:")),
    ]

    static func item(for command: Command, keybindings: Keybindings, title: String? = nil) -> NSMenuItem {
        let action = standardSelectors[command] ?? #selector(CommandResponder.performCommand(_:))
        let item = NSMenuItem(title: title ?? command.title, action: action, keyEquivalent: "")
        item.representedObject = command.rawValue
        if let combo = keybindings.primary(for: command) {
            item.keyEquivalent = KeyEquivalents.keyEquivalent(for: combo)
            item.keyEquivalentModifierMask = KeyEquivalents.modifierMask(for: combo)
        }
        return item
    }

    /// Hidden duplicates so secondary shortcuts (F5, ⌥↩, ⌘[ …) also fire.
    static func alternates(for command: Command, keybindings: Keybindings) -> [NSMenuItem] {
        let action = standardSelectors[command] ?? #selector(CommandResponder.performCommand(_:))
        return keybindings.combos(for: command).dropFirst().map { combo in
            let item = NSMenuItem(title: command.title, action: action, keyEquivalent: KeyEquivalents.keyEquivalent(for: combo))
            item.keyEquivalentModifierMask = KeyEquivalents.modifierMask(for: combo)
            item.representedObject = command.rawValue
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            return item
        }
    }

    static func build(keybindings kb: Keybindings, appName: String = "Down") -> NSMenu {
        let main = NSMenu()

        func add(_ menu: NSMenu, _ command: Command, title: String? = nil) {
            menu.addItem(item(for: command, keybindings: kb, title: title))
            alternates(for: command, keybindings: kb).forEach(menu.addItem)
        }

        // App menu
        let app = NSMenu(title: appName)
        app.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        add(app, .settings)
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp?.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        // ⌘H belongs to "Show Hidden Files" (GNOME's Ctrl+H), so Hide has no shortcut.
        app.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        addSubmenu(main, app)

        // File
        let file = NSMenu(title: "File")
        add(file, .newWindow)
        add(file, .newTab)
        add(file, .newFolder)
        file.addItem(.separator())
        add(file, .open)
        add(file, .openInTerminal)
        file.addItem(.separator())
        add(file, .rename)
        add(file, .trash)
        add(file, .deletePermanently)
        file.addItem(.separator())
        add(file, .properties)
        add(file, .pin)
        file.addItem(.separator())
        add(file, .closeTab)
        addSubmenu(main, file)

        // Edit
        let edit = NSMenu(title: "Edit")
        add(edit, .undo)
        add(edit, .redo)
        edit.addItem(.separator())
        add(edit, .cut)
        add(edit, .copy)
        add(edit, .paste)
        add(edit, .selectAll)
        add(edit, .invertSelection)
        edit.addItem(.separator())
        add(edit, .search)
        addSubmenu(main, edit)

        // View
        let view = NSMenu(title: "View")
        add(view, .viewList)
        add(view, .viewGrid)
        add(view, .viewColumns)
        view.addItem(.separator())
        add(view, .toggleHidden)
        add(view, .reload)
        view.addItem(.separator())
        add(view, .zoomIn)
        add(view, .zoomOut)
        add(view, .zoomReset)
        view.addItem(.separator())
        add(view, .toggleSidebar)
        add(view, .quickLook)
        view.addItem(.separator())
        add(view, .debugConsole)
        addSubmenu(main, view)

        // Go
        let go = NSMenu(title: "Go")
        add(go, .back)
        add(go, .forward)
        add(go, .up)
        add(go, .home)
        go.addItem(.separator())
        add(go, .locationEntry)
        addSubmenu(main, go)

        // Window
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        add(window, .nextTab)
        add(window, .previousTab)
        for c in [Command.tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9] {
            let items = [item(for: c, keybindings: kb)] + alternates(for: c, keybindings: kb)
            items.forEach { $0.isHidden = true; $0.allowsKeyEquivalentWhenHidden = true; window.addItem($0) }
        }
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        addSubmenu(main, window)
        NSApp?.windowsMenu = window

        let help = NSMenu(title: "Help")
        addSubmenu(main, help)
        NSApp?.helpMenu = help

        return main
    }

    private static func addSubmenu(_ main: NSMenu, _ submenu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }

    static func command(of item: NSMenuItem) -> Command? {
        (item.representedObject as? String).flatMap(Command.init(rawValue:))
    }
}
