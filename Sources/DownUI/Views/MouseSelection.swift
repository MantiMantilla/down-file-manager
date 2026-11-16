import AppKit

/// Finder-style click behavior inside a multi-item selection.
///
/// AppKit waits about half a second (the double-click interval) before collapsing a multi-item
/// selection to the clicked row, in case the click turns into a drag or double-click. Down
/// collapses on mouse-up instead. A double-click that follows still opens the whole previous
/// selection, because the collapse is remembered and undone for it.
enum MouseSelection {
    /// Modifiers that change what a click means (⌘ toggles, ⇧ extends, ⌃ opens the menu).
    static let meaningfulModifiers: NSEvent.ModifierFlags = [.command, .shift, .control, .option]

    /// Whether a finished press should collapse the selection to `row` right away.
    /// - Parameters:
    ///   - before/after: selection when the button went down / when tracking returned.
    ///   - endedWithMouseUp: false when tracking returned because a drag started.
    static func shouldCollapse(row: Int, clickCount: Int, modifiers: NSEvent.ModifierFlags,
                               before: IndexSet, after: IndexSet, endedWithMouseUp: Bool) -> Bool {
        row >= 0
            && clickCount == 1
            && modifiers.intersection(meaningfulModifiers).isEmpty
            && endedWithMouseUp
            && before.count > 1
            && before.contains(row)
            && after == before  // AppKit hasn't collapsed it (or changed it some other way) yet
    }

    struct Collapse: Equatable {
        let row: Int
        let previous: IndexSet
        let time: TimeInterval
    }

    /// The selection a double-click on `row` at `time` should act on, if it follows a collapse.
    static func selectionForDoubleClick(on row: Int, at time: TimeInterval, after collapse: Collapse?,
                                        interval: TimeInterval) -> IndexSet? {
        guard let collapse, collapse.row == row, time - collapse.time <= interval else { return nil }
        return collapse.previous
    }
}
