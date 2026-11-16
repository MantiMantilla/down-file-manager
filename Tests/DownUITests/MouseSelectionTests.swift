import AppKit
import Testing
@testable import DownUI

@Suite("Mouse selection (instant collapse)")
struct MouseSelectionTests {
    let range = IndexSet(3...9)

    @Test func plainClickInsideAMultiSelectionCollapsesImmediately() {
        #expect(MouseSelection.shouldCollapse(row: 8, clickCount: 1, modifiers: [], before: range, after: range,
                                              endedWithMouseUp: true))
    }

    @Test func capsLockAndFnDoNotCountAsModifiers() {
        #expect(MouseSelection.shouldCollapse(row: 8, clickCount: 1, modifiers: [.capsLock, .function],
                                              before: range, after: range, endedWithMouseUp: true))
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .shift, .control, .option])
    func modifiedClicksKeepAppKitBehavior(modifier: NSEvent.ModifierFlags) {
        #expect(!MouseSelection.shouldCollapse(row: 8, clickCount: 1, modifiers: modifier, before: range, after: range,
                                               endedWithMouseUp: true))
    }

    @Test func dragsDoNotCollapse() {
        // Tracking returned because a drag of the whole selection started.
        #expect(!MouseSelection.shouldCollapse(row: 8, clickCount: 1, modifiers: [], before: range, after: range,
                                               endedWithMouseUp: false))
    }

    @Test func secondClickOfADoubleClickDoesNotCollapse() {
        #expect(!MouseSelection.shouldCollapse(row: 8, clickCount: 2, modifiers: [], before: range, after: range,
                                               endedWithMouseUp: true))
    }

    @Test func clicksOutsideTheSelectionOrOnSingleSelectionsAreLeftToAppKit() {
        #expect(!MouseSelection.shouldCollapse(row: 1, clickCount: 1, modifiers: [], before: range, after: range,
                                               endedWithMouseUp: true))  // AppKit already selects row 1 itself
        #expect(!MouseSelection.shouldCollapse(row: 4, clickCount: 1, modifiers: [], before: [4], after: [4],
                                               endedWithMouseUp: true))
        #expect(!MouseSelection.shouldCollapse(row: -1, clickCount: 1, modifiers: [], before: range, after: range,
                                               endedWithMouseUp: true))  // empty space
    }

    @Test func noCollapseIfTheSelectionAlreadyChanged() {
        #expect(!MouseSelection.shouldCollapse(row: 8, clickCount: 1, modifiers: [], before: range, after: [8],
                                               endedWithMouseUp: true))
    }

    @Test func doubleClickRightAfterACollapseUsesThePreviousSelection() {
        let collapse = MouseSelection.Collapse(row: 8, previous: range, time: 100)
        #expect(MouseSelection.selectionForDoubleClick(on: 8, at: 100.3, after: collapse, interval: 0.5) == range)
    }

    @Test func doubleClickTooLateOrElsewhereKeepsTheCollapsedSelection() {
        let collapse = MouseSelection.Collapse(row: 8, previous: range, time: 100)
        #expect(MouseSelection.selectionForDoubleClick(on: 8, at: 101, after: collapse, interval: 0.5) == nil)
        #expect(MouseSelection.selectionForDoubleClick(on: 5, at: 100.2, after: collapse, interval: 0.5) == nil)
        #expect(MouseSelection.selectionForDoubleClick(on: 8, at: 100.2, after: nil, interval: 0.5) == nil)
    }
}
