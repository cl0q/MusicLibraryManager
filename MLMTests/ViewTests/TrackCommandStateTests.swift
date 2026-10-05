import Testing
import Foundation
@testable import MLM

/// W1-2 track-selection contract: which Track-menu commands a selection enables and how they
/// are titled (UC-MENU-03, UC-KEY-14/17, UC-CM-07/08), plus the All Tracks visibility gate.
@Suite("Track command enabling and titles (W1-2)")
struct TrackCommandStateTests {

    private func track(_ id: Int64, local: Bool = true, failed: Bool = false, downloading: Bool = false) -> Track {
        var track = Track(artist: "Artist \(id)", album: "Album", title: "Title \(id)", format: "m4a",
                          originalPath: "source://\(id)")
        track.id = id
        track.organizedPath = local ? "Artist/Title \(id).m4a" : nil
        if failed { track.downloadStatus = "failed" }
        if downloading { track.downloadStatus = "downloading" }
        return track
    }

    private let full = TrackListCapabilities(canActivate: true, canRemoveFromContainer: true,
                                             canDeselect: true, canAddToSyncProfile: true)

    // MARK: Summary

    @Test func summaryCountsAvailabilityWithoutTheDisk() {
        let summary = TrackSelectionSummary(
            tracks: [track(1), track(2, local: false), track(3, local: false, failed: true), track(4, local: false, downloading: true)],
            container: .library
        )
        #expect(summary.count == 4)
        #expect(summary.localCount == 1)
        #expect(summary.notDownloadedCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.downloadableCount == 2, "a running download isn't offered again")
        #expect(summary.firstIsLocal)
    }

    // MARK: Enabling

    @Test func nothingIsEnabledWithoutASelection() {
        let none = TrackCommandState(summary: nil, capabilities: full, isDownloadBusy: false)
        let empty = TrackCommandState(summary: TrackSelectionSummary(), capabilities: full, isDownloadBusy: false)
        for state in [none, empty] {
            #expect(!state.canPlay && !state.canPlayNext && !state.canAddTo && !state.canGetInfo)
            #expect(!state.canDownload && !state.canShowInFinder && !state.canCopy)
            #expect(!state.canRemoveFromContainer && !state.canRemoveFromLibrary && !state.canDeselectAll)
            #expect(state.downloadTitle == "Download")
            #expect(state.removeFromContainerTitle == "Remove from Playlist")
        }
    }

    @Test func playNeedsAPlayableFirstTrackAndAListThatPlays() {
        let local = TrackSelectionSummary(count: 1, localCount: 1, firstIsLocal: true, container: .library)
        #expect(TrackCommandState(summary: local, capabilities: full, isDownloadBusy: false).canPlay)
        #expect(!TrackCommandState(summary: local, capabilities: TrackListCapabilities(), isDownloadBusy: false).canPlay)
        let remoteFirst = TrackSelectionSummary(count: 2, localCount: 1, notDownloadedCount: 1, firstIsLocal: false, container: .library)
        let state = TrackCommandState(summary: remoteFirst, capabilities: full, isDownloadBusy: false)
        #expect(!state.canPlay, "the first selected track has no file; Play would do nothing")
        #expect(state.canPlayNext, "Play Next queues the playable ones")
    }

    @Test func allTracksHasNothingToRemoveFrom() {
        let summary = TrackSelectionSummary(count: 3, localCount: 3, firstIsLocal: true, container: .library)
        let state = TrackCommandState(summary: summary, capabilities: full, isDownloadBusy: false)
        #expect(!state.canRemoveFromContainer, "⌫ does nothing in All Tracks (UC-KEY-17)")
        #expect(state.canRemoveFromLibrary)
        #expect(state.removeFromContainerTitle == "Remove from Playlist")
    }

    @Test func playlistRemovalNamesThePlaylist() {
        let summary = TrackSelectionSummary(count: 2, localCount: 2, firstIsLocal: true,
                                            container: .playlist(id: 7, name: "Warm-up"))
        let state = TrackCommandState(summary: summary, capabilities: full, isDownloadBusy: false)
        #expect(state.canRemoveFromContainer)
        #expect(state.removeFromContainerTitle == "Remove from “Warm-up”")
        let withoutRemoval = TrackCommandState(summary: summary, capabilities: TrackListCapabilities(canActivate: true),
                                               isDownloadBusy: false)
        #expect(!withoutRemoval.canRemoveFromContainer, "a list that can't remove keeps the item disabled")
    }

    @Test func queueAndSyncProfileOfferNoRemoveFromLibrary() {
        for container in [TrackListContainer.queue, .syncProfile(id: 1, name: "iPod Classic")] {
            let summary = TrackSelectionSummary(count: 1, localCount: 1, firstIsLocal: true, container: container)
            let state = TrackCommandState(summary: summary, capabilities: full, isDownloadBusy: false)
            #expect(!state.canRemoveFromLibrary, "UC-CM-07")
            #expect(state.canRemoveFromContainer)
        }
        #expect(TrackCommandState.removeTitle(.queue) == "Remove from Queue")
        #expect(TrackCommandState.removeTitle(.syncProfile(id: 1, name: "iPod Classic")) == "Remove from “iPod Classic”")
    }

    @Test func fileActionsNeedAFile() {
        let remote = TrackSelectionSummary(count: 2, notDownloadedCount: 2, container: .library)
        let state = TrackCommandState(summary: remote, capabilities: full, isDownloadBusy: false)
        #expect(!state.canShowInFinder)
        #expect(!state.canCopyFilePath)
        #expect(state.canCopy, "Copy ▸ Title — Artist works without a file")
        #expect(!state.canPlayNext)
    }

    // MARK: Download

    @Test func downloadTitleAdapts() {
        #expect(TrackCommandState.downloadTitle(TrackSelectionSummary(count: 1, notDownloadedCount: 1)) == "Download")
        #expect(TrackCommandState.downloadTitle(TrackSelectionSummary(count: 1, failedCount: 1)) == "Retry Download")
        #expect(TrackCommandState.downloadTitle(TrackSelectionSummary(count: 3, notDownloadedCount: 2, failedCount: 1)) == "Download 3 Tracks")
        #expect(TrackCommandState.downloadTitle(TrackSelectionSummary(count: 4, localCount: 4)) == "Download")
    }

    @Test func downloadIsDisabledWhenNothingIsMissingOrABatchRuns() {
        let local = TrackSelectionSummary(count: 2, localCount: 2, firstIsLocal: true)
        #expect(!TrackCommandState(summary: local, capabilities: full, isDownloadBusy: false).canDownload)
        let missing = TrackSelectionSummary(count: 2, notDownloadedCount: 2)
        #expect(TrackCommandState(summary: missing, capabilities: full, isDownloadBusy: false).canDownload)
        let busy = TrackCommandState(summary: missing, capabilities: full, isDownloadBusy: true)
        #expect(!busy.canDownload)
        #expect(busy.downloadDisabledReason == TrackCommandState.downloadBusyReason)
    }

    // MARK: Selection

    @Test func selectedTracksFollowDisplayOrder() {
        let rows = [track(3), track(1), track(2)]
        let selection = TrackSelection(selectedIDs: [2, 3], rows: rows, context: .unnamed, target: TrackCommandTarget())
        #expect(selection.selectedTracks.compactMap(\.id) == [3, 2])
        #expect(TrackSelection(selectedIDs: [], rows: rows, context: .unnamed, target: TrackCommandTarget()).selectedTracks.isEmpty)
    }

    @Test func hiddenAllTracksTableDoesNotAct() {
        let all = TrackSelection(selectedIDs: [1], rows: [track(1)], context: .allTracks, target: TrackCommandTarget())
        #expect(all.usable(allTracksVisible: true) != nil)
        #expect(all.usable(allTracksVisible: false) == nil, "the kept-alive table keeps focus while another place shows")
        let playlist = TrackSelection(selectedIDs: [1], rows: [track(1)], context: .playlist(id: 1, name: "Warm-up"),
                                      target: TrackCommandTarget())
        #expect(playlist.usable(allTracksVisible: false) != nil)
        #expect(TrackListContext.playlist(id: 1, name: "Warm-up").viewName == "“Warm-up”")
    }

    // MARK: Cheap publishing (review S3)

    @Test func publisherComputesTheSummaryOnceFromTheSelectedRows() {
        let rows = [track(3, local: false), track(1), track(2, local: false, failed: true)]
        let selection = TrackSelection(selectedIDs: [2, 1], rows: rows, context: .playlist(id: 9, name: "Warm-up"),
                                       target: TrackCommandTarget())
        #expect(selection.summary.count == 2)
        #expect(selection.summary.localCount == 1)
        #expect(selection.summary.failedCount == 1)
        #expect(selection.summary.firstID == 1, "display order: 1 comes before 2")
        #expect(selection.summary.firstIsLocal)
        #expect(selection.summary.container == .playlist(id: 9, name: "Warm-up"))
        #expect(selection.hasPlayableRows)
        let remoteOnly = TrackSelection(selectedIDs: [], rows: [track(4, local: false)], context: .unnamed,
                                        target: TrackCommandTarget())
        #expect(!remoteOnly.hasPlayableRows)
        #expect(remoteOnly.summary == TrackSelectionSummary(container: .none))
    }

    @Test func rowsAreProducedOnlyWhenAnActionAsks() {
        var produced = 0
        let rows = [track(1), track(2)]
        let selection = TrackSelection(selectedIDs: [2], rows: rows, id: { $0.id ?? -1 }, isPlayable: \.isLocal,
                                       track: { produced += 1; return $0 }, context: .unnamed, target: TrackCommandTarget())
        #expect(produced == 1, "only the one selected track is copied while publishing")
        _ = selection.summary
        _ = selection.hasPlayableRows
        #expect(produced == 1, "enabling reads no rows")
        #expect(selection.rows.count == 2)
        #expect(produced == 3)
    }

    @Test func equalityIgnoresClosuresButSeesRowChanges() {
        let a = TrackSelection(selectedIDs: [1], rows: [track(1), track(2)], context: .unnamed,
                               target: TrackCommandTarget(activate: { _, _ in }))
        let same = TrackSelection(selectedIDs: [1], rows: [track(1), track(2)], context: .unnamed,
                                  target: TrackCommandTarget())
        #expect(a == same, "an unchanged selection doesn't re-run the menus")
        let reordered = TrackSelection(selectedIDs: [1], rows: [track(2), track(1)], context: .unnamed,
                                       target: TrackCommandTarget())
        #expect(a != reordered, "a re-sorted list never leaves actions with stale rows")
        let other = TrackSelection(selectedIDs: [2], rows: [track(1), track(2)], context: .unnamed,
                                   target: TrackCommandTarget())
        #expect(a != other)
    }

    @Test func disabledRemoveExplainsItselfWithoutPackageNames() {
        for container in [TrackListContainer.library, .queue, .none, .playlist(id: 1, name: "A"), .syncProfile(id: 1, name: "B")] {
            let reason = TrackCommandState.removeDisabledReason(container)
            #expect(reason.hasSuffix(".") && !reason.hasSuffix("…."))
            #expect(reason.range(of: #"W\d-"#, options: .regularExpression) == nil)
        }
        #expect(TrackCommandState.removeDisabledReason(.queue) == "Select tracks under Next to remove them from the queue.")
    }

    @Test @MainActor func playbackViewTitlesNameOnlyAKnownList() {
        #expect(PlayableList.title("Shuffle", nil) == "Shuffle")
        #expect(PlayableList.title("Play", nil) == "Play")
        let list = PlayableList(name: "“Warm-up”", canPlay: true, rows: { [] }, selected: { [] }, activate: { _, _ in })
        #expect(PlayableList.title("Shuffle", list) == "Shuffle “Warm-up”")
    }

    @Test func capabilitiesComeFromTheTarget() {
        let target = TrackCommandTarget(activate: { _, _ in }, removeFromContainer: nil, deselectAll: {})
        #expect(TrackListCapabilities(target) == TrackListCapabilities(canActivate: true, canDeselect: true))
    }

    @Test func copyLinesAreTitleDashArtist() async {
        let lines = await TrackCommandActions.titleArtistLines([track(1), track(2)])
        #expect(lines == "Title 1 — Artist 1\nTitle 2 — Artist 2")
    }
}

/// ⌘R — one concept, titled per place (UC-KEY-15, M-TRACK.N12).
@Suite("Refresh from Source per place (W1-2)")
struct RereadCommandTests {
    @Test func placesResolveToTheirReread() {
        #expect(RereadCommand.resolve(selection: .allTracks, route: nil, isSearching: false) == .scanLibraryFolder)
        #expect(RereadCommand.resolve(selection: .albums, route: nil, isSearching: false) == .scanLibraryFolder)
        #expect(RereadCommand.resolve(selection: .genres, route: nil, isSearching: false) == .scanLibraryFolder)
        #expect(RereadCommand.resolve(selection: .folders, route: nil, isSearching: false) == .scanThisFolder)
        #expect(RereadCommand.resolve(selection: .playlist(4), route: nil, isSearching: false) == .refreshPlaylist(4))
        #expect(RereadCommand.resolve(selection: .allPlaylists, route: .playlist(9), isSearching: false) == .refreshPlaylist(9))
        #expect(RereadCommand.resolve(selection: .syncProfile(2), route: nil, isSearching: false) == .recomputePlan(2))
        #expect(RereadCommand.resolve(selection: .review, route: nil, isSearching: false) == .runScan)
        #expect(RereadCommand.resolve(selection: .discover, route: nil, isSearching: false) == .none)
        #expect(RereadCommand.resolve(selection: .allPlaylists, route: nil, isSearching: false) == .none)
        #expect(RereadCommand.resolve(selection: .allTracks, route: .album(1), isSearching: false) == .none)
        #expect(RereadCommand.resolve(selection: .allTracks, route: nil, isSearching: true) == .none)
    }

    @Test func titlesNameTheAction() {
        #expect(RereadCommand.scanLibraryFolder.title() == "Scan Library Folder")
        #expect(RereadCommand.scanThisFolder.title() == "Scan This Folder")
        #expect(RereadCommand.refreshPlaylist(1).title(sourceName: "SoundCloud") == "Refresh from SoundCloud")
        #expect(RereadCommand.refreshPlaylist(1).title() == "Refresh from Source")
        #expect(RereadCommand.recomputePlan(1).title() == "Recompute Plan")
        #expect(RereadCommand.runScan.title() == "Run Scan")
        #expect(RereadCommand.none.title() == "Refresh from Source")
        #expect(RereadCommand.scanThisFolder.pendingOwner == "W3-FOLD")
        #expect(RereadCommand.runScan.pendingOwner == "W3-REV")
    }
}

/// Playback ▸ Volume Up / Down and Skip ±10 s (UC-KEY-08/09).
@Suite("Playback menu steps (W1-2)")
struct PlaybackStepTests {
    @Test func volumeMovesInTenthsAndStaysInRange() {
        #expect(PlaybackStep.volume(after: 0.5, up: true) == 0.6)
        #expect(PlaybackStep.volume(after: 0.5, up: false) == 0.4)
        #expect(PlaybackStep.volume(after: 1.0, up: true) == 1.0)
        #expect(PlaybackStep.volume(after: 0.0, up: false) == 0.0)
        #expect(abs(PlaybackStep.volume(after: 0.73, up: true) - 0.8) < 0.000_1, "snaps to the grid")
        #expect(PlaybackStep.skipSeconds == 10)
    }

    @Test @MainActor func volumeIsSharedAndClamped() {
        // The volume is remembered between launches (W2-C): use a throwaway defaults suite, never
        // the test runner's standard defaults.
        let env = PlaybackTestEnvironment()
        let playback = PlaybackViewModel(audioPlayer: MockAudioPlayerForMenus(), environment: env.environment)
        #expect(playback.volume == 1.0)
        playback.setVolume(1.4)
        #expect(playback.volume == 1.0)
        playback.setVolume(-0.2)
        #expect(playback.volume == 0.0)
        playback.setVolume(PlaybackStep.volume(after: playback.volume, up: true))
        #expect(abs(playback.volume - 0.1) < 0.000_1)
    }
}

@MainActor
private final class MockAudioPlayerForMenus: AudioPlayerControlling {
    var state: AudioPlayer.PlaybackState = .stopped
    var duration: TimeInterval = 0
    var currentPosition: TimeInterval = 0
    private(set) var volumes: [Float] = []
    func loadFile(at url: URL) throws {}
    func play() throws {}
    func pause() {}
    func togglePlayPause() throws {}
    func stop() {}
    func seek(to position: TimeInterval) throws {}
    func setVolume(_ volume: Float) { volumes.append(volume) }
    func applyLUFSCompensation(lufsI: Double?) {}
}
