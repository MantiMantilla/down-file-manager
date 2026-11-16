import AppKit
import Foundation
import Testing
@testable import DownUI

/// The Settings panes are grouped Forms, which scroll and so have no height of their own. The window
/// used to open about 100 pt tall, and kept that size afterwards because the frame is autosaved.
@Suite("Settings window", .serialized)
@MainActor
struct SettingsWindowTests {
    private let frameKey = "NSWindow Frame DownSettings"

    /// Lays the window out and lets SwiftUI settle, so a later resize by the hosting controller shows up.
    private func settled(_ controller: SettingsWindowController) async throws -> NSWindow {
        let window = try #require(controller.window)
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        window.layoutIfNeeded()
        return window
    }

    @Test func opensTallEnoughToShowItsPanes() async throws {
        UserDefaults.standard.removeObject(forKey: frameKey)
        defer { UserDefaults.standard.removeObject(forKey: frameKey) }

        let window = try await settled(SettingsWindowController(app: Harness().app))
        #expect(window.contentLayoutRect.size == SettingsWindowController.contentSize)
    }

    /// People who opened Settings before the fix have the tiny frame saved; it must not come back.
    @Test func ignoresATinySavedSize() async throws {
        // AppKit's saved-frame format: window x y w h, then the frame of the screen it was saved on.
        let screen = try #require(NSScreen.main).frame
        let top = screen.maxY - 100
        UserDefaults.standard.set("200 \(Int(top - 120)) 560 120 \(Int(screen.minX)) \(Int(screen.minY)) "
                                  + "\(Int(screen.width)) \(Int(screen.height)) ", forKey: frameKey)
        defer { UserDefaults.standard.removeObject(forKey: frameKey) }

        let window = try await settled(SettingsWindowController(app: Harness().app))
        #expect(window.contentLayoutRect.size == SettingsWindowController.contentSize)
        #expect(window.frame.minX == 200, "the saved position is still used")
        #expect(window.frame.maxY == top, "and grows downward from the saved top edge")
    }
}
