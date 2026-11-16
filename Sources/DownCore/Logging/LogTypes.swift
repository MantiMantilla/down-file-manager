import Foundation
import Synchronization

public enum LogLevel: UInt8, Sendable, Comparable, CaseIterable, Codable, CustomStringConvertible {
    case trace, debug, info, notice, error, fault

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var description: String {
        switch self {
        case .trace: "TRACE"
        case .debug: "DEBUG"
        case .info: "INFO"
        case .notice: "NOTICE"
        case .error: "ERROR"
        case .fault: "FAULT"
        }
    }

    public init?(name: some StringProtocol) {
        switch name.lowercased() {
        case "trace": self = .trace
        case "debug": self = .debug
        case "info": self = .info
        case "notice", "default", "warn", "warning": self = .notice
        case "error": self = .error
        case "fault": self = .fault
        default: return nil
        }
    }
}

public enum LogCategory: String, Sendable, CaseIterable, Codable {
    case app, nav, fs, watch, ops, dnd, volumes, ui, settings, perf
}

/// Correlates an action with the effects and errors it causes (shown as `#a1f3`).
public struct ActionID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }

    private static let counter = Atomic<UInt32>(0)
    public static func next() -> ActionID {
        ActionID(raw: counter.add(1, ordering: .relaxed).newValue & 0xFFFF)
    }

    public var description: String { "#" + String(format: "%04x", raw) }
}

/// A log message that remembers which interpolated segments are private (paths, names),
/// so each sink can render it at the right privacy level.
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    public enum Privacy: Sendable { case `public`, `private` }

    public struct Segment: Sendable, Equatable {
        public let text: String
        public let privacy: Privacy
    }

    public let segments: [Segment]

    public init(stringLiteral value: String) {
        segments = [Segment(text: value, privacy: .public)]
    }

    public init(stringInterpolation: StringInterpolation) {
        segments = stringInterpolation.segments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var segments: [Segment] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            segments.reserveCapacity(interpolationCount * 2 + 1)
        }

        public mutating func appendLiteral(_ literal: String) {
            guard !literal.isEmpty else { return }
            segments.append(Segment(text: literal, privacy: .public))
        }

        public mutating func appendInterpolation<T>(_ value: T, privacy: Privacy = .public) {
            segments.append(Segment(text: String(describing: value), privacy: privacy))
        }

        /// Paths are private by default.
        public mutating func appendInterpolation(path: some StringProtocol) {
            segments.append(Segment(text: String(path), privacy: .private))
        }

        public mutating func appendInterpolation(url: URL) {
            segments.append(Segment(text: url.isFileURL ? url.path(percentEncoded: false) : url.absoluteString,
                                    privacy: .private))
        }
    }

    /// Everything visible (in-process sinks: ring buffer, stderr).
    public var full: String { segments.map(\.text).joined() }

    /// Private segments replaced with `<private>` (unified log).
    public var redacted: String {
        segments.map { $0.privacy == .private ? "<private>" : $0.text }.joined()
    }
}

public struct LogEntry: Sendable, Identifiable {
    public let id: UInt64
    public let date: Date
    public let level: LogLevel
    public let category: LogCategory
    public let segments: [LogMessage.Segment]
    public let actionID: ActionID?
    public let metadata: [String: String]
    public let file: String
    public let line: Int
    public let thread: String

    public init(id: UInt64, date: Date, level: LogLevel, category: LogCategory, segments: [LogMessage.Segment],
                actionID: ActionID?, metadata: [String: String], file: String, line: Int, thread: String) {
        self.id = id
        self.date = date
        self.level = level
        self.category = category
        self.segments = segments
        self.actionID = actionID
        self.metadata = metadata
        self.file = file
        self.line = line
        self.thread = thread
    }

    public var message: String { segments.map(\.text).joined() }

    public var redactedMessage: String {
        segments.map { $0.privacy == .private ? "<private>" : $0.text }.joined()
    }
}

/// A destination for log entries. Implementations must be thread-safe.
public protocol LogSink: AnyObject, Sendable {
    /// Lowest level this sink wants for `category`.
    func minimumLevel(for category: LogCategory) -> LogLevel
    func write(_ entry: LogEntry)
}

extension LogSink {
    /// Lowest level across every category (used to compute the hub's fast-path threshold).
    public var lowestLevel: LogLevel {
        LogCategory.allCases.map { minimumLevel(for: $0) }.min() ?? .fault
    }
}
