import AppKit
import Foundation
import Testing
@testable import DownUI
@testable import DownCore
import DownTestSupport

@Suite("DebugConsoleViewModel")
@MainActor
struct DebugConsoleViewModelTests {
    func make() -> (DebugConsoleViewModel, LogHub, RingBufferSink) {
        let ring = RingBufferSink(capacity: 100)
        ring.setSpec(LevelSpec(base: .trace))
        let hub = LogHub()
        hub.add(ring)
        let vm = DebugConsoleViewModel(ring: ring)
        vm.loadExisting()
        return (vm, hub, ring)
    }

    @Test func tickPullsOnlyNewEntries() {
        let (vm, hub, _) = make()
        Logger(.fs, hub: hub).info("one")
        vm.send(.tick)
        Logger(.fs, hub: hub).info("two")
        vm.send(.tick)
        #expect(vm.visible.map(\.message) == ["one", "two"])
    }

    @Test func filtersByLevelCategorySearchAndAction() {
        let (vm, hub, _) = make()
        let id = ActionID(raw: 7)
        Logger(.fs, hub: hub).debug("listed folder")
        Logger(.ops, hub: hub).error("copy failed", actionID: id)
        Logger(.dnd, hub: hub).info("drop started", actionID: id)
        vm.send(.tick)

        vm.send(.setMinLevel(.info))
        #expect(vm.visible.map(\.message) == ["copy failed", "drop started"])

        vm.send(.setMinLevel(.trace))
        vm.send(.toggleCategory(.ops))
        #expect(vm.visible.map(\.message) == ["listed folder", "drop started"])
        vm.send(.setAllCategories(true))

        vm.send(.setSearch("FOLDER"))
        #expect(vm.visible.map(\.message) == ["listed folder"])
        vm.send(.setSearch(""))

        vm.send(.filterAction(id))
        #expect(vm.visible.map(\.message) == ["copy failed", "drop started"])
    }

    @Test func regexSearchAndInvalidRegex() {
        let (vm, hub, _) = make()
        Logger(.fs, hub: hub).info("listed 42 items")
        Logger(.fs, hub: hub).info("listed some items")
        vm.send(.tick)
        vm.send(.setRegex(true))
        vm.send(.setSearch(#"\d+ items"#))
        #expect(vm.visible.map(\.message) == ["listed 42 items"])
        vm.send(.setSearch("([unclosed"))
        #expect(vm.regexError != nil)
        #expect(vm.visible.count == 2)  // invalid regex doesn't hide everything
    }

    @Test func pauseStopsPullingAndClearEmpties() {
        let (vm, hub, ring) = make()
        vm.send(.setPaused(true))
        Logger(.app, hub: hub).info("while paused")
        vm.send(.tick)
        #expect(vm.visible.isEmpty)
        vm.send(.setPaused(false))  // resuming pulls what arrived meanwhile
        #expect(vm.visible.map(\.message) == ["while paused"])
        vm.send(.clear)
        #expect(vm.visible.isEmpty)
        #expect(ring.count == 0)
    }

    @Test func diagnosticsAreRedacted() {
        let (vm, hub, _) = make()
        Logger(.fs, hub: hub).info("listed \(path: NSHomeDirectory() + "/Secret/plans.txt")")
        vm.send(.tick)
        var settings = Settings()
        let report = vm.diagnostics(settings: settings)
        #expect(report.contains("~/Secret/plans.txt"))
        #expect(!report.contains(NSHomeDirectory() + "/"))
        settings.anonymizeExports = true
        let anon = vm.diagnostics(settings: settings)
        #expect(!anon.contains("plans"))
        #expect(anon.contains("Down diagnostics"))
    }
}

@Suite("Menus and shortcuts (AppKit)")
@MainActor
struct MenuTests {
    func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    @Test func everyCommandIsReachableFromTheMenuBar() {
        let menu = MainMenu.build(keybindings: Keybindings())
        let commands = Set(allItems(menu).compactMap(MainMenu.command(of:)))
        #expect(commands == Set(Command.allCases))
    }

    @Test func everyShortcutHasAMenuItemWithMatchingKeyEquivalent() {
        let kb = Keybindings()
        let items = allItems(MainMenu.build(keybindings: kb))
        for command in Command.allCases {
            for combo in kb.combos(for: command) {
                let match = items.contains {
                    MainMenu.command(of: $0) == command
                        && $0.keyEquivalent == KeyEquivalents.keyEquivalent(for: combo)
                        && $0.keyEquivalentModifierMask == KeyEquivalents.modifierMask(for: combo)
                }
                #expect(match, "no menu item for \(command) \(combo)")
            }
        }
    }

    @Test func noTwoMenuItemsShareAKeyEquivalent() {
        let items = allItems(MainMenu.build(keybindings: Keybindings())).filter { !$0.keyEquivalent.isEmpty }
        var seen: [String: String] = [:]
        for item in items {
            let key = "\(item.keyEquivalentModifierMask.rawValue):\(item.keyEquivalent)"
            if let other = seen[key] {
                Issue.record("\(item.title) and \(other) share a key equivalent")
            }
            seen[key] = item.title
        }
    }

    @Test func hideHasNoShortcutBecauseCmdHTogglesHiddenFiles() {
        let items = allItems(MainMenu.build(keybindings: Keybindings()))
        let hide = items.first { $0.action == #selector(NSApplication.hide(_:)) }
        #expect(hide?.keyEquivalent == "")
        let toggle = items.first { MainMenu.command(of: $0) == .toggleHidden && !$0.isHidden }
        #expect(toggle?.keyEquivalent == "h")
        #expect(toggle?.keyEquivalentModifierMask == .command)
    }

    @Test(arguments: [
        (KeyCombo("left", .option), NSEvent.ModifierFlags.option),
        (KeyCombo("n", [.command, .shift]), NSEvent.ModifierFlags([.command, .shift])),
        (KeyCombo("f2"), NSEvent.ModifierFlags()),
    ])
    func eventRoundTrip(combo: KeyCombo, flags: NSEvent.ModifierFlags) throws {
        let chars = KeyEquivalents.keyEquivalent(for: combo)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                  windowNumber: 0, context: nil, characters: chars,
                                                  charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0))
        #expect(KeyEquivalents.combo(for: event) == combo)
    }
}

@Suite("FileTransfer and drop policy")
struct TransferTests {
    @Test(arguments: [
        ("report.pdf", ["/d/report.pdf"], "/d/report (2).pdf"),
        ("report.pdf", ["/d/report.pdf", "/d/report (2).pdf"], "/d/report (3).pdf"),
        ("Folder", ["/d/Folder"], "/d/Folder (2)"),
        (".bashrc", ["/d/.bashrc"], "/d/.bashrc (2)"),
        ("a.tar.gz", ["/d/a.tar.gz"], "/d/a.tar (2).gz"),
        ("new.txt", [], "/d/new.txt"),
    ])
    func uniqueNames(name: String, existing: [String], expected: String) {
        let set = Set(existing)
        #expect(FileTransfer.uniqueDestination(for: name, in: "/d", exists: { set.contains($0) }) == expected)
    }

    @Test func dropPolicyFollowsFinder() {
        let all = (copy: true, move: true, link: true)
        // Same volume, no modifiers → move; different volume → copy.
        #expect(DropPolicy.operation(allowsCopy: all.copy, allowsMove: all.move, allowsLink: all.link,
                                     onlyLinkRequested: false, onlyCopyRequested: false, onlyMoveRequested: false,
                                     sameVolume: true) == .move)
        #expect(DropPolicy.operation(allowsCopy: true, allowsMove: true, allowsLink: true,
                                     onlyLinkRequested: false, onlyCopyRequested: false, onlyMoveRequested: false,
                                     sameVolume: false) == .copy)
        // ⌥ forces copy, ⌘ forces move, ⌃⌥ link.
        #expect(DropPolicy.operation(allowsCopy: true, allowsMove: true, allowsLink: true,
                                     onlyLinkRequested: false, onlyCopyRequested: true, onlyMoveRequested: false,
                                     sameVolume: true) == .copy)
        #expect(DropPolicy.operation(allowsCopy: true, allowsMove: true, allowsLink: true,
                                     onlyLinkRequested: false, onlyCopyRequested: false, onlyMoveRequested: true,
                                     sameVolume: false) == .move)
        #expect(DropPolicy.operation(allowsCopy: true, allowsMove: true, allowsLink: true,
                                     onlyLinkRequested: true, onlyCopyRequested: false, onlyMoveRequested: false,
                                     sameVolume: true) == .link)
    }

    @Test func noOpDrops() {
        #expect(DropPolicy.isNoOp(sources: ["/a/folder"], destination: "/a/folder", operation: .copy))
        #expect(DropPolicy.isNoOp(sources: ["/a/folder"], destination: "/a/folder/sub", operation: .move))
        #expect(DropPolicy.isNoOp(sources: ["/a/file"], destination: "/a", operation: .move))
        #expect(!DropPolicy.isNoOp(sources: ["/a/file"], destination: "/a", operation: .copy))  // duplicate is fine
        #expect(!DropPolicy.isNoOp(sources: ["/a/folder"], destination: "/a/folder2", operation: .move))
    }

    @Test(.enabled(if: TestEnv.integration))
    func copyAndMoveOnDisk() throws {
        let tmp = TempDir("transfer")
        let src = tmp.file("src/file.txt", contents: "data")
        let dest = tmp.dir("dest")
        tmp.file("dest/file.txt", contents: "existing")
        let (hub, _) = makeTestHub()
        let log = Logger(.ops, hub: hub)

        let copied = FileTransfer.perform(.copy, sources: [src], into: dest, log: log)
        #expect(copied.failures.isEmpty)
        #expect(copied.created == [dest + "/file (2).txt"])
        #expect(try String(contentsOfFile: dest + "/file.txt", encoding: .utf8) == "existing")  // never overwritten
        #expect(try String(contentsOfFile: dest + "/file (2).txt", encoding: .utf8) == "data")

        let moved = FileTransfer.perform(.move, sources: [src], into: dest, log: log)
        #expect(moved.created == [dest + "/file (3).txt"])
        #expect(!FileManager.default.fileExists(atPath: src))
    }

    @Test(.enabled(if: TestEnv.integration))
    func copyPreservesQuarantineAndDoesNotFollowSymlinks() throws {
        let tmp = TempDir("xattr")
        let src = tmp.file("download.zip", contents: "zip")
        let value = "0081;00000000;Safari;"
        _ = value.withCString { setxattr(src, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        let outside = TempDir("outside")
        outside.file("secret.txt", contents: "s")
        let link = tmp.symlink("link", to: outside.path)
        let dest = tmp.dir("dest")
        let (hub, _) = makeTestHub()

        let r = FileTransfer.perform(.copy, sources: [src, link], into: dest, log: Logger(.ops, hub: hub))
        #expect(r.failures.isEmpty)
        var buf = [CChar](repeating: 0, count: 64)
        let n = getxattr(dest + "/download.zip", "com.apple.quarantine", &buf, buf.count, 0, 0)
        #expect(n > 0)
        // The symlink is copied as a link, not as the folder it points to.
        let copiedLink = try FileManager.default.attributesOfItem(atPath: dest + "/link")[.type] as? FileAttributeType
        #expect(copiedLink == .typeSymbolicLink)
    }
}
