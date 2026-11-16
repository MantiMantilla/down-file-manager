import AppKit

/// Keyboard selection in the file list, GNOME-style. ↑/↓ move by one, Home/End jump to the
/// first/last item, Page Up/Down move by a screenful (fn+arrows on Mac keyboards); ⇧ extends.
///
/// All of these share one anchor/cursor model, so mixing them behaves consistently. (AppKit's
/// default only scrolls for Home/End/Page keys, and its private anchor for ⇧-arrows can't be
/// read, which made mixed sequences select the wrong range.)
enum KeyboardNavigation {
    enum Jump: Equatable {
        case previous, next, first, last, pageUp, pageDown
    }

    /// What the last keyboard selection left behind. Only trusted while the table's selection
    /// is still exactly what we set; any mouse or programmatic change invalidates it.
    struct State: Equatable {
        var anchor: Int
        var cursor: Int
        var selection: IndexSet
    }

    /// Maps a key event to a jump. Only bare or ⇧-modified keys count, so ⌥↑ (Enclosing Folder),
    /// ⌥Home (Home folder) and other shortcuts keep working.
    static func jump(for event: NSEvent) -> (jump: Jump, extend: Bool)? {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard flags.subtracting(.shift).isEmpty,
              let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first else { return nil }
        let jump: Jump
        switch Int(scalar.value) {
        case NSUpArrowFunctionKey: jump = .previous
        case NSDownArrowFunctionKey: jump = .next
        case NSHomeFunctionKey: jump = .first
        case NSEndFunctionKey: jump = .last
        case NSPageUpFunctionKey: jump = .pageUp
        case NSPageDownFunctionKey: jump = .pageDown
        default: return nil
        }
        return (jump, flags.contains(.shift))
    }

    /// Cursor (the row the keyboard is on) and anchor (where a ⇧-range starts) for the current selection.
    /// - Parameters:
    ///   - lead: the table's `selectedRow` (the most recently selected row), or nil.
    ///   - remembered: state from our last keyboard move, used only if the selection is unchanged.
    static func cursorAndAnchor(selected: IndexSet, lead: Int?, remembered: State?) -> (cursor: Int?, anchor: Int?) {
        if let r = remembered, r.selection == selected { return (r.cursor, r.anchor) }
        guard let fallback = selected.last else { return (nil, nil) }
        let cursor = lead.flatMap { selected.contains($0) ? $0 : nil } ?? fallback
        // The anchor is the far end of the contiguous run containing the cursor
        // (e.g. after click + ⇧-click on rows 5…10 with the cursor on 10, the anchor is 5).
        var lo = cursor, hi = cursor
        while lo > 0, selected.contains(lo - 1) { lo -= 1 }
        while selected.contains(hi + 1) { hi += 1 }
        return (cursor, cursor == lo ? hi : lo)
    }

    /// Row to move to.
    static func target(for jump: Jump, current: Int?, rowCount: Int, pageSize: Int) -> Int? {
        guard rowCount > 0 else { return nil }
        let last = rowCount - 1
        let page = max(1, pageSize)
        switch jump {
        case .previous: return current.map { max(0, $0 - 1) } ?? last
        case .next: return current.map { min(last, $0 + 1) } ?? 0
        case .first: return 0
        case .last: return last
        case .pageUp: return current.map { max(0, $0 - page) } ?? 0
        case .pageDown: return current.map { min(last, $0 + page) } ?? min(last, page - 1)
        }
    }

    /// Rows to select: just the target, or the range from the anchor to the target when extending.
    static func selection(target: Int, anchor: Int?, extend: Bool) -> IndexSet {
        guard extend, let anchor else { return IndexSet(integer: target) }
        return IndexSet(integersIn: min(anchor, target)...max(anchor, target))
    }

    /// One keypress: the new selection and the state to remember.
    static func apply(_ jump: Jump, extend: Bool, selected: IndexSet, lead: Int?, remembered: State?,
                      rowCount: Int, pageSize: Int) -> State? {
        let (cursor, anchor) = cursorAndAnchor(selected: selected, lead: lead, remembered: remembered)
        guard let target = target(for: jump, current: cursor, rowCount: rowCount, pageSize: pageSize) else { return nil }
        let newAnchor = extend ? (anchor ?? target) : target
        return State(anchor: newAnchor, cursor: target,
                     selection: selection(target: target, anchor: newAnchor, extend: extend))
    }
}
