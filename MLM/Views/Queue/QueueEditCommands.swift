import Foundation

/// Queue edits as the user makes them (W2-D): each one undo step on the window's `UndoCenter`
/// (DEC-041, UC-UNDO-08) with its status-bar confirmation and `Undo` (DEC-016) — never a
/// confirmation alert (DEC-050). Every route goes through here: the Track menu, the track
/// context menu, the selection bar, the Queue panel, drops on the panel and on the player.
@MainActor
enum QueueEditCommands {
    enum Adding: Equatable {
        case playNext
        case addToQueue
    }

    // MARK: From track lists

    /// Play Next / Add to Queue of tracks from a list: the tracks with a file are queued; the
    /// others are left out and counted in the same sentence (UC-DND-05).
    static func queue(_ tracks: [Track], as adding: Adding, playback: PlaybackViewModel, undo: UndoCenter) {
        let candidates = tracks.filter { $0.id != nil }
        let queueable = candidates.filter(\.isLocal)
        let leftOut = candidates.count - queueable.count
        guard !queueable.isEmpty else {
            if !candidates.isEmpty { undo.statusBar.post(QueueWords.nothingToQueue(count: candidates.count)) }
            return
        }
        Task {
            let receipt = switch adding {
            case .playNext: await playback.playNext(queueable)
            case .addToQueue: await playback.addToQueue(queueable)
            }
            record(receipt, playback: playback, undo: undo, suffix: leftOut > 0 ? QueueWords.leftOutSuffix(leftOut) : "")
        }
    }

    // MARK: From the Queue panel

    /// Run a panel edit and register it.
    static func perform(_ edit: @escaping @MainActor (PlaybackViewModel) async -> QueueEditReceipt?,
                        playback: PlaybackViewModel, undo: UndoCenter) {
        Task {
            record(await edit(playback), playback: playback, undo: undo)
        }
    }

    /// One undo step for an edit that already happened (`UndoCenter.record`): undo and redo
    /// apply to the queue as it is then (`QueueEditing.revert` / `reapply`); when nothing is
    /// left (the tracks played meanwhile) the step goes with a note.
    static func record(_ receipt: QueueEditReceipt?, playback: PlaybackViewModel, undo: UndoCenter, suffix: String = "") {
        guard let receipt else { return }
        undo.record(
            QueueWords.actionName(receipt.kind),
            message: QueueWords.message(receipt) + suffix,
            done: receipt,
            undo: { [weak playback] receipt in
                guard let playback, await playback.revertQueueEdit(receipt) else {
                    throw UndoNothingLeft(note: QueueWords.nothingLeftToUndo)
                }
                return receipt
            },
            redo: { [weak playback] receipt in
                guard let playback, await playback.reapplyQueueEdit(receipt) else {
                    throw UndoNothingLeft(note: QueueWords.nothingLeftToRedo)
                }
                return receipt
            }
        )
    }

    // MARK: Drops (UC-DND matrix: Player / Queue column)

    /// Tracks or Queue rows dropped at `position` of Next: rows of Next move there (reorder);
    /// tracks (and History rows) are queued there — `.top` is Play Next, anywhere else Add to
    /// Queue at that place.
    static func drop(_ items: [QueueRowDrag], at position: QueuePosition, playback: PlaybackViewModel,
                     undo: UndoCenter, container: DependencyContainer = .shared) {
        guard !items.isEmpty else { return }
        let queued = Set(playback.queueSnapshot.upcomingEntries.map(\.id))
        let moving = items.compactMap(\.queueEntryId).filter(queued.contains)
        if !moving.isEmpty, moving.count == items.count {
            perform({ await $0.moveEntries(moving, to: position) }, playback: playback, undo: undo)
            return
        }
        let ids = items.map(\.trackId)
        Task {
            let tracks = await orderedTracks(ids, container: container)
            let queueable = tracks.filter(\.isLocal)
            let leftOut = tracks.count - queueable.count
            guard !queueable.isEmpty else {
                if !tracks.isEmpty { undo.statusBar.post(QueueWords.nothingToQueue(count: tracks.count)) }
                return
            }
            let receipt = await playback.insert(queueable, at: position)
            record(receipt, playback: playback, undo: undo, suffix: leftOut > 0 ? QueueWords.leftOutSuffix(leftOut) : "")
        }
    }

    /// Tracks dropped on the toolbar player: Play Next (UC-TB-08); rows of Next move to the top.
    static func dropOnPlayer(_ items: [QueueRowDrag], playback: PlaybackViewModel, undo: UndoCenter) {
        drop(items, at: .top, playback: playback, undo: undo)
    }

    /// The library rows of `ids`, in that order.
    static func orderedTracks(_ ids: [Int64], container: DependencyContainer) async -> [Track] {
        guard !ids.isEmpty, let repository = container.trackRepository,
              let rows = try? await repository.fetchTracks(ids: Set(ids)) else { return [] }
        var byID: [Int64: Track] = [:]
        for track in rows { if let id = track.id { byID[id] = track } }
        return ids.compactMap { byID[$0] }
    }

    // MARK: Save as Playlist… (P-QUEUE.N15)

    /// Creates a playlist named `name` (numbered when taken, IMP-019) with the tracks in queue
    /// order — playlist and tracks are one undo step (`Save Queue as Playlist`). The queue is
    /// unchanged and the window does not navigate.
    @discardableResult
    static func saveAsPlaylist(name: String, tracks: [Track], undo: UndoCenter,
                               container: DependencyContainer = .shared) async -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let ids = ShellEdits.uniqued(tracks.compactMap(\.id))
        guard !trimmed.isEmpty, !ids.isEmpty, let repository = container.playlistRepository else { return nil }
        let effects = PlaylistEffects(window: .main)
        return try? await undo.perform(
            QueuePanelWords.saveActionName,
            failure: "Couldn’t create the playlist",
            do: { () async throws -> Playlist? in
                let playlist = try await repository.createNumbered(baseName: trimmed, trackIds: ids)
                await effects.changed(playlist.id, repository: repository)
                return playlist
            },
            undo: { playlist in try await effects.delete(playlist.id, repository: repository) },
            redo: { snapshot in try await effects.restore(snapshot, repository: repository).playlist },
            message: { QueuePanelWords.created(name: $0.name, count: ids.count) }
        )
    }
}
