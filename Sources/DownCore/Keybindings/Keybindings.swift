import Foundation

/// Every user-invocable command. Menus, shortcuts and toolbar buttons all map to one of these.
public enum Command: String, CaseIterable, Codable, Sendable {
    // Go
    case locationEntry, back, forward, up, home, open
    // View
    case toggleHidden, reload, viewList, viewGrid, viewColumns, zoomIn, zoomOut, zoomReset, toggleSidebar, quickLook
    // Window / tabs
    case newTab, newWindow, closeTab, nextTab, previousTab
    case tab1, tab2, tab3, tab4, tab5, tab6, tab7, tab8, tab9
    // File
    case newFolder, rename, trash, deletePermanently, properties, pin, openInTerminal
    // Edit
    case copy, cut, paste, undo, redo, selectAll, invertSelection, search
    // App
    case settings, debugConsole

    /// Display title for menus and Settings. Persisted settings and menu items identify commands by `rawValue`.
    public var title: String {
        switch self {
        case .locationEntry: String(localized: "Enter Location…", bundle: .module, comment: "Go menu: type a path into the path bar")
        case .back: String(localized: "Back", bundle: .module, comment: "Go menu: go to the previous folder")
        case .forward: String(localized: "Forward", bundle: .module, comment: "Go menu: go to the next folder in history")
        case .up: String(localized: "Enclosing Folder", bundle: .module, comment: "Go menu: go to the parent folder")
        case .home: String(localized: "Home", bundle: .module, comment: "Go menu: go to the home folder")
        case .open: String(localized: "Open", bundle: .module, comment: "File menu and context menu: open the selected items")
        case .toggleHidden: String(localized: "Show Hidden Files", bundle: .module, comment: "View menu: toggle showing hidden files")
        case .reload: String(localized: "Reload", bundle: .module, comment: "View menu: reload the folder")
        case .viewList: String(localized: "as List", bundle: .module, comment: "View menu: show the folder as a list (reads “View as List”)")
        case .viewGrid: String(localized: "as Grid", bundle: .module, comment: "View menu: show the folder as a grid of icons (reads “View as Grid”)")
        case .viewColumns: String(localized: "as Columns", bundle: .module, comment: "View menu: show the folder in columns (reads “View as Columns”)")
        case .zoomIn: String(localized: "Zoom In", bundle: .module, comment: "View menu: make the file list larger")
        case .zoomOut: String(localized: "Zoom Out", bundle: .module, comment: "View menu: make the file list smaller")
        case .zoomReset: String(localized: "Actual Size", bundle: .module, comment: "View menu: reset the file list zoom")
        case .toggleSidebar: String(localized: "Toggle Sidebar", bundle: .module, comment: "View menu: show or hide the sidebar")
        case .quickLook: String(localized: "Quick Look", bundle: .module, comment: "View menu: preview the selection with Quick Look (Apple feature name)")
        case .newTab: String(localized: "New Tab", bundle: .module, comment: "File menu: open a new tab")
        case .newWindow: String(localized: "New Window", bundle: .module, comment: "File menu: open a new window")
        case .closeTab: String(localized: "Close Tab", bundle: .module, comment: "File menu: close the current tab")
        case .nextTab: String(localized: "Show Next Tab", bundle: .module, comment: "Window menu: switch to the next tab")
        case .previousTab: String(localized: "Show Previous Tab", bundle: .module, comment: "Window menu: switch to the previous tab")
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            String(localized: "Go to Tab \(tabIndex! + 1)", bundle: .module, comment: "Window menu (hidden item): switch to tab number N")
        case .newFolder: String(localized: "New Folder", bundle: .module, comment: "File menu and context menu: create a folder")
        case .rename: String(localized: "Rename…", bundle: .module, comment: "File menu and context menu: rename the selected item")
        case .trash: String(localized: "Move to Trash", bundle: .module, comment: "File menu and context menu: move the selection to the Trash")
        case .deletePermanently: String(localized: "Delete Permanently…", bundle: .module, comment: "File menu: delete the selection without using the Trash")
        case .properties: String(localized: "Properties", bundle: .module, comment: "File menu and context menu: show information about the selection")
        case .pin: String(localized: "Pin to Sidebar", bundle: .module, comment: "File menu and context menus: add the folder to the sidebar’s Pinned section")
        case .openInTerminal: String(localized: "Open in Terminal", bundle: .module, comment: "File menu and context menu: open the folder in a terminal app")
        case .copy: String(localized: "Copy", bundle: .module, comment: "Edit menu and context menu: copy the selection (verb)")
        case .cut: String(localized: "Cut", bundle: .module, comment: "Edit menu and context menu: cut the selection (verb)")
        case .paste: String(localized: "Paste", bundle: .module, comment: "Edit menu and context menu: paste (verb)")
        case .undo: String(localized: "Undo", bundle: .module, comment: "Edit menu: undo the last action")
        case .redo: String(localized: "Redo", bundle: .module, comment: "Edit menu: redo the last undone action")
        case .selectAll: String(localized: "Select All", bundle: .module, comment: "Edit menu: select every item")
        case .invertSelection: String(localized: "Invert Selection", bundle: .module, comment: "Edit menu: select the unselected items and deselect the rest")
        case .search: String(localized: "Search", bundle: .module, comment: "Edit menu and toolbar: search for files (verb)")
        case .settings: String(localized: "Settings…", bundle: .module, comment: "App menu: open the Settings window")
        case .debugConsole: String(localized: "Debug Console", bundle: .module, comment: "View menu: open the Debug Console developer tool")
        }
    }

    public var tabIndex: Int? {
        switch self {
        case .tab1: 0
        case .tab2: 1
        case .tab3: 2
        case .tab4: 3
        case .tab5: 4
        case .tab6: 5
        case .tab7: 6
        case .tab8: 7
        case .tab9: 8
        default: nil
        }
    }

    /// Commands that must yield to text editing (no ⌘, or arrow/space/return keys).
    public var yieldsToTextEditing: Bool {
        switch self {
        case .back, .forward, .up, .home, .open, .trash, .deletePermanently, .quickLook, .rename,
             .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9, .properties:
            true
        default:
            false
        }
    }
}

public struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let option = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let shift = KeyModifiers(rawValue: 1 << 3)

    /// Apple's canonical order: ⌃⌥⇧⌘
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}

/// A key plus modifiers. `key` is a lowercase character ("l", "1", ".") or a named key
/// ("left", "right", "up", "down", "return", "delete", "forwardDelete", "space", "tab", "home", "end", "escape", "f1"…"f12").
public struct KeyCombo: Codable, Hashable, Sendable, CustomStringConvertible {
    public var key: String
    public var modifiers: KeyModifiers

    public init(_ key: String, _ modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func cmd(_ k: String) -> KeyCombo { KeyCombo(k, .command) }
    public static func opt(_ k: String) -> KeyCombo { KeyCombo(k, .option) }
    public static func cmdShift(_ k: String) -> KeyCombo { KeyCombo(k, [.command, .shift]) }
    public static func cmdOpt(_ k: String) -> KeyCombo { KeyCombo(k, [.command, .option]) }

    public var keySymbol: String {
        switch key {
        case "left": "←"
        case "right": "→"
        case "up": "↑"
        case "down": "↓"
        case "return": "↩"
        case "delete": "⌫"
        case "forwardDelete": "⌦"
        case "space": "Space"
        case "tab": "⇥"
        case "home": "↖"
        case "end": "↘"
        case "escape": "⎋"
        case "pageUp": "⇞"
        case "pageDown": "⇟"
        default: key.hasPrefix("f") && key.count > 1 && Int(key.dropFirst()) != nil ? key.uppercased() : key.uppercased()
        }
    }

    public var description: String { modifiers.symbols + keySymbol }

    /// The combo as shown to people (Settings' shortcut list): like `description`, but named keys are
    /// localized. `description` stays fixed because logs use it.
    public var displayDescription: String {
        let name = key == "space"
            ? String(localized: "Space", bundle: .module, comment: "Shortcut list in Settings: the space bar key")
            : keySymbol
        return modifiers.symbols + name
    }

    /// Parses "⌥←", "cmd+shift+n", "F2".
    public static func parse(_ text: String) -> KeyCombo? {
        var mods: KeyModifiers = []
        var rest = Substring(text)
        let symbolMap: [Character: KeyModifiers] = ["⌘": .command, "⌥": .option, "⌃": .control, "⇧": .shift]
        while let c = rest.first, let m = symbolMap[c] { mods.insert(m); rest = rest.dropFirst() }
        var parts = rest.split(separator: "+").map { $0.lowercased() }
        guard let last = parts.popLast() else { return nil }
        for p in parts {
            switch p {
            case "cmd", "command": mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "shift": mods.insert(.shift)
            default: return nil
            }
        }
        let named: [String: String] = ["←": "left", "→": "right", "↑": "up", "↓": "down", "↩": "return",
                                       "⌫": "delete", "⌦": "forwardDelete", "⇥": "tab", "⎋": "escape",
                                       "enter": "return", "backspace": "delete", "esc": "escape", "del": "forwardDelete"]
        return KeyCombo(named[last] ?? last, mods)
    }
}

/// GNOME Files shortcuts translated to macOS (Ctrl→⌘, Alt→⌥), plus user overrides.
public struct Keybindings: Sendable, Equatable {
    public static let defaults: [Command: [KeyCombo]] = [
        .locationEntry: [.cmd("l")],
        .back: [.opt("left"), .cmd("[")],
        .forward: [.opt("right"), .cmd("]")],
        .up: [.opt("up"), .cmd("up")],
        .home: [.opt("home"), .cmdShift("h")],
        .open: [.cmd("o"), .opt("down"), .cmd("down"), KeyCombo("return")],
        .toggleHidden: [.cmd("h"), .cmdShift(".")],
        .reload: [.cmd("r"), KeyCombo("f5")],
        .viewList: [.cmd("1")],
        .viewGrid: [.cmd("2")],
        .viewColumns: [.cmd("3")],
        .zoomIn: [.cmd("="), .cmd("+")],
        .zoomOut: [.cmd("-")],
        .zoomReset: [.cmd("0")],
        .toggleSidebar: [KeyCombo("f9"), KeyCombo("s", [.command, .control])],
        .quickLook: [KeyCombo("space")],
        .newTab: [.cmd("t")],
        .newWindow: [.cmd("n")],
        .closeTab: [.cmd("w")],
        .nextTab: [KeyCombo("tab", .control), .cmdShift("]")],
        .previousTab: [KeyCombo("tab", [.control, .shift]), .cmdShift("[")],
        .tab1: [.opt("1")], .tab2: [.opt("2")], .tab3: [.opt("3")], .tab4: [.opt("4")], .tab5: [.opt("5")],
        .tab6: [.opt("6")], .tab7: [.opt("7")], .tab8: [.opt("8")], .tab9: [.opt("9")],
        .newFolder: [.cmdShift("n")],
        .rename: [KeyCombo("f2")],
        .trash: [KeyCombo("delete"), KeyCombo("forwardDelete"), .cmd("delete")],
        .deletePermanently: [KeyCombo("forwardDelete", .shift), KeyCombo("delete", .shift), .cmdOpt("delete")],
        .properties: [.cmd("i"), .opt("return")],
        .pin: [.cmd("d")],
        .openInTerminal: [.cmdOpt("t")],
        .copy: [.cmd("c")],
        .cut: [.cmd("x")],
        .paste: [.cmd("v")],
        .undo: [.cmd("z")],
        .redo: [.cmdShift("z")],
        .selectAll: [.cmd("a")],
        .invertSelection: [.cmdShift("i")],
        .search: [.cmd("f")],
        .settings: [.cmd(",")],
        .debugConsole: [.cmdOpt("j")],
    ]

    public var overrides: [Command: [KeyCombo]]

    public init(overrides: [Command: [KeyCombo]] = [:]) {
        self.overrides = overrides
    }

    public init(settingsOverrides: [String: [KeyCombo]]) {
        var map: [Command: [KeyCombo]] = [:]
        for (k, v) in settingsOverrides { if let c = Command(rawValue: k) { map[c] = v } }
        overrides = map
    }

    public func combos(for command: Command) -> [KeyCombo] {
        overrides[command] ?? Self.defaults[command] ?? []
    }

    public func primary(for command: Command) -> KeyCombo? { combos(for: command).first }

    public func command(for combo: KeyCombo) -> Command? {
        Command.allCases.first { combos(for: $0).contains(combo) }
    }

    /// Key combos bound to more than one command.
    public func conflicts() -> [KeyCombo: [Command]] {
        var map: [KeyCombo: [Command]] = [:]
        for c in Command.allCases { for k in combos(for: c) { map[k, default: []].append(c) } }
        return map.filter { $0.value.count > 1 }
    }
}
