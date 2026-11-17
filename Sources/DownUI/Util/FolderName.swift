import Foundation

/// Folder names as Finder shows them for the folders macOS localizes ("Dokumente" for ~/Documents in
/// German, "Macintosh HD" for `/`); every other folder keeps its name on disk, as in the file list.
/// Used for window and tab titles, the path bar and the sidebar.
///
/// Only the folders macOS localizes are looked up: the standard folders in home, the top-level
/// Applications, Library, System and Users, `/` itself, and `*.localized` folders. Everything else is
/// answered from the path alone, without touching the file system, so a symlink to a network share,
/// an autofs or sshfs mount, or any other volume can never block the main thread here.
enum FolderName {
    private static let localizedInHome: Set<String> = [
        "Applications", "Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures", "Public",
    ]
    private static let localizedAtRoot: Set<String> = ["Applications", "Library", "System", "Users"]

    static func display(forPath path: String, home: String) -> String {
        let raw = path == "/" ? "/" : (path as NSString).lastPathComponent
        guard isLocalizable(path, name: raw, home: home) else { return raw }
        let shown = FileManager.default.displayName(atPath: path)
        // displayName also hides extensions and shows ":" as "/", as Finder does. Down shows those names
        // as they are on disk (like the file list), so only a real localization replaces the name.
        let colons = raw.replacingOccurrences(of: ":", with: "/")
        let rewrites: Set = [colons, (raw as NSString).deletingPathExtension, (colons as NSString).deletingPathExtension]
        return rewrites.contains(shown) ? raw : shown
    }

    private static func isLocalizable(_ path: String, name: String, home: String) -> Bool {
        if path == "/" || (name as NSString).pathExtension == "localized" { return true }
        let parent = (path as NSString).deletingLastPathComponent
        if parent == home { return localizedInHome.contains(name) }
        if parent == "/" { return localizedAtRoot.contains(name) }
        return false
    }
}
