import AppKit
import Foundation
import Testing
@testable import DownUI
@testable import DownCore
import DownTestSupport

/// Folders macOS localizes must read the same in the window title, the path bar and the sidebar.
/// A "<name>.localized" folder with a `.localized/<lang>.strings` table is localized by the system,
/// which stands in for ~/Documents and friends without switching the test machine's language.
@Suite("Localized folder names")
@MainActor
struct FolderNameTests {
    /// `<tmp>/Reports.localized/2026` where "Reports" displays as "Berichte" (English table, so it
    /// applies whatever the machine's language).
    private func fixture() throws -> (TempDir, reports: String, year: String) {
        let dir = TempDir("foldername")
        let reports = dir.path + "/Reports.localized"
        try FileManager.default.createDirectory(atPath: reports + "/.localized", withIntermediateDirectories: true)
        try #""Reports" = "Berichte";"#.write(toFile: reports + "/.localized/en.strings", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: reports + "/2026", withIntermediateDirectories: true)
        return (dir, reports, reports + "/2026")
    }

    @Test func usesTheSystemsLocalizedName() throws {
        let (dir, reports, year) = try fixture()
        _ = dir
        #expect(FolderName.display(forPath: reports) == "Berichte")
        #expect(FolderName.display(forPath: year) == "2026")
        #expect(FolderName.display(forPath: dir.path + "/missing") == "missing", "falls back to the name on disk")
    }

    @Test func doesNotLookUpOtherVolumes() {
        #expect(FolderName.display(forPath: "/Volumes/Backup/Reports.localized") == "Reports.localized")
        #expect(FolderName.display(forPath: "/Volumes") == "Volumes")
    }

    @Test func windowTitle() throws {
        let (dir, reports, _) = try fixture()
        #expect(BrowserWindowController.title(for: .file(reports), home: "/Users/nobody") == "Berichte")
        #expect(BrowserWindowController.title(for: .file(dir.path), home: dir.path) == UIStrings.home)
    }

    @Test func pathBarSegments() throws {
        let (dir, _, year) = try fixture()
        // Inside home: Home, then each folder as Finder shows it.
        let inHome = PathBarView.segments(for: .file(year), home: dir.path).map(\.title)
        #expect(inHome == [UIStrings.home, "Berichte", "2026"])
        // Outside home: the root crumb is icon-only, folders are localized all the way down.
        let fromRoot = PathBarView.segments(for: .file(year), home: "/Users/nobody").map(\.title)
        #expect(fromRoot.first == "")
        #expect(fromRoot.suffix(2) == ["Berichte", "2026"])
    }

    @Test func unrenamedPinsUseTheLocalizedNameRenamedOnesKeepTheirs() throws {
        let (dir, reports, _) = try fixture()
        _ = dir
        let unrenamed = Pin(name: "Reports.localized", path: reports, bookmark: nil)
        let renamed = Pin(name: "Quarterly", path: reports, bookmark: nil)
        #expect(SidebarViewController.title(of: unrenamed, resolvedPath: reports) == "Berichte")
        #expect(SidebarViewController.title(of: renamed, resolvedPath: reports) == "Quarterly")
    }
}
