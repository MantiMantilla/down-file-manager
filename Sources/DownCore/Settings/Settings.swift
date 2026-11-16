import Foundation

public enum Theme: String, Codable, Sendable, CaseIterable {
    case system, light, dark
}

public enum ViewMode: String, Codable, Sendable, CaseIterable {
    case list, grid, columns
}

public struct Pin: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String
    /// Bookmark data so pins survive renames/moves of the target.
    public var bookmark: Data?

    public init(id: UUID = UUID(), name: String, path: String, bookmark: Data? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
    }
}

public struct Settings: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int = Settings.currentVersion
    public var theme: Theme = .system
    public var showHidden = false
    public var defaultViewMode: ViewMode = .list
    public var sort = FileSortOrder()
    public var terminalBundleID: String?
    public var pins: [Pin] = []
    public var shortcutOverrides: [String: [KeyCombo]] = [:]
    public var sidebarVisible = true
    public var listZoom: Double = 1.0

    // Advanced
    public var debugConsoleEnabled = false
    public var verboseLogging = false
    public var verboseCategories: Set<LogCategory> = []
    public var fileLogging = false
    public var anonymizeExports = false

    public init() {}

    public init(from decoder: any Decoder) throws {
        // Tolerant decoding: unknown/missing keys fall back to defaults so old files keep working.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 0
        theme = (try? c.decodeIfPresent(Theme.self, forKey: .theme)) ?? d.theme
        showHidden = (try? c.decodeIfPresent(Bool.self, forKey: .showHidden)) ?? d.showHidden
        defaultViewMode = (try? c.decodeIfPresent(ViewMode.self, forKey: .defaultViewMode)) ?? d.defaultViewMode
        sort = (try? c.decodeIfPresent(FileSortOrder.self, forKey: .sort)) ?? d.sort
        terminalBundleID = try? c.decodeIfPresent(String.self, forKey: .terminalBundleID)
        pins = (try? c.decodeIfPresent([Pin].self, forKey: .pins)) ?? d.pins
        shortcutOverrides = (try? c.decodeIfPresent([String: [KeyCombo]].self, forKey: .shortcutOverrides)) ?? [:]
        sidebarVisible = (try? c.decodeIfPresent(Bool.self, forKey: .sidebarVisible)) ?? d.sidebarVisible
        listZoom = (try? c.decodeIfPresent(Double.self, forKey: .listZoom)) ?? d.listZoom
        debugConsoleEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .debugConsoleEnabled)) ?? d.debugConsoleEnabled
        verboseLogging = (try? c.decodeIfPresent(Bool.self, forKey: .verboseLogging)) ?? d.verboseLogging
        verboseCategories = (try? c.decodeIfPresent(Set<LogCategory>.self, forKey: .verboseCategories)) ?? []
        fileLogging = (try? c.decodeIfPresent(Bool.self, forKey: .fileLogging)) ?? d.fileLogging
        anonymizeExports = (try? c.decodeIfPresent(Bool.self, forKey: .anonymizeExports)) ?? d.anonymizeExports
        self = Settings.migrate(self)
    }

    /// Upgrades older schema versions in place.
    static func migrate(_ s: Settings) -> Settings {
        var s = s
        if s.version < 1 {
            // v0 → v1: no structural change; stamp the version.
            s.version = 1
        }
        return s
    }

    /// Short, non-sensitive summary for diagnostics (no paths, no pin names).
    public var diagnosticsSummary: String {
        """
        theme=\(theme.rawValue) showHidden=\(showHidden) view=\(defaultViewMode.rawValue) \
        sort=\(sort.field.rawValue)/\(sort.ascending ? "asc" : "desc") pins=\(pins.count) \
        shortcutOverrides=\(shortcutOverrides.count) debugConsole=\(debugConsoleEnabled) \
        verbose=\(verboseLogging) fileLogging=\(fileLogging)
        """
    }
}

/// Persists settings as JSON with atomic, debounced writes.
public actor SettingsStore {
    public nonisolated let fileURL: URL
    private let debounce: Duration
    private var pending: Settings?
    private var writeTask: Task<Void, Never>?
    private let log: Logger

    public init(directory: URL, debounce: Duration = .milliseconds(300), hub: LogHub = .shared) {
        fileURL = directory.appending(path: "settings.json")
        self.debounce = debounce
        log = Logger(.settings, hub: hub)
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Down")
    }

    /// Synchronous load (used once at launch before any UI exists).
    public nonisolated func loadNow() -> Settings {
        guard let data = try? Data(contentsOf: fileURL) else { return Settings() }
        do {
            return try JSONDecoder().decode(Settings.self, from: data)
        } catch {
            log.error("settings unreadable, using defaults: \(error.localizedDescription)")
            return Settings()
        }
    }

    public func save(_ settings: Settings) {
        pending = settings
        writeTask?.cancel()
        let delay = debounce
        writeTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    public func flush() {
        guard let settings = pending else { return }
        pending = nil
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: fileURL, options: [.atomic])
            log.debug("settings saved")
        } catch {
            log.error("settings save failed: \(error.localizedDescription)")
        }
    }
}
