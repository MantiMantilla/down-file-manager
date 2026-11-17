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
    private let noHome = "/Users/nobody-down-test"

    /// `<tmp>/Reports.localized/2026` where "Reports" displays as "Berichte" (English table, so it
    /// applies whatever the machine's language).
    private func fixture() throws -> (dir: TempDir, reports: String, year: String) {
        let dir = TempDir("foldername")
        let reports = dir.path + "/Reports.localized"
        try FileManager.default.createDirectory(atPath: reports + "/.localized", withIntermediateDirectories: true)
        try #""Reports" = "Berichte";"#.write(toFile: reports + "/.localized/en.strings", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: reports + "/2026", withIntermediateDirectories: true)
        return (dir, reports, reports + "/2026")
    }

    @Test func usesTheSystemsLocalizedName() throws {
        let f = try fixture()
        withExtendedLifetime(f.dir) {
            #expect(FolderName.display(forPath: f.reports, home: noHome) == "Berichte")
            #expect(FolderName.display(forPath: f.year, home: noHome) == "2026")
        }
        #expect(FolderName.display(forPath: "/", home: noHome) != "/", "the startup disk's name, as in Finder")
    }

    /// displayName also hides extensions and shows ":" as "/"; those aren't localizations, so the name
    /// on disk stays (as in the file list).
    @Test func keepsNamesTheSystemOnlyRewrites() throws {
        let dir = TempDir("foldername")
        for name in ["Plain.localized", "x:y.localized"] {
            try FileManager.default.createDirectory(atPath: dir.path + "/" + name, withIntermediateDirectories: true)
        }
        withExtendedLifetime(dir) {
            #expect(FolderName.display(forPath: dir.path + "/Plain.localized", home: noHome) == "Plain.localized")
            #expect(FolderName.display(forPath: dir.path + "/x:y.localized", home: noHome) == "x:y.localized")
        }
    }

    /// Only the folders macOS localizes are looked up; anything else (other volumes, network mounts,
    /// symlinks to them) is answered from the path, so it can't block.
    @Test func onlyLooksUpFoldersMacOSLocalizes() {
        for (path, name) in [("/Volumes/Backup/Documents", "Documents"), ("/volumes/nas", "nas"),
                             ("/net/server/share", "share"), ("/System/Volumes/Data", "Data"),
                             (noHome + "/NAS", "NAS"), (noHome + "/Projects/Documents", "Documents")] {
            #expect(FolderName.display(forPath: path, home: noHome) == name)
        }
    }

    @Test func windowTitle() throws {
        let f = try fixture()
        withExtendedLifetime(f.dir) {
            #expect(BrowserWindowController.title(for: .file(f.reports), home: noHome) == "Berichte")
            #expect(BrowserWindowController.title(for: .file(f.dir.path), home: f.dir.path) == UIStrings.home)
        }
    }

    @Test func pathBarSegments() throws {
        let f = try fixture()
        withExtendedLifetime(f.dir) {
            // Inside home: Home, then each folder as Finder shows it.
            let inHome = PathBarView.segments(for: .file(f.year), home: f.dir.path).map(\.title)
            #expect(inHome == [UIStrings.home, "Berichte", "2026"])
            // Outside home: the root crumb is icon-only, folders are localized all the way down.
            let fromRoot = PathBarView.segments(for: .file(f.year), home: noHome).map(\.title)
            #expect(fromRoot.first == "")
            #expect(fromRoot.suffix(2) == ["Berichte", "2026"])
        }
    }

    @Test func unrenamedPinsUseTheLocalizedNameRenamedOnesKeepTheirs() throws {
        let f = try fixture()
        withExtendedLifetime(f.dir) {
            let unrenamed = Pin(name: "Reports.localized", path: f.reports, bookmark: nil)
            let renamed = Pin(name: "Quarterly", path: f.reports, bookmark: nil)
            #expect(SidebarViewController.title(of: unrenamed, resolvedPath: f.reports, home: noHome) == "Berichte")
            #expect(SidebarViewController.title(of: renamed, resolvedPath: f.reports, home: noHome) == "Quarterly")
        }
    }
}
