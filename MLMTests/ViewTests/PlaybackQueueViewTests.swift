import Testing
import Foundation

/// Source-scan tests verifying the Playback Queue feature structure:
/// - the Queue panel (W2-D) replaced PlaybackQueueView: one List of queue entries, sections
///   "Now playing", "Next", "History", the safe CM-QUEUE menu
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

    // MARK: - The Queue panel (W2-D replaced PlaybackQueueView)

    @Test
    func queuePanelReplacesTheThreeTables() throws {
        let gone = Self.repoRoot.appendingPathComponent("MLM/Views/Queue/PlaybackQueueView.swift").path
        #expect(!FileManager.default.fileExists(atPath: gone), "the three 13-column tables are gone")
        let src = try readSource("MLM/Views/Queue/QueuePanel.swift")
        #expect(src.contains("queue_panel"), "the panel has its accessibility ID")
        #expect(!src.contains("TrackListTable("), "queue entries, not track-id rows (the same track can be queued twice)")
    }

    @Test
    func queuePanelHasTheThreeSections() throws {
        let src = try readSource("MLM/Views/Queue/QueuePanel.swift")
        #expect(src.contains("Section(QueuePanelWords.nowPlaying)") && src.contains("Section(QueuePanelWords.history)"))
        #expect(src.contains("nextHeader("))
        let words = try readSource("MLM/Views/Queue/QueuePanelModel.swift")
        #expect(words.contains("\"Now playing\"") && words.contains("\"Next\"") && words.contains("\"History\""))
        #expect(!words.contains("Currently playing") && !words.contains("Next up"), "the old section names are gone")
    }

    @Test
    func queuePanelUsesTheSafeQueueMenu() throws {
        let src = try readSource("MLM/Views/Queue/QueuePanel.swift")
        #expect(src.contains("queueRows: content.menuRows(for: subject)"), "CM-QUEUE through the shared builder")
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
        let src = try readSource("MLM/Views/Settings/PlaybackSettingsView.swift")
        #expect(src.contains("playback_history_size"),
                "PlaybackSettingsView (W3-SET) must contain playback_history_size key")
    }

    @Test
    func settingsView_containsContextCapKey() throws {
        let src = try readSource("MLM/Views/Settings/PlaybackSettingsView.swift")
        #expect(src.contains("playback_context_cap"),
                "PlaybackSettingsView (W3-SET) must contain playback_context_cap key")
    }

    @Test
    func settingsView_containsLUFSNormalizationKey() throws {
        let src = try readSource("MLM/Views/Settings/PlaybackSettingsView.swift")
        #expect(src.contains("playback_lufs_normalization"),
                "PlaybackSettingsView (W3-SET) must contain playback_lufs_normalization key")
    }
}
