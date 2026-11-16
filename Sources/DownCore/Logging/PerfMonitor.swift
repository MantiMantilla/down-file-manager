import Foundation
import Synchronization
import os

/// Wraps hot paths in os_signpost intervals and keeps recent durations for the Debug Console's Perf tab.
public final class PerfMonitor: Sendable {
    public struct Stats: Sendable, Identifiable {
        public var id: String { name }
        public let name: String
        public let count: Int
        public let last: Duration
        public let p50: Duration
        public let p95: Duration
    }

    private let signposter: OSSignposter
    private let samples = Mutex<[String: [Duration]]>([:])
    private let counts = Mutex<[String: Int]>([:])
    private let keep: Int
    private let log: Logger

    public init(subsystem: String = "app.down", keep: Int = 200, hub: LogHub = .shared) {
        signposter = OSSignposter(subsystem: subsystem, category: "perf")
        self.keep = keep
        log = Logger(.perf, hub: hub)
    }

    @discardableResult
    public func measure<T>(_ name: StaticString, detail: String = "",
                           _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            record(String(describing: name), ContinuousClock.now - start, detail: detail)
        }
        return try body()
    }

    @discardableResult
    public func measure<T>(_ name: StaticString, detail: String = "",
                           _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        let start = ContinuousClock.now
        defer {
            signposter.endInterval(name, state)
            record(String(describing: name), ContinuousClock.now - start, detail: detail)
        }
        return try await body()
    }

    public func record(_ name: String, _ duration: Duration, detail: String = "") {
        samples.withLock { s in
            var list = s[name, default: []]
            list.append(duration)
            if list.count > keep { list.removeFirst(list.count - keep) }
            s[name] = list
        }
        counts.withLock { $0[name, default: 0] += 1 }
        log.debug("\(name) \(detail.isEmpty ? "" : detail + " ")took \(Self.format(duration))")
    }

    public func stats() -> [Stats] {
        let snapshot = samples.withLock { $0 }
        let totals = counts.withLock { $0 }
        return snapshot.keys.sorted().compactMap { name in
            guard let list = snapshot[name], let last = list.last else { return nil }
            let sorted = list.sorted()
            func pct(_ p: Double) -> Duration { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            return Stats(name: name, count: totals[name] ?? list.count, last: last, p50: pct(0.5), p95: pct(0.95))
        }
    }

    public static func format(_ d: Duration) -> String {
        let ms = Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
        return ms < 10 ? String(format: "%.2f ms", ms) : String(format: "%.0f ms", ms)
    }

    /// Physical memory footprint of this process (what Activity Monitor shows as "Memory").
    public static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
