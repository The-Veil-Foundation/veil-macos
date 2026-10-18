import XCTest
@testable import XrayClient

/// Guards against the failure mode where a screen ends up half-translated:
/// `Loc` falls back to the English key when a string is missing, so an
/// untranslated entry is invisible in development and only shows up as mixed
/// language to a user running the app in their own locale.
///
/// These tests read the sources rather than the built product, so they cover
/// the iOS targets too even though the test bundle itself is macOS.
/// `Loc` is main-actor isolated, and so is its table.
@MainActor
final class LocalizationTests: XCTestCase {

    /// Every language the table claims to support.
    private static let languages: Set<String> = [
        "ru", "zh", "es", "hi", "ar", "fr", "pt", "de", "ja", "id", "tr"
    ]

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // XrayClientTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repo root

    /// Directories whose `loc("…")` calls must all resolve.
    private static let uiDirectories = [
        "Sources/XrayClient/Views",
    ]

    func testEveryKeyHasEveryLanguage() {
        for (key, translations) in Loc.table {
            let missing = Self.languages.subtracting(translations.keys)
            XCTAssertTrue(missing.isEmpty,
                          "\"\(key)\" is missing: \(missing.sorted().joined(separator: ", "))")
            for (language, text) in translations {
                XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\"\(key)\" has an empty \(language) translation")
            }
        }
    }

    func testNoUnsupportedLanguageCodesSlippedIn() {
        for (key, translations) in Loc.table {
            let extra = Set(translations.keys).subtracting(Self.languages)
            XCTAssertTrue(extra.isEmpty,
                          "\"\(key)\" has unknown language(s): \(extra.sorted().joined(separator: ", "))")
        }
    }

    /// Any string the UI passes through `loc(…)` must exist in the table,
    /// otherwise it silently renders in English.
    func testEveryStringUsedByTheUIIsTranslated() throws {
        let keys = Set(Loc.table.keys)
        var used: Set<String> = []

        for directory in Self.uiDirectories {
            let url = Self.repoRoot.appendingPathComponent(directory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                XCTFail("UI directory not found: \(directory)")
                continue
            }
            used.formUnion(try Self.locCalls(in: url))
        }

        XCTAssertFalse(used.isEmpty, "found no loc(…) calls — did the scan break?")

        let untranslated = used.subtracting(keys).sorted()
        XCTAssertTrue(untranslated.isEmpty,
                      "not in LocalizationTable: \(untranslated.joined(separator: " | "))")
    }

    /// Extracts the literal arguments of every `loc("…")` call under `url`.
    private static func locCalls(in url: URL) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: #"loc\("((?:[^"\\]|\\.)*)"\)"#)
        var found: Set<String> = []

        let enumerator = FileManager.default.enumerator(at: url,
                                                        includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            guard file.pathExtension == "swift" else { continue }
            let source = try String(contentsOf: file, encoding: .utf8)
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let literal = Range(match.range(at: 1), in: source) else { continue }
                // Undo the Swift escaping so the key matches the table's.
                found.insert(String(source[literal])
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\"))
            }
        }
        return found
    }
}
