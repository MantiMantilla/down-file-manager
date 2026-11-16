import Foundation
import CDirent

/// Local disk source backed by getattrlistbulk(2) (names + attributes in one syscall per buffer).
public final class LocalFileSource: FileSource {
    public let scheme = "file"
    public let capabilities: SourceCapabilities = [.watch, .trash, .clone, .thumbnails]

    public let firstBatchSize: Int
    public let batchSize: Int
    private let log: Logger
    private let perf: PerfMonitor?

    public init(firstBatchSize: Int = 256, batchSize: Int = 4096, hub: LogHub = .shared, perf: PerfMonitor? = nil) {
        self.firstBatchSize = firstBatchSize
        self.batchSize = batchSize
        log = Logger(.fs, hub: hub)
        self.perf = perf
    }

    public func list(_ location: Location) -> AsyncThrowingStream<[FileItem], any Error> {
        let path = location.path
        let first = firstBatchSize, size = batchSize
        let log = self.log, perf = self.perf
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let start = ContinuousClock.now
                var total = 0
                do {
                    try Self.enumerate(path: path, firstBatch: first, batch: size) { batch in
                        if Task.isCancelled { return false }
                        total += batch.count
                        continuation.yield(batch)
                        return true
                    }
                    let elapsed = ContinuousClock.now - start
                    perf?.record("list", elapsed, detail: "\(total) items")
                    log.debug("listed \(path: path) (\(total) items, \(PerfMonitor.format(elapsed)))")
                    continuation.finish()
                } catch {
                    log.error("list failed for \(path: path): \(error.localizedDescription)")
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func item(atPath path: String) async throws -> FileItem {
        try Self.statItem(path: path)
    }

    public func watch(_ location: Location) -> AsyncStream<WatchEvent> {
        DirectoryWatcher.stream(for: location.path, log: Logger(.watch, hub: log.hub))
    }

    // MARK: - Synchronous core (also used by tests and search)

    /// Calls `deliver` with batches; return false from `deliver` to stop early.
    public static func enumerate(path: String, firstBatch: Int = 256, batch: Int = 4096,
                                 deliver: ([FileItem]) throws -> Bool) throws {
        var err: Int32 = 0
        guard let ctx = cdirent_open(path, &err) else {
            throw err == ENOTDIR ? FileSourceError.notADirectory(path) : FileSourceError.posix(err, path: path)
        }
        defer { cdirent_close(ctx) }

        let prefix = path == "/" ? "/" : path + "/"
        var entry = cdirent_entry()
        var pending: [FileItem] = []
        var limit = firstBatch
        pending.reserveCapacity(limit)

        while true {
            let r = cdirent_next(ctx, &entry, &err)
            if r == 0 { break }
            if r < 0 { throw FileSourceError.posix(err, path: path) }
            if entry.error != 0 { continue }  // per-entry error (e.g. racing delete); skip it
            if let item = makeItem(entry: &entry, prefix: prefix) {
                pending.append(item)
            }
            if pending.count >= limit {
                guard try deliver(pending) else { return }
                pending.removeAll(keepingCapacity: true)
                limit = batch
            }
        }
        if !pending.isEmpty { _ = try deliver(pending) }
    }

    public static func listAll(path: String) throws -> [FileItem] {
        var all: [FileItem] = []
        try enumerate(path: path) { all.append(contentsOf: $0); return true }
        return all
    }

    public static func statItem(path: String) throws -> FileItem {
        var entry = cdirent_entry()
        let rc = cdirent_stat(path, &entry)
        if rc != 0 { throw FileSourceError.posix(rc, path: path) }
        let parent = (path as NSString).deletingLastPathComponent
        let prefix = parent == "/" ? "/" : parent + "/"
        // getattrlist reports "/" (or the volume name) as the name for volume roots; keep the path's name.
        let name = path == "/" ? "/" : (path as NSString).lastPathComponent
        guard let item = makeItem(entry: &entry, prefix: prefix, overrideName: name) else {
            throw FileSourceError.posix(EINVAL, path: path)
        }
        return item
    }

    private static func makeItem(entry: inout cdirent_entry, prefix: String, overrideName: String? = nil) -> FileItem? {
        let name: String = overrideName ?? withUnsafeBytes(of: &entry.name) { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            return String(decoding: UnsafeBufferPointer(rebasing: bytes[0..<Int(entry.name_len)]), as: UTF8.self)
        }
        guard !name.isEmpty, name != ".", name != ".." else { return nil }

        let kind: FileItem.Kind
        switch entry.kind {
        case CDIRENT_FILE: kind = .file
        case CDIRENT_DIR: kind = .directory
        case CDIRENT_SYMLINK: kind = .symlink
        default: kind = .other
        }
        let path = prefix + name
        let targetIsDir = kind == .symlink && isDirectoryFollowingLinks(path)
        let ext = (name as NSString).pathExtension
        let isPackage = kind == .directory && TypeCache.isPackageExtension(ext)
        return FileItem(
            path: path,
            name: name,
            kind: kind,
            size: Int64(clamping: entry.size),
            modified: Date(timeIntervalSince1970: Double(entry.mtime_sec) + Double(entry.mtime_nsec) / 1e9),
            created: Date(timeIntervalSince1970: Double(entry.crtime_sec) + Double(entry.crtime_nsec) / 1e9),
            isHidden: name.hasPrefix(".") || (entry.flags & UInt32(UF_HIDDEN)) != 0,
            isPackage: isPackage,
            entryCount: entry.entry_count >= 0 ? Int(entry.entry_count) : nil,
            mode: UInt16(truncatingIfNeeded: entry.mode),
            fileID: entry.file_id,
            symlinkTargetIsDirectory: targetIsDir
        )
    }
}

/// stat(2) (follows symlinks): is the final target a directory?
func isDirectoryFollowingLinks(_ path: String) -> Bool {
    var st = stat()
    return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
}
