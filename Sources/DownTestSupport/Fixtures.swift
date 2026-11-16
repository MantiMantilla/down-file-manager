import Foundation
import Synchronization
import DownCore

/// A unique temporary folder, deleted when the value is deinitialized.
public final class TempDir: @unchecked Sendable {
    public let url: URL
    public var path: String { url.path(percentEncoded: false).trimmingSuffix("/") }

    public init(_ label: String = "test") {
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        url = base.appending(path: "down-\(label)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    public func file(_ relative: String, contents: String = "", modified: Date? = nil) -> String {
        let p = url.appending(path: relative).path(percentEncoded: false)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: p, contents: Data(contents.utf8))
        if let modified { try! FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: p) }
        return p
    }

    @discardableResult
    public func dir(_ relative: String) -> String {
        let p = url.appending(path: relative).path(percentEncoded: false).trimmingSuffix("/")
        try! FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        return p
    }

    @discardableResult
    public func symlink(_ relative: String, to target: String) -> String {
        let p = url.appending(path: relative).path(percentEncoded: false)
        try! FileManager.default.createSymbolicLink(atPath: p, withDestinationPath: target)
        return p
    }

    public var location: Location { .file(path) }
}

extension String {
    func trimmingSuffix(_ s: String) -> String {
        hasSuffix(s) && count > 1 ? String(dropLast(s.count)) : self
    }
}

/// Captures log entries for assertions.
public final class TestLogSink: LogSink {
    private let stored = Mutex<[LogEntry]>([])
    private let level: LogLevel

    public init(level: LogLevel = .trace) { self.level = level }

    public func minimumLevel(for category: LogCategory) -> LogLevel { level }
    public func write(_ entry: LogEntry) { stored.withLock { $0.append(entry) } }

    public var entries: [LogEntry] { stored.withLock { $0 } }
    public func messages(_ category: LogCategory? = nil) -> [String] {
        entries.filter { category == nil || $0.category == category }.map(\.message)
    }
    public func contains(_ substring: String, category: LogCategory? = nil) -> Bool {
        messages(category).contains { $0.contains(substring) }
    }
}

/// A hub with only a TestLogSink attached, isolated from the shared hub.
public func makeTestHub(level: LogLevel = .trace) -> (LogHub, TestLogSink) {
    let hub = LogHub()
    let sink = TestLogSink(level: level)
    hub.add(sink)
    return (hub, sink)
}

public enum TestEnv {
    public static var integration: Bool { ProcessInfo.processInfo.environment["DOWN_TEST_INTEGRATION"] == "1" }
    public static var volumes: Bool { ProcessInfo.processInfo.environment["DOWN_TEST_VOLUMES"] == "1" }
    public static var snapshots: Bool { ProcessInfo.processInfo.environment["DOWN_TEST_SNAPSHOTS"] == "1" }
    public static var performance: Bool { ProcessInfo.processInfo.environment["DOWN_TEST_PERFORMANCE"] == "1" }
}
