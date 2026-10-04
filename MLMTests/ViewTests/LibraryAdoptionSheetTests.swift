import Testing
import Foundation
@testable import MLM

/// Source-scan contract for the `Set up your library file` sheet (UI-GROUNDTRUTH §3.17 /
/// §5.6, A3 Wave 3) and its routing; plus the new backup reason label.
@Suite("LibraryAdoptionSheet contract (A3 Wave 3)")
struct LibraryAdoptionSheetTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private var sheetSource: String {
        get throws { try source("MLM/Views/Shared/LibraryAdoptionSheet.swift") }
    }

    private func stringLiterals(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        var literals: [String] = []
        for line in source.components(separatedBy: .newlines) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            let range = NSRange(line.startIndex..., in: line)
            for match in regex.matches(in: line, range: range) {
                if let r = Range(match.range(at: 1), in: line) { literals.append(String(line[r])) }
            }
        }
        return literals
    }

    @Test func usesApprovedCopy() throws {
        let src = try sheetSource
        let approved = [
            "Set up your library file",
            "MLM now keeps your library — tracks, playlists, settings and playlist covers — in a single library file that you can move and back up as one item. MLM backs up first, then copies your library into the new file. Audio files are not moved.",
            "Name", "Main Library",
            "in MLM's folder in your user Library.",
            "Not now", "Create library file",
            "Backing up…", "Creating library file…", "Checking…",
            "Your library is now stored in",
            "The previous files were moved to a folder named \\\"legacy-adopted-…\\\" — you can delete it once everything looks right.",
            "Show in Finder", "Done",
            "The library file couldn't be created. Your library was not changed.",
            "Details", "Try again",
        ]
        for string in approved {
            #expect(src.contains(string), "missing approved copy: \(string)")
        }
    }

    @Test func hasNoBannedGermanOrTitleCaseStrings() throws {
        let literals = try stringLiterals(in: try sheetSource)
        let banned = [
            "Package", "package", "Bundle", "bundle", "Database file", "Migrate", "migrat",
            "Not Now", "Create Library File", "Try Again", "Show In Finder", "Reveal in Finder",
            "Bibliothek", "Mediathek", "Abbrechen", "Später",
        ]
        for literal in literals {
            for term in banned {
                #expect(!literal.contains(term), "banned term \(term) in \"\(literal)\"")
            }
        }
    }

    @Test func contentViewPresentsTheSheetForTheOffer() throws {
        let src = try source("MLM/Views/ContentView/ContentView.swift")
        #expect(src.contains("LibraryAdoptionSheet("))
        #expect(src.contains(".offerAdoption"))
    }

    @Test @MainActor func backupReasonLabel() {
        #expect(BackupSettingsViewModel.reasonLabel(.preAdoption) == "Before library file setup")
    }
}
