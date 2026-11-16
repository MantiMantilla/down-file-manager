import AppKit
import Foundation
import SwiftUI
import Testing
@testable import DownUI

/// The Settings panes are grouped Forms, which scroll and so have no height of their own: sized from
/// its content, the window opened about 100 pt tall.
@Suite("Settings window")
@MainActor
struct SettingsWindowTests {
    /// Builds the window and waits until its size stops changing, so a late resize by the hosting
    /// controller is seen (polls rather than sleeping a fixed time).
    private func settledWindow(app: AppViewModel) async throws -> NSWindow {
        let window = try #require(SettingsWindowController(app: app).window)
        var last = NSSize.zero
        var stableChecks = 0
        await waitUntil {
            window.layoutIfNeeded()
            let size = window.contentLayoutRect.size
            stableChecks = size == last ? stableChecks + 1 : 0
            last = size
            return stableChecks >= 5
        }
        #expect(stableChecks >= 5, "the window size never settled")
        return window
    }

    @Test func opensTallEnoughToBeUsable() async throws {
        let window = try await settledWindow(app: Harness().app)
        #expect(window.contentLayoutRect.height >= 400, "was about 100 pt before the fix")
        #expect(window.contentLayoutRect.width >= 520)
    }

    /// The Shortcuts pane doesn't scroll (explanations above a fixed-height list), so the tab must give
    /// it all the height it asks for at the tab's width, or its text gets squeezed and clipped.
    @Test func shortcutsPaneFitsItsTab() async throws {
        let app = Harness().app
        let window = try await settledWindow(app: app)
        let tabView = try #require(Self.firstTabView(in: window.contentView), "SwiftUI's TabView is backed by NSTabView")
        let area = tabView.contentRect.size
        let needed = NSHostingController(rootView: ShortcutsPane(app: app))
            .sizeThatFits(in: NSSize(width: area.width, height: .greatestFiniteMagnitude))
        #expect(needed.height <= area.height, "Shortcuts needs \(needed.height) pt, the tab gives \(area.height) pt")
    }

    private static func firstTabView(in view: NSView?) -> NSTabView? {
        guard let view else { return nil }
        if let tabView = view as? NSTabView { return tabView }
        for sub in view.subviews { if let found = firstTabView(in: sub) { return found } }
        return nil
    }
}
