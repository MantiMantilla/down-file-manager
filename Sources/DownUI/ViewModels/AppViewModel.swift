import Foundation
import Observation
import DownCore

/// App-wide state: settings, theme, pins, keybindings, debug-console toggles.
@MainActor @Observable
public final class AppViewModel {
    public enum Action: Sendable, CustomStringConvertible {
        case setTheme(Theme)
        case setShowHidden(Bool)
        case setDefaultViewMode(ViewMode)
        case setSort(FileSortOrder)
        case setTerminal(String?)
        case setSidebarVisible(Bool)
        case setListZoom(Double)
        case addPin(path: String, name: String?, at: Int?)
        case removePin(UUID)
        case movePin(from: Int, to: Int)
        case renamePin(UUID, String)
        case setShortcuts(Command, [KeyCombo]?)
        case setDebugConsoleEnabled(Bool)
        case setVerboseLogging(Bool)
        case setVerboseCategories(Set<LogCategory>)
        case setFileLogging(Bool)
        case setAnonymizeExports(Bool)

        public var description: String {
            switch self {
            case .setTheme(let t): "setTheme(\(t.rawValue))"
            case .setShowHidden(let b): "setShowHidden(\(b))"
            case .setDefaultViewMode(let m): "setDefaultViewMode(\(m.rawValue))"
            case .setSort(let s): "setSort(\(s.field.rawValue), asc: \(s.ascending))"
            case .setTerminal(let id): "setTerminal(\(id ?? "default"))"
            case .setSidebarVisible(let b): "setSidebarVisible(\(b))"
            case .setListZoom(let z): "setListZoom(\(z))"
            case .addPin(_, let name, let at): "addPin(\(name ?? "<path>"), at: \(at.map(String.init) ?? "end"))"
            case .removePin: "removePin"
            case .movePin(let f, let t): "movePin(\(f) → \(t))"
            case .renamePin: "renamePin"
            case .setShortcuts(let c, let k): "setShortcuts(\(c.rawValue), \(k.map { $0.map(\.description).joined(separator: " ") } ?? "default"))"
            case .setDebugConsoleEnabled(let b): "setDebugConsoleEnabled(\(b))"
            case .setVerboseLogging(let b): "setVerboseLogging(\(b))"
            case .setVerboseCategories(let c): "setVerboseCategories(\(c.map(\.rawValue).sorted()))"
            case .setFileLogging(let b): "setFileLogging(\(b))"
            case .setAnonymizeExports(let b): "setAnonymizeExports(\(b))"
            }
        }
    }

    public private(set) var settings: Settings
    public private(set) var keybindings: Keybindings
    /// `--debug` on the command line: console + verbose for this session only.
    public let debugSession: Bool
    public let env: AppEnvironment
    public let logging: LoggingSystem?

    @ObservationIgnored private let store: SettingsStore?
    @ObservationIgnored private let log: Logger
    @ObservationIgnored private var browsers: [WeakBrowser] = []

    public init(env: AppEnvironment, settings: Settings, store: SettingsStore?, logging: LoggingSystem?,
                debugSession: Bool = false) {
        self.env = env
        self.settings = settings
        self.store = store
        self.logging = logging
        self.debugSession = debugSession
        keybindings = Keybindings(settingsOverrides: settings.shortcutOverrides)
        log = env.logger(.settings)
        applyLogging()
    }

    public var debugConsoleAvailable: Bool { settings.debugConsoleEnabled || debugSession }

    public func send(_ action: Action, id: ActionID = .next()) {
        log.debug("action \(action)", actionID: id)
        switch action {
        case .setTheme(let t): update { $0.theme = t }
        case .setShowHidden(let b):
            update { $0.showHidden = b }
            broadcast { $0.send(.settingsChanged, id: id) }
        case .setDefaultViewMode(let m): update { $0.defaultViewMode = m }
        case .setSort(let s): update { $0.sort = s }
        case .setTerminal(let id): update { $0.terminalBundleID = id }
        case .setSidebarVisible(let b): update { $0.sidebarVisible = b }
        case .setListZoom(let z): update { $0.listZoom = min(2.0, max(0.75, z)) }
        case .addPin(let path, let name, let index):
            let loc = Location.file(path)
            guard !settings.pins.contains(where: { $0.path == loc.path }) else {
                log.info("already pinned: \(path: loc.path)", actionID: id)
                return
            }
            let pin = Pin(name: name ?? loc.name, path: loc.path, bookmark: Self.bookmark(for: loc.path))
            update { s in
                let i = min(max(index ?? s.pins.count, 0), s.pins.count)
                s.pins.insert(pin, at: i)
            }
            log.info("pinned \(path: loc.path)", actionID: id)
        case .removePin(let pinID): update { $0.pins.removeAll { $0.id == pinID } }
        case .movePin(let from, let to):
            guard settings.pins.indices.contains(from) else { return }
            update { s in
                let pin = s.pins.remove(at: from)
                let target = min(max(to > from ? to - 1 : to, 0), s.pins.count)
                s.pins.insert(pin, at: target)
            }
        case .renamePin(let pinID, let name):
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            update { s in
                if let i = s.pins.firstIndex(where: { $0.id == pinID }) { s.pins[i].name = trimmed }
            }
        case .setShortcuts(let command, let combos):
            update { s in s.shortcutOverrides[command.rawValue] = combos }
            keybindings = Keybindings(settingsOverrides: settings.shortcutOverrides)
        case .setDebugConsoleEnabled(let b): update { $0.debugConsoleEnabled = b }
        case .setVerboseLogging(let b): update { $0.verboseLogging = b }
        case .setVerboseCategories(let c): update { $0.verboseCategories = c }
        case .setFileLogging(let b): update { $0.fileLogging = b }
        case .setAnonymizeExports(let b): update { $0.anonymizeExports = b }
        }
    }

    /// Pins re-resolve their bookmark (folder renamed/moved) when shown.
    public func resolvedPath(for pin: Pin) -> String {
        guard let data = pin.bookmark else { return pin.path }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting],
                                 bookmarkDataIsStale: &stale) else { return pin.path }
        return url.path(percentEncoded: false)
    }

    // MARK: - Browser registry (for settings that affect every tab)

    func register(_ browser: BrowserViewModel) {
        browsers.removeAll { $0.value == nil }
        browsers.append(WeakBrowser(value: browser))
    }

    private func broadcast(_ body: (BrowserViewModel) -> Void) {
        for b in browsers { if let v = b.value { body(v) } }
    }

    public var openBrowsers: [BrowserViewModel] { browsers.compactMap(\.value) }

    // MARK: - Internals

    private func update(_ mutate: (inout Settings) -> Void) {
        var s = settings
        mutate(&s)
        guard s != settings else { return }
        settings = s
        if let store { Task { await store.save(s) } }
        applyLogging()
    }

    private func applyLogging() {
        logging?.apply(debugConsoleEnabled: debugConsoleAvailable,
                       verbose: settings.verboseLogging || debugSession,
                       verboseCategories: settings.verboseCategories,
                       fileLogging: settings.fileLogging)
    }

    private static func bookmark(for path: String) -> Data? {
        try? URL(filePath: path, directoryHint: .isDirectory).bookmarkData(options: [], includingResourceValuesForKeys: nil,
                                                                            relativeTo: nil)
    }

    public func flushSettings() async {
        await store?.flush()
    }
}

private struct WeakBrowser {
    weak var value: BrowserViewModel?
}
