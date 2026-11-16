import Foundation
import Testing

/// Static checks that keep user-facing text going through the String Catalogs. They read the sources
/// (no build, no dependencies), so they are a backstop for the usual mistakes, not a proof that every
/// string is localized. `make l10n-check` keeps the catalogs in step with the code.
///
/// Known limits: they work line by line, so a sink and its literal must start on the same line (a
/// multi-line `"""` literal that opens there is followed to its end), and literals passed to other
/// functions (`addColumn(_, "Name")`) or returned from model code aren't seen.
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

    static func isOptedOut(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasSuffix(optOut)
    }

    /// Calls that look up a localized string.
    private static let localizedCalls = ["String(localized:", "AttributedString(localized:", "LocalizedStringResource(",
                                         "NSLocalizedString("]

    /// Display-text assignments and arrays: every literal after them on the line is display text.
    private static var restOfLineSink: Regex<(Substring, Substring, Substring?)> {
        #/(\.(title|label|paletteLabel|toolTip|placeholderString|messageText|informativeText|stringValue)\s*=|\blabels:\s*\[)/#
    }

    /// Calls that take display text as a literal argument.
    private static var argumentSink: Regex<(Substring, Substring, Substring?, Substring?, Substring?)> {
        #/(\b(withTitle|title|checkboxWithTitle|labelWithString|wrappingLabelWithString|accessibilityDescription):\s*|\b(Text|Label|Toggle|Button|Picker|Section|LabeledContent|Menu|Link)\(\s*|\.(help|accessibilityLabel|navigationTitle)\(\s*)"/#
    }

    static func check(source: String, file: String) -> [Finding] {
        let lines = source.components(separatedBy: "\n")
        let restOfLineSink = restOfLineSink, argumentSink = argumentSink
        var findings: [Finding] = []

        for (index, raw) in lines.enumerated() where raw.contains("\"") || raw.contains("(localized:") {
            if isOptedOut(raw) || isComment(raw) { continue }
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

            // Rule 2: no prose literal handed straight to a UI text sink. Localized calls are blanked out
            // first, so `[String(localized: "List", …), "Grid"]` still has "Grid" checked.
            let open = calls.isEmpty ? line : blankingLocalizedCalls(in: line)
            guard open.contains("\"") else { continue }
            var literals: [String] = []
            if let sink = open.firstMatch(of: restOfLineSink) {
                let rest = String(open[sink.range.upperBound...])
                literals = stringLiterals(in: rest)
                if rest.contains("\"\"\"") { literals.append(multilineLiteral(lines, after: index)) }
            } else {
                for sink in open.matches(of: argumentSink) {
                    let rest = open[open.index(before: sink.range.upperBound)...]
                    if rest.hasPrefix("\"\"\"") {
                        literals.append(multilineLiteral(lines, after: index))
                    } else {
                        literals += stringLiterals(in: String(rest)).prefix(1)
                    }
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
            // Relative to the module folder, with symlinks resolved on both sides: under xcodebuild,
            // #filePath and the enumerator can disagree about /tmp vs /private/tmp.
            let base = dir.resolvingSymlinksInPath().path
            for url in files {
                let relative = "Sources/\(module)" + url.resolvingSymlinksInPath().path.dropFirst(base.count)
                if exemptPaths.contains(where: { relative.hasPrefix($0) }) { continue }
                findings += check(source: try String(contentsOf: url, encoding: .utf8), file: relative)
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

    /// `line` with each localized call (from its name to the matching ")", or to the end of the line if
    /// it continues) replaced by spaces.
    static func blankingLocalizedCalls(in line: String) -> String {
        var chars = Array(line)
        let text = String(chars)
        for call in localizedCalls {
            var searchStart = text.startIndex
            while let range = text.range(of: call, range: searchStart..<text.endIndex) {
                searchStart = range.upperBound
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                var i = start + call.distance(from: call.startIndex, to: call.firstIndex(of: "(")!)
                var depth = 0, inString = false
                while i < chars.count {
                    let c = chars[i]
                    if c == "\"" && chars[i - 1] != "\\" { inString.toggle() }
                    if !inString {
                        if c == "(" { depth += 1 } else if c == ")" { depth -= 1; if depth == 0 { break } }
                    }
                    i += 1
                }
                for j in start...min(i, chars.count - 1) { chars[j] = " " }
            }
        }
        return String(chars)
    }

    /// The contents of a `"""` literal that opens on line `index`, up to its closing `"""`.
    static func multilineLiteral(_ lines: [String], after index: Int) -> String {
        lines[(index + 1)...].prefix { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("\"\"\"") }.joined(separator: "\n")
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
        #"labels: [String(localized: "List", bundle: .module, comment: "Toolbar"), "Grid"], target: self"#,
        #"alert.messageText = flag ? String(localized: "One", bundle: .module, comment: "Alert title") : "Several""#,
        #"Text(String(localized: "A", bundle: .module, comment: "Title")); item.toolTip = "Raw tooltip""#,
        "alert.informativeText = \"\"\"\n    Several lines of prose\n    \"\"\"",
        "Text(\"\"\"\n    Several lines of prose\n    \"\"\")",
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
        "item.label = \"Raw\"  // l10n-ignore   ",
        #"labels: [list, grid, columns], target: self"#,
        "alert.informativeText = String(localized: \"\"\"\n    Several lines of prose\n    \"\"\", bundle: .module, comment: \"Alert\")",
        "Text(verbatim: \"\"\"\n    Not translated\n    \"\"\")",
    ])
    func allows(_ source: String) {
        #expect(LocalizationLint.check(source: source, file: "x.swift").isEmpty)
    }
}
