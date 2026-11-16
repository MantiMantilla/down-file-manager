import Foundation
import Testing

/// Repository root, from this file's location (Tests/DownCoreTests/…).
let repositoryRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The parts of an .xcstrings file these checks need.
struct StringCatalog {
    let url: URL
    let sourceLanguage: String
    let strings: [String: [String: Any]]

    init(_ relativePath: String) throws {
        url = repositoryRoot.appending(path: relativePath)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        sourceLanguage = try #require(json["sourceLanguage"] as? String)
        strings = try #require(json["strings"] as? [String: [String: Any]])
    }

    func englishValue(_ key: String) -> (value: String, state: String)? {
        let localizations = strings[key]?["localizations"] as? [String: Any]
        let unit = (localizations?["en"] as? [String: Any])?["stringUnit"] as? [String: Any]
        guard let value = unit?["value"] as? String, let state = unit?["state"] as? String else { return nil }
        return (value, state)
    }

    /// Every plural variation (including those in substitutions) under `node`.
    static func pluralVariations(in node: Any) -> [[String: Any]] {
        if let dict = node as? [String: Any] {
            let own = (dict["plural"] as? [String: Any]).map { [$0] } ?? []
            return own + dict.values.flatMap(pluralVariations(in:))
        }
        if let array = node as? [Any] { return array.flatMap(pluralVariations(in:)) }
        return []
    }
}

/// Structural checks on the String Catalogs. Whether they match the code is `make l10n-check`'s job.
@Suite("String Catalogs")
struct LocalizationCatalogTests {
    static let codeCatalogs = ["Sources/DownCore/Localizable.xcstrings", "Sources/DownUI/Localizable.xcstrings"]

    @Test(arguments: codeCatalogs + ["App/InfoPlist.xcstrings"])
    func catalogIsEnglishAndHasNoStaleEntries(path: String) throws {
        let catalog = try StringCatalog(path)
        #expect(catalog.sourceLanguage == "en")
        for (key, entry) in catalog.strings {
            #expect(entry["extractionState"] as? String != "stale", "\(path): \"\(key)\" is no longer used in code")
        }
    }

    /// Short strings are ambiguous out of context, so they must say where they appear.
    @Test(arguments: codeCatalogs)
    func shortKeysHaveComments(path: String) throws {
        let catalog = try StringCatalog(path)
        for (key, entry) in catalog.strings {
            let words = key.split(whereSeparator: \.isWhitespace).count
            guard words <= 3 else { continue }
            let comment = (entry["comment"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            #expect(!comment.isEmpty, "\(path): \"\(key)\" needs a comment: String(localized:…, comment: \"where it appears\")")
        }
    }

    /// Keys made only of placeholders and punctuation ("%@ (%@)") collide easily and tell translators
    /// nothing; such strings get a semantic key with `defaultValue:`.
    @Test(arguments: codeCatalogs + ["App/InfoPlist.xcstrings"])
    func keysHaveWordsOutsideFormatSpecifiers(path: String) throws {
        let catalog = try StringCatalog(path)
        let specifier = #/%(\d+\$)?(#@\w+@|[-+ #0']*\d*(\.\d+)?(hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfFeEgGcCsSpaA%])/#
        for key in catalog.strings.keys {
            let words = key.replacing(specifier, with: "")
            #expect(words.contains { $0.isLetter }, "\(path): \"\(key)\" has no words; give it a semantic key with defaultValue:")
        }
    }

    @Test(arguments: codeCatalogs)
    func pluralsDefineOther(path: String) throws {
        let catalog = try StringCatalog(path)
        for (key, entry) in catalog.strings {
            for plural in StringCatalog.pluralVariations(in: entry) {
                #expect(plural["other"] != nil, "\(path): plural for \"\(key)\" has no \"other\" case")
            }
        }
    }

    /// Info.plist keeps the English text (macOS reads the usage keys from there); the catalog must match it.
    @Test func infoPlistCatalogMatchesInfoPlist() throws {
        let catalog = try StringCatalog("App/InfoPlist.xcstrings")
        let data = try Data(contentsOf: repositoryRoot.appending(path: "Resources/Info.plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let usageKeys = plist.keys.filter { $0.hasSuffix("UsageDescription") }
        #expect(!usageKeys.isEmpty)
        #expect(Set(catalog.strings.keys) == Set(usageKeys))
        for key in usageKeys {
            let english = catalog.englishValue(key)
            #expect(english?.value == plist[key] as? String, "\(key) differs between Info.plist and InfoPlist.xcstrings")
            // Source-language entries in any other state ("new") aren't compiled into InfoPlist.strings.
            #expect(english?.state == "translated", "\(key) must be marked translated")
        }
    }
}
