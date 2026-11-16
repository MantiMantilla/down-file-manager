import AppKit
import DownCore

/// A breadcrumb segment: click to navigate, drop files onto it, or hover a drag to spring-load there.
final class BreadcrumbButton: NSButton {
    let location: Location
    var onSpringLoad: ((Location) -> Void)?
    var onDrop: ((Location, any NSDraggingInfo) -> Bool)?
    private var springLoader: SpringLoader?
    private var dragHighlight = false { didSet { needsDisplay = true } }

    init(title: String, image: NSImage?, location: Location, isCurrent: Bool, springDelay: Duration) {
        self.location = location
        super.init(frame: .zero)
        self.title = title
        self.image = image
        imagePosition = image == nil ? .noImage : (title.isEmpty ? .imageOnly : .imageLeading)
        bezelStyle = .accessoryBarAction
        showsBorderOnlyWhileMouseInside = !isCurrent
        font = .systemFont(ofSize: NSFont.systemFontSize, weight: isCurrent ? .semibold : .regular)
        contentTintColor = isCurrent ? .labelColor : .secondaryLabelColor
        lineBreakMode = .byTruncatingMiddle
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        toolTip = location.path
        springLoader = SpringLoader(delay: springDelay)
        registerForDraggedTypes(DragSupport.acceptedTypes)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if dragHighlight {
            NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 2), xRadius: 6, yRadius: 6).fill()
        }
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        // Sidebar pins aren't files to move: no highlight, no spring-loading, no drop.
        if DragSupport.isPinDrag(sender.draggingPasteboard.types) { return [] }
        dragHighlight = true
        springLoader?.hover(location.path) { [weak self] in
            guard let self else { return }
            onSpringLoad?(location)
        }
        return operation(for: sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { operation(for: sender) }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        dragHighlight = false
        springLoader?.cancel()
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dragHighlight = false
        springLoader?.cancel()
        guard !DragSupport.isPinDrag(sender.draggingPasteboard.types) else { return false }
        return onDrop?(location, sender) ?? false
    }

    private func operation(for info: any NSDraggingInfo) -> NSDragOperation {
        if DragSupport.isPinDrag(info.draggingPasteboard.types) { return [] }
        let urls = DragSupport.fileURLs(from: info.draggingPasteboard)
        if urls.isEmpty { return DragSupport.promises(from: info.draggingPasteboard).isEmpty ? [] : .copy }
        return DragSupport.dragOperation(DragSupport.operation(for: info, urls: urls, destination: location.path))
    }
}

/// Nautilus-style path bar: breadcrumbs that turn into an editable text field (⌘L, click empty space,
/// or typing `/` / `~` in the file view). Tab completes folder names; Esc reverts.
@MainActor
final class PathBarView: NSView, NSTextFieldDelegate {
    private let vm: BrowserViewModel
    private let crumbs = NSStackView()
    private let field = NSTextField()
    private var tokens: [ObservationToken] = []
    private(set) var isEditing = false
    private let log: Logger

    init(vm: BrowserViewModel) {
        self.vm = vm
        log = vm.app.env.logger(.nav)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        crumbs.orientation = .horizontal
        crumbs.spacing = 0
        crumbs.alignment = .centerY
        crumbs.detachesHiddenViews = true
        crumbs.setHuggingPriority(.defaultLow, for: .horizontal)
        crumbs.translatesAutoresizingMaskIntoConstraints = false
        addSubview(crumbs)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.isHidden = true
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.placeholderString = "Type a path, e.g. ~/Documents"
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingHead
        addSubview(field)

        NSLayoutConstraint.activate([
            crumbs.leadingAnchor.constraint(equalTo: leadingAnchor),
            crumbs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            crumbs.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        // Flexible toolbar item: a min/max range, and a preferred width below the fitting-size
        // compression priority so the toolbar measures the minimum but hands out spare space.
        widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        widthAnchor.constraint(lessThanOrEqualToConstant: 1400).isActive = true
        let preferred = widthAnchor.constraint(equalToConstant: 1400)
        preferred.priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
        preferred.isActive = true

        tokens.append(track { [weak self] in
            guard let self else { return }
            let loc = vm.location
            rebuild(for: loc)
        })
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { MainActor.assumeIsolated { tokens.forEach { $0.cancel() } } }

    // MARK: Breadcrumbs

    private struct Segment {
        let title: String
        let image: NSImage?
        let location: Location
    }

    private func segments(for loc: Location) -> [Segment] {
        let home = vm.app.env.homePath
        let path = loc.path
        func symbol(_ name: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)
        }
        if path == home || path.hasPrefix(home + "/") {
            var segs = [Segment(title: "Home", image: symbol("house"), location: .file(home))]
            let rest = path.dropFirst(home.count).split(separator: "/")
            var cur = home
            for part in rest {
                cur += "/" + part
                segs.append(Segment(title: String(part), image: nil, location: .file(cur)))
            }
            return segs
        }
        if path.hasPrefix("/Volumes/") {
            let parts = path.dropFirst("/Volumes/".count).split(separator: "/")
            guard let vol = parts.first else { return [] }
            var cur = "/Volumes/" + vol
            var segs = [Segment(title: String(vol), image: symbol("externaldrive"), location: .file(cur))]
            for part in parts.dropFirst() {
                cur += "/" + part
                segs.append(Segment(title: String(part), image: nil, location: .file(cur)))
            }
            return segs
        }
        var segs = [Segment(title: "", image: symbol("internaldrive"), location: .root)]
        var cur = ""
        for part in path.split(separator: "/") {
            cur += "/" + part
            segs.append(Segment(title: String(part), image: nil, location: .file(cur)))
        }
        return segs
    }

    private func rebuild(for loc: Location) {
        crumbs.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let segs = segments(for: loc)
        let delay = vm.app.env.springDelay
        for (i, seg) in segs.enumerated() {
            if i > 0 {
                let sep = NSImageView(image: NSImage(systemSymbolName: "chevron.compact.right", accessibilityDescription: nil) ?? NSImage())
                sep.contentTintColor = .tertiaryLabelColor
                sep.setContentHuggingPriority(.required, for: .horizontal)
                crumbs.addArrangedSubview(sep)
            }
            let button = BreadcrumbButton(title: DisplayName.sanitize(seg.title), image: seg.image, location: seg.location,
                                          isCurrent: i == segs.count - 1, springDelay: delay)
            button.target = self
            button.action = #selector(crumbClicked(_:))
            button.onSpringLoad = { [weak self] target in self?.vm.send(.springLoad(target)) }
            button.onDrop = { [weak self] target, info in self?.drop(info, into: target) ?? false }
            crumbs.addArrangedSubview(button)
        }
        needsLayout = true
    }

    /// Collapses leading crumbs when space runs out (the current folder always stays visible).
    override func layout() {
        super.layout()
        guard !isEditing else { return }
        let views = crumbs.arrangedSubviews
        views.forEach { $0.isHidden = false }
        var hiddenCount = 0
        while crumbs.fittingSize.width > bounds.width - 8, hiddenCount < views.count - 1 {
            views[hiddenCount].isHidden = true
            hiddenCount += 1
        }
    }

    @objc private func crumbClicked(_ sender: BreadcrumbButton) {
        vm.send(.navigate(sender.location))
    }

    private func drop(_ info: any NSDraggingInfo, into target: Location) -> Bool {
        let id = ActionID.next()
        let urls = DragSupport.fileURLs(from: info.draggingPasteboard)
        if urls.isEmpty {
            let promises = DragSupport.promises(from: info.draggingPasteboard)
            guard !promises.isEmpty else { return false }
            DropPerformer.receivePromises(promises, into: target.path, hub: vm.app.env.logHub, id: id)
            return true
        }
        guard let op = DragSupport.operation(for: info, urls: urls, destination: target.path) else { return false }
        DropPerformer.transfer(op, urls: urls, into: target.path, hub: vm.app.env.logHub, id: id)
        vm.send(.dragEnded, id: id)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking empty space (not a crumb) switches to text entry, like Nautilus.
        beginEditing(prefill: nil)
    }

    // MARK: Text entry

    func beginEditing(prefill: String?) {
        isEditing = true
        crumbs.isHidden = true
        field.isHidden = false
        field.stringValue = prefill ?? vm.location.path
        window?.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            if prefill == nil {
                editor.selectAll(nil)
            } else {
                editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
        }
        log.debug("location entry opened")
    }

    func endEditing(focusFiles: Bool = true) {
        guard isEditing else { return }
        isEditing = false
        field.isHidden = true
        crumbs.isHidden = false
        field.textColor = .labelColor
        needsLayout = true
        if focusFiles { onFinished?() }
    }

    var onFinished: (() -> Void)?

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            commit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            endEditing()
            return true
        case #selector(NSResponder.insertTab(_:)):
            complete(textView)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        field.textColor = .labelColor
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Focus moved elsewhere (click in the file view, etc.): revert to breadcrumbs.
        if isEditing { endEditing(focusFiles: false) }
    }

    private func commit() {
        let text = field.stringValue
        guard let target = PathInput.resolve(text, relativeTo: vm.location, home: vm.app.env.homePath) else {
            endEditing()
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir) {
            endEditing()
            if isDir.boolValue {
                vm.send(.navigate(target))
            } else if let parent = target.parent {
                // A file: go to its folder (and open it, like Nautilus' location entry does).
                vm.send(.navigate(parent))
                vm.send(.open(paths: [target.path]))
            }
        } else {
            field.textColor = .systemRed
            NSSound.beep()
            log.info("location entry: no such folder \(path: target.path)")
        }
    }

    /// Tab completion against the folder being typed (folders only).
    private func complete(_ textView: NSTextView) {
        let text = field.stringValue
        let (dirText, prefix) = PathInput.completionParts(text)
        let dirLocation = PathInput.resolve(dirText.isEmpty ? "." : dirText, relativeTo: vm.location,
                                            home: vm.app.env.homePath) ?? vm.location
        let showHidden = prefix.hasPrefix(".") || vm.showHidden
        let names = (try? LocalFileSource.listAll(path: dirLocation.path))?
            .filter { $0.isFolderLike && (showHidden || !$0.isHidden) && $0.name.lowercased().hasPrefix(prefix.lowercased()) }
            .map(\.name) ?? []
        guard !names.isEmpty else { NSSound.beep(); return }
        let common = PathInput.commonPrefix(names.sorted())
        var completed = dirText + (common.count >= prefix.count ? common : prefix)
        if names.count == 1 { completed += "/" }
        field.stringValue = completed
        textView.selectedRange = NSRange(location: (completed as NSString).length, length: 0)
        if names.count > 1 && common.count == prefix.count {
            NSSound.beep()  // ambiguous: nothing more to add
        }
    }
}
