import Testing
import Foundation
@testable import MLM

/// Source-scan contract for Settings ▸ Backup (W3-SET, `settings.html#backup`): tab placement,
/// native form style, the designed copy, system folder panels, Title Case buttons, and no banned
/// or German strings.
@Suite("BackupSettingsView contract (W3-SET)")
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
        // UC-SHEET-24: the system folder panel, never a hand-rolled NSOpenPanel.
        #expect(src.contains(".folderPanel(isPresented: $choosesFolder, message: \"Choose a folder for backups.\""))
        #expect(!src.contains("NSOpenPanel"))
        #expect(src.contains("ShowInFinderButton"))
        #expect(src.contains(".contextMenu {"), "ST-BACKUP.N04")
        #expect(src.contains(".pickerStyle(.segmented)"))
        // Cancel is the default of the restore alert (UC-SHEET-15).
        #expect(src.contains("Button(\"Restore and Relaunch\", role: .destructive)"))
        #expect(src.contains(".keyboardShortcut(.defaultAction)"))
    }

    @Test func paneContainsApprovedCopy() throws {
        let src = try paneSource + source("MLM/ViewModels/BackupSettingsViewModel.swift")
        let approved = [
            "Status", "Last backup", "Back Up Now", "Backing up…", "Schedule", "Back up automatically", "Keep",
            "Backup folder", "Default location", "Change…", "Use Default", "Restore…", "Show All", "Details",
            "Each backup contains the library database and playlist covers. Audio files and account credentials are never included.",
            "MLM also backs up before updating the library database, before a restore and before library file setup, whatever the schedule.",
            "Older backups are removed after a new one succeeds.",
            "Only backups of the open library are listed. Restoring never crosses libraries.",
            "Incomplete — can’t be restored", "Database version: ",
            "· automatic backups are skipped until it is connected; the backups stored there are not listed",
            "Restore the backup from ", "Restore and Relaunch", "Restoring…", "Relaunching…", "Relaunch",
            "To undo, restore the “Before restore” backup.",
            "Restore didn’t finish", "Can’t restore while work is running", "Show in Activity",
        ]
        for string in approved {
            #expect(src.contains(string), "missing approved copy: \(string)")
        }
        #expect(!src.contains("Finish active downloads and syncs first"), "running work is listed, not asked about (UC-SHEET-13)")
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

    @Test func buttonsUseTitleCase() throws {
        let src = try paneSource
        for sentenceCase in ["\"Back up now\"", "\"Use default\"", "\"Restore and relaunch\"", "\"Choose folder\""] {
            #expect(!src.contains(sentenceCase), "Title Case for buttons (UC-COPY)")
        }
    }

}
