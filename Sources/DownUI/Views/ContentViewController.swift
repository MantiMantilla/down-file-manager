import AppKit
import DownCore

/// Hosts the current file view plus overlays: loading spinner, empty/error state, and the
/// Nautilus-style floating "N items selected" pill.
@MainActor
final class ContentViewController: NSViewController {
    let vm: BrowserViewModel
    let list: FileListViewController
    let statusPill = PillLabel()  // internal for tests
    private let noticePill = PillLabel()
    private let spinner = NSProgressIndicator()
    let emptyStack = NSStackView()  // internal for tests
    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "")
    private let emptyDetail = NSTextField(wrappingLabelWithString: "")
    private let emptyButton = NSButton(title: String(localized: "Open Privacy Settings", bundle: .module,
                                                     comment: "Button under the Access Denied message: opens System Settings"),
                                       target: nil, action: nil)
    private var tokens: [ObservationToken] = []

    init(vm: BrowserViewModel) {
        self.vm = vm
        list = FileListViewController(vm: vm)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        addChild(list)
        list.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(list.view)

        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(spinner)

        emptyIcon.symbolConfiguration = .init(pointSize: 48, weight: .light)
        emptyIcon.contentTintColor = .tertiaryLabelColor
        emptyTitle.font = .systemFont(ofSize: 17, weight: .semibold)
        emptyTitle.textColor = .secondaryLabelColor
        emptyDetail.alignment = .center
        emptyDetail.textColor = .secondaryLabelColor
        emptyDetail.preferredMaxLayoutWidth = 360
        emptyButton.target = self
        emptyButton.action = #selector(openPrivacySettings)
        emptyButton.bezelStyle = .push
        for v in [emptyIcon, emptyTitle, emptyDetail, emptyButton] { emptyStack.addArrangedSubview(v) }
        emptyStack.orientation = .vertical
        emptyStack.spacing = 8
        emptyStack.alignment = .centerX
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        emptyStack.isHidden = true
        root.addSubview(emptyStack)

        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.isHidden = true
        root.addSubview(statusPill)

        noticePill.translatesAutoresizingMaskIntoConstraints = false
        noticePill.isHidden = true
        root.addSubview(noticePill)

        NSLayoutConstraint.activate([
            list.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            list.view.topAnchor.constraint(equalTo: root.topAnchor),
            list.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyStack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
            statusPill.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            statusPill.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            noticePill.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            noticePill.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tokens.append(track { [weak self] in self?.updateOverlays() })
        list.onMouseTrackingEnded = { [weak self] in
            guard let self, overlaysDeferred else { return }
            overlaysDeferred = false
            updateOverlays()
        }
    }

    deinit { MainActor.assumeIsolated { tokens.forEach { $0.cancel() } } }

    /// An overlay update skipped while the mouse was down in the list; runs at mouse-up.
    private(set) var overlaysDeferred = false

    private func updateOverlays() {
        // Read everything first: this runs inside `track`, which only re-fires for what was read.
        let state = vm.loadState
        let items = vm.items
        let selection = vm.selection
        let notice = vm.notice
        let showHidden = vm.showHidden

        // The list holds its rows until mouse-up, so the overlays must too, or "Folder is Empty"
        // or the selection pill could contradict the rows still on screen.
        if list.isTrackingMouse {
            overlaysDeferred = true
            return
        }

        // Spinner only if loading takes a moment and nothing is visible yet.
        if state == .loading && items.isEmpty {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }

        switch state {
        case .failed(let message, let denied):
            if denied {
                showEmpty(symbol: "lock",
                          title: String(localized: "Access Denied", bundle: .module, comment: "Title shown in place of a folder Down may not read"),
                          detail: String(localized: "\(message)\n\nmacOS may need you to allow Down to access this location.", bundle: .module,
                                         comment: "Shown under Access Denied; the argument is the error message"),
                          button: true)
            } else {
                showEmpty(symbol: "exclamationmark.triangle",
                          title: String(localized: "Can't Open Folder", bundle: .module, comment: "Title shown in place of a folder that failed to load"),
                          detail: message, button: false)
            }
        case .loaded where items.isEmpty:
            showEmpty(symbol: "folder",
                      title: String(localized: "Folder is Empty", bundle: .module, comment: "Title shown in place of an empty folder's file list"),
                      detail: showHidden ? "" : String(localized: "Hidden files are not shown (⌘H).", bundle: .module,
                                                       comment: "Shown under Folder is Empty when hidden files are off"),
                      button: false)
        default:
            emptyStack.isHidden = true
        }

        if selection.isEmpty {
            statusPill.isHidden = true
        } else {
            statusPill.stringValue = Self.selectionSummary(vm.selectedItems)
            statusPill.isHidden = false
        }

        if let notice {
            noticePill.stringValue = notice
            noticePill.isHidden = false
            let vm = self.vm
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                if vm.notice == notice { vm.send(.dismissError) }
            }
        } else {
            noticePill.isHidden = true
        }
    }

    /// Text of the selection pill: the item's name for one item, a count for several, plus the total
    /// size of the selected files when there are any (folders have no size). Full sentences, so
    /// translators can reorder them.
    static func selectionSummary(_ selected: [FileItem]) -> String {
        let files = selected.filter { !$0.isFolderLike }
        let size = files.isEmpty ? nil : ByteFormat.string(files.reduce(Int64(0)) { $0 + $1.size })
        if selected.count == 1 {
            let name = DisplayName.sanitize(selected[0].name)
            if let size {
                return String(localized: "“\(name)” selected (\(size))", bundle: .module,
                              comment: "Selection pill, one file: its name and size")
            }
            return String(localized: "“\(name)” selected", bundle: .module, comment: "Selection pill, one item: its name")
        }
        if let size {
            return String(localized: "\(selected.count) items selected (\(size))", bundle: .module,
                          comment: "Selection pill, several items: how many, and the total size of the selected files")
        }
        return String(localized: "\(selected.count) items selected", bundle: .module,
                      comment: "Selection pill, several items (only folders, so no size): how many")
    }

    private func showEmpty(symbol: String, title: String, detail: String, button: Bool) {
        emptyIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        emptyTitle.stringValue = title
        emptyDetail.stringValue = detail
        emptyDetail.isHidden = detail.isEmpty
        emptyButton.isHidden = !button
        emptyStack.isHidden = false
    }

    @objc private func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Rounded translucent label used for the selection/notice overlays.
final class PillLabel: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    var stringValue: String {
        get { label.stringValue }
        set { label.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
            widthAnchor.constraint(lessThanOrEqualToConstant: 480),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Display-only: never the target of clicks or drags, so the file list underneath gets them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
