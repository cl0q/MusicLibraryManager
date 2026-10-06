import Testing
import Foundation
@testable import MLM

/// Source-scan contract for Settings → Storage Location: tab placement, native form style,
/// the approved copy (UI-GROUNDTRUTH §3.14 / §5.6), and no banned or German strings.
@Suite("DataLocationsView contract (A1)")
struct DataLocationsViewTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var paneSource: String {
        get throws { try source("MLM/Views/Settings/DataLocationsView.swift") }
    }

    private var viewModelSource: String {
        get throws { try source("MLM/ViewModels/DataLocationsViewModel.swift") }
    }

    /// String literals in a source file, so comments don't count as UI copy.
    private func stringLiterals(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    /// UC-WIN-03 order (W1-2): Storage Location sits between Backup and Maintenance.
    @Test func storageTabSitsBetweenBackupAndMaintenance() throws {
        let tabs = SettingsTab.allCases
        let storage = try #require(tabs.firstIndex(of: .storage))
        #expect(tabs[storage - 1] == .backup)
        #expect(tabs[storage + 1] == .maintenance)
        #expect(SettingsTab.storage.title == "Storage Location")
        #expect(SettingsTab.storage.systemImage == "internaldrive")
        let src = try source("MLM/Views/Settings/SettingsView.swift")
        #expect(src.contains("pane(.storage) { DataLocationsView() }"))
    }

    @Test func paneUsesGroupedFormAndContainer() throws {
        let src = try paneSource
        #expect(src.contains(".formStyle(.grouped)"))
        #expect(src.contains("@Environment(\\.container)"))
        #expect(src.contains("import Charts") && src.contains("BarMark"), "ST-STORAGE.N01: the sizes chart")
        #expect(src.contains("ShowInFinderButton"))
        #expect(src.contains("SettingsPath"))
        // Transparency only: no relocation UI in this pane.
        #expect(!src.contains("NSOpenPanel"))
        #expect(!src.contains("folderPanel"))
        #expect(!src.contains("\"Change…\""))
    }

    @Test func paneNeverReadsCredentialContents() throws {
        for src in [try paneSource, try viewModelSource] {
            #expect(!src.contains("loadEnvFile"))
            #expect(!src.contains("credential(key:"))
            #expect(!src.contains("String(contentsOf"))
            #expect(!src.contains("Data(contentsOf"))
        }
    }

    @Test func paneContainsApprovedCopy() throws {
        let src = try paneSource + viewModelSource
        let approved = [
            "In this library file", "Moves with the file", "Library folder", "This library",
            "On this Mac", "Stays when a library file is moved",
            "Library file", "Database", "Inside the library file", "database file ", "recent changes ",
            "Playlist covers", "Backups", "last backup ", "List of libraries", "All libraries",
            "Credentials file", "Sign-in tokens", "Artwork and waveform caches", "Can be rebuilt",
            "Path migration backups", "Logs", "Previous install", "Transcode cache",
            "Show in Finder", "Calculate Size", "Cancel", " · calculated ",
            "Not found", "Not connected", "Calculating…", "Size not calculated", "Never",
            "No library folder set — choose one in the Library tab.",
            "The size couldn't be calculated. Check that the drive is connected and try again.",
            "Stored in the macOS Keychain",
            "Change the library folder in Library", "Change the location or clear it in Maintenance",
            "Change the backup folder in Backup",
            "Recent changes are kept in a separate file (-wal) and merged into the database automatically.",
            "Library files and the credentials file remain on your Mac if you delete the app. Audio files are never moved by this tab.",
            "Sizes refresh when this tab opens and when a drive is connected.",
            "Other files", " free",
        ]
        for string in approved {
            #expect(src.contains(string), "missing approved copy: \(string)")
        }
    }

    @Test func paneHasNoBannedOrGermanStrings() throws {
        let literals = try stringLiterals(in: try paneSource) + stringLiterals(in: try viewModelSource)
        let banned = [
            // UI-GROUNDTRUTH §1.5 / §5.8
            "Turbo", "Swarm", "Vector Gravity", "Warp Embeddings", "Drop-Fokus", "Synced",
            "kept_higher_quality", "flagged", "fingerprint_dedup", "Track #",
            "Lokal", "Remote", "In Finder anzeigen", "Papierkorb",
            // §1.5 "never called" for Storage Location / Library folder / Credentials file
            "Audio library", "Music root", "env file", "Secrets",
            // Reveal is replaced by "Show in Finder"
            "Reveal in Finder",
        ]
        let german = [
            "Sicherung", "Speicherort", "Einstellung", "Abbrechen", "Ordner", "Datenbank",
            "Größe", "nicht", "ä", "ö", "ü", "Ä", "Ö", "Ü", "ß",
        ]
        for literal in literals {
            for term in banned + german {
                #expect(!literal.contains(term), "banned term \(term) in \"\(literal)\"")
            }
            #expect(!literal.unicodeScalars.contains { $0.properties.isEmojiPresentation },
                    "emoji in \"\(literal)\"")
        }
    }

    @Test func buttonsUseTitleCase() throws {
        let src = try paneSource
        for sentenceCase in ["\"Calculate size\"", "\"Show in finder\""] {
            #expect(!src.contains(sentenceCase), "Title Case for buttons (UC-COPY)")
        }
    }

}
