import Foundation
import Testing
@testable import DownUI
@testable import DownCore
import DownTestSupport

@MainActor
struct Harness {
    let source = FakeFileSource()
    let workspace = FakeWorkspace()
    let hub: LogHub
    let logs: TestLogSink
    let app: AppViewModel

    init(settings: Settings = Settings(), debugSession: Bool = false) {
        (hub, logs) = makeTestHub()
        let env = AppEnvironment.test(source: source, workspace: workspace, hub: hub, home: "/home")
        app = AppViewModel(env: env, settings: settings, store: nil, logging: nil, debugSession: debugSession)
        source.set("/", ["home/", "tmp/"])
        source.set("/home", ["Documents/", "notes.txt", ".secret", "b.txt", "A.txt"])
        source.set("/home/Documents", ["report.pdf", "Taxes/"])
        source.set("/home/Documents/Taxes", ["2025.pdf"])
        source.set("/tmp", ["scratch"])
    }

    func browser(at path: String = "/home") async -> BrowserViewModel {
        let vm = BrowserViewModel(app: app, location: .file(path))
        vm.start()
        await vm.settle()
        return vm
    }
}

/// Polls until `condition` holds (for effects that start asynchronously, like watchers).
@MainActor
func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + timeout
    while !condition() && ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(5))
    }
}

@Suite("BrowserViewModel")
@MainActor
struct BrowserViewModelTests {
    @Test func initialLoadSortsFoldersFirstAndHidesDotfiles() async {
        let h = Harness()
        let vm = await h.browser()
        #expect(vm.loadState == .loaded)
        #expect(vm.items.map(\.name) == ["Documents", "A.txt", "b.txt", "notes.txt"])
    }

    @Test func toggleHiddenUpdatesEveryTab() async {
        let h = Harness()
        let a = await h.browser()
        let b = await h.browser()
        a.send(.toggleHidden)
        await a.settle()
        #expect(h.app.settings.showHidden)
        #expect(a.items.contains { $0.name == ".secret" })
        #expect(b.items.contains { $0.name == ".secret" })
    }

    @Test func navigationHistoryBackForwardUp() async {
        let h = Harness()
        let vm = await h.browser()
        vm.send(.navigate(.file("/home/Documents")))
        await vm.settle()
        vm.send(.navigate(.file("/home/Documents/Taxes")))
        await vm.settle()
        #expect(vm.location.path == "/home/Documents/Taxes")
        #expect(vm.canGoBack && !vm.canGoForward)

        vm.send(.goBack)
        await vm.settle()
        #expect(vm.location.path == "/home/Documents")
        #expect(vm.canGoForward)
        // Coming back out of Taxes selects it (Nautilus behavior).
        #expect(vm.selection == ["/home/Documents/Taxes"])

        vm.send(.goForward)
        await vm.settle()
        #expect(vm.location.path == "/home/Documents/Taxes")

        vm.send(.goUp)
        await vm.settle()
        #expect(vm.location.path == "/home/Documents")
        #expect(vm.selection == ["/home/Documents/Taxes"])
        #expect(!vm.canGoForward)  // a new navigation clears forward history
    }

    @Test func goHomeUsesEnvironmentHome() async {
        let h = Harness()
        let vm = await h.browser(at: "/tmp")
        vm.send(.goHome)
        await vm.settle()
        #expect(vm.location.path == "/home")
    }

    @Test func staleListingResultsAreDropped() async {
        let h = Harness()
        let vm = await h.browser()
        h.source.set("/slow", ["should-not-appear"])
        let gate = h.source.hold("/slow")
        vm.send(.navigate(.file("/slow")))
        vm.send(.navigate(.file("/tmp")))  // user moves on before /slow finishes
        gate.yield()
        gate.finish()
        await vm.settle()
        #expect(vm.location.path == "/tmp")
        #expect(vm.items.map(\.name) == ["scratch"])
    }

    @Test func permissionErrorsAreReported() async {
        let h = Harness()
        h.source.fail("/locked", with: FileSourceError.posix(EACCES, path: "/locked"))
        let vm = await h.browser()
        vm.send(.navigate(.file("/locked")))
        await vm.settle()
        guard case .failed(_, let denied) = vm.loadState else {
            Issue.record("expected failure, got \(vm.loadState)")
            return
        }
        #expect(denied)
        #expect(vm.items.isEmpty)
    }

    @Test func watchEventsUpsertAndRemove() async {
        let h = Harness()
        let vm = await h.browser(at: "/tmp")
        await waitUntil { h.source.listCalls.count >= 1 }
        try? await Task.sleep(for: .milliseconds(20))  // let the watch effect subscribe

        h.source.set("/tmp", ["fresh"])  // "scratch" deleted, "fresh" created
        h.source.emit(.changed(["scratch", "fresh"]), for: "/tmp")
        await waitUntil { vm.items.map(\.name) == ["fresh"] }
        await vm.settle()
        #expect(vm.items.map(\.name) == ["fresh"])
    }

    @Test func rescanReloadsWithoutClearingFirst() async {
        let h = Harness()
        let vm = await h.browser(at: "/tmp")
        try? await Task.sleep(for: .milliseconds(20))
        h.source.set("/tmp", ["scratch", "other"])
        h.source.emit(.rescan, for: "/tmp")
        await waitUntil { vm.items.count == 2 }
        await vm.settle()
        #expect(Set(vm.items.map(\.name)) == ["scratch", "other"])
        #expect(vm.loadState == .loaded)
    }

    @Test func springLoadingAndCancelReturnsToOrigin() async {
        let h = Harness()
        let vm = await h.browser()
        vm.send(.springLoad(.file("/home/Documents")))
        await vm.settle()
        vm.send(.springLoad(.file("/home/Documents/Taxes")))
        await vm.settle()
        #expect(vm.location.path == "/home/Documents/Taxes")
        #expect(vm.springOrigin?.path == "/home")

        vm.send(.springLoadCancelled)
        await vm.settle()
        #expect(vm.location.path == "/home")
        #expect(vm.springOrigin == nil)
        #expect(h.logs.contains("drag cancelled", category: .dnd))
    }

    @Test func deliberateNavigationClearsALeftoverSpringLoadDetour() async {
        // A drag from another app that spring-loaded us and was then cancelled never reports its end.
        let h = Harness()
        let vm = await h.browser()
        vm.send(.springLoad(.file("/home/Documents")))
        await vm.settle()
        #expect(vm.springOrigin?.path == "/home")
        vm.send(.navigate(.file("/tmp")))
        await vm.settle()
        #expect(vm.springOrigin == nil)
        // So a later cancelled drag doesn't jump back to that stale origin.
        vm.send(.springLoadCancelled)
        await vm.settle()
        #expect(vm.location.path == "/tmp")
    }

    @Test func completedDragKeepsSpringLoadedLocation() async {
        let h = Harness()
        let vm = await h.browser()
        vm.send(.springLoad(.file("/home/Documents")))
        await vm.settle()
        vm.send(.dragEnded)
        #expect(vm.springOrigin == nil)
        #expect(vm.location.path == "/home/Documents")
    }

    @Test func openingAFolderNavigatesAndAFileUsesWorkspace() async {
        let h = Harness()
        let vm = await h.browser()
        vm.send(.select(["/home/notes.txt"]))
        vm.send(.openSelection)
        await vm.settle()
        #expect(h.workspace.opened.map { $0.path(percentEncoded: false) } == ["/home/notes.txt"])

        vm.send(.select(["/home/Documents"]))
        vm.send(.openSelection)
        await vm.settle()
        #expect(vm.location.path == "/home/Documents")
    }

    @Test func openInTerminalUsesConfiguredApp() async {
        var settings = Settings()
        settings.terminalBundleID = "com.googlecode.iterm2"
        let h = Harness(settings: settings)
        let vm = await h.browser()
        vm.send(.openInTerminal)
        await vm.settle()
        let call = h.workspace.terminalOpens.first
        #expect(call?.0.path(percentEncoded: false).hasPrefix("/home") == true)
        #expect(call?.1 == "com.googlecode.iterm2")
    }

    @Test func sortChangeReordersAndPersistsAsDefault() async {
        let h = Harness()
        let vm = await h.browser()
        vm.send(.setSort(FileSortOrder(field: .name, ascending: false, foldersFirst: false)))
        #expect(vm.items.map(\.name) == ["notes.txt", "Documents", "b.txt", "A.txt"])
        #expect(h.app.settings.sort.ascending == false)
    }

    @Test func selectionIsPrunedWhenItemsDisappear() async {
        let h = Harness()
        let vm = await h.browser(at: "/tmp")
        vm.send(.select(["/tmp/scratch"]))
        h.source.set("/tmp", [])
        vm.send(.reload)
        await vm.settle()
        #expect(vm.selection.isEmpty)
    }

    @Test func largeFoldersSortOffTheMainActor() async {
        let h = Harness()
        let names = (0..<(BrowserViewModel.backgroundSortThreshold + 10)).map { "f\($0)" }.shuffled()
        h.source.set("/big", names)
        h.source.batchSize = 2_000
        let vm = await h.browser()
        vm.send(.navigate(.file("/big")))
        await vm.settle()
        #expect(vm.items.count == names.count)
        #expect(vm.items.first?.name == "f0")
        #expect(vm.items[1].name == "f1")
        #expect(vm.items.last?.name == "f\(names.count - 1)")
    }

    @Test func actionsAreLoggedWithCorrelatedIDs() async {
        let h = Harness()
        let vm = await h.browser()
        let id = ActionID(raw: 0xBEEF)
        vm.send(.navigate(.file("/tmp")), id: id)
        await vm.settle()
        let tagged = h.logs.entries.filter { $0.actionID == id }
        #expect(tagged.contains { $0.message.contains("action navigate(/tmp)") })
        #expect(tagged.contains { $0.message.contains("loading /tmp") })
    }
}

@Suite("AppViewModel")
@MainActor
struct AppViewModelTests {
    @Test func pinsAddMoveRenameRemove() {
        let h = Harness()
        h.app.send(.addPin(path: "/a", name: nil, at: nil))
        h.app.send(.addPin(path: "/b", name: "Bee", at: nil))
        h.app.send(.addPin(path: "/c", name: nil, at: 0))
        #expect(h.app.settings.pins.map(\.name) == ["c", "a", "Bee"])

        h.app.send(.addPin(path: "/a/", name: nil, at: nil))  // duplicate (normalized) is ignored
        #expect(h.app.settings.pins.count == 3)

        h.app.send(.movePin(from: 0, to: 3))
        #expect(h.app.settings.pins.map(\.name) == ["a", "Bee", "c"])

        let bee = h.app.settings.pins[1].id
        h.app.send(.renamePin(bee, "  B  "))
        #expect(h.app.settings.pins[1].name == "B")
        h.app.send(.renamePin(bee, "   "))  // blank names rejected
        #expect(h.app.settings.pins[1].name == "B")

        h.app.send(.removePin(bee))
        #expect(h.app.settings.pins.map(\.name) == ["a", "c"])
    }

    @Test func debugConsoleAvailability() {
        #expect(!Harness().app.debugConsoleAvailable)
        #expect(Harness(debugSession: true).app.debugConsoleAvailable)
        let h = Harness()
        h.app.send(.setDebugConsoleEnabled(true))
        #expect(h.app.debugConsoleAvailable)
    }

    @Test func shortcutOverridesRebuildKeybindings() {
        let h = Harness()
        h.app.send(.setShortcuts(.toggleHidden, [.cmdShift(".")]))
        #expect(h.app.keybindings.command(for: .cmd("h")) == nil)
        #expect(h.app.keybindings.command(for: .cmdShift(".")) == .toggleHidden)
        h.app.send(.setShortcuts(.toggleHidden, nil))
        #expect(h.app.keybindings.command(for: .cmd("h")) == .toggleHidden)
    }

    @Test func zoomIsClamped() {
        let h = Harness()
        h.app.send(.setListZoom(5))
        #expect(h.app.settings.listZoom == 2)
        h.app.send(.setListZoom(0.1))
        #expect(h.app.settings.listZoom == 0.75)
    }
}
