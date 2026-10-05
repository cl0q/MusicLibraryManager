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

    // MARK: Primary action (double-click / ↩)

    /// The first displayed row of `ids` (a multi-row Return acts on the first one).
    func primary(_ ids: Set<Int64>) {
        guard let row = model.selectedRows(ids).first else { return }
        perform(TrackPrimaryAction.resolve(row: row, live: live.state), on: row)
    }

    func perform(_ action: TrackPrimaryAction, on row: TrackRow) {
        switch action {
        case .play:
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
            var buttons: [StatusAction] = []
            // `Locate…` arrives with W2-C; only working buttons are offered.
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

    /// Download Again (File missing, has a source): re-check the files first — one may be
    /// back — then clear the stale path of the ones still missing and download them.
    func downloadAgain(_ rows: [TrackRow]) {
        let ids = Set(rows.filter { $0.availability == .fileMissing }.map(\.id))
        guard !ids.isEmpty, let repository = container.trackRepository, let downloads = container.downloadViewModel else { return }
        if downloads.isDownloading {
            statusBar?.post(TrackCommandState.downloadBusyReason)
            return
        }
        let monitor = container.availabilityMonitor
        let statusBar = self.statusBar
        Task {
            await monitor?.checkNow(.tracks(ids))
            var again: [Int64] = []
            for id in ids.sorted() {
                guard let track = try? await repository.fetchTrack(id: id), track.availability() == .fileMissing else { continue }
                try? await repository.demoteToRemote(trackId: id)
                again.append(id)
            }
            guard !again.isEmpty, let fresh = try? await repository.fetchTracks(ids: Set(again)) else {
                NotificationCenter.default.post(name: .trackAvailabilityDidChange, object: nil)
                return
            }
            NotificationCenter.default.post(name: .trackAvailabilityDidChange, object: nil)
            statusBar?.post(TrackPrimaryAction.downloadStartedMessage(count: fresh.count))
            await downloads.downloadTracks(fresh)
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
