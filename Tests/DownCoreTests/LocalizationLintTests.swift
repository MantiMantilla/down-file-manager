import Foundation
import Testing

/// Static checks that keep user-facing text going through the String Catalogs. They read the sources
/// (no build, no dependencies), so they are a backstop for the usual mistakes, not a proof that every
/// string is localized. `make l10n-check` keeps the catalogs in step with the code.
enum LocalizationLint {
    struct Finding: CustomStringConvertible {
        let file: String
        let line: Int
        let rule: String
        let text: String
        var description: String { "\(file):\(line): \(rule): \(text)" }
    }

    /// Modules whose strings belong in their own Localizable.xcstrings.
    static let modules = ["DownCore", "DownUI"]

    /// Developer tools whose text stays in English.
    static let exemptPaths = ["Sources/DownUI/DebugConsole/", "Sources/DownUI/ViewModels/DebugConsoleViewModel.swift"]

    /// A line ending in this comment is skipped (for the rare literal that must not be translated).
    static let optOut = "l10n-ignore"

    /// Calls that look up a localized string.
    private static let localizedCalls = ["String(localized:", "AttributedString(localized:", "LocalizedStringResource(",
                                         "NSLocalizedString("]

    /// Assignments whose whole right-hand side is display text.
    private static var propertySink: Regex<(Substring, Substring)> {
        #/\.(title|label|paletteLabel|toolTip|placeholderString|messageText|informativeText|stringValue)\s*=/#
    }

    /// Calls that take display text as a literal argument.
    private static var argumentSink: Regex<(Substring, Substring, Substring?, Substring?, Substring?)> {
        #/(\b(withTitle|title|checkboxWithTitle|labelWithString|wrappingLabelWithString|accessibilityDescription|labels):\s*\[?\s*|\b(Text|Label|Toggle|Button|Picker|Section|LabeledContent|Menu|Link)\(\s*|\.(help|accessibilityLabel|navigationTitle)\(\s*)"/#
    }

    static func check(source: String, file: String) -> [Finding] {
        let lines = source.components(separatedBy: "\n")
        let propertySink = propertySink, argumentSink = argumentSink
        var findings: [Finding] = []

        for (index, raw) in lines.enumerated() where raw.contains("\"") || raw.contains("(localized:") {
            if raw.hasSuffix(optOut) || isComment(raw) { continue }
            let line = stripComment(raw)
            let calls = localizedCalls.filter { line.contains($0) }

            // Rule 1: a localized call must name its bundle. Without `bundle:` it reads Bundle.main, which
            // shows the English key today and stays untranslated forever.
            for call in calls {
                var searchStart = line.startIndex
                while let range = line.range(of: call, range: searchStart..<line.endIndex) {
                    searchStart = range.upperBound
                    let text = balancedCall(lines, line: index, from: line.distance(from: line.startIndex, to: range.lowerBound))
                    // Generated catalog symbols (String(localized: .someKey)) carry their bundle.
                    if !text.contains("bundle:") && !text.hasPrefix("(localized: .") {
                        findings.append(Finding(file: file, line: index + 1, rule: "localized string without bundle: .module",
                                                text: raw.trimmingCharacters(in: .whitespaces)))
                    }
                }
            }

            // Rule 2: no prose literal handed straight to a UI text sink.
            guard calls.isEmpty, line.contains("\"") else { continue }
            var literals: [String] = []
            if let sink = line.firstMatch(of: propertySink) {
                literals = stringLiterals(in: String(line[sink.range.upperBound...]))
            } else {
                for sink in line.matches(of: argumentSink) {
                    let quote = line.index(before: sink.range.upperBound)
                    literals += stringLiterals(in: String(line[quote...])).prefix(1)
                }
            }
            if literals.contains(where: isProse) {
                findings.append(Finding(file: file, line: index + 1, rule: "user-facing literal bypasses the catalog",
                                        text: raw.trimmingCharacters(in: .whitespaces)))
            }
        }
        return findings
    }

    static func checkRepository() throws -> [Finding] {
        var findings: [Finding] = []
        for module in modules {
            let dir = repositoryRoot.appending(path: "Sources/\(module)")
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            #expect(!files.isEmpty, "no sources found in \(dir.path)")
            for url in files {
                let relative = String(url.path.dropFirst(repositoryRoot.path.count)).trimmingPrefix("/")
                if exemptPaths.contains(where: { relative.hasPrefix($0) }) { continue }
                findings += check(source: try String(contentsOf: url, encoding: .utf8), file: String(relative))
            }
        }
        return findings
    }

    // MARK: - Lexing helpers (good enough for this codebase's style, not a Swift parser)

    private static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// The line without a trailing `//` comment (outside string literals).
    static func stripComment(_ line: String) -> String {
        var inString = false, previous: Character = " ", out = ""
        let chars = Array(line)
        for (i, c) in chars.enumerated() {
            if c == "\"" && previous != "\\" { inString.toggle() }
            if !inString && c == "/" && i + 1 < chars.count && chars[i + 1] == "/" { break }
            out.append(c)
            previous = c
        }
        return out
    }

    /// The call starting at character `column` of line `line`: from its first "(" to the matching ")",
    /// across lines, skipping string literals.
    private static func balancedCall(_ lines: [String], line: Int, from column: Int) -> String {
        var out = "", depth = 0, inString = false, started = false
        for (n, text) in lines[line...].prefix(20).enumerated() {
            var previous: Character = " "
            for c in (n == 0 ? Array(text.dropFirst(column)) : Array(text)) {
                if !started { if c == "(" { started = true } else { continue } }
                out.append(c)
                if c == "\"" && previous != "\\" { inString.toggle() }
                if !inString {
                    if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { return out } }
                }
                previous = c
            }
            out.append("\n")
        }
        return out
    }

    /// Contents of the string literals in `text`, with interpolations removed.
    static func stringLiterals(in text: String) -> [String] {
        var literals: [String] = [], current = "", inString = false, depth = 0
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inString {
                if depth > 0 {
                    if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                } else if c == "\\" && i + 1 < chars.count && chars[i + 1] == "(" {
                    depth = 1; i += 1
                } else if c == "\\" {
                    i += 1
                } else if c == "\"" {
                    literals.append(current); current = ""; inString = false
                } else {
                    current.append(c)
                }
            } else if c == "\"" {
                inString = true
            }
            i += 1
        }
        return literals
    }

    /// Text a person reads: it has letters (symbols, numbers and empty strings don't count).
    static func isProse(_ literal: String) -> Bool {
        literal.contains { $0.isLetter }
    }
}

@Suite("Localization lint")
struct LocalizationLintTests {
    @Test func userFacingStringsGoThroughTheCatalogs() throws {
        let findings = try LocalizationLint.checkRepository()
        #expect(findings.isEmpty, """
            Use String(localized: "…", bundle: .module, comment: "where it appears"); \
            see README → Localization. End the line with // l10n-ignore if the text must not be translated.
            \(findings.map(\.description).joined(separator: "\n"))
            """)
    }

    // The checker itself.

    @Test(arguments: [
        #"menu.addItem(withTitle: "Open in New Tab", action: #selector(x), keyEquivalent: "")"#,
        #"alert.messageText = "Couldn't eject""#,
        #"alert.messageText = n == 1 ? "One" : "\(n) items""#,
        #"item.toolTip = "Search""#,
        #"NSImage(systemSymbolName: "eject.fill", accessibilityDescription: "Eject")"#,
        #"labels: ["Back", "Forward"], target: self"#,
        #"Text("General")"#,
        #"Toggle("Show hidden files", isOn: $on)"#,
        #".help("Reload")"#,
        #"let s = String(localized: "Folder")"#,
        #"let r = LocalizedStringResource("Folder", comment: "Kind column")"#,
    ])
    func flags(_ source: String) {
        #expect(!LocalizationLint.check(source: source, file: "x.swift").isEmpty)
    }

    @Test(arguments: [
        #"menu.addItem(withTitle: String(localized: "Open in New Tab", bundle: .module, comment: "Sidebar context menu"), action: #selector(x), keyEquivalent: "")"#,
        "let s = String(localized: \"Folder\",\n                bundle: .module, comment: \"Kind column\")",
        #"Text(verbatim: "Ghostty")"#,
        #"Segment(title: "", image: nil, location: .root)"#,
        #"countLabel.stringValue = "\(visible) / \(total)""#,
        #"item.title = "—""#,
        #"window.setFrameAutosaveName("DownBrowser")"#,
        #"log.info("ejected \(path: path)")"#,
        #"// alert.messageText = "Old text""#,
        #"item.label = "Raw"  // l10n-ignore"#,
        #"let s = String(localized: .kindFolder)"#,
    ])
    func allows(_ source: String) {
        #expect(LocalizationLint.check(source: source, file: "x.swift").isEmpty)
    }
}
