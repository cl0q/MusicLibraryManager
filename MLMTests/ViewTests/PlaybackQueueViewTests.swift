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
        // Count TrackTable usages — should be 3 (history, now playing, up next)
        let count = src.components(separatedBy: "TrackTable(").count - 1
        #expect(count == 3, "PlaybackQueueView must use TrackTable exactly 3 times, found \(count)")
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

    // MARK: - SidebarView

    @Test
    func sidebarView_rendersQueueAboveSettingsFooter() throws {
        let src = try readSource("MLM/Views/Sidebar/SidebarView.swift")
        // .queue row must appear before settingsFooter in the source
        guard let queueRange = src.range(of: ".queue"),
              let settingsRange = src.range(of: "settingsFooter") else {
            Issue.record("SidebarView must contain .queue and settingsFooter")
            return
        }
        #expect(queueRange.lowerBound < settingsRange.lowerBound,
                "SidebarView must render .queue above settingsFooter")
    }

    @Test
    func sidebarView_noPlaybackSectionHeader() throws {
        let src = try readSource("MLM/Views/Sidebar/SidebarView.swift")
        #expect(!src.contains("\"PLAYBACK\""),
                "SidebarView must not have a PLAYBACK List section — queue is a footer row")
    }

    @Test
    func sidebarView_queueFooterInSafeAreaInset() throws {
        let src = try readSource("MLM/Views/Sidebar/SidebarView.swift")
        #expect(src.contains("queueFooter"),
                "SidebarView must contain a queueFooter in the safeAreaInset")
        #expect(src.contains("safeAreaInset(edge: .bottom)"),
                "SidebarView must use safeAreaInset(edge: .bottom) for the footer area")
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
