import AppKit
import DownCore

/// NSWorkspace-backed implementation. No shell, no AppleScript: folders are handed to the
/// terminal app through LaunchServices, which needs no Automation permission.
public final class LiveWorkspace: WorkspaceProviding {
    public init() {}

    public func open(_ url: URL) async -> Bool {
        await withCheckedContinuation { cont in
            NSWorkspace.shared.open(url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                cont.resume(returning: error == nil)
            }
        }
    }

    public func openFolderInTerminal(_ folder: URL, terminalBundleID: String?) async throws {
        let ids = [terminalBundleID].compactMap { $0 } + TerminalApp.knownBundleIDs.map(\.0)
        guard let appURL = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: config)
    }

    public func installedTerminals() -> [TerminalApp] {
        TerminalApp.knownBundleIDs.compactMap { id, name in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil ? TerminalApp(bundleID: id, name: name) : nil
        }
    }
}
