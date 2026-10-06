import Testing
@testable import MLM

/// The playlist menus of the catalogue (UC §10.2 CM-SIDEBAR-PINNED, CM-PL-CARD, V-PLD.N01/menu,
/// V-PLD.E02/menu): one builder, subsets in the DEC-039 order (UC-CM-01/02).
@Suite struct PlaylistMenuModelTests {
    private func titles(_ sections: [[PlaylistMenuItem]]) -> [[String]] {
        sections.map { $0.map(PlaylistMenuModel.title) }
    }

    private let linkedWithGaps = PlaylistMenuModel.Facts(isLiked: false, hasCustomCover: true, isLinked: true,
                                                         refreshSource: "SoundCloud", notDownloaded: 12, failed: 3)

    @Test func sidebarRowMenu() {
        #expect(titles(PlaylistMenuModel.sections(.sidebarRow, facts: linkedWithGaps)) == [
            ["Play"], ["Play Next", "Add to Queue"], ["Add to Sync Profile"], ["Rename", "Move to Folder"],
            ["Download 12 Tracks", "Refresh from SoundCloud"], ["Show in All Playlists"], ["Delete Playlist…"],
        ])
    }

    @Test func cardMenu() {
        #expect(titles(PlaylistMenuModel.sections(.card, facts: linkedWithGaps)) == [
            ["Open", "Play"], ["Play Next", "Add to Queue"], ["Add to Sync Profile"],
            ["Rename", "Choose Cover…", "Use Automatic Cover", "Move to Folder"],
            ["Download 12 Tracks", "Show Failed Downloads", "Refresh from SoundCloud", "Change Link…"], ["Delete Playlist…"],
        ])
    }

    @Test func moreMenuOmitsTheHeaderButtonsAndAddsDetailOnlyCommands() {
        let local = PlaylistMenuModel.Facts()
        #expect(titles(PlaylistMenuModel.sections(.more, facts: local)) == [
            ["Play Next", "Add to Queue"], ["Add to Sync Profile"], ["Rename", "Choose Cover…", "Move to Folder"],
            ["Link Source…", "Import M3U into This Playlist…"], ["Export as M3U…"], ["Delete Playlist…"],
        ])
    }

    /// UC §23 C10: Delete is offered for the Liked playlist; it can't be linked.
    @Test func likedPlaylistCanBeDeletedButNotLinked() {
        let liked = PlaylistMenuModel.Facts(isLiked: true, isLinked: true, refreshSource: "SoundCloud")
        let items = PlaylistMenuModel.sections(.card, facts: liked).flatMap { $0 }
        #expect(items.contains(.delete))
        #expect(!items.contains(.link(isLinked: true)))
    }

    @Test func coverMenu() {
        #expect(titles(PlaylistMenuModel.sections(.cover, facts: PlaylistMenuModel.Facts())) == [["Choose Cover…"]])
        #expect(titles(PlaylistMenuModel.sections(.cover, facts: linkedWithGaps)) == [["Choose Cover…", "Use Automatic Cover"]])
    }

    @Test func noWordSyncForPlaylists() {
        let all = [PlaylistMenuPlace.sidebarRow, .card, .more, .cover]
            .flatMap { PlaylistMenuModel.sections($0, facts: linkedWithGaps).flatMap { $0 } }
            .map(PlaylistMenuModel.title)
        #expect(!all.contains { $0.contains("Sync to") || $0 == "Sync" || $0.contains("Pin") })
    }
}
