import AppKit
import DownCore

/// Hooks the file view uses to talk to its window (location entry, etc.).
@MainActor
protocol FileViewHost: AnyObject {
    func beginLocationEntry(prefill: String?)
}

/// NSTableView that forwards GNOME-style typing (`/`, `~`) and reports when a drag leaves it.
///
/// Do NOT override `draggingEnded(_:)` (or `draggingEntered`/`performDragOperation` to feed it):
/// overriding `draggingEnded(_:)` on an NSTableView, even with a plain call to super, stops AppKit
/// from ever finishing drags that start in this table. The table then believes its first drag is
/// still running and turns every later press into a drag-select. (Found with a standalone probe:
/// a plain table plus only that override reproduces it.) The end of our own drags is reported by
/// `tableView(_:draggingSession:endedAt:operation:)` instead. `DragOverrideTests` guards this.
final class FileTableView: NSTableView {
    var onTypeToLocation: ((String) -> Void)?
    /// The drag left the table (e.g. onto the margin or an overlay): any pending spring-load must stop.
    var onDragExited: (() -> Void)?
    /// Trace hook for mouse/drag decisions (Debug Console, category `dnd`, level trace).
    var trace: ((String) -> Void)?

    /// Called once a mouse press finishes (after any drag-select), so deferred reloads can run.
    var onMouseTrackingEnded: (() -> Void)?
    /// True while AppKit tracks a press (click, ⇧/⌘-click, drag-select). The selection the user is
    /// building lives only in the table until mouse-up, so reloading or syncing from the view model now
    /// would throw it away (and reset AppKit's drag-select anchor).
    private(set) var isTrackingMouse = false

    /// Marks the start of a press. `mouseDown` brackets AppKit's tracking with this and `endMouseTracking()`.
    func beginMouseTracking() { isTrackingMouse = true }

    /// Marks the end of a press and lets deferred reloads and selection syncs run.
    func endMouseTracking() {
        guard isTrackingMouse else { return }
        isTrackingMouse = false
        onMouseTrackingEnded?()
    }

    /// The last immediate collapse, so a following double-click can open the whole previous selection.
    private var lastCollapse: MouseSelection.Collapse?

    override func mouseDown(with event: NSEvent) {
        beginMouseTracking()
        defer { endMouseTracking() }
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        let before = selectedRowIndexes
        trace?("mouseDown row=\(row) clicks=\(event.clickCount) mods=\(Self.modifierNames(event)) selection=\(Self.ranges(before)) selectedRow=\(selectedRow)")
        super.mouseDown(with: event)
        // AppKit's tracking returns on mouse-up for a click, or early once a drag starts.
        let endedWithMouseUp = NSApp.currentEvent?.type == .leftMouseUp
        if MouseSelection.shouldCollapse(row: row, clickCount: event.clickCount, modifiers: event.modifierFlags,
                                         before: before, after: selectedRowIndexes, endedWithMouseUp: endedWithMouseUp) {
            lastCollapse = MouseSelection.Collapse(row: row, previous: before, time: event.timestamp)
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            trace?("click inside selection: collapsed \(Self.ranges(before)) → [\(row)] immediately")
        }
        let upRow = self.row(at: convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
        trace?("mouseUp row=\(upRow) selection=\(Self.ranges(selectedRowIndexes)) selectedRow=\(selectedRow)")
    }

    /// For a double-click right after an immediate collapse: restores the selection it replaced,
    /// so the double-click opens everything that was selected (Finder behavior).
    func restoreSelectionForDoubleClick(on row: Int, at time: TimeInterval) {
        defer { lastCollapse = nil }
        guard let previous = MouseSelection.selectionForDoubleClick(on: row, at: time, after: lastCollapse,
                                                                    interval: NSEvent.doubleClickInterval) else { return }
        trace?("double-click after collapse: restoring \(Self.ranges(previous))")
        selectRowIndexes(previous, byExtendingSelection: false)
    }

    /// "⇧⌘" style modifier names for traces.
    static func modifierNames(_ event: NSEvent) -> String {
        let f = event.modifierFlags
        let names = [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { f.contains($0.0) }.map(\.1).joined()
        return names.isEmpty ? "none" : names
    }

    /// `[0…3, 7, 9…12]` instead of every index.
    static func ranges(_ set: IndexSet) -> String {
        "[" + set.rangeView.map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)…\($0.upperBound - 1)" }
            .joined(separator: ", ") + "]"
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        let allowed = super.canDragRows(with: rowIndexes, at: mouseDownPoint)
        trace?("canDragRows \(Self.ranges(rowIndexes)) → \(allowed)")
        return allowed
    }

    /// Anchor/cursor from the last keyboard move (see `KeyboardNavigation.State`).
    private var keyboardState: KeyboardNavigation.State?

    override func reloadData() {
        keyboardState = nil  // row indexes may now refer to different items
        super.reloadData()
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        if flags.isEmpty, let chars = event.characters, chars == "/" || chars == "~" {
            onTypeToLocation?(chars)
            return
        }
        if let (jump, extend) = KeyboardNavigation.jump(for: event) {
            perform(jump, extend: extend)
            return
        }
        super.keyDown(with: event)
    }

    /// Rows fully visible in the scroll view (one "page").
    var visibleRowCount: Int {
        let rowStride = rowHeight + intercellSpacing.height
        guard rowStride > 0 else { return 1 }
        // The clip view's height excludes the header; visibleRect can be empty before the window is drawn.
        let height = enclosingScrollView?.contentView.bounds.height ?? visibleRect.height
        return max(1, Int(height / rowStride) - 1)
    }

    func perform(_ jump: KeyboardNavigation.Jump, extend: Bool) {
        guard let state = KeyboardNavigation.apply(jump, extend: extend, selected: selectedRowIndexes,
                                                   lead: selectedRow >= 0 ? selectedRow : nil,
                                                   remembered: keyboardState, rowCount: numberOfRows,
                                                   pageSize: visibleRowCount) else { return }
        trace?("key \(jump)\(extend ? " ⇧" : "") → \(Self.ranges(state.selection)) anchor=\(state.anchor) cursor=\(state.cursor)")
        selectRowIndexes(state.selection, byExtendingSelection: false)
        keyboardState = state
        scrollRowToVisible(state.cursor)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDragExited?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        // Right-clicking an unselected row selects it first (Nautilus/Finder behavior).
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

@MainActor
final class FileListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    let vm: BrowserViewModel
    weak var host: (any FileViewHost)?
    let tableView = FileTableView()
    private let scrollView = NSScrollView()
    private let springLoader: SpringLoader
    private var tokens: [ObservationToken] = []
    private var syncingSelection = false
    private var lastRevision = -1
    private var shownItems: [FileItem] = []
    private let log: Logger

    private enum Col {
        static let name = NSUserInterfaceItemIdentifier("name")
        static let size = NSUserInterfaceItemIdentifier("size")
        static let modified = NSUserInterfaceItemIdentifier("modified")
        static let kind = NSUserInterfaceItemIdentifier("kind")
    }

    init(vm: BrowserViewModel) {
        self.vm = vm
        springLoader = SpringLoader(delay: vm.app.env.springDelay)
        log = vm.app.env.logger(.dnd)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tokens.append(track { [weak self] in
            guard let self else { return }
            _ = vm.itemsRevision
            reloadIfNeeded()
        })
        tokens.append(track { [weak self] in
            guard let self else { return }
            let selection = vm.selection
            applySelection(selection)
        })
        tokens.append(track { [weak self] in
            guard let self else { return }
            let zoom = vm.app.settings.listZoom
            tableView.rowHeight = (24 * zoom).rounded()
        })
    }

    deinit {
        MainActor.assumeIsolated { tokens.forEach { $0.cancel() } }
    }

    // MARK: - Setup

    private func configureTable() {
        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.allowsEmptySelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsTypeSelect = true
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.autosaveName = "FileList"
        tableView.autosaveTableColumns = true

        addColumn(Col.name, "Name", width: 320, min: 140, sortKey: .name)
        addColumn(Col.size, "Size", width: 90, min: 60, sortKey: .size)
        addColumn(Col.modified, "Modified", width: 170, min: 100, sortKey: .modified)
        addColumn(Col.kind, "Kind", width: 140, min: 60, sortKey: .kind)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))

        // Drag source: file URLs work with every app.
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: false)
        tableView.setDraggingSourceOperationMask([.copy, .move, .link, .generic], forLocal: true)
        tableView.draggingDestinationFeedbackStyle = .regular
        tableView.registerForDraggedTypes(DragSupport.acceptedTypes)

        tableView.onTypeToLocation = { [weak self] text in self?.host?.beginLocationEntry(prefill: text) }
        tableView.trace = { [weak self] message in self?.log.trace("\(message)") }
        tableView.onMouseTrackingEnded = { [weak self] in self?.mouseTrackingEnded() }
        tableView.onDragExited = { [weak self] in
            self?.springLoader.cancel()
            self?.log.trace("drag exited the file list; spring-load cancelled")
        }

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu
        updateSortIndicators()
    }

    private func addColumn(_ id: NSUserInterfaceItemIdentifier, _ title: String, width: CGFloat, min: CGFloat,
                           sortKey: SortField) {
        let col = NSTableColumn(identifier: id)
        col.title = title
        col.width = width
        col.minWidth = min
        col.sortDescriptorPrototype = NSSortDescriptor(key: sortKey.rawValue, ascending: true)
        if id != Col.name { col.headerCell.alignment = id == Col.size ? .right : .left }
        tableView.addTableColumn(col)
    }

    // MARK: - Rendering

    /// Reloads or selection syncs skipped while the mouse was down; run once the press ends.
    private var syncDeferred = false

    /// While the user is mid-press, model-driven updates wait (see `FileTableView.isTrackingMouse`).
    private func deferWhileTrackingMouse(_ what: String) -> Bool {
        guard tableView.isTrackingMouse else { return false }
        log.trace("\(what) deferred until mouse-up")
        syncDeferred = true
        return true
    }

    /// True while the user is mid-press in the list; views that mirror the list (overlays) wait too.
    var isTrackingMouse: Bool { tableView.isTrackingMouse }
    /// Called after each press, once any deferred reload and selection sync have been applied.
    var onMouseTrackingEnded: (() -> Void)?

    private func mouseTrackingEnded() {
        if syncDeferred {
            syncDeferred = false
            log.trace("mouse-up: applying deferred reload/selection sync")
            reloadIfNeeded()
            applySelection(vm.selection)
        }
        onMouseTrackingEnded?()
    }

    private func reloadIfNeeded() {
        guard vm.itemsRevision != lastRevision else { return }
        if deferWhileTrackingMouse("reload") { return }
        lastRevision = vm.itemsRevision
        let oldFirst = shownItems.first?.parentPath
        shownItems = vm.items
        tableView.reloadData()
        applySelection(vm.selection)
        if let reveal = vm.pendingReveal ?? vm.selection.first,
           let row = shownItems.firstIndex(where: { $0.path == reveal }) {
            tableView.scrollRowToVisible(row)
        } else if oldFirst != shownItems.first?.parentPath {
            tableView.scrollRowToVisible(0)
        }
        updateSortIndicators()
    }

    private func applySelection(_ selection: Set<String>) {
        if deferWhileTrackingMouse("selection sync") { return }
        syncingSelection = true
        defer { syncingSelection = false }
        var indexes = IndexSet()
        if !selection.isEmpty {
            for (i, item) in shownItems.enumerated() where selection.contains(item.path) { indexes.insert(i) }
        }
        if indexes != tableView.selectedRowIndexes {
            log.trace("sync selection from view model: table \(FileTableView.ranges(tableView.selectedRowIndexes)) → \(FileTableView.ranges(indexes))")
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        }
    }

    private func updateSortIndicators() {
        let sort = vm.sort
        for col in tableView.tableColumns {
            let key = col.sortDescriptorPrototype?.key
            tableView.setIndicatorImage(key == sort.field.rawValue
                                        ? NSImage(named: sort.ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator")
                                        : nil, in: col)
        }
        tableView.highlightedTableColumn = tableView.tableColumns.first { $0.sortDescriptorPrototype?.key == sort.field.rawValue }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shownItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < shownItems.count else { return nil }
        let item = shownItems[row]
        let id = tableColumn.identifier
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? makeCell(id)
        switch id {
        case Col.name:
            cell.textField?.stringValue = DisplayName.sanitize(item.name)
            cell.imageView?.image = IconCache.shared.icon(for: item)
            cell.textField?.toolTip = DisplayName.needsSanitizing(item.name) ? "Name contains hidden control characters" : nil
        case Col.size:
            cell.textField?.stringValue = sizeText(item)
        case Col.modified:
            cell.textField?.stringValue = Self.dateText(item.modified)
        case Col.kind:
            cell.textField?.stringValue = TypeCache.kindDescription(for: item)
        default:
            break
        }
        let dimmed = item.isHidden
        cell.alphaValue = dimmed ? 0.55 : 1
        return cell
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = id == Col.name ? .byTruncatingMiddle : .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        if id != Col.name {
            text.textColor = .secondaryLabelColor
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        }
        if id == Col.size { text.alignment = .right }
        cell.addSubview(text)
        cell.textField = text
        if id == Col.name {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyUpOrDown
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.heightAnchor.constraint(equalTo: cell.heightAnchor, multiplier: 0.8),
                image.widthAnchor.constraint(equalTo: image.heightAnchor),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        NSLayoutConstraint.activate([
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func sizeText(_ item: FileItem) -> String {
        if item.isFolderLike {
            guard let n = item.entryCount else { return "—" }
            return n == 1 ? "1 item" : "\(n) items"
        }
        return ByteFormat.string(item.size)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    /// Nautilus-style: "10:42" today, "Yesterday", weekday this week, otherwise a date.
    static func dateText(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return timeFormatter.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday " + timeFormatter.string(from: date) }
        if let days = cal.dateComponents([.day], from: date, to: Date()).day, days < 7, days >= 0 {
            return date.formatted(.dateTime.weekday(.wide)) + " " + timeFormatter.string(from: date)
        }
        return dateFormatter.string(from: date)
    }

    // MARK: - Interaction

    /// Fires repeatedly while the mouse is still down (drag-select, ⇧-click); DidChange fires on mouse-up.
    func tableViewSelectionIsChanging(_ notification: Notification) {
        log.trace("selection is changing → \(FileTableView.ranges(tableView.selectedRowIndexes)) selectedRow=\(tableView.selectedRow)")
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !syncingSelection else { return }
        let paths = Set(tableView.selectedRowIndexes.compactMap { $0 < shownItems.count ? shownItems[$0].path : nil })
        log.trace("selection did change → \(FileTableView.ranges(tableView.selectedRowIndexes)) selectedRow=\(tableView.selectedRow)")
        vm.send(.select(paths))
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard let first = tableView.sortDescriptors.first, let key = first.key, let field = SortField(rawValue: key) else { return }
        var order = vm.sort
        if order.field == field {
            order.ascending.toggle()
        } else {
            order.field = field
            order.ascending = field == .name || field == .kind  // dates/sizes: newest/largest first
        }
        vm.send(.setSort(order))
        updateSortIndicators()
    }

    @objc private func doubleClicked(_ sender: Any?) {
        guard tableView.clickedRow >= 0 else { return }
        tableView.restoreSelectionForDoubleClick(on: tableView.clickedRow, at: NSApp.currentEvent?.timestamp ?? 0)
        vm.send(.openSelection)
    }

    func focus() {
        view.window?.makeFirstResponder(tableView)
    }

    // MARK: - Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let commands: [Command?]
        if vm.selection.isEmpty {
            commands = [.newFolder, .paste, nil, .openInTerminal, nil, .toggleHidden, .reload, nil, .pin]
        } else {
            commands = [.open, nil, .cut, .copy, nil, .rename, .trash, nil, .properties]
        }
        let kb = vm.app.keybindings
        for c in commands {
            guard let c else { menu.addItem(.separator()); continue }
            menu.addItem(MainMenu.item(for: c, keybindings: kb))
        }
        if vm.selection.count == 1, let item = vm.selectedItems.first, item.isFolderLike {
            menu.insertItem(NSMenuItem.separator(), at: 1)
            let pin = NSMenuItem(title: "Pin to Sidebar", action: #selector(pinSelection(_:)), keyEquivalent: "")
            pin.target = self
            menu.insertItem(pin, at: 2)
        }
    }

    @objc private func pinSelection(_ sender: Any?) {
        guard let item = vm.selectedItems.first else { return }
        vm.app.send(.addPin(path: item.path, name: nil, at: nil))
    }

    // MARK: - Copy / cut / paste (standard responder selectors, so text fields keep theirs)

    @objc func copy(_ sender: Any?) {
        FileClipboard.write(vm.selectedItems.map(\.path), cut: false)
        vm.app.env.logger(.ops).info("copied \(vm.selection.count) item(s) to clipboard")
    }

    @objc func cut(_ sender: Any?) {
        FileClipboard.write(vm.selectedItems.map(\.path), cut: true)
        vm.app.env.logger(.ops).info("cut \(vm.selection.count) item(s) to clipboard")
    }

    @objc func paste(_ sender: Any?) {
        let (urls, cut) = FileClipboard.read()
        guard !urls.isEmpty else { return }
        let dest = vm.location.path
        let id = ActionID.next()
        DropPerformer.transfer(cut ? .move : .copy, urls: urls, into: dest, hub: vm.app.env.logHub, id: id)
        if cut { FileClipboard.clearCut() }
    }

    func validate(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(copy(_:)), #selector(cut(_:)): !vm.selection.isEmpty
        case #selector(paste(_:)): FileClipboard.canPaste && vm.location.isLocal
        default: true
        }
    }

    // MARK: - Drag source

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard row < shownItems.count else { return nil }
        return shownItems[row].url as NSURL
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        vm.send(.dragBegan)
        log.debug("drag started with \(rowIndexes.count) item(s) (session \(session.draggingSequenceNumber))")
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        log.debug("drag ended (session \(session.draggingSequenceNumber), \(operation.isEmpty ? "cancelled or refused" : "dropped"))")
        dragEnded(performed: !operation.isEmpty)
    }

    private func dragEnded(performed: Bool) {
        springLoader.cancel()
        if !performed && vm.springOrigin != nil {
            vm.send(.springLoadCancelled)
        } else if vm.springOrigin != nil {
            vm.send(.dragEnded)
        }
    }

    // MARK: - Drop destination (+ spring-loading on folder rows)

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        // A sidebar pin carries its folder's URL, but dropping it here must never move that folder.
        if DragSupport.isPinDrag(info.draggingPasteboard.types) {
            springLoader.cancel()
            return []
        }
        let urls = DragSupport.fileURLs(from: info.draggingPasteboard)
        var destination = vm.location

        if dropOperation == .on, row >= 0, row < shownItems.count, shownItems[row].isFolderLike {
            let folder = shownItems[row]
            destination = folder.location
            springLoader.hover(folder.path) { [weak self] in
                self?.vm.send(.springLoad(folder.location))
            }
        } else {
            springLoader.hover(nil) {}
            tableView.setDropRow(-1, dropOperation: .on)  // whole view = current folder
        }

        guard destination.isLocal else { return [] }
        if urls.isEmpty {
            return DragSupport.promises(from: info.draggingPasteboard).isEmpty ? [] : .copy
        }
        return DragSupport.dragOperation(DragSupport.operation(for: info, urls: urls, destination: destination.path))
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        springLoader.cancel()
        guard !DragSupport.isPinDrag(info.draggingPasteboard.types) else { return false }
        let destination = (row >= 0 && row < shownItems.count && shownItems[row].isFolderLike) ? shownItems[row].path : vm.location.path
        let id = ActionID.next()
        let urls = DragSupport.fileURLs(from: info.draggingPasteboard)
        if urls.isEmpty {
            let promises = DragSupport.promises(from: info.draggingPasteboard)
            guard !promises.isEmpty else { return false }
            DropPerformer.receivePromises(promises, into: destination, hub: vm.app.env.logHub, id: id)
            vm.send(.dragEnded, id: id)
            return true
        }
        guard let op = DragSupport.operation(for: info, urls: urls, destination: destination) else { return false }
        DropPerformer.transfer(op, urls: urls, into: destination, hub: vm.app.env.logHub, id: id)
        vm.send(.dragEnded, id: id)
        return true
    }
}
