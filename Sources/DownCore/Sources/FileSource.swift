import Foundation

public struct SourceCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let watch = SourceCapabilities(rawValue: 1 << 0)
    public static let trash = SourceCapabilities(rawValue: 1 << 1)
    public static let clone = SourceCapabilities(rawValue: 1 << 2)
    public static let thumbnails = SourceCapabilities(rawValue: 1 << 3)
}

public enum WatchEvent: Sendable, Equatable {
    /// These child names (of the watched folder) changed: created, deleted, renamed or modified.
    case changed(Set<String>)
    /// Too many changes or dropped events; re-list the folder.
    case rescan
    /// The watched folder itself was deleted, renamed or unmounted.
    case rootChanged
}

public enum FileSourceError: Error, Equatable, LocalizedError {
    case posix(Int32, path: String)
    case unsupportedScheme(String)
    case notADirectory(String)

    public var errorDescription: String? {
        switch self {
        case .posix(let code, let path):
            let reason = String(cString: strerror(code))
            switch code {
            case EACCES, EPERM: return "You don't have permission to open “\((path as NSString).lastPathComponent)”. (\(reason))"
            case ENOENT: return "“\((path as NSString).lastPathComponent)” doesn't exist."
            default: return "\(reason) (\(path))"
            }
        case .unsupportedScheme(let s): return "Unsupported location type “\(s)”."
        case .notADirectory(let p): return "“\((p as NSString).lastPathComponent)” is not a folder."
        }
    }

    public var isPermissionDenied: Bool {
        if case .posix(let code, _) = self { return code == EACCES || code == EPERM }
        return false
    }
}

/// A place files come from. `LocalFileSource` today; network sources implement the same protocol.
public protocol FileSource: Sendable {
    var scheme: String { get }
    var capabilities: SourceCapabilities { get }

    /// Streams the folder's entries in batches (small first batch for a fast first paint).
    func list(_ location: Location) -> AsyncThrowingStream<[FileItem], any Error>

    /// One entry, without following symlinks.
    func item(atPath path: String) async throws -> FileItem

    /// Live changes to the folder's direct children.
    func watch(_ location: Location) -> AsyncStream<WatchEvent>
}

/// Resolves a location's scheme to its source.
public struct SourceRegistry: Sendable {
    private var sources: [String: any FileSource]

    public init(_ sources: [any FileSource]) {
        var map: [String: any FileSource] = [:]
        for s in sources { map[s.scheme] = s }
        self.sources = map
    }

    public func source(for location: Location) throws -> any FileSource {
        guard let s = sources[location.scheme] else { throw FileSourceError.unsupportedScheme(location.scheme) }
        return s
    }
}
