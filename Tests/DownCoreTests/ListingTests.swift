import Foundation
import Testing
@testable import DownCore
import DownTestSupport

@Suite("Listing (getattrlistbulk)")
struct ListingTests {
    @Test func listsFilesFoldersAndAttributes() throws {
        let tmp = TempDir("list")
        let mtime = Date(timeIntervalSince1970: 1_600_000_000)
        tmp.file("a.txt", contents: "hello", modified: mtime)
        tmp.dir("folder")
        tmp.file("folder/inner1")
        tmp.file("folder/inner2")
        tmp.file(".hidden")

        let items = try LocalFileSource.listAll(path: tmp.path)
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0) })

        #expect(Set(byName.keys) == ["a.txt", "folder", ".hidden"])
        let a = try #require(byName["a.txt"])
        #expect(a.kind == .file)
        #expect(a.size == 5)
        #expect(abs(a.modified.timeIntervalSince(mtime)) < 1)
        #expect(a.path == tmp.path + "/a.txt")
        #expect(!a.isHidden)

        let folder = try #require(byName["folder"])
        #expect(folder.kind == .directory)
        #expect(folder.isFolderLike)
        #expect(folder.entryCount == 2)

        #expect(byName[".hidden"]?.isHidden == true)
    }

    @Test func unicodeNamesRoundTrip() throws {
        let tmp = TempDir("unicode")
        let names = ["café.txt", "日本語", "emoji 🎉.png", "Ünïcödé"]
        for n in names { tmp.file(n) }
        let listed = Set(try LocalFileSource.listAll(path: tmp.path).map(\.name))
        // APFS preserves normalization; compare canonically.
        #expect(Set(listed.map { $0.precomposedStringWithCanonicalMapping }) ==
                Set(names.map { $0.precomposedStringWithCanonicalMapping }))
    }

    @Test func symlinksReportTargetKind() throws {
        let tmp = TempDir("links")
        let target = tmp.dir("real")
        tmp.symlink("link-to-dir", to: target)
        tmp.symlink("dangling", to: tmp.path + "/nope")
        let items = Dictionary(uniqueKeysWithValues: try LocalFileSource.listAll(path: tmp.path).map { ($0.name, $0) })
        #expect(items["link-to-dir"]?.kind == .symlink)
        #expect(items["link-to-dir"]?.symlinkTargetIsDirectory == true)
        #expect(items["link-to-dir"]?.isFolderLike == true)
        #expect(items["dangling"]?.symlinkTargetIsDirectory == false)
    }

    @Test func packagesAreNotFolderLike() throws {
        let tmp = TempDir("pkg")
        tmp.dir("Thing.app/Contents")
        let item = try #require(try LocalFileSource.listAll(path: tmp.path).first)
        #expect(item.isPackage)
        #expect(!item.isFolderLike)
    }

    @Test func batchesFirstSmallThenLarge() throws {
        let tmp = TempDir("batches")
        for i in 0..<50 { tmp.file("f\(i)") }
        var sizes: [Int] = []
        try LocalFileSource.enumerate(path: tmp.path, firstBatch: 5, batch: 20) { sizes.append($0.count); return true }
        #expect(sizes == [5, 20, 20, 5])
    }

    @Test func missingFolderThrowsPosixError() {
        #expect(throws: FileSourceError.posix(ENOENT, path: "/definitely/not/here")) {
            try LocalFileSource.listAll(path: "/definitely/not/here")
        }
    }

    @Test func listingAFileThrowsNotADirectory() throws {
        let tmp = TempDir("notdir")
        let f = tmp.file("plain")
        #expect(throws: FileSourceError.notADirectory(f)) { try LocalFileSource.listAll(path: f) }
    }

    @Test func statSingleItemDoesNotFollowSymlinks() throws {
        let tmp = TempDir("stat")
        let target = tmp.dir("dir")
        let link = tmp.symlink("ln", to: target)
        let item = try LocalFileSource.statItem(path: link)
        #expect(item.kind == .symlink)
        #expect(item.name == "ln")
        let dir = try LocalFileSource.statItem(path: target)
        #expect(dir.kind == .directory)
    }

    @Test func streamingListYieldsAllItems() async throws {
        let tmp = TempDir("stream")
        for i in 0..<300 { tmp.file("f\(i)") }
        let (hub, sink) = makeTestHub()
        let source = LocalFileSource(firstBatchSize: 10, batchSize: 100, hub: hub)
        var total = 0
        var batches = 0
        for try await batch in source.list(tmp.location) { total += batch.count; batches += 1 }
        #expect(total == 300)
        #expect(batches == 4)
        #expect(sink.contains("listed", category: .fs))
    }
}

@Suite("Directory watcher", .enabled(if: TestEnv.integration), .tags(.integration))
struct WatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func reportsCreatedAndDeletedChildren() async throws {
        let tmp = TempDir("watch")
        tmp.file("existing")
        let (hub, _) = makeTestHub()
        let stream = LocalFileSource(hub: hub).watch(tmp.location)
        var iterator = stream.makeAsyncIterator()
        try await Task.sleep(for: .milliseconds(300))  // let FSEvents start

        tmp.file("new-file")
        var seen = Set<String>()
        while !seen.contains("new-file") {
            guard let event = await iterator.next() else { break }
            if case .changed(let names) = event { seen.formUnion(names) }
        }
        #expect(seen.contains("new-file"))

        try FileManager.default.removeItem(atPath: tmp.path + "/existing")
        seen = []
        while !seen.contains("existing") {
            guard let event = await iterator.next() else { break }
            if case .changed(let names) = event { seen.formUnion(names) }
        }
        #expect(seen.contains("existing"))
    }
}

extension Tag {
    @Tag static var integration: Self
    @Tag static var performance: Self
}
