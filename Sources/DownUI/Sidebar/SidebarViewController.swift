import AppKit
import DownCore

@MainActor
protocol SidebarHost: AnyObject {
    func openInNewTab(_ location: Location)
}

@MainActor
final class SidebarNode: NSObject {
    enum Kind: Equatable {
        case section(String)
        case place
        case pin(UUID)
        case volume(ejectable: Bool)
        case trash
    }

    let kind: Kind
    let title: String
    let symbol: String?
    let path: String?
    var children: [SidebarNode] = []

    init(kind: Kind, title: String, symbol: String? = nil, path: String? = nil, children: [SidebarNode] = []) {
        self.kind = kind
        self.title = title
        self.symbol = symbol
        self.path = path
        self.children = children
    }

    var isSection: Bool { if case .section = kind { true } else { false } }
    var location: Location? { path.map(Location.file) }
}

/// Sidebar outline. Like `FileTableView`, it must not override `draggingEnded(_:)`: doing so stops
/// AppKit from finishing drags that start here (reordering pins). See `DragOverrideTests`.
final class SidebarOutlineView: NSOutlineView {
    var onDragExited: (() -> Void)?

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragExited?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        menuRow = row
        return super.menu(for: event)
    }

    var menuRow = -1
}

@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    private let vm: BrowserViewModel
    weak var host: (any SidebarHost)?
    private let outline = SidebarOutlineView()
    private var roots: [SidebarNode] = []
    private var tokens: [ObservationToken] = []
    private let springLoader: SpringLoader
    private var suppressSelection = false
    private var workspaceObservers: [NSObjectProtocol] = []
    private let log: Logger

    init(vm: BrowserViewModel) {
        self.vm = vm
        springLoader = SpringLoader(delay: vm.app.env.springDelay)
        log = vm.app.env.logger(.ui)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let column = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 0
        outline.dataSource = self
        outline.delegate = self
        outline.registerForDraggedTypes(DragSupport.acceptedTypes + [DragSupport.pinType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        // Pins are shortcuts, not files: dropping one on Finder or another app must not copy or move
        // the real folder, so pin drags can't leave Down.
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.draggingDestinationFeedbackStyle = .sourceList
        outline.onDragExited = { [weak self] in self?.springLoader.cancel() }
        outline.target = self
        outline.action = #selector(rowClicked(_:))
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tokens.append(track { [weak self] in
            guard let self else { return }
            _ = vm.app.settings.pins
            rebuild()
        })
        tokens.append(track { [weak self] in
            guard let self else { return }
            let loc = vm.location
            selectRow(for: loc)
        })
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let name = note.name.rawValue
                MainActor.assumeIsolated {
                    self?.log.info("volumes changed (\(name))")
                    self?.rebuild()
                }
            })
        }
    }

    deinit {
        MainActor.assumeIsolated {
            tokens.forEach { $0.cancel() }
            workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        }
    }

    // MARK: - Model

    private func rebuild() {
        let home = vm.app.env.homePath
        let fm = FileManager.default
        var places = [SidebarNode(kind: .place, title: UIStrings.home, symbol: "house", path: home)]
        // Standard folders take the system's localized names, as in Finder.
        for (name, symbol) in [("Desktop", "menubar.dock.rectangle"), ("Documents", "doc"), ("Downloads", "arrow.down.circle"),
                               ("Pictures", "photo"), ("Music", "music.note"), ("Movies", "film")] {
            let p = home + "/" + name
            if fm.fileExists(atPath: p) {
                places.append(SidebarNode(kind: .place, title: fm.displayName(atPath: p), symbol: symbol, path: p))
            }
        }
        places.append(SidebarNode(kind: .place, title: fm.displayName(atPath: "/Applications"), symbol: "square.grid.3x3",
                                  path: "/Applications"))

        let pins = vm.app.settings.pins.map { pin in
            let path = vm.app.resolvedPath(for: pin)
            return SidebarNode(kind: .pin(pin.id), title: Self.title(of: pin, resolvedPath: path), symbol: "folder", path: path)
        }

        var devices: [SidebarNode] = []
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsEjectableKey, .volumeIsRemovableKey,
                                      .volumeIsInternalKey, .volumeIsRootFileSystemKey]
        for url in fm.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            let v = try? url.resourceValues(forKeys: Set(keys))
            let isRoot = v?.volumeIsRootFileSystem ?? false
            let ejectable = (v?.volumeIsEjectable ?? false) || (v?.volumeIsRemovable ?? false) || !(v?.volumeIsInternal ?? true)
            let symbol = isRoot ? "internaldrive" : (ejectable ? "externaldrive" : "internaldrive")
            devices.append(SidebarNode(kind: .volume(ejectable: ejectable && !isRoot),
                                       title: v?.volumeLocalizedName ?? url.lastPathComponent,
                                       symbol: symbol, path: url.path(percentEncoded: false)))
        }

        let trash = SidebarNode(kind: .trash, title: String(localized: "Trash", bundle: .module, comment: "Sidebar row: the Trash"),
                                symbol: "trash", path: home + "/.Trash")

        // Section kinds are identifiers; only the titles are localized.
        roots = [SidebarNode(kind: .section("Places"),
                             title: String(localized: "Places", bundle: .module, comment: "Sidebar section header: standard folders"),
                             children: places)]
        // Always show the Pinned section so there's somewhere to drop folders.
        roots.append(SidebarNode(kind: .section("Pinned"),
                                 title: String(localized: "Pinned", bundle: .module,
                                               comment: "Sidebar section header: folders the user pinned"),
                                 children: pins))
        roots.append(SidebarNode(kind: .section("Devices"),
                                 title: String(localized: "Devices", bundle: .module, comment: "Sidebar section header: disks and volumes"),
                                 children: devices))
        roots.append(SidebarNode(kind: .section("Other"),
                                 title: String(localized: "Other", bundle: .module,
                                               comment: "Sidebar section header: everything else (holds the Trash)"),
                                 children: [trash]))

        suppressSelection = true
        outline.reloadData()
        roots.forEach { outline.expandItem($0) }
        suppressSelection = false
        selectRow(for: vm.location)
    }

    private var pinnedSection: SidebarNode? { roots.first { $0.kind == .section("Pinned") } }

    private func selectRow(for loc: Location) {
        suppressSelection = true
        defer { suppressSelection = false }
        for section in roots {
            for node in section.children where node.path == loc.path {
                let row = outline.row(forItem: node)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
                return
            }
        }
        outline.deselectAll(nil)
    }

    // MARK: - Data source / delegate

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? SidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? SidebarNode)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNode)?.isSection ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        !((item as? SidebarNode)?.isSection ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, shouldShowOutlineCellForItem item: Any) -> Bool { false }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? SidebarNode else { return nil }
        if node.isSection {
            let cell = (outlineView.makeView(withIdentifier: .init("header"), owner: self) as? NSTableCellView) ?? {
                let c = NSTableCellView()
                c.identifier = .init("header")
                let t = NSTextField(labelWithString: "")
                t.translatesAutoresizingMaskIntoConstraints = false
                c.addSubview(t)
                c.textField = t
                NSLayoutConstraint.activate([
                    t.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                    t.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                ])
                return c
            }()
            cell.textField?.stringValue = node.title
            return cell
        }
        let cell = (outlineView.makeView(withIdentifier: .init("row"), owner: self) as? SidebarRowView) ?? SidebarRowView()
        cell.configure(node: node) { [weak self] in self?.eject(node) }
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection else { return }
        navigateToSelected()
    }

    @objc private func rowClicked(_ sender: Any?) {
        // Clicking the already-selected row navigates again (e.g. back to Home after browsing elsewhere).
        if outline.clickedRow >= 0, outline.clickedRow == outline.selectedRow { navigateToSelected() }
    }

    private func navigateToSelected() {
        guard let node = outline.item(atRow: outline.selectedRow) as? SidebarNode, let loc = node.location else { return }
        if NSEvent.modifierFlags.contains(.command) {
            host?.openInNewTab(loc)
        } else if loc != vm.location {
            vm.send(.navigate(loc))
        }
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let node = outline.item(atRow: outline.menuRow) as? SidebarNode, !node.isSection else { return }
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").representedObject = node
        }
        add(String(localized: "Open in New Tab", bundle: .module, comment: "Sidebar context menu"), #selector(menuOpenInNewTab(_:)))
        switch node.kind {
        case .pin:
            menu.addItem(.separator())
            add(String(localized: "Rename…", bundle: .module, comment: "Sidebar context menu on a pinned folder"), #selector(menuRenamePin(_:)))
            add(String(localized: "Unpin", bundle: .module, comment: "Sidebar context menu: remove a pinned folder"), #selector(menuUnpin(_:)))
        case .volume(let ejectable) where ejectable:
            menu.addItem(.separator())
            add(String(localized: "Eject “\(DisplayName.sanitize(node.title))”", bundle: .module, comment: "Sidebar context menu: the volume name"),
                #selector(menuEject(_:)))
        case .place:
            menu.addItem(.separator())
            add(Command.pin.title, #selector(menuPin(_:)))
        default:
            break
        }
        menu.items.forEach { $0.target = self }
    }

    @objc private func menuOpenInNewTab(_ sender: NSMenuItem) {
        guard let loc = (sender.representedObject as? SidebarNode)?.location else { return }
        host?.openInNewTab(loc)
    }

    @objc private func menuPin(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, let path = node.path else { return }
        vm.app.send(.addPin(path: path, name: Self.pinName(forPlaceAt: path, home: vm.app.env.homePath), at: nil))
    }

    /// The name stored for a pin made from a Places row. Home is named "Home" (as before), not after the
    /// account folder. Other places pass nil, so the pin takes the folder's own name, which `title(of:)`
    /// then shows in the system's language.
    static func pinName(forPlaceAt path: String, home: String) -> String? {
        path == home ? UIStrings.home : nil
    }

    /// A pin's sidebar title. A pin still named after its folder (never renamed) shows the folder's
    /// localized display name, like the Places rows ("Dokumente" for Documents in German). A name the
    /// user gave it is shown as is. Nothing about the stored pin changes.
    static func title(of pin: Pin, resolvedPath: String) -> String {
        guard pin.name == (pin.path as NSString).lastPathComponent else { return pin.name }
        return FileManager.default.displayName(atPath: resolvedPath)
    }

    @objc private func menuUnpin(_ sender: NSMenuItem) {
        guard case .pin(let id) = (sender.representedObject as? SidebarNode)?.kind else { return }
        vm.app.send(.removePin(id))
    }

    @objc private func menuRenamePin(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode, case .pin(let id) = node.kind else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Rename Pinned Folder", bundle: .module, comment: "Alert title, from the sidebar’s Rename… menu item")
        alert.addButton(withTitle: String(localized: "Rename", bundle: .module, comment: "Button in the Rename Pinned Folder alert"))
        alert.addButton(withTitle: UIStrings.cancel)
        let field = NSTextField(string: node.title)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard let window = view.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { self?.vm.app.send(.renamePin(id, field.stringValue)) }
        }
    }

    @objc private func menuEject(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? SidebarNode else { return }
        eject(node)
    }

    private func eject(_ node: SidebarNode) {
        guard let path = node.path else { return }
        let log = vm.app.env.logger(.volumes)
        if vm.location.path.hasPrefix(path) { vm.send(.goHome) }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: URL(filePath: path))
            log.info("ejected \(path: path)")
        } catch {
            log.error("eject failed for \(path: path): \(error.localizedDescription)")
            let alert = NSAlert(error: error)
            alert.messageText = String(localized: "“\(DisplayName.sanitize(node.title))” couldn't be ejected", bundle: .module,
                                       comment: "Alert title: the volume name")
            alert.informativeText = String(localized: "It may be in use by another app. \(error.localizedDescription)", bundle: .module,
                                           comment: "Eject failure alert; the system's error message follows")
            alert.runModal()
        }
    }

    // MARK: - Drag source (reordering pins)

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let node = item as? SidebarNode, case .pin(let id) = node.kind else { return nil }
        let pb = NSPasteboardItem()
        pb.setString(id.uuidString, forType: DragSupport.pinType)
        if let path = node.path { pb.setString(URL(filePath: path).absoluteString, forType: .fileURL) }
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        vm.send(.dragBegan)
        log.debug("pin drag started (session \(session.draggingSequenceNumber))")
    }

    /// The end of drags that start in the sidebar (reordering pins). This data-source callback is the
    /// supported way to learn it; never override `draggingEnded(_:)` on the outline view.
    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                     endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        springLoader.cancel()
        vm.send(operation.isEmpty ? .springLoadCancelled : .dragEnded)
        log.debug("pin drag ended (session \(session.draggingSequenceNumber), \(operation.isEmpty ? "cancelled" : "dropped"))")
    }

    // MARK: - Drop destination

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo, proposedItem item: Any?,
                     proposedChildIndex index: Int) -> NSDragOperation {
        let node = item as? SidebarNode
        let pb = info.draggingPasteboard

        // Reordering a pin: only between rows of the Pinned section.
        if pb.types?.contains(DragSupport.pinType) == true {
            springLoader.cancel()
            guard let section = pinnedSection else { return [] }
            if node === section, index != NSOutlineViewDropOnItemIndex { return .move }
            if let node, case .pin = node.kind, let i = section.children.firstIndex(of: node) {
                outlineView.setDropItem(section, dropChildIndex: i)
                return .move
            }
            return []
        }

        let urls = DragSupport.fileURLs(from: pb)

        // Between rows in Pinned (or onto the header) → pin folders there.
        if let section = pinnedSection, node === section {
            springLoader.cancel()
            guard !urls.isEmpty, urls.allSatisfy({ isDirectory($0) }) else { return [] }
            if index == NSOutlineViewDropOnItemIndex { outlineView.setDropItem(section, dropChildIndex: section.children.count) }
            return .link
        }

        // Onto a row → spring-load there and/or drop into it.
        guard let node, !node.isSection, let path = node.path, index == NSOutlineViewDropOnItemIndex else {
            springLoader.cancel()
            return []
        }
        springLoader.hover(path) { [weak self] in
            guard let self, let loc = node.location else { return }
            vm.send(.springLoad(loc))
        }
        if urls.isEmpty { return DragSupport.promises(from: pb).isEmpty || node.kind == .trash ? [] : .copy }
        if node.kind == .trash { return .delete }
        return DragSupport.dragOperation(DragSupport.operation(for: info, urls: urls, destination: path))
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        springLoader.cancel()
        let node = item as? SidebarNode
        let pb = info.draggingPasteboard
        let id = ActionID.next()

        if let raw = pb.string(forType: DragSupport.pinType), let pinID = UUID(uuidString: raw),
           let from = vm.app.settings.pins.firstIndex(where: { $0.id == pinID }) {
            vm.app.send(.movePin(from: from, to: index), id: id)
            return true
        }

        let urls = DragSupport.fileURLs(from: pb)
        if let section = pinnedSection, node === section {
            for (offset, url) in urls.enumerated() where isDirectory(url) {
                vm.app.send(.addPin(path: url.path(percentEncoded: false), name: nil, at: index + offset), id: id)
            }
            return true
        }

        guard let node, let path = node.path else { return false }
        if node.kind == .trash {
            let log = vm.app.env.logger(.ops)
            for url in urls {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    log.info("trashed \(url: url)", actionID: id)
                } catch {
                    log.error("trash failed for \(url: url): \(error.localizedDescription)", actionID: id)
                }
            }
            return true
        }
        if urls.isEmpty {
            let promises = DragSupport.promises(from: pb)
            guard !promises.isEmpty else { return false }
            DropPerformer.receivePromises(promises, into: path, hub: vm.app.env.logHub, id: id)
            return true
        }
        guard let op = DragSupport.operation(for: info, urls: urls, destination: path) else { return false }
        DropPerformer.transfer(op, urls: urls, into: path, hub: vm.app.env.logHub, id: id)
        vm.send(.dragEnded, id: id)
        return true
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir) && isDir.boolValue
    }
}

/// Sidebar row: symbol + title (+ eject button for removable volumes).
final class SidebarRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    private var onEject: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = .init("row")
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(scale: .medium)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.lineBreakMode = .byTruncatingTail
        ejectButton.translatesAutoresizingMaskIntoConstraints = false
        let ejectLabel = String(localized: "Eject", bundle: .module, comment: "Accessibility label: eject button on a sidebar volume row")
        ejectButton.image = NSImage(systemSymbolName: "eject.fill", accessibilityDescription: ejectLabel)
        ejectButton.isBordered = false
        ejectButton.contentTintColor = .secondaryLabelColor
        ejectButton.target = self
        ejectButton.action = #selector(ejectClicked)
        ejectButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(icon)
        addSubview(title)
        addSubview(ejectButton)
        imageView = icon
        textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.trailingAnchor.constraint(lessThanOrEqualTo: ejectButton.leadingAnchor, constant: -4),
            ejectButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            ejectButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @MainActor
    func configure(node: SidebarNode, onEject: @escaping () -> Void) {
        icon.image = node.symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        title.stringValue = DisplayName.sanitize(node.title)
        toolTip = node.path
        if case .volume(let ejectable) = node.kind, ejectable {
            ejectButton.isHidden = false
        } else {
            ejectButton.isHidden = true
        }
        self.onEject = onEject
    }

    @objc private func ejectClicked() { onEject?() }
}
