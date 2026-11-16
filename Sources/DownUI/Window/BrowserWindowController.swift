import AppKit
import DownCore

@MainActor
public protocol AppCoordinating: AnyObject {
    func newWindow(at location: Location?)
    func newTab(beside window: NSWindow, at location: Location?)
    func showSettings()
    func showDebugConsole()
}

/// One window = one tab (native NSWindow tabbing). Owns the tab's BrowserViewModel.
@MainActor
public final class BrowserWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate,
                                            NSMenuItemValidation, CommandResponder, FileViewHost, SidebarHost {
    public let vm: BrowserViewModel
    private weak var coordinator: (any AppCoordinating)?
    private let split = NSSplitViewController()
    private let sidebar: SidebarViewController
    private let content: ContentViewController
    private let pathBar: PathBarView
    private var tokens: [ObservationToken] = []
    private let log: Logger

    private enum ToolbarID {
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let pathBar = NSToolbarItem.Identifier("pathBar")
        static let viewMode = NSToolbarItem.Identifier("viewMode")
        static let search = NSToolbarItem.Identifier("search")
        static let menu = NSToolbarItem.Identifier("menu")
    }

    public init(vm: BrowserViewModel, coordinator: any AppCoordinating) {
        self.vm = vm
        self.coordinator = coordinator
        sidebar = SidebarViewController(vm: vm)
        content = ContentViewController(vm: vm)
        pathBar = PathBarView(vm: vm)
        log = vm.app.env.logger(.ui)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "app.down.browser"
        window.minSize = NSSize(width: 560, height: 360)
        window.setFrameAutosaveName("DownBrowser")
        super.init(window: window)
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !vm.app.settings.sidebarVisible
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = 360
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "DownSplit"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1100, height: 680))

        let toolbar = NSToolbar(identifier: "DownToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        sidebar.host = self
        content.list.host = self
        pathBar.onFinished = { [weak self] in self?.content.list.focus() }

        tokens.append(track { [weak self] in
            guard let self, let window = self.window else { return }
            let loc = vm.location
            window.title = loc.path == vm.app.env.homePath ? UIStrings.home : DisplayName.sanitize(loc.name)
            window.representedURL = loc.isLocal ? loc.url : nil
            window.tab.title = window.title
        })
        tokens.append(track { [weak self] in
            guard let self else { return }
            _ = (vm.canGoBack, vm.canGoForward, vm.viewMode)
            self.window?.toolbar?.validateVisibleItems()
            updateToolbarState()
        })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { MainActor.assumeIsolated { tokens.forEach { $0.cancel() } } }

    public func start() {
        vm.start()
        window?.makeFirstResponder(content.list.tableView)
    }

    // MARK: - Toolbar (GNOME header bar)

    public func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, ToolbarID.navigation, ToolbarID.pathBar, ToolbarID.search, ToolbarID.viewMode, ToolbarID.menu]
    }

    public func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    private var navGroup: NSToolbarItemGroup?
    private var viewGroup: NSToolbarItemGroup?

    public func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                        willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ToolbarID.navigation:
            let back = Command.back.title, forward = Command.forward.title
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: back)!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: forward)!,
            ], selectionMode: .momentary, labels: [back, forward], target: self, action: #selector(navClicked(_:)))
            group.controlRepresentation = .expanded
            group.label = String(localized: "Back/Forward", bundle: .module, comment: "Toolbar: label of the back and forward buttons")
            group.autovalidates = false
            group.subitems.forEach { $0.autovalidates = false }
            navGroup = group
            updateToolbarState()
            return group
        case ToolbarID.pathBar:
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = pathBar
            item.label = String(localized: "Location", bundle: .module, comment: "Toolbar: label of the path bar")
            item.visibilityPriority = .high
            return item
        case ToolbarID.viewMode:
            let list = String(localized: "List", bundle: .module, comment: "Toolbar: view-mode button, show files as a list (noun)")
            let grid = String(localized: "Grid", bundle: .module, comment: "Toolbar: view-mode button, show files as icons (noun)")
            let columns = String(localized: "Columns", bundle: .module, comment: "Toolbar: view-mode button, show files in columns (noun)")
            let group = NSToolbarItemGroup(itemIdentifier: id, images: [
                NSImage(systemSymbolName: "list.bullet", accessibilityDescription: list)!,
                NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: grid)!,
                NSImage(systemSymbolName: "rectangle.split.3x1", accessibilityDescription: columns)!,
            ], selectionMode: .selectOne, labels: [list, grid, columns], target: self, action: #selector(viewModeClicked(_:)))
            group.label = UIStrings.view
            group.autovalidates = false
            group.subitems.forEach { $0.autovalidates = false }
            viewGroup = group
            updateToolbarState()
            return group
        case ToolbarID.search:
            let item = NSToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: Command.search.title)
            item.label = Command.search.title
            item.toolTip = String(localized: "Search (⌘F) — coming soon", bundle: .module,
                                  comment: "Toolbar: tooltip of the search button, which isn't available yet")
            item.isEnabled = false
            item.autovalidates = false
            return item
        case ToolbarID.menu:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            let label = String(localized: "Menu", bundle: .module, comment: "Toolbar: the button that opens a menu of common commands")
            item.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: label)
            item.label = label
            item.showsIndicator = false
            item.menu = hamburgerMenu()
            return item
        default:
            return nil
        }
    }

    private func hamburgerMenu() -> NSMenu {
        let kb = vm.app.keybindings
        let menu = NSMenu()
        for c in [Command.newWindow, .newTab, .newFolder] { menu.addItem(MainMenu.item(for: c, keybindings: kb)) }
        menu.addItem(.separator())
        menu.addItem(MainMenu.item(for: .toggleHidden, keybindings: kb))
        let sortItem = NSMenuItem(title: String(localized: "Sort By", bundle: .module, comment: "Toolbar menu: submenu of sort orders"),
                                  action: nil, keyEquivalent: "")
        let sortMenu = NSMenu()
        for field in SortField.allCases {
            let i = NSMenuItem(title: UIStrings.title(of: field), action: #selector(sortMenuClicked(_:)), keyEquivalent: "")
            i.representedObject = field.rawValue
            i.target = self
            sortMenu.addItem(i)
        }
        sortMenu.addItem(.separator())
        let folders = NSMenuItem(title: String(localized: "Folders First", bundle: .module,
                                               comment: "Toolbar menu, Sort By submenu: list folders before files"), action: #selector(toggleFoldersFirst(_:)), keyEquivalent: "")
        folders.target = self
        sortMenu.addItem(folders)
        sortItem.submenu = sortMenu
        menu.addItem(sortItem)
        menu.addItem(.separator())
        menu.addItem(MainMenu.item(for: .openInTerminal, keybindings: kb))
        menu.addItem(MainMenu.item(for: .reload, keybindings: kb))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item(for: .settings, keybindings: kb))
        return menu
    }

    private func updateToolbarState() {
        navGroup?.subitems.first?.isEnabled = vm.canGoBack
        navGroup?.subitems.last?.isEnabled = vm.canGoForward
        if let viewGroup {
            viewGroup.selectedIndex = ViewMode.allCases.firstIndex(of: vm.viewMode) ?? 0
            // Grid and column views arrive in a later milestone.
            if viewGroup.subitems.count == 3 {
                viewGroup.subitems[1].isEnabled = false
                viewGroup.subitems[2].isEnabled = false
            }
        }
    }

    @objc private func navClicked(_ sender: NSToolbarItemGroup) {
        vm.send(sender.selectedIndex == 0 ? .goBack : .goForward)
    }

    @objc private func viewModeClicked(_ sender: NSToolbarItemGroup) {
        let mode = ViewMode.allCases[max(0, sender.selectedIndex)]
        perform(mode == .list ? .viewList : mode == .grid ? .viewGrid : .viewColumns)
    }

    @objc private func sortMenuClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let field = SortField(rawValue: raw) else { return }
        var order = vm.sort
        if order.field == field { order.ascending.toggle() } else { order.field = field; order.ascending = true }
        vm.send(.setSort(order))
    }

    @objc private func toggleFoldersFirst(_ sender: NSMenuItem) {
        var order = vm.sort
        order.foldersFirst.toggle()
        vm.send(.setSort(order))
    }

    // MARK: - Commands

    @objc public func performCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = MainMenu.command(of: item) else { return }
        perform(command)
    }

    func perform(_ command: Command) {
        log.trace("command \(command.rawValue)")
        switch command {
        case .back: vm.send(.goBack)
        case .forward: vm.send(.goForward)
        case .up: vm.send(.goUp)
        case .home: vm.send(.goHome)
        case .open: vm.send(.openSelection)
        case .reload: vm.send(.reload)
        case .toggleHidden: vm.send(.toggleHidden)
        case .locationEntry: beginLocationEntry(prefill: nil)
        case .openInTerminal: vm.send(.openInTerminal)
        case .viewList: vm.send(.setViewMode(.list))
        case .viewGrid, .viewColumns: NSSound.beep()  // later milestone
        case .zoomIn: vm.app.send(.setListZoom(vm.app.settings.listZoom + 0.125))
        case .zoomOut: vm.app.send(.setListZoom(vm.app.settings.listZoom - 0.125))
        case .zoomReset: vm.app.send(.setListZoom(1))
        case .toggleSidebar:
            split.toggleSidebar(nil)
            vm.app.send(.setSidebarVisible(!(split.splitViewItems.first?.isCollapsed ?? false)))
        case .newWindow: coordinator?.newWindow(at: vm.location)
        case .newTab: if let window { coordinator?.newTab(beside: window, at: vm.location) }
        case .closeTab: window?.performClose(nil)
        case .nextTab: window?.selectNextTab(nil)
        case .previousTab: window?.selectPreviousTab(nil)
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            if let index = command.tabIndex, let tabs = window?.tabbedWindows, index < tabs.count {
                tabs[index].makeKeyAndOrderFront(nil)
            }
        case .pin: vm.app.send(.addPin(path: vm.location.path, name: nil, at: nil))
        case .invertSelection:
            let all = Set(vm.items.map(\.path))
            vm.send(.select(all.subtracting(vm.selection)))
        case .settings: coordinator?.showSettings()
        case .debugConsole: coordinator?.showDebugConsole()
        case .copy, .cut, .paste, .selectAll, .undo, .redo:
            break  // standard selectors, handled by the responder chain
        case .newFolder, .rename, .trash, .deletePermanently, .properties, .search, .quickLook:
            NSSound.beep()  // later milestones
        }
    }

    /// Implemented in later milestones; menus show them disabled until then.
    private static let notYetImplemented: Set<Command> = [
        .viewGrid, .viewColumns, .newFolder, .rename, .trash, .deletePermanently, .properties, .search, .quickLook, .undo, .redo,
    ]

    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Standard selectors forwarded to the list (copy/cut/paste) are validated there.
        if let action = item.action, action != #selector(performCommand(_:)) {
            return content.list.validate(action)
        }
        guard let command = MainMenu.command(of: item) else { return true }
        if Self.notYetImplemented.contains(command) { return false }

        // Plain-key commands must not steal keys from text fields (path entry, rename).
        if command.yieldsToTextEditing, window?.firstResponder is NSText { return false }

        switch command {
        case .back: return vm.canGoBack
        case .forward: return vm.canGoForward
        case .up: return vm.canGoUp
        case .open: return !vm.selection.isEmpty
        case .toggleHidden:
            item.state = vm.showHidden ? .on : .off
            return true
        case .viewList:
            item.state = vm.viewMode == .list ? .on : .off
            return true
        case .toggleSidebar:
            item.title = (split.splitViewItems.first?.isCollapsed ?? false)
                ? String(localized: "Show Sidebar", bundle: .module, comment: "View menu: shown in place of Toggle Sidebar while it is hidden")
                : String(localized: "Hide Sidebar", bundle: .module, comment: "View menu: shown in place of Toggle Sidebar while it is visible")
            return true
        case .debugConsole:
            return vm.app.debugConsoleAvailable  // visibility is kept in sync by the app delegate
        case .invertSelection: return !vm.items.isEmpty
        case .tab1, .tab2, .tab3, .tab4, .tab5, .tab6, .tab7, .tab8, .tab9:
            return (command.tabIndex ?? 99) < (window?.tabbedWindows?.count ?? 1)
        case .pin: return vm.location.isLocal
        default: return true
        }
    }

    // Copy / cut / paste reach the window controller when focus is elsewhere (e.g. the sidebar).
    @objc func copy(_ sender: Any?) { content.list.copy(sender) }
    @objc func cut(_ sender: Any?) { content.list.cut(sender) }
    @objc func paste(_ sender: Any?) { content.list.paste(sender) }

    /// Views rendered individually by `--snapshot` (glass backgrounds can't be cached).
    func snapshotParts() -> [(String, NSView)] {
        var parts: [(String, NSView)] = [("pathbar", pathBar)]
        if let sidebarView = sidebar.view as? NSScrollView, let doc = sidebarView.documentView { parts.append(("sidebar", doc)) }
        return parts
    }

    // MARK: - Hosts

    func beginLocationEntry(prefill: String?) {
        pathBar.beginEditing(prefill: prefill)
    }

    func openInNewTab(_ location: Location) {
        guard let window else { return }
        coordinator?.newTab(beside: window, at: location)
    }

    // Native tab bar "+" button.
    public override func newWindowForTab(_ sender: Any?) {
        guard let window else { return }
        coordinator?.newTab(beside: window, at: vm.location)
    }

    public func windowWillClose(_ notification: Notification) {
        log.debug("window closed")
    }
}
