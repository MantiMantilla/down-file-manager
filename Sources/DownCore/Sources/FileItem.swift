import Foundation
import Synchronization
import UniformTypeIdentifiers

public struct FileItem: Sendable, Hashable, Identifiable {
    public enum Kind: UInt8, Sendable, Codable {
        case file, directory, symlink, other
    }

    /// Full path; unique across folders (search results mix folders).
    public var id: String { path }

    public let path: String
    public let name: String
    public let kind: Kind
    public let size: Int64
    public let modified: Date
    public let created: Date
    public let isHidden: Bool
    public let isPackage: Bool
    /// Directory entry count when the file system reports it cheaply.
    public let entryCount: Int?
    public let mode: UInt16
    public let fileID: UInt64
    /// Symlinks only: whether the target is a directory (so it can be navigated into).
    public let symlinkTargetIsDirectory: Bool
    /// Precomputed natural-order collation key (see `SortKey`).
    public let sortKey: [UInt8]

    public init(path: String, name: String, kind: Kind, size: Int64, modified: Date, created: Date,
                isHidden: Bool, isPackage: Bool, entryCount: Int?, mode: UInt16, fileID: UInt64,
                symlinkTargetIsDirectory: Bool = false) {
        self.path = path
        self.name = name
        self.kind = kind
        self.size = size
        self.modified = modified
        self.created = created
        self.isHidden = isHidden
        self.isPackage = isPackage
        self.entryCount = entryCount
        self.mode = mode
        self.fileID = fileID
        self.symlinkTargetIsDirectory = symlinkTargetIsDirectory
        sortKey = SortKey.make(name)
    }

    public var url: URL { URL(filePath: path, directoryHint: isFolderLike ? .isDirectory : .notDirectory) }

    /// Folders the user can navigate into (directories that aren't packages, and symlinks to them).
    public var isFolderLike: Bool {
        (kind == .directory && !isPackage) || (kind == .symlink && symlinkTargetIsDirectory)
    }

    public var fileExtension: String { (name as NSString).pathExtension }

    public var location: Location { .file(path) }

    public var parentPath: String { (path as NSString).deletingLastPathComponent }

    public static func == (a: FileItem, b: FileItem) -> Bool {
        a.path == b.path && a.modified == b.modified && a.size == b.size && a.kind == b.kind
            && a.isHidden == b.isHidden && a.entryCount == b.entryCount && a.mode == b.mode
    }

    public func hash(into h: inout Hasher) { h.combine(path) }

    /// Every stored field matches. Unlike `==`, this also covers fields that change how the item is
    /// shown or opened without touching its own metadata (a symlink's target kind, the package flag).
    /// `sortKey` is derived from `name`, so it's covered too.
    public func isIdentical(to other: FileItem) -> Bool {
        self == other && name == other.name && created == other.created && isPackage == other.isPackage
            && fileID == other.fileID && symlinkTargetIsDirectory == other.symlinkTargetIsDirectory
    }
}

/// Cached UTType lookups keyed by extension (UTType creation is relatively expensive).
public enum TypeCache {
    private struct Entry: Sendable { let isPackage: Bool; let description: String }
    private static let fileCache = Mutex<[String: Entry]>([:])
    private static let packageCache = Mutex<[String: Bool]>([:])

    /// For regular files (UTType lookup conforming to public.data).
    private static func entry(for ext: String) -> Entry {
        let key = ext.lowercased()
        if let hit = fileCache.withLock({ $0[key] }) { return hit }
        let type = UTType(filenameExtension: key)
        let entry = Entry(isPackage: false,
                          description: type?.localizedDescription ?? (key.isEmpty ? "Document" : "\(key.uppercased()) file"))
        fileCache.withLock { $0[key] = entry }
        return entry
    }

    /// Directory extensions must be looked up as directories, or `.app` resolves to a dynamic data type.
    public static func isPackageExtension(_ ext: String) -> Bool {
        guard !ext.isEmpty else { return false }
        let key = ext.lowercased()
        if let hit = packageCache.withLock({ $0[key] }) { return hit }
        let isPackage = UTType(filenameExtension: key, conformingTo: .directory)?.conforms(to: .package) ?? false
        packageCache.withLock { $0[key] = isPackage }
        return isPackage
    }

    private static func packageDescription(for ext: String) -> String {
        UTType(filenameExtension: ext.lowercased(), conformingTo: .directory)?.localizedDescription ?? "Package"
    }

    public static func kindDescription(for item: FileItem) -> String {
        switch item.kind {
        case .directory where !item.isPackage: return "Folder"
        case .directory: return packageDescription(for: item.fileExtension)
        case .symlink: return item.symlinkTargetIsDirectory ? "Alias (folder)" : "Alias"
        case .other: return "Special file"
        default: return entry(for: item.fileExtension).description
        }
    }
}
