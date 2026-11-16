import AppKit
import DownCore

/// Fires once after the cursor has rested on the same drop target for the spring-loading delay.
@MainActor
final class SpringLoader {
    private var target: AnyHashable?
    private var timer: Timer?
    let delay: TimeInterval
    /// Whether a drag is still in progress when the timer fires. A drag holds the mouse button down;
    /// if it was released (dropped or cancelled) without the view hearing that the drag left, the
    /// pending spring-load must not navigate.
    private let isDragLive: () -> Bool

    init(delay: Duration, isDragLive: @escaping () -> Bool = { NSEvent.pressedMouseButtons & 1 != 0 }) {
        let c = delay.components
        self.delay = Double(c.seconds) + Double(c.attoseconds) / 1e18
        self.isDragLive = isDragLive
    }

    /// Call on every drag update with the folder under the cursor (nil when not over a folder).
    func hover(_ newTarget: AnyHashable?, fire: @escaping @MainActor () -> Void) {
        guard newTarget != target else { return }
        cancel()
        target = newTarget
        guard newTarget != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                self.target = nil  // allow re-arming if the cursor stays (e.g. after navigating)
                guard self.isDragLive() else { return }
                fire()
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        target = nil
    }
}

@MainActor
enum DragSupport {
    /// Marks a drag of a sidebar pin. Pin drags also carry the folder's file URL (so other parts of
    /// macOS can show it), but inside Down they must never be treated as moving or copying files.
    static let pinType = NSPasteboard.PasteboardType("app.down.pin")

    static func isPinDrag(_ types: [NSPasteboard.PasteboardType]?) -> Bool {
        types?.contains(pinType) ?? false
    }

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    static func promises(from pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver] ?? []
    }

    static func volumeID(_ path: String) -> NSObject? {
        try? URL(filePath: path).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
    }

    /// Finder-like operation for a drop of `urls` into `destination`.
    static func operation(for info: any NSDraggingInfo, urls: [URL], destination: String) -> TransferOperation? {
        let mask = info.draggingSourceOperationMask
        let sameVolume: Bool = {
            guard let destVol = volumeID(destination), let first = urls.first,
                  let srcVol = volumeID(first.path(percentEncoded: false)) else { return false }
            return destVol.isEqual(srcVol)
        }()
        let op = DropPolicy.operation(
            allowsCopy: mask.contains(.copy), allowsMove: mask.contains(.move) || mask.contains(.generic),
            allowsLink: mask.contains(.link),
            onlyLinkRequested: mask == .link, onlyCopyRequested: mask == .copy,
            onlyMoveRequested: mask == .move || mask == .generic && NSEvent.modifierFlags.contains(.command),
            sameVolume: sameVolume)
        guard let op else { return nil }
        if DropPolicy.isNoOp(sources: urls.map { $0.path(percentEncoded: false) }, destination: destination, operation: op) {
            return nil
        }
        return op
    }

    static func dragOperation(_ op: TransferOperation?) -> NSDragOperation {
        switch op {
        case .copy: .copy
        case .move: .move
        case .link: .link
        case nil: []
        }
    }
}

/// Performs drops/pastes and promise receipts off the main actor, logging under `dnd`/`ops`.
@MainActor
enum DropPerformer {
    static func transfer(_ op: TransferOperation, urls: [URL], into destination: String, hub: LogHub, id: ActionID) {
        let sources = urls.map { $0.path(percentEncoded: false) }
        let log = Logger(.ops, hub: hub)
        Logger(.dnd, hub: hub).info("drop \(sources.count) item(s) → \(path: destination) (\(op.rawValue))", actionID: id)
        Task.detached(priority: .userInitiated) {
            let result = FileTransfer.perform(op, sources: sources, into: destination, log: log, actionID: id)
            if !result.failures.isEmpty {
                await MainActor.run { presentFailures(result.failures) }
            }
        }
    }

    static func receivePromises(_ receivers: [NSFilePromiseReceiver], into destination: String, hub: LogHub, id: ActionID) {
        let log = Logger(.dnd, hub: hub)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        let dest = URL(filePath: destination, directoryHint: .isDirectory)
        for receiver in receivers {
            receiver.receivePromisedFiles(atDestination: dest, options: [:], operationQueue: queue) { url, error in
                if let error {
                    log.error("file promise failed: \(error.localizedDescription)", actionID: id)
                } else {
                    log.info("received promised file \(url: url)", actionID: id)
                }
            }
        }
    }

    static func presentFailures(_ failures: [(path: String, message: String)]) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        // Separate strings rather than a plural: the one-item sentence has no number, and some languages
        // use their "one" plural form for 21, 31…
        alert.messageText = failures.count == 1
            ? String(localized: "Couldn't complete the operation", bundle: .module, comment: "Alert title: one dropped or pasted item failed")
            : String(localized: "\(failures.count) items couldn't be transferred", bundle: .module,
                     comment: "Alert title: several dropped or pasted items failed")
        alert.informativeText = failures.prefix(5).map { failure in
            let name = DisplayName.sanitize((failure.path as NSString).lastPathComponent)
            return String(localized: "\(name): \(failure.message)", bundle: .module,
                          comment: "Transfer failure alert, one line per item: the file name, then the error message")
        }.joined(separator: "\n")
        alert.runModal()
    }
}

/// Copy / cut / paste through the general pasteboard. Cut adds a private marker type so a later
/// paste moves instead of copies; the URLs alone remain readable by Finder and other apps.
@MainActor
enum FileClipboard {
    static let cutMarker = NSPasteboard.PasteboardType("app.down.cut")

    static func write(_ paths: [String], cut: Bool, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        let urls = paths.map { URL(filePath: $0) as NSURL }
        pasteboard.writeObjects(urls)
        if cut {
            // Attach the marker to the first item; its presence is all that matters.
            pasteboard.pasteboardItems?.first?.setString(String(ProcessInfo.processInfo.processIdentifier), forType: cutMarker)
        }
    }

    static func read(pasteboard: NSPasteboard = .general) -> (urls: [URL], cut: Bool) {
        let urls = DragSupport.fileURLs(from: pasteboard)
        let cut = pasteboard.pasteboardItems?.contains { $0.types.contains(cutMarker) } ?? false
        return (urls, cut)
    }

    static var canPaste: Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    static func clearCut(pasteboard: NSPasteboard = .general) {
        let (urls, cut) = read(pasteboard: pasteboard)
        guard cut else { return }
        write(urls.map { $0.path(percentEncoded: false) }, cut: false, pasteboard: pasteboard)
    }
}
