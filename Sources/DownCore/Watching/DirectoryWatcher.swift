import Foundation
import CoreServices

/// FSEvents watcher for one folder's direct children, turned into `WatchEvent`s.
public final class DirectoryWatcher: @unchecked Sendable {
    // @unchecked: all mutable state is touched only on `queue`.
    private let path: String
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?
    private let continuation: AsyncStream<WatchEvent>.Continuation
    private let log: Logger
    /// Above this many changed children in one callback, ask for a full rescan instead.
    static let rescanThreshold = 500

    public static func stream(for path: String, latency: TimeInterval = 0.1, log: Logger) -> AsyncStream<WatchEvent> {
        AsyncStream { continuation in
            let watcher = DirectoryWatcher(path: path, continuation: continuation, log: log)
            watcher.start(latency: latency)
            continuation.onTermination = { _ in watcher.stop() }
        }
    }

    private init(path: String, continuation: AsyncStream<WatchEvent>.Continuation, log: Logger) {
        // FSEvents reports canonical paths (e.g. /private/var/… for /var/…); compare against the same form.
        self.path = Self.canonical(path)
        self.continuation = continuation
        self.log = log
        queue = DispatchQueue(label: "app.down.watch", qos: .utility)
    }

    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func start(latency: TimeInterval) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passRetained(self).toOpaque(),
                                           retain: nil, release: { info in
                                               guard let info else { return }
                                               Unmanaged<DirectoryWatcher>.fromOpaque(info).release()
                                           }, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes |
                           kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context,
                                               [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                               latency, flags) else {
            log.error("could not create FSEvents stream for \(path: path)")
            continuation.finish()
            return
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        log.debug("watching \(path: path)")
    }

    private func stop() {
        queue.async { [self] in
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            log.debug("stopped watching \(path: path)")
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
        let cfPaths = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
        let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
        watcher.handle(paths: cfPaths, flags: flagList)
    }

    private func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let root = path == "/" ? "/" : path
        var names = Set<String>()
        for (p, f) in zip(paths, flags) {
            let flag = Int(f)
            if flag & (kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount) != 0 {
                continuation.yield(.rootChanged)
                return
            }
            if flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped |
                       kFSEventStreamEventFlagKernelDropped) != 0 {
                continuation.yield(.rescan)
                return
            }
            let normalized = p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p
            if normalized == root { continue }  // metadata change on the folder itself
            let parent = (normalized as NSString).deletingLastPathComponent
            if parent == root {
                names.insert((normalized as NSString).lastPathComponent)
            } else if normalized.hasPrefix(root == "/" ? "/" : root + "/") {
                // Deeper change: the direct child containing it may have new mtime / entry count.
                let rel = normalized.dropFirst(root == "/" ? 1 : root.count + 1)
                if let first = rel.split(separator: "/").first { names.insert(String(first)) }
            }
        }
        guard !names.isEmpty else { return }
        if names.count > Self.rescanThreshold {
            continuation.yield(.rescan)
        } else {
            log.trace("\(names.count) change(s) in \(path: path)")
            continuation.yield(.changed(names))
        }
    }
}
