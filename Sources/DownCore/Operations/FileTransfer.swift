import Foundation

public enum TransferOperation: String, Sendable, Codable {
    case copy, move, link
}

/// What a drop should do, decided Finder-style from the drag's modifier mask and volumes.
public enum DropPolicy {
    /// - Parameters:
    ///   - allowsCopy/Move/Link: what the drag source permits (after modifiers are applied by AppKit).
    ///   - onlyCopyRequested: the user is holding ⌥ (source mask reduced to copy).
    ///   - sameVolume: source and destination are on the same volume.
    public static func operation(allowsCopy: Bool, allowsMove: Bool, allowsLink: Bool,
                                 onlyLinkRequested: Bool, onlyCopyRequested: Bool, onlyMoveRequested: Bool,
                                 sameVolume: Bool) -> TransferOperation? {
        if onlyLinkRequested { return allowsLink ? .link : nil }
        if onlyCopyRequested { return allowsCopy ? .copy : nil }
        if onlyMoveRequested { return allowsMove ? .move : nil }
        if sameVolume && allowsMove { return .move }
        if allowsCopy { return .copy }
        if allowsMove { return .move }
        return nil
    }

    /// Dropping a folder into itself or its own descendant, or an item onto the folder it's already in (move).
    public static func isNoOp(sources: [String], destination: String, operation: TransferOperation) -> Bool {
        let dest = Location.file(destination).path
        for s in sources {
            let src = Location.file(s).path
            if dest == src || dest.hasPrefix(src + "/") { return true }   // into itself
            if operation == .move && (src as NSString).deletingLastPathComponent == dest { return true }
        }
        return false
    }
}

/// Minimal copy/move used by drops and paste until the full operation queue (conflicts,
/// progress, undo) lands. Never overwrites: conflicting names get a " (2)" suffix.
public enum FileTransfer {
    public struct Result: Sendable {
        public var created: [String] = []
        public var failures: [(path: String, message: String)] = []
    }

    public static func perform(_ op: TransferOperation, sources: [String], into destination: String,
                               log: Logger, actionID: ActionID? = nil) -> Result {
        var result = Result()
        for src in sources {
            let name = (src as NSString).lastPathComponent
            let target = uniqueDestination(for: name, in: destination)
            do {
                switch op {
                case .copy:
                    try copy(src, to: target)
                case .move:
                    if rename(src, target) != 0 {
                        if errno == EXDEV {
                            try copy(src, to: target)
                            try FileManager.default.removeItem(atPath: src)
                        } else {
                            throw FileSourceError.posix(errno, path: src)
                        }
                    }
                case .link:
                    try FileManager.default.createSymbolicLink(atPath: target, withDestinationPath: src)
                }
                result.created.append(target)
                log.info("\(op.rawValue) \(path: src) → \(path: target)", actionID: actionID)
            } catch {
                result.failures.append((src, error.localizedDescription))
                log.error("\(op.rawValue) failed for \(path: src): \(error.localizedDescription)", actionID: actionID)
            }
        }
        return result
    }

    /// copyfile(3): clones on APFS (instant, no extra space), preserves xattrs/ACLs/quarantine, never follows symlinks.
    static func copy(_ src: String, to dst: String) throws {
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW | COPYFILE_EXCL)
        if copyfile(src, dst, nil, flags) != 0 {
            throw FileSourceError.posix(errno, path: src)
        }
    }

    /// `report.pdf` → `report (2).pdf`, `report (3).pdf`, …; folders and dotfiles handled.
    public static func uniqueDestination(for name: String, in directory: String,
                                         exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String {
        let dir = directory == "/" ? "" : directory
        let first = dir + "/" + name
        guard exists(first) else { return first }
        let (base, ext) = splitName(name)
        var n = 2
        while true {
            let candidate = dir + "/" + base + " (\(n))" + (ext.isEmpty ? "" : "." + ext)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    static func splitName(_ name: String) -> (String, String) {
        // Dotfiles without another dot (".bashrc") have no extension; "archive.tar.gz" keeps "gz".
        let ns = name as NSString
        let ext = ns.pathExtension
        if ext.isEmpty || name.hasPrefix(".") && !name.dropFirst().contains(".") { return (name, "") }
        var base = ns.deletingPathExtension
        // Strip an existing " (N)" so copies of copies don't become "a (2) (2)".
        if let range = base.range(of: #" \(\d+\)$"#, options: .regularExpression) { base.removeSubrange(range) }
        return (base, ext)
    }
}
