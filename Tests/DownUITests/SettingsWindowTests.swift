import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DownUI

/// The Settings panes are grouped Forms, which scroll and so have no height of their own: sized from
/// its content, the window opened about 100 pt tall (and autosaved that frame).
@Suite("Settings window")
@MainActor
struct SettingsWindowTests {
    /// Builds the window and waits until its size stops changing, so a late resize by the hosting
    /// controller is seen (polls rather than sleeping a fixed time).
    private func settledWindow() async throws -> NSWindow {
        let window = try #require(SettingsWindowController(app: Harness().app).window)
        var last = NSSize.zero
        var stableChecks = 0
        await waitUntil {
            window.layoutIfNeeded()
            let size = window.contentLayoutRect.size
            stableChecks = size == last ? stableChecks + 1 : 0
            last = size
            return stableChecks >= 5
        }
        return window
    }

    @Test func opensTallEnoughToBeUsable() async throws {
        let window = try await settledWindow()
        #expect(window.contentLayoutRect.height >= 400, "was about 100 pt before the fix")
        #expect(window.contentLayoutRect.width >= 520)
    }

    /// The Shortcuts pane doesn't scroll (explanations above a fixed-height list), so the tab must give
    /// it all the height it asks for at the tab's width, or its text gets squeezed and clipped.
    @Test func shortcutsPaneFitsItsTab() async throws {
        let window = try await settledWindow()
        let tabView = try #require(Self.firstTabView(in: window.contentView), "SwiftUI's TabView is backed by NSTabView")
        let area = tabView.contentRect.size
        let needed = NSHostingController(rootView: ShortcutsPane(app: Harness().app))
            .sizeThatFits(in: NSSize(width: area.width, height: .greatestFiniteMagnitude))
        #expect(needed.height <= area.height, "Shortcuts needs \(needed.height) pt, the tab gives \(area.height) pt")
    }

    /// Builds before the fix autosaved a ~100 pt tall frame under this name; it must not come back.
    @Test func ignoresTheOldSavedFrame() async throws {
        let key = "NSWindow Frame DownSettings"
        let saved = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set("200 300 560 120 0 0 1440 900 ", forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        let window = try await settledWindow()
        #expect(window.contentLayoutRect.height >= 400)
    }

    private static func firstTabView(in view: NSView?) -> NSTabView? {
        guard let view else { return nil }
        if let tabView = view as? NSTabView { return tabView }
        for sub in view.subviews { if let found = firstTabView(in: sub) { return found } }
        return nil
    }
}
