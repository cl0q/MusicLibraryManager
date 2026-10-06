import Foundation
import Testing
@testable import MLM

/// The shared track table's pure parts (W2-A): row presentation, the album rule (DEC-013),
/// status words, dimming, primary action (UC-PRIM), the track menu (DEC-039) and sorting.
@Suite("TrackListComponentTests")
@MainActor
struct TrackListComponentTests {

    // MARK: - Fixtures

    private static let failureJSON = try! TrackDownloadFailure(
        reason: "Source timed out", date: Date(timeIntervalSince1970: 1_720_000_000), attempts: 2
    ).encodedJSON()

    private func track(
        _ id: Int64,
        title: String = "Song",
        artist: String = "Artist",
        album: String = "Album",
        path: String? = "A/song.m4a",
        missing: Bool = false,
        status: String? = nil,
        failure: String? = nil,
        original: String = "https://soundcloud.com/a/b",
        duration: Int? = 200
    ) -> Track {
        var track = Track(artist: artist, album: album, title: title, format: "m4a", originalPath: original)
        track.id = id
        track.organizedPath = path
        track.fileMissingSince = missing ? "2026-10-05T10:00:00Z" : nil
        track.downloadStatus = status
        track.downloadFailure = failure
        track.duration = duration
        return track
    }

    private func row(_ track: Track) -> TrackRow {
        TrackRowBuilder.build([track])[0]
    }

    private let offline = TrackTableLiveState(offlineVolumePath: "/Volumes/Lexxar", offlineVolumeName: "Lexxar")

    // MARK: - Album rule (DEC-013, UC-TABLE-11)

    @Test(arguments: [
        "unknown album", "Unknown Album", " unknown album ", "SoundCloud", "YouTube", "Downloads", "Web",
        "Unknown", "", "   ", "SoundCloud Likes", "soundcloud likes", "https://youtube.com/watch?v=x",
        "http://example.com", "Discovered Neighbors", "Reels Inbox Imports",
    ])
    func notAnAlbum(_ literal: String) {
        #expect(!TrackMetadataPresentation.isRealAlbum(literal))
        #expect(TrackMetadataPresentation.albumDisplay(literal) == nil)
    }

    @Test(arguments: ["Discovery", "Unknown Pleasures", "The Downloads", "german top100 single charts", "YouTube Hits 2020"])
    func realAlbums(_ album: String) {
        #expect(TrackMetadataPresentation.isRealAlbum(album))
        #expect(TrackMetadataPresentation.albumDisplay(album) == album)
    }

    @Test func absentValuesRenderAsDash() {
        let built = row(track(1, artist: "Unknown", album: "unknown album", duration: nil))
        #expect(built.albumText == nil)
        #expect(built.artistText == nil)
        #expect(built.timeText == nil)
        #expect(built.bpmText == nil)
        #expect(built.energyLevel == nil)
        #expect(TrackMetadataPresentation.artistDisplay("Unknown Artist") == nil)
        #expect(TrackMetadataPresentation.artistDisplay("Björk") == "Björk")
    }

    // MARK: - Status column and dimming (UC-TABLE-10/12, DEC-014, DEC-051, N17)

    @Test func statusWordsPerState() {
        let idle = TrackTableLiveState.idle
        #expect(TrackRowPresentation(row: row(track(1)), live: idle).status == nil)
        #expect(TrackRowPresentation(row: row(track(2, path: nil)), live: idle).status?.text == "Not downloaded")
        #expect(TrackRowPresentation(row: row(track(3, path: nil, status: "downloading")), live: idle).status?.text == "Downloading…")
        let failed = TrackRowPresentation(row: row(track(4, path: nil, failure: Self.failureJSON)), live: idle)
        #expect(failed.status?.text == "Download failed")
        #expect(failed.status?.tint == .attention)
        let missing = TrackRowPresentation(row: row(track(5, missing: true)), live: idle)
        #expect(missing.status?.text == "File missing")
        #expect(missing.status?.tint == .error)
        // In-memory download state shows Downloading… for a queued row.
        let queued = TrackTableLiveState(activeDownloadIDs: [2])
        #expect(TrackRowPresentation(row: row(track(2, path: nil)), live: queued).status == .downloading)
    }

    @Test func driveAwayDimsLocalRowsAndNeverSaysFileMissing() {
        let local = TrackRowPresentation(row: row(track(1)), live: offline)
        #expect(local.isDimmed)
        #expect(local.status == nil)
        let missing = TrackRowPresentation(row: row(track(2, missing: true)), live: offline)
        #expect(missing.isDimmed)
        #expect(missing.status == nil, "never File missing because of the drive")
        // Not downloaded / failed rows keep their word and are not dimmed (DEC-051).
        let remote = TrackRowPresentation(row: row(track(3, path: nil)), live: offline)
        #expect(!remote.isDimmed)
        #expect(remote.status?.text == "Not downloaded")
        let failed = TrackRowPresentation(row: row(track(4, path: nil, failure: Self.failureJSON)), live: offline)
        #expect(!failed.isDimmed)
        #expect(failed.status?.text == "Download failed")
        // A file on another disk is not affected.
        let elsewhere = TrackRowPresentation(row: row(track(5, path: "/Users/o/Music/x.m4a")), live: offline)
        #expect(!elsewhere.isDimmed)
        let sameDisk = TrackRowPresentation(row: row(track(6, path: "/Volumes/Lexxar/Other/x.m4a")), live: offline)
        #expect(sameDisk.isDimmed)
    }

    @Test func placeholderArtworkOnlyWithoutAFile() {
        #expect(TrackRowPresentation(row: row(track(1, path: nil)), live: .idle).showsPlaceholderArtwork)
        #expect(!TrackRowPresentation(row: row(track(2)), live: .idle).showsPlaceholderArtwork)
        #expect(!TrackRowPresentation(row: row(track(3, missing: true)), live: .idle).showsPlaceholderArtwork)
    }

    @Test func nowPlayingIsTheCurrentTrackEvenWhilePaused() {
        let live = TrackTableLiveState(nowPlayingID: 7, isPlaying: false)
        #expect(TrackRowPresentation(row: row(track(7)), live: live).isNowPlaying)
        #expect(!TrackRowPresentation(row: row(track(8)), live: live).isNowPlaying)
    }

    @Test func failureDetailIsReasonAndAttemptsLeft() {
        let built = row(track(1, path: nil, failure: Self.failureJSON))
        // The stored reason in plain words (W2-B, `DownloadFailureReasonText`).
        #expect(built.failureDetail == "The source didn’t answer · 1 attempt left")
        #expect(row(track(2)).failureDetail == nil)
    }

    // MARK: - Primary action (UC-PRIM-01…04)

    @Test func primaryActionPerRowKind() {
        let idle = TrackTableLiveState.idle
        #expect(TrackPrimaryAction.resolve(row: row(track(1)), live: idle) == .play)
        #expect(TrackPrimaryAction.resolve(row: row(track(2, path: nil)), live: idle) == .download)
        #expect(TrackPrimaryAction.resolve(row: row(track(3, path: nil, failure: Self.failureJSON)), live: idle) == .download)
        #expect(TrackPrimaryAction.resolve(row: row(track(4, path: nil, status: "downloading")), live: idle) == .awaitDownload)
        #expect(TrackPrimaryAction.resolve(row: row(track(5, path: nil)), live: TrackTableLiveState(activeDownloadIDs: [5])) == .awaitDownload)
        #expect(TrackPrimaryAction.resolve(row: row(track(6, missing: true)), live: idle) == .fileMissing)
        #expect(TrackPrimaryAction.resolve(row: row(track(7)), live: offline) == .driveNotConnected(volumeName: "Lexxar"))
        #expect(TrackPrimaryAction.resolve(row: row(track(8, missing: true)), live: offline) == .driveNotConnected(volumeName: "Lexxar"))
        #expect(TrackPrimaryAction.resolve(row: row(track(9, path: nil)), live: offline) == .download)
    }

    @Test func primaryActionWording() {
        #expect(TrackPrimaryAction.downloadingMessage(title: "Warm Night") == "Downloading “Warm Night” — it will play when it’s ready")
        #expect(TrackPrimaryAction.driveNotConnectedMessage("Lexxar") == "Can’t play — “Lexxar” is not connected.")
        #expect(TrackPrimaryAction.fileMissingMessage == "File missing")
        #expect(TrackPrimaryAction.downloadStartedMessage(count: 44) == "Download started — 44 tracks")
        #expect(PlaylistTrackRemoval.message(count: 9, playlist: "Warm-up") == "Removed 9 tracks from “Warm-up” — the files stay in the library")
        #expect(PlaylistTrackRemoval.actionName(playlist: "Warm-up") == "Remove from “Warm-up”")
    }

    // MARK: - Track menu (CM-TRACK, DEC-039)

    private let library = TrackMenuContext(container: .library, canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true)
    private let playlist = TrackMenuContext(container: .playlist(id: 1, name: "Warm-up"), canActivate: true, canRemoveFromContainer: true, canAddToSyncProfile: true)
    private let queue = TrackMenuContext(container: .queue, canActivate: true, canRemoveFromContainer: false, canAddToSyncProfile: true)

    private func menu(_ tracks: [Track], _ context: TrackMenuContext, live: TrackTableLiveState = .idle) -> TrackMenuModel {
        TrackMenuModel.make(subject: TrackMenuSubject(rows: TrackRowBuilder.build(tracks), live: live), context: context)
    }

    @Test func localTrackInTheLibraryFollowsTheGroupOrder() {
        let model = menu([track(1)], library)
        #expect(model.sections == [
            [.play(enabled: true), .preview(enabled: true)],
            [.playNext, .addToQueue],
            [.addToPlaylist, .addToSyncProfile],
            [.getInfo, .goToArtist("Artist"), .findSimilar],
            [.showInFinder(enabled: true), .copy(filePath: true, link: true), .share(enabled: true)],
            [.removeFromLibrary(enabled: true)],
        ])
    }

    /// Go to Artist (W2-I): one track with a real artist; never several, never `Unknown Artist`.
    @Test func goToArtistNeedsOneTrackWithAnArtist() {
        #expect(menu([track(1, artist: "Overmono")], library).items.contains(.goToArtist("Overmono")))
        #expect(!menu([track(1, artist: "Unknown Artist")], library).items.contains { if case .goToArtist = $0 { true } else { false } })
        #expect(!menu([track(1), track(2)], library).items.contains { if case .goToArtist = $0 { true } else { false } })
    }

    @Test func localTrackInAPlaylistHasTheReversibleRemovalFirst() {
        let model = menu([track(1)], playlist)
        #expect(model.sections.last == [.removeFromContainer(title: "Remove from Playlist"), .removeFromLibrary(enabled: true)])
    }

    @Test func queueRowsHaveNoRemoveFromLibrary() {
        let items = menu([track(1)], queue).items
        #expect(!items.contains(.removeFromLibrary(enabled: true)))
        #expect(!items.contains { if case .removeFromContainer = $0 { true } else { false } })
    }

    @Test func notDownloadedFailedAndMissingVariants() throws {
        let notDownloaded = menu([track(1, path: nil)], library).items
        #expect(notDownloaded.first == .play(enabled: true))
        #expect(notDownloaded.contains(.download(title: "Download")))
        #expect(!notDownloaded.contains(.playNext), "Play Next only queues playable files")
        #expect(!notDownloaded.contains { if case .showInFinder = $0 { true } else { false } })
        #expect(notDownloaded.contains(.copy(filePath: false, link: true)))

        let failed = menu([track(2, path: nil, failure: Self.failureJSON)], library).items
        #expect(failed.contains(.download(title: "Retry Download")))

        let missing = menu([track(3, missing: true)], library).items
        #expect(!missing.contains { if case .play = $0 { true } else { false } }, "nothing plays")
        #expect(!missing.contains { if case .preview = $0 { true } else { false } }, "nothing previews")
        // Fix group: Locate File… · Download Again (W2-C, CM-TRACK File missing).
        #expect(missing.contains(.downloadAgain))
        let locate = try #require(missing.firstIndex(of: .locateFile))
        #expect(locate < (missing.firstIndex(of: .downloadAgain) ?? 0))
        #expect(failed.contains(.locateFile), "Download failed: Retry Download ⌘D · Locate File…")
        #expect(!notDownloaded.contains(.locateFile))
        let missingImported = menu([track(4, missing: true, original: "/Users/o/import.m4a")], library).items
        #expect(!missingImported.contains(.downloadAgain), "Download Again needs a source")
    }

    @Test func multiSelectionStartsWithTheCountAndCountsDownloads() {
        let model = menu([track(1), track(2, path: nil), track(3, path: nil, failure: Self.failureJSON)], library)
        #expect(model.sections.first == [.countHeader(3)])
        #expect(model.items.contains(.download(title: "Download 2 Not-Downloaded Tracks")))
        #expect(model.items.contains(.play(enabled: true)))
        let one = menu([track(1), track(2, path: nil)], library)
        #expect(one.items.contains(.download(title: "Download 1 Not-Downloaded Track")))
    }

    @Test func driveAwayDisablesFileActionsUnderAHeader() {
        let model = menu([track(1)], library, live: offline)
        #expect(model.sections.first == [.driveHeader(volumeName: "Lexxar")])
        #expect(model.items.contains(.play(enabled: false)))
        #expect(model.items.contains(.preview(enabled: false)), "Preview is a file action (UC-CM-05)")
        #expect(model.items.contains(.showInFinder(enabled: false)))
        #expect(model.items.contains(.removeFromLibrary(enabled: false)))
        #expect(!model.items.contains(.playNext))
        // Not downloaded tracks keep their normal menu (Download is queued).
        let remote = menu([track(2, path: nil)], library, live: offline)
        #expect(!remote.items.contains(.driveHeader(volumeName: "Lexxar")))
        #expect(remote.items.contains(.download(title: "Download")))
    }

    @Test func noDeadItemsFromLaterPackages() {
        // Go to Album doesn't exist in a playlist's menu here (Share… arrived with W5-1b) (Preview and Locate File… arrived with W2-C, Go to
        // Artist with W2-I, Add to Queue with W2-D, Find Similar with W3-DISC-A).
        let all = menu([track(1)], playlist).items + menu([track(2, missing: true)], library).items
        let titles = all.map { "\($0)" }.joined(separator: " ")
        for absent in ["goToAlbum"] {
            #expect(!titles.contains(absent))
        }
        #expect(all.contains(.addToQueue))
        #expect(all.contains(.findSimilar))
        #expect(all.contains(.preview(enabled: true)) && all.contains(.locateFile))
        // Preview needs exactly one track (UC-CM-04).
        #expect(!menu([track(1), track(2)], library).items.contains { if case .preview = $0 { true } else { false } })
    }

    // MARK: - Sorting (UC-TABLE-04)

    @Test func sortsEveryColumnWithAbsentValuesLast() {
        var tracks: [Track] = []
        for (index, title) in ["beta", "Álpha", "gamma", "alpha"].enumerated() {
            var t = track(Int64(index + 1), title: title, duration: index == 2 ? nil : 100 * (4 - index))
            t.bpm = index == 0 ? nil : 120 + index
            tracks.append(t)
        }
        let rows = TrackRowBuilder.build(tracks)
        let byTitle = TrackRowSorter.sorted(rows, by: TrackSortOrder(column: .title, ascending: true)).map(\.id)
        #expect(byTitle == [2, 4, 1, 3], "case/diacritic-insensitive; ties keep the container order")
        let byTimeDesc = TrackRowSorter.sorted(rows, by: TrackSortOrder(column: .time, ascending: false)).map(\.id)
        #expect(byTimeDesc == [1, 2, 4, 3], "absent time last also when descending")
        let byBPM = TrackRowSorter.sorted(rows, by: TrackSortOrder(column: .bpm, ascending: true)).map(\.id)
        #expect(byBPM.last == 1)
        for column in TrackColumnID.allCases {
            for ascending in [true, false] {
                let sorted = TrackRowSorter.sorted(rows, by: TrackSortOrder(column: column, ascending: ascending))
                #expect(Set(sorted.map(\.id)) == Set(rows.map(\.id)))
            }
        }
    }

    @Test func statusSortsInScopeOrder() {
        let rows = TrackRowBuilder.build([
            track(1, missing: true), track(2, path: nil), track(3), track(4, path: nil, failure: Self.failureJSON),
        ])
        #expect(TrackRowSorter.sorted(rows, by: TrackSortOrder(column: .status, ascending: true)).map(\.id) == [3, 2, 4, 1])
    }

    @Test func containerOrderIsPosition() {
        let rows = TrackRowBuilder.build([track(5), track(3), track(9)])
        #expect(rows.map(\.position) == [1, 2, 3])
        let byTitle = TrackRowSorter.sorted(rows, by: TrackSortOrder(column: .number, ascending: false))
        #expect(byTitle.map(\.id) == [9, 3, 5])
        #expect(TrackRowSorter.sorted(rows, by: TrackSortOrder(column: .number, ascending: true)).map(\.id) == [5, 3, 9])
    }

    @Test func sortOrderPersistsAsRawValueAndMapsTheHeader() {
        let order = TrackSortOrder(column: .added, ascending: false)
        #expect(order.rawValue == "added:desc")
        #expect(TrackSortOrder(rawValue: "added:desc") == order)
        #expect(TrackSortOrder(rawValue: "nonsense") == nil)
        for column in TrackColumnID.allCases {
            let comparator = TrackSortOrder(column: column, ascending: true).comparator
            #expect(TrackSortOrder(comparator) == TrackSortOrder(column: column, ascending: true))
        }
    }

    // MARK: - Model: selection survives refresh, removal prunes it

    @Test func selectionSurvivesRefreshFilterAndSort() async {
        let model = TrackListModel(sortOrder: TrackSortOrder(column: .title, ascending: true))
        await model.setTracks([track(1, title: "b"), track(2, title: "a"), track(3, title: "c")])
        model.selection = [1, 3]
        await model.setTracks([track(1, title: "b"), track(3, title: "c")])  // filtered
        #expect(model.selection == [1, 3])
        #expect(model.selectedRows().map(\.id) == [1, 3])
        await model.setTracks([track(1, title: "b"), track(2, title: "a"), track(3, title: "c")])  // unfiltered again
        await model.setSortOrder(TrackSortOrder(column: .title, ascending: false))
        #expect(model.rows.map(\.id) == [3, 1, 2])
        #expect(model.selection == [1, 3])
        #expect(model.selectedRows().map(\.id) == [3, 1], "display order")
        model.remove(ids: [3])
        #expect(model.selection == [1])
        #expect(model.rows.map(\.id) == [1, 2])
    }

    @Test func playlistFilterKeepsPositions() async {
        let model = TrackListModel(sortOrder: TrackSortOrder(column: .number, ascending: true))
        await model.setTracks([track(10), track(11), track(12)], visibleIDs: [12])
        #expect(model.rows.map(\.position) == [3])
    }

    @Test func summaryCountsReachableFilesOnly() {
        let rows = TrackRowBuilder.build([track(1), track(2, missing: true), track(3, path: nil)])
        let online = TrackSelectionSummary(rows: rows, container: .library, live: .idle)
        #expect(online.localCount == 1 && online.missingCount == 1 && online.notDownloadedCount == 1 && online.firstIsLocal)
        let away = TrackSelectionSummary(rows: rows, container: .library, live: offline)
        #expect(away.localCount == 0 && away.unreachableCount == 2 && !away.firstIsLocal)
        let state = TrackCommandState(summary: away, capabilities: TrackListCapabilities(canActivate: true), isDownloadBusy: false)
        #expect(!state.canPlay && !state.canShowInFinder && state.canDownload)
    }

    // MARK: - Status bar wording (UC-STATUS-02/03, UC-COPY-10)

    @Test func durations() {
        #expect(TrackDurationText.trackTime(204) == "3:24")
        #expect(TrackDurationText.trackTime(3725) == "1:02:05")
        #expect(TrackDurationText.trackTime(nil) == nil)
        #expect(TrackDurationText.total(52 * 60) == "52 min")
        #expect(TrackDurationText.total(171 * 60) == "2 h 51 min")
        #expect(TrackDurationText.total(38 * 24 * 3600) == "38 days")
    }
}
