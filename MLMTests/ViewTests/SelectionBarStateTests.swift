import Foundation
import Testing
@testable import MLM

// MARK: - Fixtures

@MainActor
private enum SelectionBarFixtures {
    static let offline = TrackTableLiveState(offlineVolumePath: "/Volumes/Lexxar", offlineVolumeName: "Lexxar")

    enum Kind { case local, notDownloaded, failed, missing }

    static func track(_ id: Int64, _ kind: Kind = .local, duration: Int? = 200) -> Track {
        var track = Track(artist: "Artist \(id)", album: "Album", title: "Title \(id)", format: "m4a",
                          originalPath: "https://soundcloud.com/a/\(id)")
        track.id = id
        track.duration = duration
        switch kind {
        case .local:
            track.organizedPath = "A/\(id).m4a"
        case .notDownloaded:
            track.organizedPath = nil
        case .failed:
            track.organizedPath = nil
            track.downloadStatus = "failed"
        case .missing:
            track.organizedPath = "A/\(id).m4a"
            track.fileMissingSince = "2026-10-05T10:00:00Z"
        }
        return track
    }

    static func rows(_ kinds: [Kind], duration: Int? = 200) -> [TrackRow] {
        TrackRowBuilder.build(kinds.enumerated().map { track(Int64($0.offset + 1), $0.element, duration: duration) })
    }

    static func context(_ container: TrackListContainer = .library, remove: Bool = false) -> TrackMenuContext {
        TrackMenuContext(container: container, canActivate: true, canRemoveFromContainer: remove, canAddToSyncProfile: true)
    }

    static func state(
        _ kinds: [Kind],
        container: TrackListContainer = .library,
        live: TrackTableLiveState = .idle,
        busy: Bool = false,
        info: Bool = true
    ) -> SelectionBarState? {
        SelectionBarState.make(rows: rows(kinds), context: context(container, remove: container != .library),
                               live: live, isDownloadBusy: busy, canShowInfo: info)
    }
}

// MARK: - What the bar shows (UC-SELBAR-01/02)

/// The selection bar's pure model (W2-G): when it shows, its text, its actions in order and
/// their enabling for every availability mix, container and drive state.
@Suite("SelectionBarStateTests")
@MainActor
struct SelectionBarStateTests {
    private typealias F = SelectionBarFixtures

    @Test func showsOnlyWithTwoOrMoreShownRows() {
        #expect(F.state([]) == nil)
        #expect(F.state([.local]) == nil, "one selected row: no bar (UC-SELBAR-01)")
        #expect(F.state([.local, .local]) != nil)
        #expect(SelectionBarState.minimumCount == 2)
    }

    @Test func neverInTheQueue() {
        #expect(F.state([.local, .local, .local], container: .queue) == nil, "UC-SELBAR-05")
    }

    @Test func countDurationAndVoiceOverText() throws {
        let state = try #require(F.state([.local, .local, .notDownloaded]))
        #expect(state.count == 3)
        #expect(state.countText == "3 selected")
        #expect(state.durationText == "10 min", "3 × 200 s")
        #expect(state.accessibilityLabel == "Selection actions, 3 tracks selected")
    }

    @Test func largeCountsUseThousandsSeparators() throws {
        let kinds = Array(repeating: F.Kind.local, count: 1_234)
        let state = try #require(SelectionBarState.make(
            rows: F.rows(kinds, duration: 120), context: F.context(), live: .idle, isDownloadBusy: false, canShowInfo: true))
        #expect(state.countText == "\(1_234.formatted(.number)) selected")
        #expect(state.accessibilityLabel == "Selection actions, \(1_234.formatted(.number)) tracks selected")
        #expect(state.durationText == "2 days", "1,234 × 2 min ≈ 41 h")
    }

    @Test func unknownDurationsCountAsZero() throws {
        let state = try #require(SelectionBarState.make(
            rows: F.rows([.local, .local], duration: nil), context: F.context(), live: .idle,
            isDownloadBusy: false, canShowInfo: true))
        #expect(state.durationText == "0 min")
    }

    @Test func actionsInDesignOrder() throws {
        let all = try #require(F.state([.local, .notDownloaded]))
        #expect(all.actions.map(\.id) == [.playNext, .addToPlaylist, .editInfo, .download, .more])
        #expect(all.actions.map(\.title) == ["Play Next", "Add to Playlist", "Edit Info", "Download", "More"])
        let localOnly = try #require(F.state([.local, .local]))
        #expect(localOnly.actions.map(\.id) == [.playNext, .addToPlaylist, .editInfo, .more],
                "Download only when something needs downloading")
    }

    @Test func everyControlHasASymbolAndAHelpText() throws {
        let state = try #require(F.state([.local, .failed]))
        for action in state.actions {
            #expect(!action.systemImage.isEmpty, "\(action.title) collapses to a symbol when narrow")
            #expect(!action.help.isEmpty, "\(action.title) has a tooltip (UC-A11Y-02)")
        }
        #expect(state.playNext.help == "Play Next ⌥↩")
        #expect(state.editInfo.help == "Edit Info ⌘I")
    }

    // MARK: Availability mix

    @Test func playNextNeedsAFileThatCanPlay() throws {
        let mixed = try #require(F.state([.notDownloaded, .local]))
        #expect(mixed.playNext.isEnabled, "the playable ones are queued")
        let none = try #require(F.state([.notDownloaded, .failed, .missing]))
        #expect(!none.playNext.isEnabled)
        #expect(none.playNext.help == SelectionBarState.noPlayableReason)
        #expect(none.playNext.help.hasSuffix("."), "help text is a sentence (UC-COPY-04)")
    }

    @Test func downloadCountsNotDownloadedAndFailed() throws {
        let one = try #require(F.state([.local, .failed]))
        let download = try #require(one.download)
        #expect(download.isEnabled)
        #expect(download.title == "Download")
        #expect(download.help == "Retry Download ⌘D")
        let nine = try #require(F.state(Array(repeating: .notDownloaded, count: 6) + Array(repeating: .failed, count: 3) + [.local]))
        #expect(nine.download?.help == "Download 9 Tracks ⌘D", "a mixed selection downloads the 9 that need it")
        #expect(F.state([.local, .missing])?.download == nil, "File missing is not downloadable here")
    }

    @Test func downloadIsDisabledWhileAnotherBatchRuns() throws {
        let state = try #require(F.state([.notDownloaded, .notDownloaded], busy: true))
        let download = try #require(state.download)
        #expect(!download.isEnabled)
        #expect(download.help == TrackCommandState.downloadBusyReason)
    }

    @Test func addToPlaylistAndMoreAreAlwaysEnabled() throws {
        for kinds: [F.Kind] in [[.local, .local], [.notDownloaded, .failed], [.missing, .missing]] {
            let state = try #require(F.state(kinds))
            #expect(state.addToPlaylist.isEnabled && state.more.isEnabled)
        }
    }

    @Test func editInfoNeedsTheInfoColumn() throws {
        #expect(try #require(F.state([.local, .local])).editInfo.isEnabled)
        let without = try #require(F.state([.local, .local], info: false))
        #expect(!without.editInfo.isEnabled)
        #expect(without.editInfo.help == SelectionBarState.noInfoReason)
    }

    // MARK: Drive not connected (UC-CM-05, §15.2)

    @Test func driveAwayDisablesFileActionsWithItsName() throws {
        let state = try #require(F.state([.local, .local, .missing], live: F.offline))
        #expect(!state.playNext.isEnabled)
        #expect(state.playNext.help == "“Lexxar” is not connected")
        #expect(state.addToPlaylist.isEnabled && state.editInfo.isEnabled, "browse and edit keep working")
        // Inside More: the file actions are there, disabled, under the drive header.
        let items = state.moreMenu.items
        #expect(items.contains(.driveHeader(volumeName: "Lexxar")))
        #expect(items.contains(.showInFinder(enabled: false)))
        #expect(items.contains(.removeFromLibrary(enabled: false)))
    }

    @Test func driveAwayStillQueuesDownloads() throws {
        let state = try #require(F.state([.local, .notDownloaded], live: F.offline))
        #expect(state.download?.isEnabled == true, "downloads are queued while the drive is away (UC-CM-05)")
        #expect(!state.playNext.isEnabled)
    }

    // MARK: More (•••)

    @Test func moreIsTheTrackMenuWithoutTheBarsActions() throws {
        let rows = F.rows([.local, .notDownloaded, .failed])
        let context = F.context(.playlist(id: 7, name: "Warm-up"), remove: true)
        let state = try #require(SelectionBarState.make(rows: rows, context: context, live: .idle,
                                                        isDownloadBusy: false, canShowInfo: true))
        let full = TrackMenuModel.make(subject: TrackMenuSubject(rows: rows, live: .idle), context: context)
        #expect(state.moreMenu.items == full.items.filter { !$0.isSelectionBarAction }, "a subset, never a reordering")
        for item in state.moreMenu.items {
            switch item {
            case .playNext, .addToPlaylist, .getInfo, .download: Issue.record("\(item) is a bar button")
            default: break
            }
        }
        #expect(state.moreMenu.items.first == .countHeader(3), "≥ 2 subjects: count header first (UC-CM-04)")
        #expect(state.moreMenu.items.contains(.removeFromContainer(title: "Remove from Playlist")))
        #expect(state.moreMenu.items.last == .removeFromLibrary(enabled: true), "irreversible item last (UC-CM-07)")
        #expect(!state.moreMenu.sections.contains { $0.isEmpty }, "emptied groups disappear")
    }

    @Test func moreInAllTracksHasNoContainerRemoval() throws {
        let state = try #require(F.state([.local, .local]))
        #expect(!state.moreMenu.items.contains { if case .removeFromContainer = $0 { true } else { false } })
        #expect(state.moreMenu.items.contains(.removeFromLibrary(enabled: true)))
    }

    @Test func addToPlaylistLeavesOutTheCurrentPlaylist() {
        let a = Playlist(id: 7, name: "Warm-up", description: nil, category: "native", isLiked: 0, isSmart: 0, isPinned: 0)
        let b = Playlist(id: 8, name: "Sets", description: nil, category: "native", isLiked: 0, isSmart: 0, isPinned: 0)
        #expect(SelectionBarState.playlists([a, b], for: .playlist(id: 7, name: "Warm-up")).map(\.name) == ["Sets"])
        #expect(SelectionBarState.playlists([a, b], for: .library).map(\.name) == ["Warm-up", "Sets"])
    }
}

// MARK: - Which table drives the bar (adoption)

/// The bar of a scaffold follows only a table the user can see (W2-G): the kept-alive All
/// Tracks table never drives it while another place shows or the search pane covers it.
@Suite("SelectionBarVisibilityTests")
@MainActor
struct SelectionBarVisibilityTests {
    @Test func hiddenAllTracksTableNeverDrivesTheBar() {
        let allTracks = TrackListContext.allTracks
        #expect(TrackSelectionBarVisibility.isShown(host: .place, list: allTracks, allTracksVisible: true, isSearching: false))
        #expect(!TrackSelectionBarVisibility.isShown(host: .place, list: allTracks, allTracksVisible: false, isSearching: false),
                "another place shows")
        #expect(!TrackSelectionBarVisibility.isShown(host: .place, list: allTracks, allTracksVisible: true, isSearching: true),
                "the search pane covers All Tracks")
    }

    @Test func placesGiveWayToTheSearchPane() {
        let playlist = TrackListContext.playlist(id: 1, name: "Warm-up")
        #expect(TrackSelectionBarVisibility.isShown(host: .place, list: playlist, allTracksVisible: false, isSearching: false))
        #expect(!TrackSelectionBarVisibility.isShown(host: .place, list: playlist, allTracksVisible: false, isSearching: true))
    }

    @Test func searchResultsShowOnlyWhileSearching() {
        #expect(TrackSelectionBarVisibility.isShown(host: .searchResults, list: .unnamed, allTracksVisible: true, isSearching: true))
        #expect(!TrackSelectionBarVisibility.isShown(host: .searchResults, list: .unnamed, allTracksVisible: true, isSearching: false))
    }

    @Test func theQueueNeverDrivesTheBar() {
        for host in [TrackSelectionBarHost.place, .searchResults] {
            for searching in [false, true] {
                #expect(!TrackSelectionBarVisibility.isShown(host: host, list: .queue, allTracksVisible: true, isSearching: searching))
            }
        }
    }

    @Test func channelFollowsTheTableThatRegisteredLast() {
        let channel = TrackSelectionBarChannel()
        let first = TrackListModel()
        let second = TrackListModel()
        let live = TrackTableLive()
        let configuration = TrackListConfiguration.searchResults(activate: nil)
        #expect(channel.source == nil)
        channel.register(TrackSelectionBarSource(model: first, configuration: configuration, live: live))
        #expect(channel.source?.model === first)
        // A replacing table (a playlist re-opened) appears before the old one disappears.
        channel.register(TrackSelectionBarSource(model: second, configuration: configuration, live: live))
        channel.unregister(first)
        #expect(channel.source?.model === second, "the old table's disappearance leaves the new one")
        channel.unregister(second)
        #expect(channel.source == nil)
    }

    @Test func selectedRowsAreTheShownOnesInDisplayOrder() async {
        // The bar acts on `selectedRows()`: a selected row a filter hides is not acted on.
        let model = TrackListModel()
        let tracks = (1...4).map { SelectionBarFixtures.track(Int64($0)) }
        await model.setTracks(tracks, visibleIDs: [1, 3, 4])
        model.selection = [4, 2, 1]
        #expect(model.selectedRows().map(\.id) == [1, 4])
        let state = SelectionBarState.make(rows: model.selectedRows(), context: SelectionBarFixtures.context(),
                                           live: .idle, isDownloadBusy: false, canShowInfo: true)
        #expect(state?.count == 2)
        model.selection = [2, 3]
        #expect(SelectionBarState.make(rows: model.selectedRows(), context: SelectionBarFixtures.context(),
                                       live: .idle, isDownloadBusy: false, canShowInfo: true) == nil,
                "only one of the two selected rows is shown")
    }
}
