import Foundation

/// Opening things with other apps (LaunchServices). Live implementation lives in DownUI (NSWorkspace).
public protocol WorkspaceProviding: Sendable {
    func open(_ url: URL) async -> Bool
    func openFolderInTerminal(_ folder: URL, terminalBundleID: String?) async throws
    func installedTerminals() -> [TerminalApp]
}

public struct TerminalApp: Hashable, Sendable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    public static let knownBundleIDs: [(String, String)] = [
        ("com.googlecode.iterm2", "iTerm"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.apple.Terminal", "Terminal"),
    ]
}

/// Every service a ViewModel may use. Tests build one with fakes; the app uses `live`.
public struct AppEnvironment: Sendable {
    public var logHub: LogHub
    public var sources: SourceRegistry
    public var workspace: any WorkspaceProviding
    public var perf: PerfMonitor
    public var homePath: String
    /// Spring-loading delay while dragging (system setting `com.apple.springing.delay`).
    public var springDelay: Duration

    public init(logHub: LogHub, sources: SourceRegistry, workspace: any WorkspaceProviding,
                perf: PerfMonitor, homePath: String = NSHomeDirectory(), springDelay: Duration = .milliseconds(500)) {
        self.logHub = logHub
        self.sources = sources
        self.workspace = workspace
        self.perf = perf
        self.homePath = homePath
        self.springDelay = springDelay
    }

    public func logger(_ category: LogCategory) -> Logger { Logger(category, hub: logHub) }

    public static func systemSpringDelay() -> Duration {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "com.apple.springing.enabled") as? Bool == false {
            return .seconds(3600)
        }
        let seconds = defaults.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        return .milliseconds(Int(max(0.1, seconds) * 1000))
    }
}
