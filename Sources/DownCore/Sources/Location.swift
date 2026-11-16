import Foundation

/// Where a tab points. Local today (`file://`); other schemes (smb, sftp, s3) plug in through `FileSource`.
public struct Location: Hashable, Sendable, Codable, CustomStringConvertible {
    public let url: URL

    public init(url: URL) {
        if url.isFileURL {
            self.url = URL(filePath: Self.normalize(url.path(percentEncoded: false)), directoryHint: .isDirectory)
        } else {
            self.url = url
        }
    }

    public static func file(_ path: String) -> Location {
        Location(url: URL(filePath: path, directoryHint: .isDirectory))
    }

    public static var home: Location { .file(NSHomeDirectory()) }
    public static var root: Location { .file("/") }

    public var scheme: String { url.scheme ?? "file" }
    public var isLocal: Bool { url.isFileURL }

    /// POSIX path without a trailing slash (except for `/`).
    public var path: String { Self.normalize(url.path(percentEncoded: false)) }

    public var name: String {
        if path == "/" { return "/" }
        return (path as NSString).lastPathComponent
    }

    public var parent: Location? {
        guard path != "/" else { return nil }
        return .file((path as NSString).deletingLastPathComponent)
    }

    /// Root first: `/`, `/Users`, `/Users/me`, …
    public var ancestry: [Location] {
        var chain: [Location] = [self]
        var cur = self
        while let p = cur.parent { chain.append(p); cur = p }
        return chain.reversed()
    }

    public func appending(_ name: String) -> Location {
        .file(path == "/" ? "/" + name : path + "/" + name)
    }

    public var description: String { path }

    /// Collapses duplicate slashes, `.` and `..`, removes trailing slash.
    static func normalize(_ raw: String) -> String {
        var p = raw.isEmpty ? "/" : raw
        if !p.hasPrefix("/") { p = "/" + p }
        var parts: [Substring] = []
        for comp in p.split(separator: "/", omittingEmptySubsequences: true) {
            if comp == "." { continue }
            if comp == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(comp)
        }
        return "/" + parts.joined(separator: "/")
    }
}

/// Parses what the user types in the location entry: `~/src`, `/tmp/../var`, `file:///x`, `..`.
public enum PathInput {
    public static func resolve(_ text: String, relativeTo base: Location, home: String = NSHomeDirectory()) -> Location? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("file://"), let url = URL(string: s), url.isFileURL {
            return Location(url: url)
        }
        if s == "~" { s = home } else if s.hasPrefix("~/") { s = home + s.dropFirst(1) }
        if !s.hasPrefix("/") { s = base.path + "/" + s }
        return .file(s)
    }

    /// Splits typed text into (directory to list, prefix to complete). `~/Doc` → (`~`, `Doc`).
    public static func completionParts(_ text: String) -> (directory: String, prefix: String) {
        guard let slash = text.lastIndex(of: "/") else { return ("", text) }
        let dir = String(text[...slash])
        let prefix = String(text[text.index(after: slash)...])
        return (dir, prefix)
    }

    /// Longest common prefix (case-insensitive match, case taken from the first candidate).
    public static func commonPrefix(_ names: [String]) -> String {
        guard var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            var end = prefix.startIndex
            var other = name.startIndex
            while end < prefix.endIndex, other < name.endIndex,
                  prefix[end].lowercased() == name[other].lowercased() {
                end = prefix.index(after: end)
                other = name.index(after: other)
            }
            prefix = String(prefix[..<end])
            if prefix.isEmpty { break }
        }
        return prefix
    }
}
