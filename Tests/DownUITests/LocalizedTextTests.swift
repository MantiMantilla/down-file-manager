import Foundation
import Testing
@testable import DownUI
@testable import DownCore
import DownTestSupport

/// UI text assembled from catalog strings. The English output also proves the lookups hit DownUI's
/// catalog: a plural looked up in the wrong bundle falls back to its key ("2 items selected" would
/// still pass, but "1 items" wouldn't).
@Suite("Localized UI text")
@MainActor
struct LocalizedTextTests {
    @Test func oneFileShowsItsNameAndSize() {
        let file = FakeFileSource.item("/x/notes.txt", size: 2048)
        #expect(ContentViewController.selectionSummary([file]) == "“notes.txt” selected (\(ByteFormat.string(2048)))")
    }

    @Test func oneFolderShowsOnlyItsName() {
        let folder = FakeFileSource.item("/x/Projects", isDir: true)
        #expect(ContentViewController.selectionSummary([folder]) == "“Projects” selected")
    }

    @Test func severalItemsShowTheCountAndTheSizeOfTheFiles() {
        let items = [FakeFileSource.item("/x/a", size: 1000), FakeFileSource.item("/x/b", size: 500),
                     FakeFileSource.item("/x/Folder", isDir: true)]
        #expect(ContentViewController.selectionSummary(items) == "3 items selected (\(ByteFormat.string(1500)))")
    }

    @Test func severalFoldersShowOnlyTheCount() {
        let items = [FakeFileSource.item("/x/A", isDir: true), FakeFileSource.item("/x/B", isDir: true)]
        #expect(ContentViewController.selectionSummary(items) == "2 items selected")
    }

    @Test func namesAreSanitized() {
        let file = FakeFileSource.item("/x/\u{202E}gnp.exe", isDir: true)
        #expect(ContentViewController.selectionSummary([file]) == "“\\u{202E}gnp.exe” selected")
    }

    @Test func folderSizesUseThePlural() {
        func folder(_ n: Int) -> FileItem {
            FileItem(path: "/x/f", name: "f", kind: .directory, size: 0, modified: .now, created: .now,
                     isHidden: false, isPackage: false, entryCount: n, mode: 0, fileID: 1)
        }
        #expect(FileListViewController.sizeText(folder(1)) == "1 item")
        #expect(FileListViewController.sizeText(folder(5)) == "5 items")
    }

    /// Semantic keys ("modified.weekdayTime") resolve to their English default value, not the key.
    @Test func semanticKeysShowTheirDefaultValue() throws {
        let date = try #require(Calendar.current.date(byAdding: .day, value: -3, to: Date()))
        let text = FileListViewController.dateText(date)
        #expect(text.hasPrefix(date.formatted(.dateTime.weekday(.wide)) + " "))
        #expect(!text.contains("modified."))
        #expect(FileSourceError.posix(EIO, path: "/x/y").errorDescription?.hasSuffix(" (/x/y)") == true)
    }

    @Test func pinningHomeKeepsTheHomeName() {
        #expect(SidebarViewController.pinName(forPlaceAt: "/Users/someone", home: "/Users/someone") == "Home")
        #expect(SidebarViewController.pinName(forPlaceAt: "/Users/someone/Documents", home: "/Users/someone") == nil)
    }

    @Test func pinTitles() {
        // Never renamed (still named after its folder): the resolved folder's display name.
        let unrenamed = Pin(name: "proj", path: "/x/proj")
        #expect(SidebarViewController.title(of: unrenamed, resolvedPath: "/Applications", home: "/Users/someone")
                == FileManager.default.displayName(atPath: "/Applications"))
        // Renamed by the user: kept as is.
        let renamed = Pin(name: "Work", path: "/x/proj")
        #expect(SidebarViewController.title(of: renamed, resolvedPath: "/Applications", home: "/Users/someone") == "Work")
        let home = Pin(name: "Home", path: "/Users/someone")
        #expect(SidebarViewController.title(of: home, resolvedPath: "/Users/someone", home: "/Users/someone") == "Home")
    }

    @Test func sortFieldTitles() {
        #expect(SortField.allCases.map(UIStrings.title(of:)) == ["Name", "Size", "Modified", "Kind"])
    }
}

@Suite("Snapshot part paths")
@MainActor
struct SnapshotPathTests {
    @Test(arguments: [
        ("/tmp/shot.png", "/tmp/shot-settings.png"),
        ("/tmp/shot", "/tmp/shot-settings"),
        ("/tmp/x.png.d/shot.png", "/tmp/x.png.d/shot-settings.png"),
        ("/tmp/x.png.d/shot", "/tmp/x.png.d/shot-settings"),
        ("shot.PNG", "shot-settings.PNG"),
    ])
    func partPath(path: String, expected: String) {
        #expect(DownAppDelegate.snapshotPath(path, part: "settings") == expected)
    }
}
