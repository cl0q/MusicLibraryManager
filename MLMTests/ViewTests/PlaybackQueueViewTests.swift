import Testing
import Foundation

/// Source-scan tests verifying the Playback Queue feature structure:
/// - PlaybackQueueView contains three accessibility IDs and three TrackTable usages
/// - PlaybackQueueView has section headers "History", "Currently playing", "Next up"
/// - SidebarView renders .queue above settingsFooter
/// - SettingsView contains the three setting keys
@Suite("PlaybackQueueViewTests")
struct PlaybackQueueViewTests {

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - PlaybackQueueView

    @Test
    func playbackQueueView_containsHistoryAccessibilityID() throws {
        let src = try readSource("MLM/Views/Queue/PlaybackQueueView.swift")
        #expect(src.contains("queue_history_table"),
                "PlaybackQueueView must contain queue_history_table accessibility ID")
    }

    @Test
    func playbackQueueView_containsNowPlayingAccessibilityID() throws {
        let src = try readSource("MLM/Views/Queue/PlaybackQueueView.swift")
        #expect(src.contains("queue_now_playing_table"),
                "PlaybackQueueView must contain queue_now_playing_table accessibility ID")
    }

    @Test
    func playbackQueueView_containsUpNextAccessibilityID() throws {
        let src = try readSource("MLM/Views/Queue/PlaybackQueueView.swift")
        #expect(src.contains("queue_upnext_table"),
                "PlaybackQueueView must contain queue_upnext_table accessibility ID")
    }

    @Test
    func playbackQueueView_usesTrackTable() throws {
        let src = try readSource("MLM/Views/Queue/PlaybackQueueView.swift")
        // Count shared track-table usages — should be 3 (history, now playing, up next)
        let count = src.components(separatedBy: "TrackListTable(").count - 1
        #expect(count == 3, "PlaybackQueueView must use TrackListTable exactly 3 times, found \(count)")
    }

    @Test
    func playbackQueueView_containsSectionHeaders() throws {
        let src = try readSource("MLM/Views/Queue/PlaybackQueueView.swift")
        #expect(src.contains("History"), "PlaybackQueueView must have 'History' section header")
        #expect(src.contains("Currently playing"), "PlaybackQueueView must have 'Currently playing' section header")
        #expect(src.contains("Next up"), "PlaybackQueueView must have 'Next up' section header")
    }

    // MARK: - Now playing fixed height

    @Test
    func playbackQueueView_nowPlayingFixedHeight() throws {
        let src = try readSource("MLM/Views/Queue/PlaybackQueueView.swift")
        #expect(src.contains(".frame(height:"),
                "Now-playing TrackTable must have a fixed .frame(height:) to show exactly one row")
    }

    // MARK: - Full context menu in queue tables

    @Test
    func playbackQueueView_fullContextMenu() throws {
        let src = try readSource("MLM/Views/Queue/PlaybackQueueView.swift")
        #expect(!src.contains("contextMenuAllowsLibraryActions: false"),
                "Queue tables must use the full context menu (no contextMenuAllowsLibraryActions: false)")
    }

    // MARK: - SidebarView (W1-1: the Queue is a trailing-column mode, DEC-006)

    @Test
    func sidebarView_hasNoQueueOrSettingsRows() throws {
        let src = try readSource("MLM/Views/Sidebar/SidebarView.swift")
        #expect(!src.contains("queueFooter") && !src.contains("settingsFooter"),
                "The Queue and Settings footer rows left the sidebar")
        #expect(!src.contains("\"PLAYBACK\""))
    }

    @Test
    func sidebarView_footerIsTheLibraryFooter() throws {
        let src = try readSource("MLM/Views/Sidebar/SidebarView.swift")
        #expect(src.contains("safeAreaInset(edge: .bottom"),
                "SidebarView must use safeAreaInset(edge: .bottom) for the footer area")
        #expect(src.contains("LibraryFooter()"))
    }

    @Test
    func queueOpensFromThePlayerAndTheMenu() throws {
        let player = try readSource("MLM/Views/Player/PlayerBar.swift")
        #expect(player.contains("toggle(.queue)"), "The player's queue button toggles the Queue column")
        let view = try readSource("MLM/App/Commands/ViewCommands.swift")
        #expect(view.contains("CommandButton(.toggleQueue"), "View ▸ Show Queue toggles the Queue")
        let catalog = try readSource("MLM/App/Commands/MenuCatalog.swift")
        #expect(catalog.contains("case .toggleQueue: Entry(menu: .view, title: \"Show Queue\", shortcut: .cmd(\"u\", .option)"),
                "⌥⌘U toggles the Queue")
        #expect(!catalog.contains(".cmd(\"8\""), "⌘8 is gone")
    }

    // MARK: - SettingsView

    @Test
    func settingsView_containsHistorySizeKey() throws {
        let src = try readSource("MLM/Views/Settings/SettingsView.swift")
        #expect(src.contains("playback_history_size"),
                "SettingsView must contain playback_history_size key")
    }

    @Test
    func settingsView_containsContextCapKey() throws {
        let src = try readSource("MLM/Views/Settings/SettingsView.swift")
        #expect(src.contains("playback_context_cap"),
                "SettingsView must contain playback_context_cap key")
    }

    @Test
    func settingsView_containsLUFSNormalizationKey() throws {
        let src = try readSource("MLM/Views/Settings/SettingsView.swift")
        #expect(src.contains("playback_lufs_normalization"),
                "SettingsView must contain playback_lufs_normalization key")
    }
}
