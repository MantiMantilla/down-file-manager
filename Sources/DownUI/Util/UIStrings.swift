import DownCore
import Foundation

/// Localized strings shown in more than one place, so each has a single catalog entry and comment.
/// Strings used once stay inline at their call site.
enum UIStrings {
    static var home: String {
        String(localized: "Home", bundle: .module, comment: "The user's home folder: sidebar row, path bar and window title")
    }

    static var view: String {
        String(localized: "View", bundle: .module, comment: "Menu bar title, and the label of the toolbar's view-mode buttons")
    }

    /// A sort field's name: file list column header and the toolbar menu's Sort By items.
    static func title(of field: SortField) -> String {
        switch field {
        case .name: String(localized: "Name", bundle: .module, comment: "File list column header, and an item in the Sort By menu")
        case .size: String(localized: "Size", bundle: .module, comment: "File list column header, and an item in the Sort By menu")
        case .modified:
            String(localized: "Modified", bundle: .module, comment: "File list column header (date modified), and an item in the Sort By menu")
        case .kind:
            String(localized: "Kind", bundle: .module, comment: "File list column header (type of file), and an item in the Sort By menu")
        }
    }

    static var cancel: String {
        String(localized: "Cancel", bundle: .module, comment: "Alert button")
    }
}
