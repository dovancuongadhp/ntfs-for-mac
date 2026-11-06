import Foundation
import Testing

/// Every sentence the File Transfer screens show must have a Vietnamese translation. This reads the source
/// files and the string catalog as text, so a new English string with no `vi` entry fails here rather than
/// showing up untranslated.
struct TransferLocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    /// Source files whose string literals are all expected to be user-facing (or listed in `notUserFacing`).
    private static let scannedFiles: [String] = {
        let transfer = root.appending(path: "App/Transfer", directoryHint: .isDirectory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: transfer.path)) ?? []
        return names.filter { $0.hasSuffix(".swift") }.sorted().map { "App/Transfer/\($0)" }
            + [
                "App/NTFSForMacApp.swift", "App/Views/MenuContentView.swift",
                "App/Views/Main/SidebarView.swift", "App/Views/Main/MainWindowView.swift",
                "App/Views/Main/Components.swift",
            ]
    }()

    /// Literals that are file names, settings keys, reasons for the system or other text nobody reads as a sentence.
    private static let notUserFacing: Set<String> = [
        "TransferVerify", "TransferAskOnError", "TransferPreventSleep",
        "TransferProgressCollapsed", "TransferLog.json",
        "XCTestConfigurationFilePath", "zZ",
        // The app's name and a speed such as "12 MB/s" read the same in every language.
        "NTFS for Mac", "%@/s",
    ]

    private struct Entry {
        let state: String?
        let value: String?
    }

    /// The catalog's keys and their Vietnamese text.
    private static func catalog() throws -> [String: Entry] {
        let data = try Data(contentsOf: root.appending(path: "App/Localizable.xcstrings"))
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(json["strings"] as? [String: [String: Any]])
        return strings.mapValues { item in
            let localizations = item["localizations"] as? [String: Any]
            let vi = localizations?["vi"] as? [String: Any]
            let unit = vi?["stringUnit"] as? [String: Any]
            return Entry(state: unit?["state"] as? String, value: unit?["value"] as? String)
        }
    }

    /// `%1$@`, `%lld` and `%@` all become `%@`, so a key from the catalog and a literal from the source compare equal.
    private static func normalized(_ text: String) -> String {
        text.replacing(/%(\d+\$)?(@|lld|ld|d|f)/, with: "%@")
    }

    /// One placeholder: where its argument sits (1-based) and what kind of value it takes.
    struct Placeholder: Equatable, Comparable {
        let position: Int
        /// `@` for text, `d` for whole numbers (`%d`, `%ld`, `%lld`), `f` for fractions.
        let kind: Character

        static func < (a: Placeholder, b: Placeholder) -> Bool { a.position < b.position }
    }

    /// The placeholders of `text` by argument position: `%1$@` is the first argument whatever its place in
    /// the sentence, and a plain `%@` is the next argument in order.
    static func placeholders(_ text: String) -> [Placeholder] {
        var next = 1
        return text.matches(of: /%(?:(\d+)\$)?(@|lld|ld|d|f)/).map { match in
            let position: Int
            if let explicit = match.output.1, let number = Int(explicit) {
                position = number
            } else {
                position = next
                next += 1
            }
            let kind: Character = match.output.2 == "@" ? "@" : match.output.2 == "f" ? "f" : "d"
            return Placeholder(position: position, kind: kind)
        }.sorted()
    }

    @Test func theCatalogIsValidAndEveryVietnameseEntryIsTranslated() throws {
        let catalog = try Self.catalog()
        #expect(!catalog.isEmpty)
        for (key, entry) in catalog where entry.value != nil {
            #expect(entry.state == "translated", "“\(key)” is not marked translated")
            #expect(entry.value?.isEmpty == false, "“\(key)” has an empty translation")
        }
    }

    @Test func placeholdersAreComparedByArgumentPositionAndKind() {
        // A translation may move an argument, but it must still be the same argument of the same kind.
        #expect(Self.placeholders("%@ of %@") == Self.placeholders("%1$@ / %2$@"))
        #expect(Self.placeholders("%1$@ and %2$@") == Self.placeholders("%2$@ và %1$@"))
        #expect(Self.placeholders("%lld of %lld") == Self.placeholders("%1$lld / %2$lld"))
        #expect(Self.placeholders("%lld files") == Self.placeholders("%ld tệp"))
        #expect(Self.placeholders("%lld files") != Self.placeholders("%@ tệp"))
        #expect(Self.placeholders("%@ then %lld") != Self.placeholders("%1$lld rồi %2$@"))
        #expect(Self.placeholders("%@ then %@") != Self.placeholders("%1$@ rồi %1$@"))
        #expect(Self.placeholders("%@") != Self.placeholders("không có"))
    }

    @Test func translationsKeepTheirPlaceholders() throws {
        for (key, entry) in try Self.catalog() {
            guard let value = entry.value else { continue }
            #expect(Self.placeholders(key) == Self.placeholders(value), "Placeholders differ in “\(key)”")
        }
    }

    @Test func everyTransferStringHasAVietnameseTranslation() throws {
        let known = Set(try Self.catalog().filter { $0.value.value != nil }.keys.map(Self.normalized))
        var missing: [String] = []
        for file in Self.scannedFiles {
            let source = try String(contentsOf: Self.root.appending(path: file), encoding: .utf8)
            for literal in Self.literals(in: source) {
                let text = Self.normalized(literal)
                guard Self.looksLikeText(text), !Self.notUserFacing.contains(literal), !known.contains(text) else { continue }
                missing.append("\(file): “\(literal)”")
            }
        }
        #expect(missing.isEmpty, "No Vietnamese translation for:\n\(missing.joined(separator: "\n"))")
    }

    @Test func theLiteralScannerFindsStringsAndSkipsComments() {
        let source = """
            // "in a comment"
            let a = "plain" // "trailing"
            let b = "Files: \\(items.map { "x" }.joined(separator: ", ")) done"
            Text("Quote \\" inside")
            """
        #expect(Self.literals(in: source) == ["plain", "Files: %@ done", "Quote \" inside"])
    }

    /// Whether a literal contains words: not an empty string, a bare placeholder, a path or a symbol name.
    private static func looksLikeText(_ text: String) -> Bool {
        if text.hasPrefix("/") { return false }
        let letters = text.replacing("%@", with: "").filter(\.isLetter)
        if letters.isEmpty { return false }
        // SF Symbol names, identifiers and key paths: lowercase, no spaces.
        return text.range(of: #"^[a-z0-9._]+$"#, options: .regularExpression) == nil
    }

    /// The text of every string literal in `source`, with each interpolation replaced by `%@`.
    private static func literals(in source: String) -> [String] {
        let chars = Array(source)
        var found: [String] = []
        var index = 0
        while index < chars.count {
            if chars[index] == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                while index < chars.count, chars[index] != "\n" { index += 1 }
            } else if chars[index] == "\"" {
                index += 1
                found.append(readString(chars, &index))
            } else {
                index += 1
            }
        }
        return found
    }

    /// Reads a literal whose opening quote has been consumed, up to and including the closing quote.
    private static func readString(_ chars: [Character], _ index: inout Int) -> String {
        var text = ""
        while index < chars.count {
            let char = chars[index]
            index += 1
            if char == "\"" { break }
            guard char == "\\", index < chars.count else {
                text.append(char)
                continue
            }
            let next = chars[index]
            index += 1
            switch next {
            case "(":
                skipInterpolation(chars, &index)
                text += "%@"
            case "n": text.append("\n")
            case "t": text.append("\t")
            default: text.append(next)
            }
        }
        return text
    }

    /// Skips an interpolation whose `\(` has been consumed, including strings nested in it.
    private static func skipInterpolation(_ chars: [Character], _ index: inout Int) {
        var depth = 1
        while index < chars.count, depth > 0 {
            let char = chars[index]
            index += 1
            switch char {
            case "(": depth += 1
            case ")": depth -= 1
            case "\"": _ = readString(chars, &index)
            default: break
            }
        }
    }
}
