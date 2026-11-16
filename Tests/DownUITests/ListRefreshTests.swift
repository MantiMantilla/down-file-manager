import AppKit
import Foundation
import Testing
@testable import DownUI
@testable import DownCore
import DownTestSupport

/// Background refreshes (FSEvents) must not disturb the selection the user is making.
/// Reported: in ~, ~/Library (hidden) changes several times a second. Each change reloaded the list,
/// which flipped drag-selections to start at row 0, emptied them, or restored a selection just cleared.
@Suite("List refresh vs. selection")
@MainActor
struct ListRefreshTests {
    // MARK: View model: only real changes bump the revision

    @Test func refreshOfAHiddenItemDoesNotBumpTheRevision() async {
        let h = Harness()
        let vm = await h.browser()
        await waitUntil { h.source.listCalls.count >= 1 }
        try? await Task.sleep(for: .milliseconds(20))  // let the watch effect subscribe
        let revision = vm.itemsRevision

        h.source.emit(.changed([".secret"]), for: "/home")  // like ~/Library: hidden, changes constantly
        await waitUntil { h.logs.contains("itemsRefreshed", category: .nav) }
        await vm.settle()
        #expect(vm.itemsRevision == revision)

        // A change to a visible item still reloads.
        let touched = Date(timeIntervalSince1970: 1_800_000_000)
        h.source.set("/home", ["Documents/", "notes.txt", ".secret", "b.txt", "A.txt"], modified: touched)
        h.source.emit(.changed(["notes.txt"]), for: "/home")
        await waitUntil { vm.items.first { $0.name == "notes.txt" }?.modified == touched }
        await vm.settle()
        #expect(vm.itemsRevision == revision + 1)
    }

    /// `==` ignores a symlink's target kind; skipping the reload must not drop that change.
    @Test func reloadPicksUpASymlinkRetargetedFromFolderToFile() async {
        let h = Harness()
        func link(toFolder: Bool) -> FileItem {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            return FileItem(path: "/tmp/link", name: "link", kind: .symlink, size: 10, modified: date, created: date,
                            isHidden: false, isPackage: false, entryCount: nil, mode: 0o755, fileID: 42,
                            symlinkTargetIsDirectory: toFolder)
        }
        h.source.setItems("/tmp", [link(toFolder: true)])
        let vm = await h.browser(at: "/tmp")
        #expect(vm.items.first?.isFolderLike == true)
        let revision = vm.itemsRevision

        h.source.setItems("/tmp", [link(toFolder: false)])  // the link itself is untouched
        vm.send(.reload)
        await vm.settle()
        #expect(vm.items.first?.isFolderLike == false)
        #expect(vm.itemsRevision == revision + 1)
    }

    @Test func selectDropsPathsThatNoLongerExist() async {
        let h = Harness()
        let vm = await h.browser()
        vm.send(.select(["/home/notes.txt", "/home/deleted.txt"]))
        #expect(vm.selection == ["/home/notes.txt"])
    }

    // MARK: File list: no reload or selection sync while the mouse is down

    /// Puts `controller` in an off-screen window (the caller closes it).
    private func host(_ controller: NSViewController) async throws -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // Swift owns it; AppKit releasing on close would double-free
        window.contentViewController = controller
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(20))  // let observations run and the watch effect subscribe
        return window
    }

    private func makeList(_ h: Harness, rows: Int) async throws -> (BrowserViewModel, FileTableView, NSWindow) {
        h.source.set("/many", (0..<rows).map { String(format: "f%03d", $0) })
        let vm = await h.browser(at: "/many")
        let list = FileListViewController(vm: vm)
        let window = try await host(list)
        #expect(list.tableView.numberOfRows == rows)
        return (vm, list.tableView, window)
    }

    /// Mid-press the table still shows a deleted file's row; the selection it reports at mouse-up
    /// must not keep that file.
    @Test func aRowDeletedMidPressDoesNotStaySelected() async throws {
        let h = Harness()
        let (vm, table, window) = try await makeList(h, rows: 20)
        defer { window.close() }

        table.beginMouseTracking()
        h.source.set("/many", (0..<20).filter { $0 != 5 }.map { String(format: "f%03d", $0) })
        h.source.emit(.changed(["f005"]), for: "/many")
        await waitUntil { h.logs.contains("reload deferred until mouse-up", category: .dnd) }
        #expect(vm.items.count == 19)
        #expect(table.numberOfRows == 20)  // f005's row is still on screen

        table.selectRowIndexes(IndexSet(4...5), byExtendingSelection: false)  // the press ends on f004–f005
        #expect(vm.selection == ["/many/f004"])
        table.endMouseTracking()
        #expect(table.numberOfRows == 19)
        #expect(table.selectedRowIndexes == IndexSet(integer: 4))
    }

    @Test func overlaysWaitForMouseUp() async throws {
        let h = Harness()
        h.source.set("/many", ["f000", "f001"])
        let vm = await h.browser(at: "/many")
        let content = ContentViewController(vm: vm)
        let window = try await host(content)
        defer { window.close() }

        vm.send(.select(["/many/f000"]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(!content.statusPill.isHidden)
        #expect(content.emptyStack.isHidden)

        // Every file is deleted mid-press: the old rows stay until mouse-up, so the overlays must too.
        content.list.tableView.beginMouseTracking()
        h.source.set("/many", [])
        h.source.emit(.changed(["f000", "f001"]), for: "/many")
        await waitUntil { content.overlaysDeferred }
        #expect(vm.items.isEmpty)
        #expect(content.emptyStack.isHidden, "no \"Folder is Empty\" over rows still on screen")
        #expect(!content.statusPill.isHidden)

        content.list.tableView.endMouseTracking()
        #expect(!content.emptyStack.isHidden)
        #expect(content.statusPill.isHidden)
    }

    @Test func reloadAndSelectionSyncWaitForMouseUp() async throws {
        let h = Harness()
        let (vm, table, window) = try await makeList(h, rows: 20)
        defer { window.close() }
        await waitUntil { h.source.listCalls.count >= 1 }
        try await Task.sleep(for: .milliseconds(20))  // let the watch effect subscribe

        vm.send(.select(["/many/f003"]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(table.selectedRowIndexes == IndexSet(integer: 3))

        // Mid-press (e.g. a drag-select in progress), a file appears and the model's selection changes.
        table.beginMouseTracking()
        h.source.set("/many", (0..<21).map { String(format: "f%03d", $0) })
        h.source.emit(.changed(["f020"]), for: "/many")
        await waitUntil { vm.items.count == 21 }
        await waitUntil { h.logs.contains("reload deferred until mouse-up", category: .dnd) }
        vm.send(.select(["/many/f007"]))
        await waitUntil { h.logs.contains("selection sync deferred until mouse-up", category: .dnd) }
        #expect(table.numberOfRows == 20, "the table must not reload while the mouse is down")
        #expect(table.selectedRowIndexes == IndexSet(integer: 3), "the selection being made must not be replaced")

        // Mouse-up: the deferred reload and sync run at once.
        table.endMouseTracking()
        #expect(table.numberOfRows == 21)
        #expect(table.selectedRowIndexes == IndexSet(integer: 7))
        #expect(h.logs.contains("deferred until mouse-up", category: .dnd))
    }
}
