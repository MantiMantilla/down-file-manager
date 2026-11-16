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
    private let emptyButton = NSButton(title: "Open Privacy Settings", target: nil, action: nil)
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
            showEmpty(symbol: denied ? "lock" : "exclamationmark.triangle",
                      title: denied ? "Access Denied" : "Can't Open Folder",
                      detail: denied ? message + "\n\nmacOS may need you to allow Down to access this location." : message,
                      button: denied)
        case .loaded where items.isEmpty:
            showEmpty(symbol: "folder", title: "Folder is Empty",
                      detail: showHidden ? "" : "Hidden files are not shown (⌘H).", button: false)
        default:
            emptyStack.isHidden = true
        }

        if selection.isEmpty {
            statusPill.isHidden = true
        } else {
            let selected = vm.selectedItems
            let files = selected.filter { !$0.isFolderLike }
            let bytes = files.reduce(Int64(0)) { $0 + $1.size }
            var text = selected.count == 1 ? "“\(DisplayName.sanitize(selected[0].name))” selected" : "\(selected.count) items selected"
            if !files.isEmpty { text += " (\(ByteFormat.string(bytes)))" }
            statusPill.stringValue = text
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
