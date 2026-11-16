import Foundation

/// Folder names as Finder shows them: localized for the folders macOS localizes ("Dokumente" for
/// ~/Documents in German, "Macintosh HD" for `/`), otherwise the name on disk. Used wherever Down shows
/// a folder by name (window and tab titles, path bar, sidebar), so the same folder reads the same
/// everywhere.
///
/// Only paths on the startup disk are looked up. The lookup touches the file system, which could block
/// the main thread on an unresponsive network volume, and folders on other volumes aren't localized.
/// Callers still pass the result through `DisplayName.sanitize`.
enum FolderName {
    static func display(forPath path: String) -> String {
        if path == "/Volumes" || path.hasPrefix("/Volumes/") {
            return (path as NSString).lastPathComponent
        }
        return FileManager.default.displayName(atPath: path)
    }
}
