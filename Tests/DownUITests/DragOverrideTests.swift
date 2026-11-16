import AppKit
import ObjectiveC
import Testing
@testable import DownUI

/// Overriding `draggingEnded(_:)` on an NSTableView / NSOutlineView, even with a plain call to
/// super, stops AppKit from ever finishing drags that start in that view: the end-of-drag callback
/// never arrives, the view believes its first drag is still running, and every later press turns
/// into a drag-select. (Isolated with a standalone probe: a plain NSTableView plus only that
/// override reproduces it; the other drop hooks don't.) These tests keep the override from
/// creeping back into the views that start drags.
@Suite("Drag-source views don't override draggingEnded")
struct DragOverrideTests {
    static let draggingEnded = NSSelectorFromString("draggingEnded:")

    /// True when `cls` provides its own implementation of `selector` instead of inheriting it.
    static func overrides(_ cls: AnyClass, _ selector: Selector) -> Bool {
        guard let superclass = class_getSuperclass(cls) else { return false }
        return class_getMethodImplementation(cls, selector) != class_getMethodImplementation(superclass, selector)
    }

    @Test func fileListDoesNotOverrideDraggingEnded() {
        #expect(!Self.overrides(FileTableView.self, Self.draggingEnded))
    }

    @Test func sidebarDoesNotOverrideDraggingEnded() {
        #expect(!Self.overrides(SidebarOutlineView.self, Self.draggingEnded))
    }

    @Test func theCheckDetectsAnOverride() {
        // Sanity check that `overrides` can actually see an override.
        #expect(Self.overrides(OverridingTable.self, Self.draggingEnded))
    }
}

private final class OverridingTable: NSTableView {
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        super.draggingEnded(sender)
    }
}
