import AppKit
import UniformTypeIdentifiers
import DownCore

/// Icons cached per type; per-file icons only where they differ (apps, packages, custom icons).
@MainActor
final class IconCache {
    static let shared = IconCache()

    private var byType: [String: NSImage] = [:]
    private let perFile = NSCache<NSString, NSImage>()

    private init() {
        perFile.countLimit = 2000
    }

    func icon(for item: FileItem) -> NSImage {
        if item.isPackage || item.fileExtension.lowercased() == "app" {
            if let hit = perFile.object(forKey: item.path as NSString) { return hit }
            let icon = NSWorkspace.shared.icon(forFile: item.path)
            perFile.setObject(icon, forKey: item.path as NSString)
            return icon
        }
        let key: String
        let type: UTType
        switch item.kind {
        // Packages returned above, so every directory here is a plain folder.
        case .directory:
            key = "public.folder"
            type = .folder
        case .symlink where item.symlinkTargetIsDirectory:
            key = "public.folder"
            type = .folder
        case .symlink:
            key = "ext:" + item.fileExtension.lowercased()
            type = UTType(filenameExtension: item.fileExtension) ?? .item
        default:
            key = "ext:" + item.fileExtension.lowercased()
            type = item.fileExtension.isEmpty ? .data : (UTType(filenameExtension: item.fileExtension) ?? .data)
        }
        if let hit = byType[key] { return hit }
        let icon = NSWorkspace.shared.icon(for: type)
        byType[key] = icon
        return icon
    }

    func icon(forPath path: String) -> NSImage {
        if let hit = perFile.object(forKey: path as NSString) { return hit }
        let icon = NSWorkspace.shared.icon(forFile: path)
        perFile.setObject(icon, forKey: path as NSString)
        return icon
    }
}
