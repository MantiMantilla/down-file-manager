import Foundation

public enum SortField: String, Codable, Sendable, CaseIterable {
    case name, size, modified, kind
}

public struct FileSortOrder: Codable, Hashable, Sendable {
    public var field: SortField
    public var ascending: Bool
    public var foldersFirst: Bool

    public init(field: SortField = .name, ascending: Bool = true, foldersFirst: Bool = true) {
        self.field = field
        self.ascending = ascending
        self.foldersFirst = foldersFirst
    }
}

/// Natural-order collation keys, computed once per item so sorting is a byte comparison.
///
/// Rules: case- and diacritic-insensitive; runs of digits compare numerically
/// (`file2` < `file10`), encoded as a length byte followed by the digits without leading zeros.
public enum SortKey {
    public static func make(_ name: String) -> [UInt8] {
        let source: String.UTF8View
        let folded: String
        if name.utf8.allSatisfy({ $0 < 0x80 }) {
            folded = name
        } else {
            folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }
        source = folded.utf8

        var key: [UInt8] = []
        key.reserveCapacity(source.count + 4)
        var digits: [UInt8] = []

        func flushDigits() {
            guard !digits.isEmpty else { return }
            var start = 0
            while start < digits.count - 1, digits[start] == 0x30 { start += 1 }  // strip leading zeros
            let significant = digits[start...]
            key.append(0x30 &+ UInt8(min(significant.count, 0x4F)))
            key.append(contentsOf: significant)
            digits.removeAll(keepingCapacity: true)
        }

        for b in source {
            if b >= 0x30 && b <= 0x39 {
                digits.append(b)
            } else {
                flushDigits()
                // ASCII lowercase (non-ASCII was already folded above).
                key.append(b >= 0x41 && b <= 0x5A ? b + 0x20 : b)
            }
        }
        flushDigits()
        return key
    }

    @inline(__always)
    public static func compare(_ a: [UInt8], _ b: [UInt8]) -> Int {
        a.withUnsafeBufferPointer { pa in
            b.withUnsafeBufferPointer { pb in
                let n = min(pa.count, pb.count)
                let r = n == 0 ? 0 : memcmp(pa.baseAddress!, pb.baseAddress!, n)
                if r != 0 { return Int(r) }
                return pa.count - pb.count
            }
        }
    }
}

public enum Sorter {
    public static func sorted(_ items: [FileItem], by order: FileSortOrder) -> [FileItem] {
        // Precompute kind descriptions once for kind sort.
        var kinds: [String: String] = [:]
        if order.field == .kind {
            for item in items where kinds[item.path] == nil {
                kinds[item.path] = TypeCache.kindDescription(for: item)
            }
        }
        return items.sorted { a, b in
            if order.foldersFirst {
                let fa = a.isFolderLike, fb = b.isFolderLike
                if fa != fb { return fa }
            }
            var c: Int
            switch order.field {
            case .name:
                c = 0
            case .size:
                // Folders have no meaningful byte size; compare entry counts instead.
                if a.isFolderLike && b.isFolderLike {
                    c = (a.entryCount ?? 0) < (b.entryCount ?? 0) ? -1 : ((a.entryCount ?? 0) > (b.entryCount ?? 0) ? 1 : 0)
                } else {
                    c = a.size < b.size ? -1 : (a.size > b.size ? 1 : 0)
                }
            case .modified:
                c = a.modified < b.modified ? -1 : (a.modified > b.modified ? 1 : 0)
            case .kind:
                c = (kinds[a.path] ?? "").localizedStandardCompare(kinds[b.path] ?? "").rawValue
            }
            if c == 0 { c = SortKey.compare(a.sortKey, b.sortKey) }
            if c == 0 { c = a.name < b.name ? -1 : (a.name > b.name ? 1 : 0) }
            return order.ascending ? c < 0 : c > 0
        }
    }
}
