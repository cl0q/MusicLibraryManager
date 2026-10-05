import AppKit
import SwiftUI

/// What a track table does when the user acts — the primary action (UC-PRIM), the context
/// menu's items and the keys. Built per table from its configuration and the window's
/// status bar, undo center and shell; shared commands go through `TrackCommandActions`.
@MainActor
struct TrackListActions {
    let model: TrackListModel
    let configuration: TrackListConfiguration
    let live: TrackTableLive
    let statusBar: StatusBarCenter?
    let undo: UndoCenter?
    let shell: ShellActions?
    var container: DependencyContainer = .shared
    /// The window's navigation — where a played row came from (⌘L, W2-C).
    var navigation: NavigationModel? = nil

    // MARK: Preview (Space, W2-C)

    /// This table as the owner of a preview (its selection moves the preview).
    var previewOwner: PreviewOwner { "\(ObjectIdentifier(model).hashValue)" }

    /// What Space would preview now: the shown selected rows (UC-STATUS-07 refusals).
    func previewCandidate(_ rows: [TrackRow]? = nil) -> PreviewCandidate {
        PreviewCandidate.make(rows: rows ?? model.selectedRows(), live: live.state)
    }

    /// Space on the focused table, or Track ▸ Preview / the context menu's Preview: start a
    /// preview of the selected track, or end the running one. Never Play/Pause (§10 Q1).
    func preview(_ rows: [TrackRow]? = nil) {
        container.playbackViewModel?.preview.toggle(owner: previewOwner, candidate: previewCandidate(rows))
    }

    /// The selection changed: a preview this table started follows it (debounced).
    func previewSelectionDidChange() {
        guard let preview = container.playbackViewModel?.preview, preview.isActive else { return }
        preview.selectionChanged(owner: previewOwner, candidate: previewCandidate())
    }

    /// Locate File… (File missing / Download failed, one track).
    func locateFile(_ rows: [TrackRow]) {
        guard rows.count == 1, let row = rows.first else { return }
        LocateFileRequest.shared.begin(row.track)
    }

    /// Where a row of this list plays from (⌘L) — named lists only; search results and the
    /// queue fall back to All Tracks.
    var playbackOrigin: PlaybackOrigin? {
        guard let navigation, configuration.listContext.viewName != nil else { return nil }
        return PlaybackOrigin(place: navigation.selection, path: navigation.path,
                              listKey: configuration.persistenceKey, container: configuration.listContext.container)
    }

    // MARK: Primary action (double-click / ↩)

    /// The first displayed row of `ids` (a multi-row Return acts on the first one).
    func primary(_ ids: Set<Int64>) {
        guard let row = model.selectedRows(ids).first else { return }
        perform(TrackPrimaryAction.resolve(row: row, live: live.state), on: row)
    }

    func perform(_ action: TrackPrimaryAction, on row: TrackRow) {
        let playback = container.playbackViewModel
        if action != .play, playback?.preview.isActive == true {
            // Return on a row that can't play ends the preview first (it resumes main).
            playback?.preview.end()
        }
        switch action {
        case .play:
            if let playback {
                // ⌘L returns to this list (W2-C); Return while previewing plays the previewed
                // track for real from the previewed position (UC-KEY-06).
                if let origin = playbackOrigin { playback.willActivate(row.id, from: origin) }
                playback.preview.handOver(row.track)
            }
            configuration.activate?(row.track, model.tracks)
        case .download:
            guard let downloads = container.downloadViewModel else { return }
            if downloads.isDownloading {
                statusBar?.post(TrackCommandState.downloadBusyReason)
                return
            }
            TrackCommandActions.download([row.track], container: container)
            awaitDownload(row)
        case .awaitDownload:
            awaitDownload(row)
        case .fileMissing:
            // `File missing — Locate… · Download Again` (UC-PRIM-03).
            var buttons: [StatusAction] = [StatusAction("Locate…") { LocateFileRequest.shared.begin(row.track) }]
            if TrackLinks.hasSource(row.track) {
                buttons.append(StatusAction("Download Again") { [self] in downloadAgain([row]) })
            }
            statusBar?.post(TrackPrimaryAction.fileMissingMessage, actions: buttons)
        case .driveNotConnected(let name):
            statusBar?.post(TrackPrimaryAction.driveNotConnectedMessage(name))
        }
    }

    /// `Downloading “‹title›” — it will play when it’s ready · Cancel`
    private func awaitDownload(_ row: TrackRow) {
        guard let activate = configuration.activate else {
            statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: 1))
            return
        }
        PendingTrackPlayback.shared.playWhenReady(trackID: row.id, activate: activate)
        let downloads = container.downloadViewModel
        statusBar?.post(TrackPrimaryAction.downloadingMessage(title: row.title), actions: [
            StatusAction("Cancel") {
                PendingTrackPlayback.shared.cancel()
                downloads?.cancel()
            },
        ])
    }

    // MARK: Menu items

    /// Play from the menu: one row = the primary action; several = the playable ones in order.
    func play(_ rows: [TrackRow]) {
        if rows.count == 1 {
            primary([rows[0].id])
            return
        }
        let playable = rows.filter { row in
            row.availability == .local
                && !TrackRowPresentation.isUnreachable(availability: row.availability, fileLocation: row.fileLocation, live: live.state)
        }
        guard let first = playable.first else { return }
        configuration.activate?(first.track, playable.map(\.track))
    }

    func playNext(_ rows: [TrackRow]) {
        TrackCommandActions.playNext(rows.map(\.track), container: container)
    }

    func addToPlaylist(_ playlistID: Int64, _ rows: [TrackRow]) {
        TrackCommandActions.addToPlaylist(playlistID, tracks: rows.map(\.track), shell: shell)
    }

    func newPlaylist(_ rows: [TrackRow]) {
        TrackCommandActions.newPlaylistFromSelection(rows.map(\.track), shell: shell)
    }

    func addToSyncProfile(_ profile: SyncProfile, _ rows: [TrackRow]) {
        let ids = rows.map(\.id)
        let sync = container.syncViewModel
        Task {
            sync?.selectedProfile = profile
            await sync?.addTracks(ids)
        }
    }

    func newSyncProfile(_ rows: [TrackRow]) {
        TrackCommandActions.newSyncProfileFromSelection(rows.map(\.track))
    }

    /// Get Info ⌘I: Info shows the first track (the existing Show Details path).
    func getInfo(_ rows: [TrackRow]) {
        guard let id = rows.first?.id else { return }
        NotificationCenter.default.post(name: .openTrackDetailForTrack, object: nil, userInfo: ["trackId": id])
    }

    func download(_ rows: [TrackRow]) {
        let downloadable = rows.filter { $0.availability.isDownloadable }
        guard !downloadable.isEmpty, let downloads = container.downloadViewModel else { return }
        if downloads.isDownloading {
            statusBar?.post(TrackCommandState.downloadBusyReason)
            return
        }
        TrackCommandActions.download(downloadable.map(\.track), container: container)
        statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: downloadable.count))
    }

    /// Download Again (File missing, has a source): see `TrackDownloadAgain`. The stored path
    /// is never cleared up front; only a finished download replaces it.
    func downloadAgain(_ rows: [TrackRow]) {
        let ids = Set(rows.filter { $0.availability == .fileMissing }.map(\.id))
        guard !ids.isEmpty, let repository = container.trackRepository, let downloads = container.downloadViewModel,
              let monitor = container.availabilityMonitor else { return }
        if downloads.isDownloading {
            statusBar?.post(TrackCommandState.downloadBusyReason)
            return
        }
        let statusBar = self.statusBar
        let volumeName = LibraryDriveState.current(container).volumeName
        Task {
            let prepared = await TrackDownloadAgain.prepare(
                ids: ids,
                repository: repository,
                check: { await monitor.checkNow(.tracks($0)) },
                isFolderReachable: { await monitor.isLibraryFolderReachable() }
            )
            switch prepared {
            case .ready(let tracks):
                statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: tracks.count))
                await downloads.downloadTracks(tracks)
            case .notConnected:
                statusBar?.post(TrackDownloadAgain.notConnectedMessage(volumeName))
            case .nothingMissing:
                NotificationCenter.default.post(name: .trackAvailabilityDidChange, object: nil)
            case .checkStopped:
                statusBar?.post(TrackDownloadAgain.checkStoppedMessage)
            }
        }
    }

    func showInFinder(_ rows: [TrackRow]) {
        TrackCommandActions.showInFinder(reachableTracks(rows), container: container)
    }

    func copyTitleAndArtist(_ rows: [TrackRow]) {
        TrackCommandActions.copyTitleAndArtist(rows.map(\.track))
    }

    func copyFilePaths(_ rows: [TrackRow]) {
        TrackCommandActions.copyFilePaths(reachableTracks(rows), container: container)
    }

    func copyLinks(_ rows: [TrackRow]) {
        let links = rows.compactMap { TrackLinks.sourceURL($0.track)?.absoluteString }
        guard !links.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(links.joined(separator: "\n"), forType: .string)
    }

    func removeFromContainer(_ rows: [TrackRow]) {
        configuration.removeFromContainer?(Set(rows.map(\.id)))
    }

    func removeFromLibrary(_ rows: [TrackRow]) {
        TrackCommandActions.removeFromLibrary(rows.map(\.track), container: container)
    }

    /// ⌘C: one `Title — Artist` line per selected row (UC-CM-13, UC-KEY-19).
    func copyItems() -> [NSItemProvider] {
        let rows = model.selectedRows()
        guard !rows.isEmpty else { return [] }
        return [NSItemProvider(object: TrackCommandActions.titleArtistLines(rows.map(\.track)) as NSString)]
    }

    private func reachableTracks(_ rows: [TrackRow]) -> [Track] {
        rows.filter { row in
            row.availability == .local
                && !TrackRowPresentation.isUnreachable(availability: row.availability, fileLocation: row.fileLocation, live: live.state)
        }.map(\.track)
    }
}

// MARK: - Download Again (File missing, §15.4)

/// Download Again, made safe (W2-A review S1):
/// 1. check the files first — one may be back — and go on only when that check completed
///    (never while the library folder or its disk is away);
/// 2. check once more that the folder is reachable;
/// 3. hand the still-missing tracks that have a source to the download pipeline **without
///    touching the database**: the copies passed in have no `organizedPath` in memory only, so
///    the pipeline accepts them; a finished download overwrites the stored path and clears
///    the flag (`TrackRepository.markAsDownloaded`), a failed or cancelled one leaves the row
///    exactly as it was (File missing, old path kept).
enum TrackDownloadAgain {
    enum Prepared: Equatable {
        case ready([Track])
        case notConnected
        case nothingMissing
        case checkStopped
    }

    static func prepare(
        ids: Set<Int64>,
        repository: TrackRepository,
        check: (Set<Int64>) async -> TrackAvailabilityReconciler.Report,
        isFolderReachable: () async -> Bool
    ) async -> Prepared {
        let report = await check(ids)
        switch report.outcome {
        case .completed: break
        case .skippedRootUnreachable, .abortedRootLost: return .notConnected
        case .abortedSuspicious, .cancelled: return .checkStopped
        }
        guard await isFolderReachable() else { return .notConnected }
        var tracks: [Track] = []
        for id in ids.sorted() {
            guard var track = try? await repository.fetchTrack(id: id),
                  track.availability() == .fileMissing,
                  TrackLinks.hasSource(track) else { continue }
            track.organizedPath = nil  // in memory only — see above
            tracks.append(track)
        }
        return tracks.isEmpty ? .nothingMissing : .ready(tracks)
    }

    /// `Can’t download — “Lexxar” is not connected`
    static func notConnectedMessage(_ volumeName: String?) -> String {
        guard let volumeName else { return "Can’t download — the library folder can’t be read" }
        return "Can’t download — “\(volumeName)” is not connected"
    }

    static let checkStoppedMessage = "Can’t download — the files couldn’t be checked"
}

/// The live state rows read, as one observable per table so a change re-renders only the
/// visible cells — never the table's row list.
@MainActor
@Observable
final class TrackTableLive {
    var state: TrackTableLiveState

    init(state: TrackTableLiveState = .idle) {
        self.state = state
    }
}

// MARK: - Removing from a playlist (undoable, UC-UNDO-06, UC-SURF-05)

@MainActor
enum PlaylistTrackRemoval {
    /// `Removed ‹n› tracks from “‹name›” — the files stay in the library`
    static func message(count: Int, playlist: String) -> String {
        "Removed \(StatusBarText.tracks(count)) from “\(playlist)” — the files stay in the library"
    }

    /// `Remove from “‹name›”` (Edit ▸ Undo Remove from “Warm-up”, UC-UNDO-07).
    static func actionName(playlist: String) -> String {
        "Remove from “\(playlist)”"
    }

    /// Removes exactly the selected tracks' rows of the playlist — no question asked — as one
    /// undo step; Undo puts the same rows back with their ids and positions.
    static func remove(
        _ trackIDs: Set<Int64>,
        fromPlaylist playlistID: Int64,
        name: String,
        undo: UndoCenter?,
        container: DependencyContainer = .shared
    ) {
        guard !trackIDs.isEmpty, let tracks = container.trackRepository, let playlists = container.playlistRepository else { return }
        let changed: @MainActor () -> Void = {
            NotificationCenter.default.post(name: .playlistDidChange, object: nil, userInfo: ["playlistId": playlistID])
        }
        guard let undo else {
            // No window undo (tests, previews): remove without a step.
            Task {
                guard let entries = try? await tracks.fetchPlaylistEntries(playlistId: playlistID, trackIds: trackIDs),
                      (try? await playlists.removeEntries(entries)) != nil else { return }
                changed()
            }
            return
        }
        Task {
            _ = try? await undo.perform(
                actionName(playlist: name),
                failure: "Couldn’t remove \(StatusBarText.tracks(trackIDs.count)) from “\(name)”",
                do: { () async throws -> [PlaylistTrack]? in
                    let entries = try await tracks.fetchPlaylistEntries(playlistId: playlistID, trackIds: trackIDs)
                    let removed = try await playlists.removeEntries(entries)
                    guard !removed.isEmpty else { return nil }
                    changed()
                    return removed
                },
                undo: { removed in
                    let restored = try await playlists.restoreEntries(removed)
                    changed()
                    return restored
                },
                redo: { restored in
                    let removed = try await playlists.removeEntries(restored)
                    changed()
                    return removed
                },
                message: { PlaylistTrackRemoval.message(count: $0.count, playlist: name) }
            )
        }
    }
}
