import Foundation
import Synchronization
import os

/// Per-category level configuration, parsed from specs like `debug,ops=trace,watch=info`.
public struct LevelSpec: Sendable, Equatable {
    public var base: LogLevel
    public var overrides: [LogCategory: LogLevel]

    public init(base: LogLevel, overrides: [LogCategory: LogLevel] = [:]) {
        self.base = base
        self.overrides = overrides
    }

    public func level(for category: LogCategory) -> LogLevel { overrides[category] ?? base }

    /// Parses `debug`, `ops=trace`, `debug,ops=trace,watch=error`. Unknown tokens are ignored.
    public static func parse(_ spec: String, default base: LogLevel = .info) -> LevelSpec {
        var result = LevelSpec(base: base)
        for raw in spec.split(separator: ",") {
            let token = raw.trimmingCharacters(in: .whitespaces)
            if let eq = token.firstIndex(of: "=") {
                let name = token[..<eq], value = token[token.index(after: eq)...]
                if let cat = LogCategory(rawValue: name.lowercased()), let lvl = LogLevel(name: value) {
                    result.overrides[cat] = lvl
                }
            } else if let lvl = LogLevel(name: token) {
                result.base = lvl
            }
        }
        return result
    }
}

// MARK: - Unified log

/// Always-on sink into the unified logging system (subsystem `app.down`).
/// Private segments are already replaced with `<private>` before they get here.
public final class OSLogSink: LogSink {
    private let loggers: [LogCategory: os.Logger]
    private let spec = Mutex(LevelSpec(base: .info))

    public init(subsystem: String = "app.down") {
        var map: [LogCategory: os.Logger] = [:]
        for cat in LogCategory.allCases { map[cat] = os.Logger(subsystem: subsystem, category: cat.rawValue) }
        loggers = map
    }

    public func setSpec(_ new: LevelSpec) { spec.withLock { $0 = new } }
    public func minimumLevel(for category: LogCategory) -> LogLevel { spec.withLock { $0.level(for: category) } }

    public func write(_ entry: LogEntry) {
        guard let logger = loggers[entry.category] else { return }
        let text = entry.actionID.map { "\($0) \(entry.redactedMessage)" } ?? entry.redactedMessage
        switch entry.level {
        case .trace, .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        case .fault: logger.fault("\(text, privacy: .public)")
        }
    }
}

// MARK: - Ring buffer

/// Fixed-capacity in-memory buffer feeding the Debug Console.
public final class RingBufferSink: LogSink {
    private struct Storage {
        var buffer: [LogEntry?]
        var head = 0      // next write index
        var count = 0
        var spec = LevelSpec(base: .info)
    }

    public let capacity: Int
    private let storage: Mutex<Storage>

    public init(capacity: Int = 10_000) {
        self.capacity = capacity
        storage = Mutex(Storage(buffer: Array(repeating: nil, count: capacity)))
    }

    public func setSpec(_ new: LevelSpec) { storage.withLock { $0.spec = new } }
    public func minimumLevel(for category: LogCategory) -> LogLevel { storage.withLock { $0.spec.level(for: category) } }

    public func write(_ entry: LogEntry) {
        storage.withLock { s in
            s.buffer[s.head] = entry
            s.head = (s.head + 1) % capacity
            s.count = min(s.count + 1, capacity)
        }
    }

    /// Entries in chronological order, optionally only those with `id > afterID`.
    public func entries(after afterID: UInt64 = 0) -> [LogEntry] {
        storage.withLock { s in
            var out: [LogEntry] = []
            out.reserveCapacity(s.count)
            let start = (s.head - s.count + capacity) % capacity
            for i in 0..<s.count {
                if let e = s.buffer[(start + i) % capacity], e.id > afterID { out.append(e) }
            }
            return out
        }
    }

    public func clear() {
        storage.withLock { s in
            s.buffer = Array(repeating: nil, count: capacity)
            s.head = 0
            s.count = 0
        }
    }

    public var count: Int { storage.withLock { $0.count } }
}

// MARK: - stderr

/// Colored one-line-per-entry output for terminal launches.
public final class StderrSink: LogSink {
    private let spec: Mutex<LevelSpec>
    private let colorize: Bool
    private let lock = Mutex(())
    private let formatter: LogLineFormatter

    public init(spec: LevelSpec, colorize: Bool = isatty(STDERR_FILENO) != 0,
                homeDirectory: String = NSHomeDirectory()) {
        self.spec = Mutex(spec)
        self.colorize = colorize
        formatter = LogLineFormatter(homeDirectory: homeDirectory)
    }

    public func setSpec(_ new: LevelSpec) { spec.withLock { $0 = new } }
    public func minimumLevel(for category: LogCategory) -> LogLevel { spec.withLock { $0.level(for: category) } }

    public func write(_ entry: LogEntry) {
        var line = formatter.format(entry, redaction: .abbreviateHome)
        if colorize { line = Self.color(for: entry.level) + line + "\u{1B}[0m" }
        line += "\n"
        lock.withLock { _ in FileHandle.standardError.write(Data(line.utf8)) }
    }

    private static func color(for level: LogLevel) -> String {
        switch level {
        case .trace: "\u{1B}[90m"
        case .debug: "\u{1B}[36m"
        case .info: "\u{1B}[0m"
        case .notice: "\u{1B}[34m"
        case .error: "\u{1B}[31m"
        case .fault: "\u{1B}[1;31m"
        }
    }
}

// MARK: - Rolling file

/// Opt-in file log with size-based rotation: down.log, down.1.log … down.(keep-1).log
public final class RollingFileSink: LogSink {
    private struct State {
        var handle: FileHandle?
        var size: UInt64 = 0
        var spec = LevelSpec(base: .info)
    }

    public let directory: URL
    public let maxBytes: UInt64
    public let keep: Int
    private let state = Mutex(State())
    private let formatter: LogLineFormatter

    public init(directory: URL, maxBytes: UInt64 = 2 * 1024 * 1024, keep: Int = 5,
                homeDirectory: String = NSHomeDirectory()) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.keep = keep
        formatter = LogLineFormatter(homeDirectory: homeDirectory)
    }

    deinit { state.withLock { try? $0.handle?.close() } }

    public var currentFile: URL { directory.appending(path: "down.log") }

    public func setSpec(_ new: LevelSpec) { state.withLock { $0.spec = new } }
    public func minimumLevel(for category: LogCategory) -> LogLevel { state.withLock { $0.spec.level(for: category) } }

    public func write(_ entry: LogEntry) {
        let data = Data((formatter.format(entry, redaction: .abbreviateHome) + "\n").utf8)
        state.withLock { s in
            if s.handle == nil { open(&s) }
            if s.size + UInt64(data.count) > maxBytes {
                rotate(&s)
            }
            guard let handle = s.handle else { return }
            handle.write(data)
            s.size += UInt64(data.count)
        }
    }

    private func open(_ s: inout State) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if !fm.fileExists(atPath: currentFile.path) {
            fm.createFile(atPath: currentFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        s.handle = try? FileHandle(forWritingTo: currentFile)
        s.size = (try? s.handle?.seekToEnd()) ?? 0
    }

    private func rotate(_ s: inout State) {
        try? s.handle?.close()
        s.handle = nil
        let fm = FileManager.default
        func file(_ i: Int) -> URL { i == 0 ? currentFile : directory.appending(path: "down.\(i).log") }
        try? fm.removeItem(at: file(keep - 1))
        if keep > 1 {
            for i in stride(from: keep - 2, through: 0, by: -1) {
                try? fm.moveItem(at: file(i), to: file(i + 1))
            }
        }
        open(&s)
    }
}

// MARK: - Formatting / redaction

public enum Redaction: Sendable, Equatable {
    /// Show everything.
    case none
    /// Replace the home directory with `~` inside private segments.
    case abbreviateHome
    /// `~` for home and private segments' file names replaced with short hashes.
    case anonymize
}

public struct LogLineFormatter: Sendable {
    public let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    /// 24-hour `HH:mm:ss.SSS` in the local time zone.
    public static func time(_ date: Date) -> String {
        var t = time_t(date.timeIntervalSince1970)
        var parts = tm()
        localtime_r(&t, &parts)
        let ms = Int((date.timeIntervalSince1970 - Double(t)) * 1000) % 1000
        return String(format: "%02d:%02d:%02d.%03d", parts.tm_hour, parts.tm_min, parts.tm_sec, max(0, ms))
    }

    /// `12:03:44.120 DEBUG [fs] #a1f3 listed ~/src (4812 items, 38 ms)`
    public func format(_ entry: LogEntry, redaction: Redaction) -> String {
        var line = Self.time(entry.date)
        line += " "
        line += entry.level.description.padding(toLength: 6, withPad: " ", startingAt: 0)
        line += "[\(entry.category.rawValue)] "
        if let id = entry.actionID { line += "\(id) " }
        line += message(entry, redaction: redaction)
        return line
    }

    public func message(_ entry: LogEntry, redaction: Redaction) -> String {
        entry.segments.map { seg in
            guard seg.privacy == .private else { return seg.text }
            switch redaction {
            case .none: return seg.text
            case .abbreviateHome: return abbreviateHome(seg.text)
            case .anonymize: return anonymize(seg.text)
            }
        }.joined()
    }

    public func abbreviateHome(_ text: String) -> String {
        guard !homeDirectory.isEmpty else { return text }
        if text == homeDirectory { return "~" }
        return text.replacingOccurrences(of: homeDirectory + "/", with: "~/")
    }

    /// `~/Documents/taxes/2025.pdf` → `~/Documents/3f2a/c41e.pdf` (first level kept for context).
    public func anonymize(_ text: String) -> String {
        let abbreviated = abbreviateHome(text)
        var parts = abbreviated.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        // parts[0] is "~" or "" (absolute path); parts[1] is the first folder, kept for context.
        for i in parts.indices where i >= 2 && !parts[i].isEmpty {
            let name = parts[i]
            let ext = (name as NSString).pathExtension
            let hash = Self.shortHash(name)
            parts[i] = ext.isEmpty ? hash : "\(hash).\(ext)"
        }
        return parts.joined(separator: "/")
    }

    /// Stable, non-cryptographic 4-hex-digit hash (FNV-1a), enough to tell names apart.
    static func shortHash(_ s: String) -> String {
        var h: UInt32 = 2_166_136_261
        for b in s.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return String(format: "%04x", h & 0xFFFF)
    }
}
