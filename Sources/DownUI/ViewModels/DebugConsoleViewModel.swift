import Foundation
import Observation
import DownCore

/// Filters and buffers ring-buffer log entries for the Debug Console. Pulls new entries on `tick`
/// (10 Hz while visible) so heavy logging never floods the main thread with per-entry updates.
@MainActor @Observable
public final class DebugConsoleViewModel {
    public enum Action: Sendable {
        case tick
        case setMinLevel(LogLevel)
        case toggleCategory(LogCategory)
        case setAllCategories(Bool)
        case setSearch(String)
        case setRegex(Bool)
        case filterAction(ActionID?)
        case setPaused(Bool)
        case clear
    }

    public private(set) var visible: [LogEntry] = []
    public private(set) var minLevel: LogLevel = .trace
    public private(set) var categories: Set<LogCategory> = Set(LogCategory.allCases)
    public private(set) var search = ""
    public private(set) var useRegex = false
    public private(set) var regexError: String?
    public private(set) var actionFilter: ActionID?
    public private(set) var paused = false
    /// Bumped when `visible` changes (table reload trigger).
    public private(set) var revision = 0
    public private(set) var totalBuffered = 0

    @ObservationIgnored private var all: [LogEntry] = []
    @ObservationIgnored private var lastID: UInt64 = 0
    @ObservationIgnored private var regex: NSRegularExpression?
    @ObservationIgnored private let source: () -> [LogEntry]
    @ObservationIgnored private let sourceAfter: (UInt64) -> [LogEntry]
    @ObservationIgnored private let clearSource: () -> Void
    @ObservationIgnored public let capacity: Int

    public init(ring: RingBufferSink) {
        source = { ring.entries() }
        sourceAfter = { ring.entries(after: $0) }
        clearSource = { ring.clear() }
        capacity = ring.capacity
    }

    public func send(_ action: Action) {
        switch action {
        case .tick:
            guard !paused else { return }
            let fresh = sourceAfter(lastID)
            guard !fresh.isEmpty else { return }
            lastID = fresh.last!.id
            all.append(contentsOf: fresh)
            if all.count > capacity { all.removeFirst(all.count - capacity) }
            totalBuffered = all.count
            let matching = fresh.filter(matches)
            if !matching.isEmpty {
                visible.append(contentsOf: matching)
                if visible.count > capacity { visible.removeFirst(visible.count - capacity) }
                revision &+= 1
            }
        case .setMinLevel(let l):
            minLevel = l
            refilter()
        case .toggleCategory(let c):
            if categories.contains(c) { categories.remove(c) } else { categories.insert(c) }
            refilter()
        case .setAllCategories(let on):
            categories = on ? Set(LogCategory.allCases) : []
            refilter()
        case .setSearch(let s):
            search = s
            compileRegex()
            refilter()
        case .setRegex(let on):
            useRegex = on
            compileRegex()
            refilter()
        case .filterAction(let id):
            actionFilter = id
            refilter()
        case .setPaused(let p):
            paused = p
            if !p { send(.tick) }
        case .clear:
            clearSource()
            all = []
            visible = []
            totalBuffered = 0
            revision &+= 1
        }
    }

    /// Initial load when the console opens.
    public func loadExisting() {
        all = source()
        lastID = all.last?.id ?? 0
        totalBuffered = all.count
        refilter()
    }

    public func matches(_ e: LogEntry) -> Bool {
        guard e.level >= minLevel, categories.contains(e.category) else { return false }
        if let actionFilter, e.actionID != actionFilter { return false }
        guard !search.isEmpty else { return true }
        let text = e.message
        if useRegex {
            guard let regex else { return true }  // invalid regex: don't hide everything
            return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        return text.localizedCaseInsensitiveContains(search)
    }

    private func refilter() {
        visible = all.filter(matches)
        revision &+= 1
    }

    private func compileRegex() {
        regex = nil
        regexError = nil
        guard useRegex, !search.isEmpty else { return }
        do {
            regex = try NSRegularExpression(pattern: search, options: [.caseInsensitive])
        } catch {
            regexError = "Invalid regular expression"
        }
    }

    public func diagnostics(settings: Settings) -> String {
        Diagnostics.report(entries: all, settingsSummary: settings.diagnosticsSummary,
                           redaction: settings.anonymizeExports ? .anonymize : .abbreviateHome)
    }

    public func copyText(for entries: [LogEntry], anonymize: Bool) -> String {
        let f = LogLineFormatter()
        return entries.map { f.format($0, redaction: anonymize ? .anonymize : .abbreviateHome) }.joined(separator: "\n")
    }
}
