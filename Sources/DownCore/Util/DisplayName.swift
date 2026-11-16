import Foundation

/// Makes file names safe to display: control characters and bidi overrides become visible escapes,
/// so `‮gnp.exe` can't masquerade as `exe.png`.
public enum DisplayName {
    private static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F,                  // LRM, RLM
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,  // LRE, RLE, PDF, LRO, RLO
        0x2066, 0x2067, 0x2068, 0x2069,  // LRI, RLI, FSI, PDI
        0x061C,                          // ALM
    ]

    public static func needsSanitizing(_ name: String) -> Bool {
        name.unicodeScalars.contains { isSuspicious($0) }
    }

    public static func sanitize(_ name: String) -> String {
        guard needsSanitizing(name) else { return name }
        var out = String.UnicodeScalarView()
        for s in name.unicodeScalars {
            if isSuspicious(s) {
                out.append(contentsOf: String(format: "\\u{%X}", s.value).unicodeScalars)
            } else {
                out.append(s)
            }
        }
        return String(out)
    }

    private static func isSuspicious(_ s: Unicode.Scalar) -> Bool {
        s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value) || bidiControls.contains(s.value)
    }
}

public enum ByteFormat {
    private static let style = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                                    includesActualByteCount: false)
    public static func string(_ bytes: Int64) -> String { bytes.formatted(style) }
}
