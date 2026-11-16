import AppKit
import UniformTypeIdentifiers
import DownCore

/// Utility panel with Log / State / Perf tabs. Read-only: it never changes app state.
@MainActor
public final class DebugConsoleWindowController: NSWindowController, NSWindowDelegate {
    private let vm: DebugConsoleViewModel
    private let app: AppViewModel
    private let stateProvider: () -> [(String, String)]
    private var timer: Timer?
    private let logTab: LogTabController
    private let stateTab: StateTabController
    private let perfTab: PerfTabController

    public init(app: AppViewModel, ring: RingBufferSink, stateProvider: @escaping () -> [(String, String)]) {
        self.app = app
        vm = DebugConsoleViewModel(ring: ring)
        self.stateProvider = stateProvider
        logTab = LogTabController(vm: vm, app: app)
        stateTab = StateTabController()
        perfTab = PerfTabController(perf: app.env.perf)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        // The window title matches the menu command; the console's internals stay in English (developer tool).
        panel.title = Command.debugConsole.title
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.setFrameAutosaveName("DownDebugConsole")
        panel.minSize = NSSize(width: 560, height: 240)
        super.init(window: panel)
        panel.delegate = self

        let tabs = NSTabViewController()
        tabs.tabStyle = .segmentedControlOnTop
        for (vc, title) in [(logTab as NSViewController, "Log"), (stateTab, "State"), (perfTab, "Perf")] {
            let item = NSTabViewItem(viewController: vc)
            item.label = title
            tabs.addTabViewItem(item)
        }
        panel.contentViewController = tabs
        panel.setContentSize(NSSize(width: 900, height: 420))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    public override func showWindow(_ sender: Any?) {
        if timer == nil {
            vm.loadExisting()
            logTab.reload(scrollToEnd: true)
            startTimer()
        }
        super.showWindow(sender)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private var tickCount = 0
    private func tick() {
        vm.send(.tick)
        tickCount += 1
        if tickCount % 5 == 0 { stateTab.update(stateProvider()) }
        if tickCount % 10 == 0 { perfTab.reload() }
    }

    public func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - Log tab

@MainActor
private final class LogTabController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let vm: DebugConsoleViewModel
    let app: AppViewModel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let levelPopup = NSPopUpButton()
    private let categoryButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let searchField = NSSearchField()
    private let regexCheck = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let actionChip = NSButton(title: "", target: nil, action: nil)
    private let pauseButton = NSButton()
    private let countLabel = NSTextField(labelWithString: "")
    private var tokens: [ObservationToken] = []
    private var lastRevision = -1
    private let formatter = LogLineFormatter()


    init(vm: DebugConsoleViewModel, app: AppViewModel) {
        self.vm = vm
        self.app = app
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for level in LogLevel.allCases { levelPopup.addItem(withTitle: "≥ " + level.description) }
        levelPopup.target = self
        levelPopup.action = #selector(levelChanged)

        categoryButton.addItem(withTitle: "Categories")
        let all = NSMenuItem(title: "All", action: #selector(allCategories), keyEquivalent: "")
        all.target = self
        let none = NSMenuItem(title: "None", action: #selector(noCategories), keyEquivalent: "")
        none.target = self
        categoryButton.menu?.addItem(all)
        categoryButton.menu?.addItem(none)
        categoryButton.menu?.addItem(.separator())
        for c in LogCategory.allCases {
            let item = NSMenuItem(title: c.rawValue, action: #selector(categoryToggled(_:)), keyEquivalent: "")
            item.representedObject = c.rawValue
            item.target = self
            categoryButton.menu?.addItem(item)
        }

        searchField.placeholderString = "Filter messages"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(searchChanged)
        regexCheck.target = self
        regexCheck.action = #selector(regexToggled)

        actionChip.bezelStyle = .push
        actionChip.controlSize = .small
        actionChip.target = self
        actionChip.action = #selector(clearActionFilter)
        actionChip.isHidden = true

        pauseButton.setButtonType(.pushOnPushOff)
        pauseButton.bezelStyle = .toolbar
        pauseButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: "Pause")
        pauseButton.toolTip = "Pause"
        pauseButton.target = self
        pauseButton.action = #selector(pauseToggled)

        func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .toolbar
            b.toolTip = tip
            return b
        }
        countLabel.textColor = .secondaryLabelColor
        countLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)

        let bar = NSStackView(views: [levelPopup, categoryButton, searchField, regexCheck, actionChip, NSView(), countLabel,
                                      pauseButton, iconButton("trash", "Clear", #selector(clear)),
                                      iconButton("doc.on.doc", "Copy selected", #selector(copySelected)),
                                      iconButton("square.and.arrow.down", "Save Diagnostics…", #selector(saveDiagnostics))])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true

        for (id, title, width) in [("time", "Time", 92.0), ("level", "Level", 58.0), ("cat", "Category", 70.0),
                                   ("action", "Action", 60.0), ("msg", "Message", 600.0)] {
            let col = NSTableColumn(identifier: .init(id))
            col.title = title
            col.width = width
            table.addTableColumn(col)
        }
        table.style = .plain
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.rowHeight = 17
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true

        let root = NSStackView(views: [bar, scroll])
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .leading
        bar.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tokens.append(track { [weak self] in
            guard let self else { return }
            _ = vm.revision
            reload(scrollToEnd: false)
        })
        tokens.append(track { [weak self] in
            guard let self else { return }
            let filter = vm.actionFilter
            actionChip.isHidden = filter == nil
            actionChip.title = filter.map { "\($0) ✕" } ?? ""
            searchField.textColor = vm.regexError == nil ? .labelColor : .systemRed
            levelPopup.selectItem(at: Int(vm.minLevel.rawValue))
            for item in categoryButton.menu?.items ?? [] {
                if let raw = item.representedObject as? String, let c = LogCategory(rawValue: raw) {
                    item.state = vm.categories.contains(c) ? .on : .off
                }
            }
        })
    }

    deinit { MainActor.assumeIsolated { tokens.forEach { $0.cancel() } } }

    func reload(scrollToEnd: Bool) {
        guard vm.revision != lastRevision || scrollToEnd else { return }
        lastRevision = vm.revision
        let clip = scroll.contentView
        let atBottom = clip.bounds.maxY >= table.bounds.maxY - table.rowHeight * 2
        table.reloadData()
        countLabel.stringValue = "\(vm.visible.count) / \(vm.totalBuffered)"
        if (atBottom || scrollToEnd) && !vm.paused && !vm.visible.isEmpty {
            table.scrollRowToVisible(vm.visible.count - 1)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { vm.visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < vm.visible.count else { return nil }
        let e = vm.visible[row]
        let id = tableColumn.identifier
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        field.textColor = .labelColor
        switch id.rawValue {
        case "time": field.stringValue = LogLineFormatter.time(e.date)
        case "level":
            field.stringValue = e.level.description
            field.textColor = Self.color(e.level)
        case "cat": field.stringValue = e.category.rawValue
        case "action":
            field.stringValue = e.actionID?.description ?? ""
            field.textColor = .linkColor
        default:
            field.stringValue = formatter.message(e, redaction: .none)
            field.toolTip = "\(e.file):\(e.line) [\(e.thread)]"
            if e.level >= .error { field.textColor = Self.color(e.level) }
        }
        return field
    }

    private static func color(_ level: LogLevel) -> NSColor {
        switch level {
        case .trace: .tertiaryLabelColor
        case .debug: .secondaryLabelColor
        case .info: .labelColor
        case .notice: .systemBlue
        case .error: .systemRed
        case .fault: .systemPurple
        }
    }

    @objc private func rowClicked() {
        // Clicking an action ID filters to that action's whole chain.
        let row = table.clickedRow, col = table.clickedColumn
        guard row >= 0, col >= 0, table.tableColumns[col].identifier.rawValue == "action",
              let id = vm.visible[row].actionID else { return }
        vm.send(.filterAction(id))
    }

    @objc private func levelChanged() {
        if let level = LogLevel(rawValue: UInt8(levelPopup.indexOfSelectedItem)) { vm.send(.setMinLevel(level)) }
    }

    @objc private func categoryToggled(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let c = LogCategory(rawValue: raw) { vm.send(.toggleCategory(c)) }
    }

    @objc private func allCategories() { vm.send(.setAllCategories(true)) }
    @objc private func noCategories() { vm.send(.setAllCategories(false)) }
    @objc private func searchChanged() { vm.send(.setSearch(searchField.stringValue)) }
    @objc private func regexToggled() { vm.send(.setRegex(regexCheck.state == .on)) }
    @objc private func clearActionFilter() { vm.send(.filterAction(nil)) }

    @objc private func pauseToggled() {
        vm.send(.setPaused(pauseButton.state == .on))
        pauseButton.image = NSImage(systemSymbolName: vm.paused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
    }

    @objc private func clear() { vm.send(.clear) }

    @objc private func copySelected() {
        let rows = table.selectedRowIndexes.isEmpty ? IndexSet(integersIn: 0..<vm.visible.count) : table.selectedRowIndexes
        let text = vm.copyText(for: rows.map { vm.visible[$0] }, anonymize: app.settings.anonymizeExports)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func saveDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Down-diagnostics-\(Date().formatted(.iso8601.year().month().day())).txt"
        panel.allowedContentTypes = [.plainText]
        guard let window = view.window else { return }
        let report = vm.diagnostics(settings: app.settings)
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - State tab

@MainActor
private final class StateTabController: NSViewController {
    private let text = NSTextView()

    override func loadView() {
        let scroll = NSTextView.scrollableTextView()
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            tv.textContainerInset = NSSize(width: 8, height: 8)
        }
        view = scroll
    }

    func update(_ pairs: [(String, String)]) {
        guard let tv = (view as? NSScrollView)?.documentView as? NSTextView else { return }
        let width = pairs.map(\.0.count).max() ?? 0
        let body = pairs.map { $0.0.padding(toLength: width + 2, withPad: " ", startingAt: 0) + $0.1 }.joined(separator: "\n")
        if tv.string != body { tv.string = body }
    }
}

// MARK: - Perf tab

@MainActor
private final class PerfTabController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let perf: PerfMonitor
    private let table = NSTableView()
    private let memory = NSTextField(labelWithString: "")
    private var stats: [PerfMonitor.Stats] = []

    init(perf: PerfMonitor) {
        self.perf = perf
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        for (id, title, w) in [("name", "Interval", 160.0), ("count", "Count", 70.0), ("last", "Last", 90.0),
                               ("p50", "p50", 90.0), ("p95", "p95", 90.0)] {
            let c = NSTableColumn(identifier: .init(id))
            c.title = title
            c.width = w
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.style = .plain
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        memory.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let stack = NSStackView(views: [memory, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 0, right: 0)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        view = stack
        reload()
    }

    func reload() {
        stats = perf.stats()
        table.reloadData()
        memory.stringValue = "Memory footprint: " + ByteFormat.string(Int64(PerfMonitor.memoryFootprint()))
    }

    func numberOfRows(in tableView: NSTableView) -> Int { stats.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn else { return nil }
        let s = stats[row]
        let f = NSTextField(labelWithString: "")
        f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        switch tableColumn.identifier.rawValue {
        case "name": f.stringValue = s.name
        case "count": f.stringValue = "\(s.count)"
        case "last": f.stringValue = PerfMonitor.format(s.last)
        case "p50": f.stringValue = PerfMonitor.format(s.p50)
        default: f.stringValue = PerfMonitor.format(s.p95)
        }
        return f
    }
}
