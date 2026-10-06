import Foundation
import Testing

/// The global source sweep behind `UI-CONVENTIONS.md` §22 "Never" (UC-COLOR-03, UC-TYPE-01,
/// UC-GLASS-04, UC-GLOSS-02, UC-COPY-01/05): walks every `MLM/**/*.swift` file once, splits it
/// into code, comments and string literals with a small lexer, and checks the three kinds of text
/// separately. Failure messages list `file:line` for every hit.
///
/// Log lines are not UI copy: a literal inside an `AppLogger` call, an `NSLocalizedDescriptionKey`
/// entry or a `print` is exempt from the wording checks (never from the emoji check). Everything
/// else that is allowed to break a rule is in `allowList`, one exact `file:substring` pair with a
/// reason each.
@Suite("Source conventions (UC-§22)")
struct SourceConventionsTests {
    // MARK: Allow-list

    /// `file` (path below `MLM/`) and a substring of the offending literal (or code line).
    struct Allowed {
        let file: String
        let substring: String
        let reason: String
    }

    static let allowList: [Allowed] = [
        Allowed(file: "Services/Reels/ReelTextReader.swift", substring: "gefällt mir",
                reason: "Words the Reels OCR must recognise on German screenshots; never shown."),
        Allowed(file: "Services/Reels/ReelTextReader.swift", substring: "hinzufügen",
                reason: "Same list."),
        Allowed(file: "Services/Reels/ReelTextReader.swift", substring: "tonspur",
                reason: "Same list: German interface words filtered out of recognised text."),
        Allowed(file: "Views/Shared/TrackMetadataPresentation.swift", substring: "unknown album",
                reason: "The placeholder values the album column recognises and hides (UC-TABLE-11); data, never displayed."),
        Allowed(file: "Views/Shared/TrackMetadataPresentation.swift", substring: "soundcloud likes",
                reason: "Same placeholder list."),
        Allowed(file: "Services/Sources/SoundCloudClient.swift", substring: "soundcloud likes",
                reason: "Stored legacy album value recognised by the importer; not displayed."),
        Allowed(file: "Services/Sources/PlaylistImporter.swift", substring: "unknown album",
                reason: "Placeholder list the importer treats as no album."),
        Allowed(file: "Services/Sources/PlaylistImporter.swift", substring: "soundcloud likes",
                reason: "Same placeholder list."),
        Allowed(file: "Services/Import/MetadataExtractor.swift", substring: "unknown album",
                reason: "Stored fallback that the album column hides; changing it would alter stored data."),
        Allowed(file: "Services/Albums/SourceAlbumCleanup.swift", substring: "soundcloud likes",
                reason: "Source names the Clear Source Names job recognises in the Album field; data."),
        Allowed(file: "Services/Albums/SourceAlbumCleanup.swift", substring: "youtube likes",
                reason: "Same list."),
        Allowed(file: "ViewModels/DownloadViewModel.swift", substring: "Discovered Neighbors",
                reason: "Name of an existing folder inside users' libraries; renaming it would orphan their files. Never shown."),
        Allowed(file: "Services/Analysis/DuplicateDetectionService.swift", substring: "fingerprint_dedup",
                reason: "Persisted review_queue.action_type value (schema data), never displayed."),
        Allowed(file: "Database/AnalysisRepository.swift", substring: "fingerprint_dedup",
                reason: "Query on the persisted action_type value."),
    ]

    // MARK: Source files

    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct SourceFile {
        let path: String          // below MLM/
        let text: [Unicode.Scalar]
        let masked: [Unicode.Scalar]   // comments and literal contents blanked, quotes kept
        let literals: [Literal]
    }

    struct Literal {
        let line: Int
        let text: String          // content, interpolations replaced by U+FFFC
        let inLog: Bool
        let lineText: String
    }

    static let files: [SourceFile] = {
        let base = root.appendingPathComponent("MLM")
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { return [] }
        var result: [SourceFile] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let path = String(url.path.dropFirst(base.path.count + 1))
            result.append(lex(path: path, source: source))
        }
        return result.sorted { $0.path < $1.path }
    }()

    // MARK: Lexer

    static func lex(path: String, source: String) -> SourceFile {
        let s = Array(source.unicodeScalars)
        var masked = s
        var literals: [(start: Int, end: Int, content: String)] = []
        var i = 0

        func blank(_ range: Range<Int>) {
            for k in range where masked[k] != "\n" { masked[k] = " " }
        }

        /// Scans the literal whose opening quote is at `i`; returns the index after the closing quote.
        func scanString(_ open: Int) -> (end: Int, content: String) {
            var hashes = 0
            var p = open - 1
            while p >= 0, s[p] == "#" { hashes += 1; p -= 1 }
            let multiline = open + 2 < s.count && s[open + 1] == "\"" && s[open + 2] == "\""
            var k = open + (multiline ? 3 : 1)
            var content = String.UnicodeScalarView()
            func terminates(at k: Int) -> Int? {
                let quotes = multiline ? 3 : 1
                guard k + quotes + hashes <= s.count else { return nil }
                for q in 0..<quotes where s[k + q] != "\"" { return nil }
                for h in 0..<hashes where s[k + quotes + h] != "#" { return nil }
                return k + quotes + hashes
            }
            while k < s.count {
                if let end = terminates(at: k) { return (end, String(content)) }
                if s[k] == "\n", !multiline { return (k, String(content)) }   // malformed; stop at EOL
                if s[k] == "\\" {
                    // escape: `\` followed by `#` * hashes for raw strings
                    var h = 0
                    while h < hashes, k + 1 + h < s.count, s[k + 1 + h] == "#" { h += 1 }
                    if h == hashes {
                        let next = k + 1 + hashes
                        if next < s.count, s[next] == "(" {
                            var depth = 1
                            var m = next + 1
                            while m < s.count, depth > 0 {
                                if s[m] == "\"" { m = scanString(m).end; continue }
                                if s[m] == "(" { depth += 1 } else if s[m] == ")" { depth -= 1 }
                                m += 1
                            }
                            content.append("\u{FFFC}")
                            k = m
                            continue
                        }
                        content.append(s[k])
                        k = min(next + 1, s.count)
                        if next < s.count { content.append(s[next]) }
                        continue
                    }
                }
                content.append(s[k])
                k += 1
            }
            return (k, String(content))
        }

        while i < s.count {
            let c = s[i]
            if c == "/", i + 1 < s.count, s[i + 1] == "/" {
                var j = i
                while j < s.count, s[j] != "\n" { j += 1 }
                blank(i..<j)
                i = j
            } else if c == "/", i + 1 < s.count, s[i + 1] == "*" {
                var depth = 1
                var j = i + 2
                while j < s.count, depth > 0 {
                    if s[j] == "/", j + 1 < s.count, s[j + 1] == "*" { depth += 1; j += 2 }
                    else if s[j] == "*", j + 1 < s.count, s[j + 1] == "/" { depth -= 1; j += 2 }
                    else { j += 1 }
                }
                blank(i..<j)
                i = j
            } else if c == "\"" {
                let (end, content) = scanString(i)
                literals.append((i, end, content))
                blank((i + 1)..<max(i + 1, end - 1))
                i = end
            } else {
                i += 1
            }
        }

        // Line numbers and lines.
        var lineStarts = [0]
        for (k, ch) in s.enumerated() where ch == "\n" { lineStarts.append(k + 1) }
        func line(of offset: Int) -> Int {
            var lo = 0, hi = lineStarts.count - 1
            while lo < hi {
                let mid = (lo + hi + 1) / 2
                if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
            }
            return lo
        }
        func text(ofLine n: Int) -> String {
            let from = lineStarts[n]
            let to = n + 1 < lineStarts.count ? lineStarts[n + 1] - 1 : s.count
            var view = String.UnicodeScalarView()
            view.append(contentsOf: s[from..<max(from, to)])
            return String(view)
        }

        let built = literals.map { lit -> Literal in
            let n = line(of: lit.start)
            return Literal(line: n + 1, text: lit.content, inLog: isLog(literalStart: lit.start, line: n),
                           lineText: text(ofLine: n).trimmingCharacters(in: .whitespaces))
        }
        return SourceFile(path: path, text: s, masked: masked, literals: built)

        /// A literal is a log line when it sits inside an unclosed `AppLogger…(` call that began on
        /// this or one of the two previous lines, or on a line with `NSLocalizedDescriptionKey`/`print(`.
        func isLog(literalStart: Int, line n: Int) -> Bool {
            let lineText = text(ofLine: n)
            let lowest = lineStarts[max(0, n - 2)]
            let window = String(String.UnicodeScalarView(masked[lowest..<literalStart]))
            let current = window.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            if lineText.contains("NSLocalizedDescriptionKey") || current.contains("print(") { return true }
            guard let range = window.range(of: "AppLogger", options: .backwards) else { return false }
            var depth = 0
            for ch in window[range.lowerBound...] {
                if ch == "(" || ch == "[" { depth += 1 } else if ch == ")" || ch == "]" { depth -= 1 }
            }
            return depth > 0
        }
    }

    // MARK: Helpers

    private static func isAllowed(_ file: String, _ text: String) -> Bool {
        allowList.contains { $0.file == file && text.contains($0.substring) }
    }

    private static func report(_ title: String, _ hits: [String]) -> Comment {
        Comment(rawValue: "\(title):\n" + hits.joined(separator: "\n"))
    }

    private func codeLines(_ file: SourceFile) -> [(Int, String)] {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: file.masked)
        return String(view).split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .map { ($0.offset + 1, String($0.element)) }
    }

    private func sweepCode(_ pattern: String, skip: (SourceFile) -> Bool = { _ in false }) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        var hits: [String] = []
        for file in Self.files where !skip(file) {
            for (n, line) in codeLines(file) {
                let range = NSRange(line.startIndex..., in: line)
                if regex.firstMatch(in: line, range: range) != nil, !Self.isAllowed(file.path, line) {
                    hits.append("MLM/\(file.path):\(n): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return hits
    }

    private func sweepLiterals(_ pattern: String, options: NSRegularExpression.Options = [],
                               includeLogs: Bool = false) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern, options: options)
        var hits: [String] = []
        for file in Self.files {
            for literal in file.literals where includeLogs || !literal.inLog {
                let range = NSRange(literal.text.startIndex..., in: literal.text)
                if regex.firstMatch(in: literal.text, range: range) != nil, !Self.isAllowed(file.path, literal.text) {
                    hits.append("MLM/\(file.path):\(literal.line): \"\(literal.text)\"")
                }
            }
        }
        return hits
    }

    // MARK: Sanity

    @Test func theSweepSeesTheSourceTree() {
        #expect(Self.files.count > 300, "the walk found \(Self.files.count) files")
        let literals = Self.files.reduce(0) { $0 + $1.literals.count }
        #expect(literals > 5000, "the lexer found \(literals) string literals")
        let selection = Self.files.first { $0.path == "Views/TrackList/SelectionBar.swift" }
        #expect(selection?.literals.isEmpty == false, "the selection bar file is lexed")
    }

    @Test func theLexerSplitsCodeCommentsAndLiterals() {
        let source = """
        // "in a comment" ...
        let a = "plain \\(value + "nested") end" /* "block" */
        let b = #"raw "quoted" \\#(x)"#
        let c = \"\"\"
        multi ...
        \"\"\"
        """
        let file = Self.lex(path: "x.swift", source: source)
        #expect(file.literals.map(\.text) == ["plain \u{FFFC} end", "raw \"quoted\" \u{FFFC}", "\nmulti ...\n"])
        #expect(!String(String.UnicodeScalarView(file.masked)).contains("comment"))
        let logged = Self.lex(path: "y.swift", source: "AppLogger.shared.info(\n    \"a\",\n    source: \"S\"\n)\nlet t = \"b\"")
        #expect(logged.literals.map(\.inLog) == [true, true, false])
    }

    // MARK: Colour, type, glass, availability (UC-COLOR-03, UC-TYPE-01, UC-GLASS-04, THOUGHTS §10)

    @Test func noMlmTokensAnywhere() {
        // `mlmUuid*` is the embedded playlist/track UUID tag, `mlmHelp` a menu-command case.
        let hits = sweepCode(#"\bmlm[A-Z]"#).filter { !$0.contains("mlmUuid") && !$0.contains("mlmHelp") }
        let comments = Self.files.flatMap { file -> [String] in
            var view = String.UnicodeScalarView()
            view.append(contentsOf: file.text)
            return String(view).split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap {
                let line = String($0.element)
                guard line.range(of: #"\bmlm[A-Z]"#, options: .regularExpression) != nil,
                      !line.contains("mlmUuid"), !line.contains("mlmHelp") else { return nil }
                return "MLM/\(file.path):\($0.offset + 1): \(line.trimmingCharacters(in: .whitespaces))"
            }
        }
        #expect((hits + comments).isEmpty, Self.report("`mlm*` colour or font tokens (UC-COLOR-03)", hits + comments))
    }

    @Test func noCustomFontsOrThemeTypes() {
        let hits = sweepCode(#"\bMLMFont\b|\bMLMColor\b|\bMLMGlass\b"#)
        #expect(hits.isEmpty, Self.report("custom font or theme types (UC-TYPE-01, UC-COLOR-03)", hits))
    }

    @Test func noAvailabilityChecks() {
        let hits = sweepCode(#"#available|#unavailable|@available\(macOS"#)
        #expect(hits.isEmpty, Self.report("macOS 27 only: no availability checks (THOUGHTS §10)", hits))
    }

    @Test func noHexOrComponentColours() {
        let hits = sweepCode(#"Color\(hex|Color\(red:|Color\(\.sRGB|Color\(white:|Color\(hue:"#)
        #expect(hits.isEmpty, Self.report("hex / component colours (UC-COLOR-03)", hits))
    }

    @Test func glassOnlyOnTheSelectionBar() {
        let hits = sweepCode(#"\.glassEffect|\bGlassEffectContainer|\.buttonStyle\(\.glass"#) { $0.path == "Views/TrackList/SelectionBar.swift" }
        #expect(hits.isEmpty, Self.report("glass outside the selection bar (UC-GLASS-04)", hits))
    }

    @Test func noHiddenTitleBarOrToasts() {
        let hits = sweepCode(#"hiddenTitleBar|windowStyle\(\.plain|\bToast[A-Z(]|\.toast\("#)
        #expect(hits.isEmpty, Self.report("custom chrome or toasts (UC-WIN, UC-FB)", hits))
    }

    // MARK: Words (UC-GLOSS-02, UC-COPY-01/05)

    @Test func noGermanInStrings() {
        let umlauts = sweepLiterals("[äöüßÄÖÜ]")
        let words = sweepLiterals(#"\b(nicht|und|für|Datei|Titel|Wiedergabe|Fehler|Bitte)\b"#)
        let hits = umlauts + words
        #expect(hits.isEmpty, Self.report("German strings (UC-COPY-01)", hits))
    }

    @Test func noEmojiInStrings() {
        var hits: [String] = []
        for file in Self.files {
            for literal in file.literals where !Self.isAllowed(file.path, literal.text) {
                let bad = literal.text.unicodeScalars.contains {
                    $0.value >= 0x1F300 || "✓✔✗✘⚠★☆♪♫".unicodeScalars.contains($0)
                }
                if bad { hits.append("MLM/\(file.path):\(literal.line): \"\(literal.text)\"") }
            }
        }
        #expect(hits.isEmpty, Self.report("emoji or glyph stand-ins (UC-COPY-01)", hits))
    }

    @Test func noThreeDotEllipsisInStrings() {
        // URLs and format strings may hold dots; log lines are not UI copy.
        let hits = sweepLiterals(#"\.\.\."#).filter { !$0.contains("://") && !$0.contains("%") }
        #expect(hits.isEmpty, Self.report("three dots instead of … (UC-COPY-05)", hits))
    }

    @Test func noBannedGlossaryWordsInStrings() {
        let patterns = [
            #"\b(Turbo|Swarm|Vector Gravity|Warp Embeddings|Drop-Fokus|Groove|Groove Studio|Genre Workshop)\b"#,
            #"\bNeighbors?\b"#,
            #"kept_higher_quality|fingerprint_dedup"#,
            #"\bflagged\b"#,
            #"\bReveal\b|\bRe-scan\b|Token inaccessible|Loading Library|Failed to Initialize|Playback unavailable"#,
            #"Are you sure\?|This cannot be undone\.?"#,
            #"\b(Pin|Unpin)\b"#,
            #"\bSync to\b"#,
        ]
        var hits = patterns.flatMap { sweepLiterals($0) }
        // Whole-literal values and titles.
        // (`youtube` as a source id is data; the displayed name is `YouTube`.)
        hits += sweepLiterals(#"^(unknown album|soundcloud likes|Error|Stream)$"#)
        #expect(hits.isEmpty, Self.report("banned or retired words (UC-GLOSS-02)", Array(Set(hits)).sorted()))
    }

    // MARK: Allow-list hygiene

    @Test func everyAllowListEntryStillMatchesSomething() {
        for entry in Self.allowList {
            let file = Self.files.first { $0.path == entry.file }
            let found = file?.literals.contains { $0.text.contains(entry.substring) } == true
            #expect(found, "allow-list entry \(entry.file): \(entry.substring) matches nothing — remove it")
            #expect(!entry.reason.isEmpty)
        }
    }
}
