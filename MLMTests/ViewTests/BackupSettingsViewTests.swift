import Testing
import Foundation
@testable import MLM

/// Source-scan contract for Settings → Backup: tab placement, native form style, the
/// approved copy (UI-GROUNDTRUTH §3.14 / §5.6), and no banned or German strings.
@Suite("BackupSettingsView contract (Wave 3)")
struct BackupSettingsViewTests {

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
        get throws { try source("MLM/Views/Settings/BackupSettingsView.swift") }
    }

    /// String literals in the pane source, so comments don't count as UI copy.
    private func stringLiterals(in source: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            Range(match.range(at: 1), in: source).map { String(source[$0]) }
        }
    }

    /// UC-WIN-03 order (W1-2): Backup sits between Sources and Storage Location and hosts the
    /// existing pane.
    @Test func backupTabSitsBetweenSourcesAndStorageLocation() throws {
        let tabs = SettingsTab.allCases
        let backup = try #require(tabs.firstIndex(of: .backup))
        #expect(tabs[backup - 1] == .sources)
        #expect(tabs[backup + 1] == .storage)
        #expect(SettingsTab.backup.title == "Backup")
        #expect(SettingsTab.backup.systemImage == "externaldrive.badge.timemachine")
        let src = try source("MLM/Views/Settings/SettingsView.swift")
        #expect(src.contains("pane(.backup) { BackupSettingsView() }"))
    }

    @Test func paneUsesGroupedFormAndContainer() throws {
        let src = try paneSource
        #expect(src.contains(".formStyle(.grouped)"))
        #expect(src.contains("@Environment(\\.container)"))
        #expect(src.contains("NSOpenPanel()"))
        #expect(src.contains("activateFileViewerSelecting"))
    }

    @Test func paneContainsApprovedCopy() throws {
        let src = try paneSource
        let approved = [
            "Backups are available once the library has loaded.",
            "Backup folder", "Default location", "Change…", "Use default", "Show in Finder",
            "Last backup", "Backups", "Total size",
            "Each backup contains the library database and playlist covers. Audio files and account credentials are never included.",
            "No backups yet. MLM backs up automatically at launch, at most once a day.",
            "Incomplete — can't be restored", "Restore…", "Database version: ",
            "Back up now", "Backing up…",
            "The 10 most recent backups are kept. MLM also backs up at launch (at most once a day) and before updating the library database.",
            "Restore backup from ", "Restore and relaunch", "Cancel", "Restoring…", "Relaunching…", "Relaunch",
            "MLM first saves a copy of your current library, then replaces the library database and playlist covers with this backup and relaunches. Audio files are not changed. Finish active downloads and syncs first. To undo, restore the \\\"Before restore\\\" backup.",
            "Status", "Actions", "Details",
        ]
        for string in approved {
            #expect(src.contains(string), "missing approved copy: \(string)")
        }
    }

    @Test func paneHasNoBannedOrGermanStrings() throws {
        let literals = try stringLiterals(in: try paneSource)
            + stringLiterals(in: try source("MLM/ViewModels/BackupSettingsViewModel.swift"))
        let banned = [
            // UI-GROUNDTRUTH §1.5 / §5.8
            "Turbo", "Swarm", "Vector Gravity", "Warp Embeddings", "Drop-Fokus", "Synced",
            "kept_higher_quality", "flagged", "fingerprint_dedup", "Track #",
            "Lokal", "Remote", "In Finder anzeigen", "Papierkorb",
            // §1.5 "never called" for Backup / Restore
            "Snapshot", "Export", "Rollback",
            // Reveal is replaced by "Show in Finder"
            "Reveal in Finder",
        ]
        let german = [
            "Sicherung", "Wiederherstell", "Einstellung", "Abbrechen", "Speicher", "Ordner",
            "Datenbank", "ä", "ö", "ü", "Ä", "Ö", "Ü", "ß",
        ]
        for literal in literals {
            for term in banned + german {
                #expect(!literal.contains(term), "banned term \(term) in \"\(literal)\"")
            }
            #expect(!literal.unicodeScalars.contains { $0.properties.isEmojiPresentation },
                    "emoji in \"\(literal)\"")
        }
    }

    @Test func buttonsUseSentenceCase() throws {
        let src = try paneSource
        for titleCase in ["Back Up Now", "Show In Finder", "Use Default", "Restore And Relaunch"] {
            #expect(!src.contains(titleCase))
        }
    }
}
