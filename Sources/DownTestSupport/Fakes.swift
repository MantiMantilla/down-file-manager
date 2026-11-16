import Foundation
import Synchronization
import DownCore

/// Scriptable in-memory file source.
public final class FakeFileSource: FileSource, @unchecked Sendable {
    public let scheme: String
    public let capabilities: SourceCapabilities = [.watch]

    private struct State {
        var folders: [String: [FileItem]] = [:]
        var errors: [String: any Error] = [:]
        var gates: [String: AsyncStream<Void>] = [:]
        var watchers: [String: AsyncStream<WatchEvent>.Continuation] = [:]
        var listCalls: [String] = []
    }
    private let state = Mutex(State())
    public var batchSize = 2

    public init(scheme: String = "file") { self.scheme = scheme }

    /// Defines a folder's contents. Names ending in "/" are folders.
    public func set(_ path: String, _ names: [String], modified: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        let items = names.map { raw -> FileItem in
            let isDir = raw.hasSuffix("/")
            let name = isDir ? String(raw.dropLast()) : raw
            return FakeFileSource.item(path == "/" ? "/\(name)" : "\(path)/\(name)", isDir: isDir, modified: modified)
        }
        state.withLock { $0.folders[path] = items }
    }

    public func setItems(_ path: String, _ items: [FileItem]) { state.withLock { $0.folders[path] = items } }

    public func fail(_ path: String, with error: any Error) { state.withLock { $0.errors[path] = error } }

    /// Makes `list(path)` wait until `release(path)` is called (to test stale results / cancellation).
    public func hold(_ path: String) -> AsyncStream<Void>.Continuation {
        let (stream, cont) = AsyncStream<Void>.makeStream()
        state.withLock { $0.gates[path] = stream }
        return cont
    }

    public var listCalls: [String] { state.withLock { $0.listCalls } }

    public func emit(_ event: WatchEvent, for path: String) {
        _ = state.withLock { $0.watchers[path]?.yield(event) }
    }

    public static func item(_ path: String, isDir: Bool = false, size: Int64 = 100,
                            modified: Date = Date(timeIntervalSince1970: 1_700_000_000),
                            hidden: Bool? = nil) -> FileItem {
        let name = (path as NSString).lastPathComponent
        return FileItem(path: path, name: name, kind: isDir ? .directory : .file, size: size,
                        modified: modified, created: modified, isHidden: hidden ?? name.hasPrefix("."),
                        isPackage: false, entryCount: isDir ? 0 : nil, mode: 0o644, fileID: UInt64(abs(path.hashValue)))
    }

    public func list(_ location: Location) -> AsyncThrowingStream<[FileItem], any Error> {
        let path = location.path
        let (items, error, gate) = state.withLock { s -> ([FileItem]?, (any Error)?, AsyncStream<Void>?) in
            s.listCalls.append(path)
            return (s.folders[path], s.errors[path], s.gates[path])
        }
        let size = batchSize
        return AsyncThrowingStream { cont in
            let task = Task {
                if let gate { for await _ in gate { break } }
                if let error { cont.finish(throwing: error); return }
                guard let items else { cont.finish(throwing: FileSourceError.posix(ENOENT, path: path)); return }
                var i = 0
                while i < items.count {
                    if Task.isCancelled { break }
                    cont.yield(Array(items[i..<min(i + size, items.count)]))
                    i += size
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public func item(atPath path: String) async throws -> FileItem {
        let parent = (path as NSString).deletingLastPathComponent
        let found = state.withLock { $0.folders[parent]?.first { $0.path == path } }
        guard let found else { throw FileSourceError.posix(ENOENT, path: path) }
        return found
    }

    public func watch(_ location: Location) -> AsyncStream<WatchEvent> {
        let (stream, cont) = AsyncStream<WatchEvent>.makeStream()
        state.withLock { $0.watchers[location.path] = cont }
        return stream
    }
}

public final class FakeWorkspace: WorkspaceProviding, @unchecked Sendable {
    private let state = Mutex<(opened: [URL], terminal: [(URL, String?)])>(([], []))
    public var terminals: [TerminalApp] = [TerminalApp(bundleID: "com.apple.Terminal", name: "Terminal")]

    public init() {}

    public func open(_ url: URL) async -> Bool {
        state.withLock { $0.opened.append(url) }
        return true
    }

    public func openFolderInTerminal(_ folder: URL, terminalBundleID: String?) async throws {
        state.withLock { $0.terminal.append((folder, terminalBundleID)) }
    }

    public func installedTerminals() -> [TerminalApp] { terminals }

    public var opened: [URL] { state.withLock { $0.opened } }
    public var terminalOpens: [(URL, String?)] { state.withLock { $0.terminal } }
}

extension AppEnvironment {
    /// Environment wired with fakes and an isolated log hub.
    public static func test(source: FakeFileSource = FakeFileSource(),
                            workspace: FakeWorkspace = FakeWorkspace(),
                            hub: LogHub? = nil,
                            home: String = "/home") -> AppEnvironment {
        let hub = hub ?? makeTestHub().0
        return AppEnvironment(logHub: hub, sources: SourceRegistry([source]), workspace: workspace,
                              perf: PerfMonitor(hub: hub), homePath: home, springDelay: .milliseconds(50))
    }
}
