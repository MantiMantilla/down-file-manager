import Foundation
import Synchronization

/// Fans log entries out to sinks. A disabled level costs one atomic load.
public final class LogHub: Sendable {
    public static let shared = LogHub()

    /// Same call site logging more than this many times per window gets collapsed.
    public static let floodLimit = 20
    public static let floodWindow: TimeInterval = 1

    private struct FloodState {
        var windowStart: Date
        var count: Int
        var suppressed: Int
    }

    private struct State {
        var sinks: [any LogSink] = []
        var flood: [String: FloodState] = [:]
    }

    private let state = Mutex(State())
    private let threshold = Atomic<UInt8>(LogLevel.fault.rawValue + 1)
    private let sequence = Atomic<UInt64>(0)
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func add(_ sink: any LogSink) {
        state.withLock { $0.sinks.append(sink) }
        recomputeThreshold()
    }

    public func remove(_ sink: any LogSink) {
        state.withLock { $0.sinks.removeAll { $0 === sink } }
        recomputeThreshold()
    }

    /// Call after a sink changes its levels.
    public func recomputeThreshold() {
        let lowest = state.withLock { s in s.sinks.map(\.lowestLevel).min() }
        threshold.store(lowest?.rawValue ?? LogLevel.fault.rawValue + 1, ordering: .relaxed)
    }

    @inline(__always)
    public func isEnabled(_ level: LogLevel) -> Bool {
        level.rawValue >= threshold.load(ordering: .relaxed)
    }

    public func log(_ level: LogLevel,
                    _ category: LogCategory,
                    _ message: () -> LogMessage,
                    actionID: ActionID? = nil,
                    metadata: [String: String] = [:],
                    file: String = #fileID,
                    line: Int = #line) {
        guard isEnabled(level) else { return }

        let date = now()
        let site = "\(file):\(line)"
        let (sinks, summary): ([any LogSink], LogEntry?) = state.withLock { s in
            var summary: LogEntry?
            var flood = s.flood[site] ?? FloodState(windowStart: date, count: 0, suppressed: 0)
            if date.timeIntervalSince(flood.windowStart) >= Self.floodWindow {
                if flood.suppressed > 0 {
                    summary = makeEntry(level: level, category: category,
                                        segments: [.init(text: "… repeated ×\(flood.suppressed) in \(Int(Self.floodWindow)) s", privacy: .public)],
                                        actionID: nil, metadata: [:], file: file, line: line, date: date)
                }
                flood = FloodState(windowStart: date, count: 0, suppressed: 0)
            }
            flood.count += 1
            let suppressed = flood.count > Self.floodLimit
            if suppressed { flood.suppressed += 1 }
            s.flood[site] = flood
            if s.flood.count > 4096 { s.flood.removeAll(keepingCapacity: true) }
            return (suppressed ? [] : s.sinks, summary)
        }

        if let summary { deliver(summary, to: sinksSnapshot()) }
        guard !sinks.isEmpty else { return }

        let msg = message()
        let entry = makeEntry(level: level, category: category, segments: msg.segments, actionID: actionID,
                              metadata: metadata, file: file, line: line, date: date)
        deliver(entry, to: sinks)
    }

    private func sinksSnapshot() -> [any LogSink] { state.withLock { $0.sinks } }

    private func deliver(_ entry: LogEntry, to sinks: [any LogSink]) {
        for sink in sinks where entry.level >= sink.minimumLevel(for: entry.category) {
            sink.write(entry)
        }
    }

    private func makeEntry(level: LogLevel, category: LogCategory, segments: [LogMessage.Segment],
                           actionID: ActionID?, metadata: [String: String], file: String, line: Int,
                           date: Date) -> LogEntry {
        LogEntry(id: sequence.add(1, ordering: .relaxed).newValue,
                 date: date, level: level, category: category, segments: segments,
                 actionID: actionID, metadata: metadata, file: file, line: line,
                 thread: Thread.isMainThread ? "main" : "bg")
    }
}

/// Per-category logger. Messages are autoclosures: they're only built if some sink wants them.
public struct Logger: Sendable {
    public let category: LogCategory
    public let hub: LogHub

    public init(_ category: LogCategory, hub: LogHub = .shared) {
        self.category = category
        self.hub = hub
    }

    public func log(_ level: LogLevel, _ message: @autoclosure () -> LogMessage, actionID: ActionID? = nil,
                    metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        hub.log(level, category, message, actionID: actionID, metadata: metadata, file: file, line: line)
    }

    public func trace(_ message: @autoclosure () -> LogMessage, actionID: ActionID? = nil,
                      metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        hub.log(.trace, category, message, actionID: actionID, metadata: metadata, file: file, line: line)
    }

    public func debug(_ message: @autoclosure () -> LogMessage, actionID: ActionID? = nil,
                      metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        hub.log(.debug, category, message, actionID: actionID, metadata: metadata, file: file, line: line)
    }

    public func info(_ message: @autoclosure () -> LogMessage, actionID: ActionID? = nil,
                     metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        hub.log(.info, category, message, actionID: actionID, metadata: metadata, file: file, line: line)
    }

    public func notice(_ message: @autoclosure () -> LogMessage, actionID: ActionID? = nil,
                       metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        hub.log(.notice, category, message, actionID: actionID, metadata: metadata, file: file, line: line)
    }

    public func error(_ message: @autoclosure () -> LogMessage, actionID: ActionID? = nil,
                      metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        hub.log(.error, category, message, actionID: actionID, metadata: metadata, file: file, line: line)
    }

    public func fault(_ message: @autoclosure () -> LogMessage, actionID: ActionID? = nil,
                      metadata: [String: String] = [:], file: String = #fileID, line: Int = #line) {
        hub.log(.fault, category, message, actionID: actionID, metadata: metadata, file: file, line: line)
    }
}
