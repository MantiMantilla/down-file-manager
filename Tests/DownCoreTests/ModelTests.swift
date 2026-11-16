import Foundation
import Testing
@testable import DownCore
import DownTestSupport

@Suite("Sorting")
struct SortingTests {
    @Test(arguments: [
        (["file10", "file2", "file1"], ["file1", "file2", "file10"]),
        (["B", "a", "C"], ["a", "B", "C"]),
        (["écrit", "ecrire", "Ezra"], ["ecrire", "écrit", "Ezra"]),
        (["v1.10", "v1.9", "v1.09b"], ["v1.9", "v1.09b", "v1.10"]),
        (["img007", "img7", "img08"], ["img007", "img7", "img08"]),
    ])
    func naturalNameOrder(input: [String], expected: [String]) {
        let items = input.map { FakeFileSource.item("/x/\($0)") }
        let sorted = Sorter.sorted(items, by: FileSortOrder(field: .name))
        #expect(sorted.map(\.name) == expected)
    }

    @Test func foldersFirstThenNames() {
        let items = [FakeFileSource.item("/x/b"), FakeFileSource.item("/x/z", isDir: true),
                     FakeFileSource.item("/x/a"), FakeFileSource.item("/x/c", isDir: true)]
        #expect(Sorter.sorted(items, by: FileSortOrder()).map(\.name) == ["c", "z", "a", "b"])
        #expect(Sorter.sorted(items, by: FileSortOrder(foldersFirst: false)).map(\.name) == ["a", "b", "c", "z"])
    }

    @Test func descendingBySize() {
        let items = [FakeFileSource.item("/x/s", size: 1), FakeFileSource.item("/x/l", size: 300),
                     FakeFileSource.item("/x/m", size: 20)]
        #expect(Sorter.sorted(items, by: FileSortOrder(field: .size, ascending: false)).map(\.name) == ["l", "m", "s"])
    }

    @Test func byModifiedDate() {
        let items = [FakeFileSource.item("/x/new", modified: Date(timeIntervalSince1970: 3)),
                     FakeFileSource.item("/x/old", modified: Date(timeIntervalSince1970: 1))]
        #expect(Sorter.sorted(items, by: FileSortOrder(field: .modified)).map(\.name) == ["old", "new"])
    }
}

@Suite("Location and path input")
struct LocationTests {
    @Test(arguments: [
        ("/Users/me/", "/Users/me"),
        ("//Users//me", "/Users/me"),
        ("/Users/me/../you/./x", "/Users/you/x"),
        ("/..", "/"),
        ("/", "/"),
    ])
    func normalizes(raw: String, expected: String) {
        #expect(Location.file(raw).path == expected)
    }

    @Test func ancestryRootFirst() {
        #expect(Location.file("/a/b/c").ancestry.map(\.path) == ["/", "/a", "/a/b", "/a/b/c"])
        #expect(Location.root.parent == nil)
        #expect(Location.file("/a/b").name == "b")
    }

    @Test(arguments: [
        ("~/src", "/home/me/src"),
        ("~", "/home/me"),
        ("/tmp/../var", "/var"),
        ("docs", "/base/docs"),
        ("..", "/"),
        ("file:///etc", "/etc"),
    ])
    func resolvesTypedInput(text: String, expected: String) {
        let loc = PathInput.resolve(text, relativeTo: .file("/base"), home: "/home/me")
        #expect(loc?.path == expected)
    }

    @Test func completionParts() {
        #expect(PathInput.completionParts("~/Doc") == ("~/", "Doc"))
        #expect(PathInput.completionParts("/usr/lo") == ("/usr/", "lo"))
        #expect(PathInput.completionParts("abc") == ("", "abc"))
    }

    @Test func commonPrefix() {
        #expect(PathInput.commonPrefix(["Documents", "Downloads", "Do"]) == "Do")
        #expect(PathInput.commonPrefix(["Music"]) == "Music")
        #expect(PathInput.commonPrefix(["abc", "ABd"]) == "ab")
        #expect(PathInput.commonPrefix([]) == "")
    }
}

@Suite("Display names")
struct DisplayNameTests {
    @Test func bidiOverrideIsEscaped() {
        let spoof = "\u{202E}gnp.exe"
        #expect(DisplayName.needsSanitizing(spoof))
        #expect(DisplayName.sanitize(spoof) == "\\u{202E}gnp.exe")
    }

    @Test func controlCharactersAreEscaped() {
        #expect(DisplayName.sanitize("a\nb") == "a\\u{A}b")
        #expect(DisplayName.sanitize("tab\there") == "tab\\u{9}here")
    }

    @Test func normalNamesUntouched() {
        for n in ["report.pdf", "日本語", "emoji 🎉", "عربي"] {
            #expect(DisplayName.sanitize(n) == n)
        }
    }

    /// Unknown extensions are named in the Kind column ("XYZ file"), so they are sanitized too.
    /// (Bidi controls never get this far: NSString reports no extension for them, so the kind is "Document".)
    @Test func unknownKindsSanitizeTheExtension() {
        #expect(TypeCache.kindDescription(for: FakeFileSource.item("/x/a.b\u{1}c")) == "B\\u{1}C file")
        #expect(TypeCache.kindDescription(for: FakeFileSource.item("/x/report.f\u{7F}dp")) == "F\\u{7F}DP file")
    }

    /// A bidi override in a name must not reorder the message around it.
    @Test func errorMessagesSanitizeNames() {
        #expect(FileSourceError.notADirectory("/x/\u{202E}gnp.exe").errorDescription == "“\\u{202E}gnp.exe” is not a folder.")
        #expect(FileSourceError.posix(ENOENT, path: "/x/a\nb").errorDescription == "“a\\u{A}b” doesn't exist.")
    }
}

@Suite("Keybindings")
struct KeybindingTests {
    @Test func everyCommandHasAShortcut() {
        let kb = Keybindings()
        for c in Command.allCases {
            #expect(!kb.combos(for: c).isEmpty, "\(c) has no shortcut")
        }
    }

    @Test func noDuplicateDefaultCombos() {
        #expect(Keybindings().conflicts().isEmpty, "conflicts: \(Keybindings().conflicts())")
    }

    @Test func gnomeMappings() {
        let kb = Keybindings()
        #expect(kb.command(for: .cmd("l")) == .locationEntry)
        #expect(kb.command(for: .opt("left")) == .back)
        #expect(kb.command(for: .opt("up")) == .up)
        #expect(kb.command(for: .cmd("h")) == .toggleHidden)
        #expect(kb.command(for: KeyCombo("f2")) == .rename)
        #expect(kb.command(for: KeyCombo("delete", .shift)) == .deletePermanently)
    }

    @Test func overridesReplaceDefaults() {
        let kb = Keybindings(settingsOverrides: ["toggleHidden": [.cmdShift(".")]])
        #expect(kb.command(for: .cmd("h")) == nil)
        #expect(kb.primary(for: .toggleHidden) == .cmdShift("."))
    }

    @Test(arguments: [
        ("⌥←", KeyCombo("left", .option)),
        ("cmd+shift+n", KeyCombo("n", [.command, .shift])),
        ("F2", KeyCombo("f2")),
        ("alt+enter", KeyCombo("return", .option)),
    ])
    func parsesCombos(text: String, expected: KeyCombo) {
        #expect(KeyCombo.parse(text) == expected)
    }

    @Test func displayString() {
        #expect(KeyCombo("left", .option).description == "⌥←")
        #expect(KeyCombo("n", [.command, .shift]).description == "⇧⌘N")
    }

    /// Named keys are localized for display only; `description` (used in logs) stays fixed.
    @Test func displayStringLocalizesNamedKeysOnly() {
        #expect(KeyCombo("space").description == "Space")
        #expect(KeyCombo("space", .shift).displayDescription == "⇧Space")
        #expect(KeyCombo("left", .option).displayDescription == "⌥←")
    }
}

@Suite("Settings")
struct SettingsTests {
    @Test func roundTripsThroughStore() async throws {
        let tmp = TempDir("settings")
        let (hub, _) = makeTestHub()
        let store = SettingsStore(directory: tmp.url, debounce: .milliseconds(1), hub: hub)
        var s = Settings()
        s.theme = .dark
        s.pins = [Pin(name: "src", path: "/src")]
        s.debugConsoleEnabled = true
        await store.save(s)
        await store.flush()
        #expect(store.loadNow() == s)
    }

    @Test func toleratesUnknownAndMissingKeys() throws {
        let json = #"{"theme":"light","bogus":42,"sort":{"nope":true}}"#
        let s = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        #expect(s.theme == .light)
        #expect(s.sort == FileSortOrder())
        #expect(s.version == Settings.currentVersion)
    }

    @Test func corruptFileFallsBackToDefaults() throws {
        let tmp = TempDir("corrupt")
        try Data("{not json".utf8).write(to: tmp.url.appending(path: "settings.json"))
        let (hub, sink) = makeTestHub()
        #expect(SettingsStore(directory: tmp.url, hub: hub).loadNow() == Settings())
        #expect(sink.contains("settings unreadable"))
    }
}

@Suite("Launch options")
struct LaunchOptionTests {
    @Test func parsesFlagsAndPath() {
        let o = LaunchOptions.parse(arguments: ["Down", "--log-level", "debug,ops=trace", "--debug", "~/src"],
                                    environment: [:])
        #expect(o.debugSession)
        #expect(o.initialPath == "~/src")
        #expect(o.stderrSpec == LevelSpec(base: .debug, overrides: [.ops: .trace]))
    }

    @Test func environmentVariable() {
        let o = LaunchOptions.parse(arguments: ["Down"], environment: ["DOWN_LOG": "watch=error"])
        #expect(o.stderrSpec?.level(for: .watch) == .error)
        #expect(o.stderrSpec?.level(for: .fs) == .debug)
    }

    @Test func ignoresAppKitFlags() {
        let o = LaunchOptions.parse(arguments: ["Down", "-NSDocumentRevisionsDebugMode", "YES"], environment: [:])
        #expect(o.initialPath == nil)
    }
}
