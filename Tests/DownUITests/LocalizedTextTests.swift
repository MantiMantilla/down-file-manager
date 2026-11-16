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

    @Test func sortFieldTitles() {
        #expect(SortField.allCases.map(UIStrings.title(of:)) == ["Name", "Size", "Modified", "Kind"])
    }
}
