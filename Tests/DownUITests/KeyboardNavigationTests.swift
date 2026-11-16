import AppKit
import Foundation
import Testing
@testable import DownUI
@testable import DownCore
import DownTestSupport

@Suite("Keyboard navigation (Home/End/Page Up/Page Down)")
@MainActor
struct KeyboardNavigationTests {
    @Test(arguments: [
        (KeyboardNavigation.Jump.first, Int?.some(50), 0),
        (.last, 50, 99),
        (.pageDown, 50, 60),
        (.pageDown, 95, 99),     // clamps at the end
        (.pageUp, 50, 40),
        (.pageUp, 3, 0),         // clamps at the start
        (.pageDown, nil, 9),     // nothing selected: first page's last row
        (.pageUp, nil, 0),
    ])
    func targets(jump: KeyboardNavigation.Jump, current: Int?, expected: Int) {
        #expect(KeyboardNavigation.target(for: jump, current: current, rowCount: 100, pageSize: 10) == expected)
    }

    @Test func emptyFolderHasNoTarget() {
        #expect(KeyboardNavigation.target(for: .last, current: nil, rowCount: 0, pageSize: 10) == nil)
    }

    @Test func shiftExtendsFromAnchor() {
        #expect(KeyboardNavigation.selection(target: 7, anchor: 3, extend: true) == IndexSet(3...7))
        #expect(KeyboardNavigation.selection(target: 1, anchor: 3, extend: true) == IndexSet(1...3))
        #expect(KeyboardNavigation.selection(target: 7, anchor: 3, extend: false) == IndexSet(integer: 7))
    }

    @Test func arrowTargets() {
        #expect(KeyboardNavigation.target(for: .next, current: 4, rowCount: 10, pageSize: 3) == 5)
        #expect(KeyboardNavigation.target(for: .previous, current: 0, rowCount: 10, pageSize: 3) == 0)
        #expect(KeyboardNavigation.target(for: .next, current: nil, rowCount: 10, pageSize: 3) == 0)
        #expect(KeyboardNavigation.target(for: .previous, current: nil, rowCount: 10, pageSize: 3) == 9)
    }

    @Test func anchorIsInferredFromTheSelectionWhenNotRemembered() {
        // Range made by the mouse (click 5, ⇧-click 10): cursor on 10 → anchor 5, and vice versa.
        #expect(KeyboardNavigation.cursorAndAnchor(selected: IndexSet(5...10), lead: 10, remembered: nil) == (10, 5))
        #expect(KeyboardNavigation.cursorAndAnchor(selected: IndexSet(5...10), lead: 5, remembered: nil) == (5, 10))
        #expect(KeyboardNavigation.cursorAndAnchor(selected: IndexSet(integer: 3), lead: 3, remembered: nil) == (3, 3))
        #expect(KeyboardNavigation.cursorAndAnchor(selected: [], lead: nil, remembered: nil) == (nil, nil))
        // Disjoint (⌘-click) selection: the run containing the cursor.
        #expect(KeyboardNavigation.cursorAndAnchor(selected: [1, 2, 7, 8, 9], lead: 9, remembered: nil) == (9, 7))
    }

    @Test func rememberedStateOnlyAppliesToAnUnchangedSelection() {
        let r = KeyboardNavigation.State(anchor: 3, cursor: 6, selection: IndexSet(3...6))
        #expect(KeyboardNavigation.cursorAndAnchor(selected: IndexSet(3...6), lead: 6, remembered: r) == (6, 3))
        // Mouse changed it since: ignore the stale state.
        #expect(KeyboardNavigation.cursorAndAnchor(selected: IndexSet(integer: 20), lead: 20, remembered: r) == (20, 20))
    }

    @Test func onlyBareOrShiftedKeysAreJumps() throws {
        #expect(KeyboardNavigation.jump(for: try key(NSEndFunctionKey))?.jump == .last)
        #expect(KeyboardNavigation.jump(for: try key(NSPageDownFunctionKey, [.shift]))?.extend == true)
        #expect(KeyboardNavigation.jump(for: try key(NSHomeFunctionKey, [.option])) == nil)  // ⌥Home = Home folder
        #expect(KeyboardNavigation.jump(for: try key(NSPageUpFunctionKey, [.command])) == nil)
        // fn+arrow events carry the function-key flag; it must not block the jump.
        #expect(KeyboardNavigation.jump(for: try key(NSHomeFunctionKey, [.function, .numericPad]))?.jump == .first)
    }

    // MARK: In-process AppKit: real key events into the file list

    private func makeList(rows: Int = 200) async throws -> (BrowserViewModel, FileTableView, NSWindow) {
        let h = Harness()
        h.source.set("/many", (0..<rows).map { String(format: "f%03d", $0) })
        let vm = await h.browser(at: "/many")
        let list = FileListViewController(vm: vm)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // Swift owns it; AppKit releasing on close would double-free
        window.contentViewController = list
        window.setContentSize(NSSize(width: 600, height: 400))  // contentViewController shrinks it to fit
        window.layoutIfNeeded()
        list.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(20))  // let the observation reload the table
        #expect(list.tableView.numberOfRows == rows)
        return (vm, list.tableView, window)
    }

    private func rows(_ vm: BrowserViewModel) -> [Int] {
        vm.selection.compactMap { Int($0.dropFirst("/many/f".count)) }.sorted()
    }

    private func press(_ table: FileTableView, _ code: Int, _ flags: NSEvent.ModifierFlags = [], times: Int = 1) throws {
        for _ in 0..<times { table.keyDown(with: try key(code, flags)) }
    }

    @Test func keysMoveTheSelectionInTheFileList() async throws {
        let (vm, table, window) = try await makeList()
        defer { window.close() }
        let page = table.visibleRowCount
        #expect(page > 1)

        try press(table, NSEndFunctionKey)
        #expect(rows(vm) == [199])
        try press(table, NSHomeFunctionKey)
        #expect(rows(vm) == [0])
        try press(table, NSPageDownFunctionKey)
        #expect(rows(vm) == [page])
        try press(table, NSPageDownFunctionKey, [.shift])
        #expect(rows(vm) == Array(page...(page * 2)))
        try press(table, NSHomeFunctionKey, [.shift])  // back past the anchor to the top
        #expect(rows(vm) == Array(0...page))
        try press(table, NSPageUpFunctionKey)
        #expect(rows(vm) == [0])
    }

    /// Reported scenario 1: first item selected, ⇧↓ a few times, then ⇧End.
    @Test func shiftDownThenShiftEndFromTheTop() async throws {
        let (vm, table, window) = try await makeList()
        defer { window.close() }
        try press(table, NSHomeFunctionKey)
        try press(table, NSDownArrowFunctionKey, [.shift], times: 3)
        #expect(rows(vm) == [0, 1, 2, 3])
        try press(table, NSEndFunctionKey, [.shift])
        #expect(rows(vm) == Array(0...199))
    }

    /// Reported scenario 2: ↓ a few times, ⇧↓ a few times, then ⇧End — must keep the range's start.
    @Test func downThenShiftDownThenShiftEnd() async throws {
        let (vm, table, window) = try await makeList()
        defer { window.close() }
        try press(table, NSHomeFunctionKey)
        try press(table, NSDownArrowFunctionKey, times: 3)
        #expect(rows(vm) == [3])
        try press(table, NSDownArrowFunctionKey, [.shift], times: 3)
        #expect(rows(vm) == [3, 4, 5, 6])
        try press(table, NSEndFunctionKey, [.shift])
        #expect(rows(vm) == Array(3...199))
        // And shrinking back with ⇧↑ keeps the same anchor.
        try press(table, NSUpArrowFunctionKey, [.shift], times: 190)
        #expect(rows(vm) == Array(3...9))
    }

    /// A range made with the mouse (click + ⇧-click) extends from its first row.
    @Test func shiftJumpAfterMouseRangeSelection() async throws {
        let (vm, table, window) = try await makeList()
        defer { window.close() }
        // Click row 5, ⇧-click row 10: AppKit's selectedRow ends up on the most recently added row (10).
        table.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        for row in 6...10 { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true) }
        #expect(table.selectedRow == 10)
        try press(table, NSHomeFunctionKey, [.shift])
        #expect(rows(vm) == Array(0...5))
    }

    private func key(_ code: Int, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let chars = String(Character(UnicodeScalar(code)!))
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                             windowNumber: 0, context: nil, characters: chars,
                                             charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0))
    }
}
