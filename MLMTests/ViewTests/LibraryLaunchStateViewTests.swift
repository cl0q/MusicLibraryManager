import Testing
import Foundation

/// Source-scan contract for the launch placeholder (no library open, library can't be
/// opened, New Library sheet): approved copy from UI-GROUNDTRUTH §3.17 / §5.6, no banned,
/// German or title-case strings, and routing from `ContentView`.
@Suite("LibraryLaunchStateView contract (A3 Wave 2)")
struct LibraryLaunchStateViewTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var viewSource: String {
        get throws { try source("MLM/Views/Shared/LibraryLaunchStateView.swift") }
    }

    private func stringLiterals(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var literals: [String] = []
        for line in source.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                if let r = Range(match.range(at: 1), in: line) { literals.append(String(line[r])) }
            }
        }
        return literals
    }

    @Test func usesApprovedCopy() throws {
        let src = try viewSource
        let approved = [
            "No library open",
            "Create a new library or open an existing library file.",
            "New Library…", "Open Library…",
            "can't be opened",
            "The library file isn't where MLM last found it. Open it from its new location, or create a new library.",
            "The library file is on a disk that isn't connected. Connect the disk, then try again.",
            "Try again",
            "The library file and its database don't belong together. This can happen when files inside a library file were replaced. MLM didn't change anything.",
            "Show in Finder", "OK",
            "isn't a valid library file.",
            "New Library", "Name", "Main Library",
            "A library keeps its own tracks, playlists and settings. Audio files stay where they are.",
            "Create", "Cancel",
            "opticaldisc",
        ]
        for string in approved {
            #expect(src.contains(string), "missing approved copy: \(string)")
        }
    }

    @Test func hasNoBannedGermanOrTitleCaseStrings() throws {
        let literals = try stringLiterals(in: try viewSource)
        let banned = [
            "Package", "package", "Bundle", "bundle", "Database file", "Reveal in Finder",
            "Try Again", "Open Library…\u{0020}", "Show In Finder", "New library…", "Open library…",
            "Bibliothek", "Mediathek", "Abbrechen", "Erstellen", "Öffnen",
        ]
        for literal in literals {
            for term in banned {
                #expect(!literal.contains(term), "banned term \(term) in \"\(literal)\"")
            }
            #expect(!literal.unicodeScalars.contains { $0.properties.isEmojiPresentation })
        }
    }

    @Test func contentViewRoutesLaunchScreens() throws {
        let src = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(src.contains("LibraryLaunchStateView("))
        #expect(src.contains("LibraryLaunchCoordinator.shared"))
    }

    @Test func appDelegateStartsTheCoordinator() throws {
        let src = try source("MLM/App/AppDelegate.swift")
        #expect(src.contains("LibraryLaunchCoordinator.shared.start()"))
        #expect(!src.contains("DependencyContainer.shared.initialize()"))
    }
}
