import Foundation
import Testing
@testable import MLM

/// W3-SET: the pure pieces behind the rebuilt tabs — the library-folder comparison of
/// S-SET-LIBFOLDER, notification categories (ST-GENERAL.N02), the diagnostic summary and list
/// cache line (ST-ADVANCED), and the plain-word reasons of the path preview (ST-MAINT.E16).
@Suite("Settings tabs logic (W3-SET)")
@MainActor
struct SettingsTabsLogicTests {

    @Test func folderComparisonCountsKnownFiles() {
        let folder = URL(fileURLWithPath: "/Volumes/New/Music")
        let existing: Set<String> = ["/Volumes/New/Music/A/1.m4a", "/Volumes/New/Music/B/2.flac", "/Users/x/outside.mp3"]
        let result = ImportViewModel.compare(
            folder: folder,
            organizedPaths: ["A/1.m4a", "B/2.flac", "C/3.mp3", "/Users/x/outside.mp3", ""],
            fileExists: existing.contains)
        #expect(result == ImportViewModel.FolderComparison(found: 3, total: 4))
        #expect(result.missing == 1)
    }

    @Test func aRelativePathWithALeadingSlashIsRelative() {
        let result = ImportViewModel.compare(
            folder: URL(fileURLWithPath: "/M"), organizedPaths: ["/01_SoundCloud/x.m4a"],
            fileExists: { $0 == "/M/01_SoundCloud/x.m4a" })
        #expect(result.found == 1)
    }

    @Test func notificationCategoriesDefaultOnAndMapKinds() {
        let name = "SettingsTabsLogicTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(ActivitySystemNotifier.Category.sync.isEnabled(in: defaults), "on unless turned off: the old meaning")
        defaults.set(false, forKey: ActivitySystemNotifier.Category.sync.rawValue)
        #expect(!ActivitySystemNotifier.Category.sync.isEnabled(in: defaults))
        #expect(ActivitySystemNotifier.Category(kind: .download) == .importsAndDownloads)
        #expect(ActivitySystemNotifier.Category(kind: .folderScan) == .importsAndDownloads)
        #expect(ActivitySystemNotifier.Category(kind: .restore) == .backups)
        #expect(ActivitySystemNotifier.Category(kind: .artwork) == nil)
    }

    @Test func diagnosticSummaryHasNoTitlesOrCredentials() {
        let tools = [
            DownloadToolRow(tool: .ytdlp, isFound: true, version: "2026.09.12", path: "/opt/homebrew/bin/yt-dlp"),
            DownloadToolRow(tool: .fpcalc, isFound: false, version: nil, path: nil),
        ]
        let text = AdvancedSettingsView.diagnosticSummary(appVersion: "1.0", system: "Version 27.0", tools: tools,
                                                          libraryName: "Main Library", tracksWithFile: 8_902)
        #expect(text.contains("MLM 1.0"))
        #expect(text.contains("yt-dlp: 2026.09.12 at /opt/homebrew/bin/yt-dlp"))
        #expect(text.contains("fpcalc: not found"))
        #expect(text.contains("Library open: yes · 8902 tracks with a file"))
        #expect(!text.contains("Main Library"), "no names")
    }

    @Test func listCacheLineNamesWhatIsKept() {
        let line = AdvancedSettingsView.listCacheLine(libraryRows: 10, playlists: ["Warm-up", "Closing"], playlistRows: 5)
        #expect(line.hasPrefix("Makes reopening instant; 0 turns it off. In use now: about "))
        #expect(line.hasSuffix("— All Tracks and 2 playlists (Warm-up, Closing)."))
    }

    @Test func installHelpForEveryListedTool() {
        for tool in DownloadToolsModel.listed {
            let row = DownloadToolRow(tool: tool, isFound: false, version: nil, path: nil)
            #expect(row.installCommand.hasPrefix("brew install ") || row.installCommand.hasPrefix("pipx install "))
            #expect(row.statusText.hasPrefix("Not found · "))
        }
    }

    // MARK: Review S5

    @Test func folderChangeIsRefusedWhileFileWorkRuns() {
        func op(_ kind: ActivityKind, _ title: String) -> ActivityOperation {
            ActivityOperation(id: UUID(), kind: kind, title: title, subject: .none, state: .running, wait: nil,
                              progress: .indeterminate, result: nil, startedAt: Date(), endedAt: nil, isAutomatic: false,
                              libraryID: nil, needsAttention: false, dismissedAt: nil, itemNoun: .track,
                              messageName: "", controls: .none, isFromHistory: false)
        }
        #expect(ImportViewModel.folderChangeRefusal(operations: [op(.backup, "Back Up Now")]) == nil)
        let text = ImportViewModel.folderChangeRefusal(operations: [op(.download, "Import “Warm-up”"), op(.sync, "Sync “iPod”")])
        #expect(text?.hasPrefix("MLM can’t change the library folder while 1 download and 1 sync are running.") == true)
        #expect(text?.contains("• Sync “iPod”") == true)
    }

    @Test func absolutePathsUnderTheOldFolderMoveWithIt() {
        let result = ImportViewModel.compare(
            folder: URL(fileURLWithPath: "/Volumes/B/Music"),
            organizedPaths: ["/Volumes/A/Music/x.m4a", "/Volumes/A/Music/y.m4a"], oldRoot: "/Volumes/A/Music",
            fileExists: { $0 == "/Volumes/B/Music/x.m4a" || $0 == "/Volumes/A/Music/y.m4a" })
        #expect(result.found == 1, "a file still in the old folder isn't found in the new one")
    }
}
