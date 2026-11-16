import Foundation
import Synchronization
import Testing
@testable import DownCore
import DownTestSupport

@Suite("Logging")
struct LoggingTests {
    @Test func routesByLevelPerSink() {
        let hub = LogHub()
        let verbose = TestLogSink(level: .debug)
        let quiet = TestLogSink(level: .error)
        hub.add(verbose)
        hub.add(quiet)
        let log = Logger(.fs, hub: hub)
        log.debug("d")
        log.info("i")
        log.error("e")
        #expect(verbose.messages() == ["d", "i", "e"])
        #expect(quiet.messages() == ["e"])
    }

    @Test func messagesAreNotBuiltBelowThreshold() {
        let hub = LogHub()
        hub.add(TestLogSink(level: .error))
        let counter = Atomic<Int>(0)
        func expensive() -> String { counter.add(1, ordering: .relaxed); return "x" }
        let log = Logger(.ui, hub: hub)
        for _ in 0..<100 { log.debug("value \(expensive())") }
        #expect(counter.load(ordering: .relaxed) == 0)
        log.error("value \(expensive())")
        #expect(counter.load(ordering: .relaxed) == 1)
    }

    @Test func privateSegmentsAreRedactedForUnifiedLog() {
        let msg: LogMessage = "listed \(path: "/Users/me/secret") (3 items)"
        #expect(msg.full == "listed /Users/me/secret (3 items)")
        #expect(msg.redacted == "listed <private> (3 items)")
    }

    @Test func actionIDsAreCarried() {
        let (hub, sink) = makeTestHub()
        let id = ActionID(raw: 0xA1F3)
        Logger(.dnd, hub: hub).info("drop", actionID: id)
        #expect(sink.entries.first?.actionID == id)
        #expect(id.description == "#a1f3")
    }

    @Test func ringBufferWrapsAround() {
        let ring = RingBufferSink(capacity: 3)
        ring.setSpec(LevelSpec(base: .trace))
        let hub = LogHub()
        hub.add(ring)
        let log = Logger(.app, hub: hub)
        for i in 1...5 { log.info("m\(i)") }
        #expect(ring.entries().map(\.message) == ["m3", "m4", "m5"])
        let lastID = ring.entries()[1].id
        #expect(ring.entries(after: lastID).map(\.message) == ["m5"])
        ring.clear()
        #expect(ring.count == 0)
    }

    @Test func ringBufferIsThreadSafe() async {
        let ring = RingBufferSink(capacity: 1000)
        ring.setSpec(LevelSpec(base: .trace))
        let hub = LogHub()
        hub.add(ring)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    let log = Logger(.app, hub: hub)
                    // Distinct call sites per task would be ideal; use metadata to vary and stay under flood limit.
                    for i in 0..<15 { log.info("t\(t)-\(i)") }
                }
            }
        }
        // 8 tasks × 15 from one call site: flood control allows 20 per window, the rest are suppressed.
        #expect(ring.count >= LogHub.floodLimit)
        #expect(ring.count <= 120)
    }

    @Test func floodControlCollapsesRepeats() {
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let hub = LogHub(now: { clock.withLock { $0 } })
        let sink = TestLogSink()
        hub.add(sink)
        let log = Logger(.watch, hub: hub)
        func storm() { log.debug("storm") }  // one call site
        for _ in 0..<100 { storm() }
        #expect(sink.entries.count == LogHub.floodLimit)
        clock.withLock { $0 = Date(timeIntervalSince1970: 2) }
        storm()
        let last2 = sink.messages().suffix(2)
        #expect(last2.first?.contains("repeated ×80") == true)
        #expect(last2.last == "storm")
    }

    @Test func levelSpecParsing() {
        let spec = LevelSpec.parse("debug,ops=trace,watch=error,bogus=1,nonsense,dnd=warning")
        #expect(spec.base == .debug)
        #expect(spec.level(for: .ops) == .trace)
        #expect(spec.level(for: .watch) == .error)
        #expect(spec.level(for: .fs) == .debug)
        #expect(spec.level(for: .dnd) == .notice)  // "warning" is accepted as an alias
    }

    @Test func formatterAbbreviatesAndAnonymizes() {
        let f = LogLineFormatter(homeDirectory: "/Users/me")
        let entry = LogEntry(id: 1, date: Date(timeIntervalSince1970: 0), level: .debug, category: .fs,
                             segments: [.init(text: "listed ", privacy: .public),
                                        .init(text: "/Users/me/Documents/taxes/2025.pdf", privacy: .private)],
                             actionID: ActionID(raw: 1), metadata: [:], file: "f", line: 1, thread: "main")
        #expect(f.message(entry, redaction: .none) == "listed /Users/me/Documents/taxes/2025.pdf")
        #expect(f.message(entry, redaction: .abbreviateHome) == "listed ~/Documents/taxes/2025.pdf")
        let anon = f.message(entry, redaction: .anonymize)
        #expect(anon.hasPrefix("listed ~/Documents/"))
        #expect(!anon.contains("taxes"))
        #expect(anon.hasSuffix(".pdf"))
        #expect(f.format(entry, redaction: .abbreviateHome).contains("DEBUG [fs] #0001 listed ~/Documents"))
    }

    @Test func rollingFileRotates() throws {
        let tmp = TempDir("logs")
        let sink = RollingFileSink(directory: tmp.url, maxBytes: 300, keep: 3)
        sink.setSpec(LevelSpec(base: .trace))
        let hub = LogHub()
        hub.add(sink)
        let log = Logger(.app, hub: hub)
        for i in 0..<15 { log.log(.info, "line number \(i) with some padding text", metadata: ["i": "\(i)"], line: i) }
        let files = try FileManager.default.contentsOfDirectory(atPath: tmp.path).sorted()
        #expect(files == ["down.1.log", "down.2.log", "down.log"])
    }

    @Test func perfMonitorComputesPercentiles() {
        let (hub, _) = makeTestHub()
        let perf = PerfMonitor(hub: hub)
        for ms in 1...100 { perf.record("list", .milliseconds(ms)) }
        let stats = try! #require(perf.stats().first)
        #expect(stats.count == 100)
        #expect(stats.p50 == .milliseconds(50))
        #expect(stats.p95 == .milliseconds(95))
        #expect(PerfMonitor.memoryFootprint() > 0)
    }
}
