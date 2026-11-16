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

    // MARK: File list: no reload or selection sync while the mouse is down

    private func makeList(_ h: Harness, rows: Int) async throws -> (BrowserViewModel, FileTableView, NSWindow) {
        h.source.set("/many", (0..<rows).map { String(format: "f%03d", $0) })
        let vm = await h.browser(at: "/many")
        let list = FileListViewController(vm: vm)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // Swift owns it; AppKit releasing on close would double-free
        window.contentViewController = list
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(20))  // let the observation reload the table
        #expect(list.tableView.numberOfRows == rows)
        return (vm, list.tableView, window)
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
        vm.send(.select(["/many/f007"]))
        try await Task.sleep(for: .milliseconds(30))  // observation callbacks would have run by now
        #expect(table.numberOfRows == 20, "the table must not reload while the mouse is down")
        #expect(table.selectedRowIndexes == IndexSet(integer: 3), "the selection being made must not be replaced")

        // Mouse-up: the deferred reload and sync run at once.
        table.endMouseTracking()
        #expect(table.numberOfRows == 21)
        #expect(table.selectedRowIndexes == IndexSet(integer: 7))
        #expect(h.logs.contains("deferred until mouse-up", category: .dnd))
    }
}
