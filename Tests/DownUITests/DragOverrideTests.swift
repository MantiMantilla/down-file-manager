import AppKit
import ObjectiveC
import Testing
@testable import DownUI

/// Overriding `draggingEnded(_:)` on an NSTableView / NSOutlineView, even with a plain call to
/// super, stops AppKit from ever finishing drags that start in that view: the end-of-drag callback
/// never arrives, the view believes its first drag is still running, and every later press turns
/// into a drag-select. (Isolated with a standalone probe: a plain NSTableView plus only that
/// override reproduces it; the other drop hooks don't.) These tests keep it from creeping back.
@Suite("Drag-source views keep AppKit's drag-end handling")
struct DragOverrideTests {
    static let draggingEnded = NSSelectorFromString("draggingEnded:")
    /// The source-side end callback; overriding it without forwarding would also hide the end of drags.
    static let sessionEnded = NSSelectorFromString("draggingSession:endedAtPoint:operation:")

    /// True when `cls` (or any class between it and AppKit's `base`) replaced `base`'s implementation.
    /// Comparing against the AppKit class itself, not the direct superclass, also catches an override
    /// hidden in an intermediate base class.
    static func replaces(_ cls: AnyClass, _ base: AnyClass, _ selector: Selector) -> Bool {
        class_getMethodImplementation(cls, selector) != class_getMethodImplementation(base, selector)
    }

    @Test(arguments: [draggingEnded, sessionEnded])
    func fileListKeepsAppKitsImplementation(selector: Selector) {
        #expect(!Self.replaces(FileTableView.self, NSTableView.self, selector))
    }

    @Test(arguments: [draggingEnded, sessionEnded])
    func sidebarKeepsAppKitsImplementation(selector: Selector) {
        #expect(!Self.replaces(SidebarOutlineView.self, NSOutlineView.self, selector))
    }

    @Test func theCheckDetectsADirectOverride() {
        #expect(Self.replaces(OverridingTable.self, NSTableView.self, Self.draggingEnded))
    }

    @Test func theCheckDetectsAnOverrideInAnIntermediateBaseClass() {
        // The case a direct-superclass comparison would miss.
        #expect(Self.replaces(InheritingTable.self, NSTableView.self, Self.draggingEnded))
    }
}

private class OverridingTable: NSTableView {
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
    }
}

private final class InheritingTable: OverridingTable {}
