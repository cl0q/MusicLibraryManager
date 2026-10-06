import AppKit
import Foundation

/// The undoable edits the shell offers today (W2-F adoptions of `UndoCenter`): New Playlist,
/// New Playlist from Selection, Add to Playlist ▸, playlist rename, Delete Playlist, sync
/// profile rename. Each is one undo step with a UC-UNDO-07 action name and a UC-STATUS-05
/// confirmation; nothing here asks before acting except Delete Playlist (UC-UNDO-05).
///
/// Owned by `ShellActions` (`actions.edits`). The undo and redo closures capture only the
/// repositories and a `ShellWindowModels` box — never this object or one window's models —
/// so a step undone after the main window was closed and reopened updates the new window.
@MainActor
final class ShellEdits {
    /// Where the edits read and write; `live(_:)` in the app, temporary databases in tests.
    struct Dependencies {
        var playlists: @MainActor () -> PlaylistRepository?
        var syncProfiles: @MainActor () -> SyncRepository?
        /// Reload what shows sync profiles after the profile with this id changed.
        var syncProfileDidChange: @MainActor (Int64) async -> Void
        /// The library's tracks (drops check that dropped tracks still exist, W2-H).
        var tracks: @MainActor () -> TrackRepository? = { nil }
        /// Reload what shows a sync profile's content after it changed (W2-H drops).
        var syncContentDidChange: @MainActor (Int64) async -> Void = { _ in }
        /// Playlist covers (cover drops, W2-H).
        var covers: @MainActor () -> PlaylistCoverService? = { nil }

        static func live(_ container: DependencyContainer) -> Dependencies {
            Dependencies(
                playlists: { container.playlistRepository },
                syncProfiles: { container.syncRepository },
                syncProfileDidChange: { id in
                    await container.syncViewModel?.profileDidChange(id)
                },
                tracks: { container.trackRepository },
                syncContentDidChange: { id in
                    // The profile's page shows the new content and a fresh plan (W3-SYNC: every
                    // profile has its own state; nothing switches, D-SYNC-TRACKS-TO-PROFILE).
                    await container.syncViewModel?.profileDidChange(id)
                    NotificationCenter.default.post(name: .syncProfileDidChange, object: nil, userInfo: ["profileId": id])
                },
                covers: { container.playlistCoverService }
            )
        }
    }

    /// Default name of a new playlist (UC §23 C5).
    static let untitledPlaylistName = "Untitled Playlist"

    let dependencies: Dependencies
    let undo: UndoCenter
    let effects: PlaylistEffects

    /// - Parameter window: the current main window's models (`ShellWindowModels.main` in the app).
    init(dependencies: Dependencies, undo: UndoCenter, window: ShellWindowModels) {
        self.dependencies = dependencies
        self.undo = undo
        effects = PlaylistEffects(window: window)
    }

    // MARK: New Playlist (⌘N, S-PL-NEWPLAYLIST)

    /// Creates `Untitled Playlist` (numbered when taken), opens it and puts its sidebar name
    /// into edit mode. Undo removes it; Redo brings back the same playlist (same id).
    @discardableResult
    func newPlaylist() async -> Playlist? {
        guard let repository = dependencies.playlists() else { return nil }
        let effects = self.effects
        let created = try? await undo.perform(
            "New Playlist",
            failure: "Couldn’t create the playlist",
            do: { () async throws -> Playlist? in
                let playlist = try await repository.createNumbered(baseName: Self.untitledPlaylistName)
                await effects.changed(playlist.id, repository: repository)
                return playlist
            },
            undo: { playlist in try await effects.delete(playlist.id, repository: repository) },
            redo: { snapshot in try await effects.restore(snapshot, repository: repository).playlist },
            message: { "Created “\($0.name)”" }
        )
        if let id = created?.id {
            effects.window.navigation?.select(.playlist(id))
            effects.window.sidebar?.requestRename(playlist: id)
        }
        return created
    }

    // MARK: New Playlist from Selection (⇧⌘N, S-SEL-NEWPLAYLIST)

    /// Creates `Untitled Playlist` with the tracks in the given (display) order — playlist and
    /// tracks are one step — and puts its sidebar name into edit mode. Doesn't navigate.
    @discardableResult
    func newPlaylist(fromTrackIDs trackIDs: [Int64]) async -> Playlist? {
        let ordered = Self.uniqued(trackIDs)
        guard !ordered.isEmpty, let repository = dependencies.playlists() else { return nil }
        let effects = self.effects
        let created = try? await undo.perform(
            "New Playlist from Selection",
            failure: "Couldn’t create the playlist",
            do: { () async throws -> Playlist? in
                let playlist = try await repository.createNumbered(baseName: Self.untitledPlaylistName, trackIds: ordered)
                await effects.changed(playlist.id, repository: repository)
                return playlist
            },
            undo: { playlist in try await effects.delete(playlist.id, repository: repository) },
            redo: { snapshot in try await effects.restore(snapshot, repository: repository).playlist },
            message: { "Created “\($0.name)” with \(StatusBarText.tracks(ordered.count))" }
        )
        if let id = created?.id {
            effects.window.sidebar?.requestRename(playlist: id)
        }
        return created
    }

    // MARK: Add to Playlist ▸

    /// Appends the tracks (display order) after the playlist's last track. Undo removes
    /// exactly the rows this added — never a track that was already in the playlist.
    func addTracks(_ trackIDs: [Int64], toPlaylist playlistID: Int64, messageSuffix: String = "") async {
        let ordered = Self.uniqued(trackIDs)
        guard !ordered.isEmpty, let repository = dependencies.playlists() else { return }
        let name = await playlistName(playlistID, repository: repository)
        let effects = self.effects
        do {
            let result = try await undo.perform(
                "Add to “\(name)”",
                failure: "Couldn’t add \(StatusBarText.tracks(ordered.count)) to “\(name)”",
                do: { () async throws -> PlaylistAppendResult? in
                    let result = try await repository.appendTracksReturningEntries(playlistId: playlistID, trackIds: ordered)
                    guard !result.entries.isEmpty else { return nil }
                    await effects.changed(playlistID, repository: repository)
                    return result
                },
                undo: { added in
                    let removed = try await repository.removeEntries(added.entries)
                    // Removed meanwhile by something else: nothing left to undo (no empty Redo).
                    guard !removed.isEmpty else {
                        throw UndoNothingLeft(note: "Nothing to undo — the tracks are no longer in “\(name)”")
                    }
                    await effects.changed(playlistID, repository: repository)
                    return removed
                },
                redo: { removed in
                    let restored = try await repository.restoreEntries(removed)
                    guard !restored.isEmpty else {
                        throw UndoNothingLeft(note: "Nothing to redo — the tracks can’t go back into “\(name)”")
                    }
                    await effects.changed(playlistID, repository: repository)
                    return PlaylistAppendResult(entries: restored, alreadyPresent: 0)
                },
                message: { Self.addedMessage(added: $0.entries.count, alreadyPresent: $0.alreadyPresent, playlist: name) + messageSuffix }
            )
            if result == nil {
                effects.window.statusBar?.post(Self.alreadyPresentMessage(count: ordered.count, playlist: name))
            }
        } catch {
            // Reported in the status bar by the center.
        }
    }

    /// `Added 3 tracks to “Warm-up”` · `Added 2 tracks to “Warm-up” · 1 was already in it`
    /// (UC-STATUS-05).
    static func addedMessage(added: Int, alreadyPresent: Int, playlist: String) -> String {
        var text = "Added \(StatusBarText.tracks(added)) to “\(playlist)”"
        if alreadyPresent > 0 {
            text += " · \(alreadyPresent.formatted(.number)) \(alreadyPresent == 1 ? "was" : "were") already in it"
        }
        return text
    }

    /// Nothing was added: every track was already there (no step, no Undo).
    static func alreadyPresentMessage(count: Int, playlist: String) -> String {
        count == 1
            ? "The track was already in “\(playlist)”"
            : "All \(count.formatted(.number)) tracks were already in “\(playlist)”"
    }

    // MARK: Rename (sidebar inline rename, UC-SIDE-09)

    /// Renames a playlist as one undo step (`Rename Playlist`). Throws so the inline field can
    /// show the failure under itself (UC-SHEET-17); `renameFailure(_:)` words it.
    func renamePlaylist(_ playlistID: Int64, from oldName: String, to newName: String) async throws {
        guard let repository = dependencies.playlists() else { throw PlaylistRepositoryError.playlistNotFound }
        let effects = self.effects
        try await undo.perform(
            "Rename Playlist",
            message: "Renamed “\(oldName)” to “\(newName)”",
            failure: nil,
            do: {
                try await Self.rename(playlistID, to: newName, currentName: oldName, repository: repository)
                await effects.changed(playlistID, repository: repository)
            },
            undo: {
                try await Self.rename(playlistID, to: oldName, currentName: newName, repository: repository)
                await effects.changed(playlistID, repository: repository)
            }
        )
    }

    private static func rename(_ id: Int64, to name: String, currentName: String, repository: PlaylistRepository) async throws {
        guard try await repository.fetch(id: id) != nil else {
            throw UndoTargetMissing(quotedName: "“\(currentName)”")
        }
        // One name space in any letter case; a case change of its own name is fine.
        if let other = try await repository.findByName(name), other.id != id {
            throw NameTaken(kind: "playlist", name: other.name)
        }
        try await repository.rename(id: id, name: name)
    }

    /// Renames a sync profile as one undo step (`Rename Sync Profile`, `sync.html` copy).
    func renameSyncProfile(_ profileID: Int64, from oldName: String, to newName: String) async throws {
        guard let repository = dependencies.syncProfiles() else { throw UndoTargetMissing(quotedName: "“\(oldName)”") }
        let didChange = dependencies.syncProfileDidChange
        try await undo.perform(
            "Rename Sync Profile",
            message: "Renamed to “\(newName)”",
            failure: nil,
            do: {
                try await Self.renameProfile(profileID, to: newName, currentName: oldName, repository: repository)
                await didChange(profileID)
            },
            undo: {
                try await Self.renameProfile(profileID, to: oldName, currentName: newName, repository: repository)
                await didChange(profileID)
            }
        )
    }

    private static func renameProfile(_ id: Int64, to name: String, currentName: String, repository: SyncRepository) async throws {
        let profiles = try await repository.fetchAll()
        guard profiles.contains(where: { $0.id == id }) else {
            throw UndoTargetMissing(quotedName: "“\(currentName)”")
        }
        if let other = profiles.first(where: { $0.id != id && $0.name.lowercased() == name.lowercased() }) {
            throw NameTaken(kind: "sync profile", name: other.name)
        }
        try await repository.updateSettings(profileId: id, name: name)
    }

    /// The sentence under a rename field (UC-SHEET-17).
    static func renameFailure(_ error: Error, kind: String) -> String {
        UndoFailure.sentence("Couldn’t rename the \(kind)", error) + "."
    }

    // MARK: Delete Playlist (A-PL-DELETE, DEC-049)

    /// The confirmation for deleting `playlist`, with what it leaves.
    func deletionConfirmation(for playlist: Playlist) async -> PlaylistDeletionConfirmation {
        let impact: PlaylistDeletionImpact?
        if let id = playlist.id, let repository = dependencies.playlists() {
            impact = try? await repository.deletionImpact(id: id)
        } else {
            impact = nil
        }
        return .make(name: playlist.name, impact: impact ?? PlaylistDeletionImpact(trackCount: 0, syncProfileNames: []))
    }

    /// Deletes the playlist after the confirmation; restorable with Undo until MLM quits.
    func deletePlaylist(_ playlistID: Int64, name: String) async {
        guard let repository = dependencies.playlists() else { return }
        let effects = self.effects
        _ = try? await undo.perform(
            "Delete “\(name)”",
            failure: "Couldn’t delete “\(name)”",
            do: { () async throws -> PlaylistSnapshot? in
                try await effects.delete(playlistID, repository: repository)
            },
            undo: { snapshot in try await effects.restore(snapshot, repository: repository).playlist.id ?? playlistID },
            redo: { restoredID in try await effects.delete(restoredID, repository: repository) },
            message: { _ in "Deleted “\(name)”" }
        )
    }

    // MARK: -

    private func playlistName(_ id: Int64, repository: PlaylistRepository) async -> String {
        if let name = effects.window.sidebar?.playlistName(id) { return name }
        return (try? await repository.fetch(id: id))?.name ?? "the playlist"
    }

    static func uniqued(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }
}

// MARK: - Effects shared by do / undo / redo

/// The current main window's models, for undo and redo closures that may run after the window
/// that started them closed. The app has one (`main`), filled by the window when it appears.
@MainActor
final class ShellWindowModels {
    static let main = ShellWindowModels()

    private(set) weak var navigation: NavigationModel?
    private(set) weak var sidebar: SidebarModel?
    private(set) weak var statusBar: StatusBarCenter?

    init(navigation: NavigationModel? = nil, sidebar: SidebarModel? = nil, statusBar: StatusBarCenter? = nil) {
        self.navigation = navigation
        self.sidebar = sidebar
        self.statusBar = statusBar
    }

    func use(navigation: NavigationModel, sidebar: SidebarModel, statusBar: StatusBarCenter) {
        self.navigation = navigation
        self.sidebar = sidebar
        self.statusBar = statusBar
    }
}

/// What every playlist change must update in the window: the sidebar rows, routes to a
/// deleted playlist, and everyone listening for `.playlistDidChange` (detail views, covers).
@MainActor
struct PlaylistEffects {
    let window: ShellWindowModels

    func changed(_ playlistID: Int64?, repository: PlaylistRepository) async {
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: playlistID.map { ["playlistId": $0] }
        )
        guard let sidebar = window.sidebar else { return }
        for removed in await sidebar.reloadPlaylists(repository) {
            window.navigation?.removePlaylist(removed)
        }
    }

    /// Delete with a snapshot; leave the playlist's destination.
    func delete(_ playlistID: Int64?, repository: PlaylistRepository) async throws -> PlaylistSnapshot {
        guard let playlistID else { throw PlaylistRepositoryError.playlistNotFound }
        let snapshot = try await repository.deleteReturningSnapshot(id: playlistID)
        window.navigation?.removePlaylist(playlistID)
        await changed(playlistID, repository: repository)
        return snapshot
    }

    /// Restore a snapshot. Says so in the status bar only when it couldn't come back exactly.
    func restore(_ snapshot: PlaylistSnapshot, repository: PlaylistRepository) async throws -> PlaylistRestoreResult {
        let result = try await repository.restore(snapshot)
        await changed(result.playlist.id, repository: repository)
        if let note = Self.restoreNote(original: snapshot.playlist.name, result: result) {
            window.statusBar?.post(note)
        }
        return result
    }

    /// `Restored “Warm-up 2” — “Warm-up” was taken` · `… — 2 of its tracks are no longer in the
    /// library` · `… — 1 of its sync profiles no longer exists` · `… — “Warm-up” was imported
    /// again, so this copy is no longer linked to SoundCloud`; nil when the restore was exact.
    static func restoreNote(original: String, result: PlaylistRestoreResult) -> String? {
        var causes: [String] = []
        if let unlinked = result.unlinked {
            causes.append("“\(unlinked.otherPlaylistName)” was imported again, so this copy is no longer linked to \(sourceDisplayName(unlinked.sourceName))")
        }
        if result.wasRenamed { causes.append("“\(original)” was taken") }
        if result.droppedTrackCount > 0 {
            let n = result.droppedTrackCount
            causes.append("\(n.formatted(.number)) of its tracks \(n == 1 ? "is" : "are") no longer in the library")
        }
        if result.droppedSyncProfileCount > 0 {
            let n = result.droppedSyncProfileCount
            causes.append("\(n.formatted(.number)) of its sync profiles no longer \(n == 1 ? "exists" : "exist")")
        }
        guard !causes.isEmpty else { return nil }
        return "Restored “\(result.playlist.name)” — " + causes.joined(separator: ", ")
    }

    /// Glossary name of a stored source name (`soundcloud` → `SoundCloud`, UC-GLOSS-01).
    static func sourceDisplayName(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let names: [(String, String)] = [
            ("soundcloud", "SoundCloud"), ("spotify", "Spotify"), ("youtube", "YouTube"),
            ("apple", "Apple Music"), ("dab", "DAB"), ("qobuz", "Qobuz"), ("last", "Last.fm"),
        ]
        return names.first { lowered.contains($0.0) }?.1 ?? raw
    }
}

// MARK: - Delete Playlist confirmation

/// A-PL-DELETE: one confirmation for the sidebar (and later the grid and detail). The title
/// asks with the name; the message says what the playlist leaves, what stays, and that Undo
/// works until MLM quits (UC-SHEET-12/13, UC-UNDO-05). Pure, so the wording is unit-tested.
struct PlaylistDeletionConfirmation: Equatable, Sendable {
    static let confirmTitle = "Delete Playlist"

    let title: String
    let message: String

    static func make(name: String, impact: PlaylistDeletionImpact) -> PlaylistDeletionConfirmation {
        let leaves: String
        switch impact.syncProfileNames.count {
        case 0:
            leaves = "The playlist is removed from the sidebar."
        case 1:
            leaves = "The playlist is removed from the sidebar and from the sync profile “\(impact.syncProfileNames[0])”."
        case 2:
            leaves = "The playlist is removed from the sidebar and from the sync profiles “\(impact.syncProfileNames[0])” and “\(impact.syncProfileNames[1])”."
        default:
            leaves = "The playlist is removed from the sidebar and from \(impact.syncProfileNames.count.formatted(.number)) sync profiles."
        }
        let stays: String
        switch impact.trackCount {
        case 0: stays = "It has no tracks."
        case 1: stays = "Its track and its file stay in the library."
        default: stays = "Its \(impact.trackCount.formatted(.number)) tracks and their files stay in the library."
        }
        return PlaylistDeletionConfirmation(
            title: "Delete “\(name)”?",
            message: "\(leaves) \(stays) You can undo this until you quit MLM."
        )
    }
}

/// Another thing of the same kind already has the name (rename).
struct NameTaken: PlainCauseError {
    let kind: String
    let name: String
    var plainCause: String { "another \(kind) is called “\(name)”" }
}

// MARK: - Drops (W2-H, DEC-040)

/// The undoable edits a drop makes that no menu made before: tracks placed at a position in a
/// playlist (reorder and insert, exact positions on undo), sync-profile content, playlist
/// covers, a new playlist named after a dropped folder. Every drop is one undo step
/// (UC-UNDO-08) with its UC-UNDO-07 name and status-bar confirmation; nothing here asks.
extension ShellEdits {
    // MARK: Place in a playlist (D-PLD-REORDER, D-PLD-INSERT)

    /// A track's position before and after a placement.
    struct PlacementMove: Equatable, Sendable {
        let trackID: Int64
        let from: String
        let to: String
    }

    /// What a placement did: members moved, rows inserted, and where the first track landed.
    struct PlacementDone: Sendable {
        let moves: [PlacementMove]
        let inserted: [PlaylistTrack]
        /// 1-based position of the first placed track afterwards.
        let position: Int
    }

    /// What its undo did (for redo).
    struct PlacementUndone: Sendable {
        let moves: [PlacementMove]
        let removed: [PlaylistTrack]
    }

    /// Places `plan.trackIDs` before `plan.beforeTrackID` (or at the end) in the playlist —
    /// members move, others are inserted — as one step. Undo puts every moved track back at its
    /// exact earlier position and removes exactly the rows this inserted; Redo restores those
    /// rows (same row ids, positions, added dates) and the new positions.
    func placeTracks(_ plan: PlaylistDropPlan, inPlaylist playlistID: Int64, name: String) async {
        guard let repository = dependencies.playlists() else { return }
        let effects = self.effects
        let tracks = dependencies.tracks()
        let isReorder = plan.kind == .reorder
        _ = try? await undo.perform(
            isReorder ? DropWords.reorderActionName(name) : DropWords.addActionName(name),
            failure: isReorder ? "Couldn’t reorder “\(name)”" : "Couldn’t add \(StatusBarText.tracks(plan.trackIDs.count)) to “\(name)”",
            do: { () async throws -> PlacementDone? in
                guard let before = try await repository.snapshot(id: playlistID) else {
                    throw UndoTargetMissing(quotedName: "“\(name)”")
                }
                let members = Set(before.entries.map(\.trackId))
                var ids = plan.trackIDs
                // Never a row for a track that left the library meanwhile.
                let newIDs = ids.filter { !members.contains($0) }
                if !newIDs.isEmpty, let tracks {
                    let existing = Set(try await tracks.fetchTracks(ids: Set(newIDs)).compactMap(\.id))
                    ids = ids.filter { members.contains($0) || existing.contains($0) }
                }
                guard !ids.isEmpty else { return nil }
                let placements = PlaylistPlacement.positions(
                    for: ids, before: plan.beforeTrackID,
                    in: before.entries.map { (trackID: $0.trackId, position: Optional($0.position)) }
                )
                try await repository.placeTracks(playlistId: playlistID, placements: placements)
                guard let after = try await repository.snapshot(id: playlistID) else { return nil }
                let oldPosition = Dictionary(before.entries.map { ($0.trackId, $0.position) }, uniquingKeysWith: { first, _ in first })
                let moves = placements.compactMap { placement in
                    oldPosition[placement.trackId].map { PlacementMove(trackID: placement.trackId, from: $0, to: placement.position) }
                }
                let placed = Set(ids)
                let inserted = after.entries.filter { placed.contains($0.trackId) && !members.contains($0.trackId) }
                let first = after.entries.firstIndex { placed.contains($0.trackId) } ?? 0
                await effects.changed(playlistID, repository: repository)
                return PlacementDone(moves: moves, inserted: inserted, position: first + 1)
            },
            undo: { done in
                let removed = try await repository.removeEntries(done.inserted)
                let moves = try await Self.presentMoves(done.moves, playlistID: playlistID, repository: repository)
                try await repository.placeTracks(playlistId: playlistID, placements: moves.map { ($0.trackID, $0.from) })
                guard !removed.isEmpty || !moves.isEmpty else {
                    throw UndoNothingLeft(note: "Nothing to undo — the tracks are no longer in “\(name)”")
                }
                await effects.changed(playlistID, repository: repository)
                return PlacementUndone(moves: moves, removed: removed)
            },
            redo: { undone in
                let restored = try await repository.restoreEntries(undone.removed)
                let moves = try await Self.presentMoves(undone.moves, playlistID: playlistID, repository: repository)
                try await repository.placeTracks(playlistId: playlistID, placements: moves.map { ($0.trackID, $0.to) })
                guard !restored.isEmpty || !moves.isEmpty else {
                    throw UndoNothingLeft(note: "Nothing to redo — the tracks can’t go back into “\(name)”")
                }
                await effects.changed(playlistID, repository: repository)
                return PlacementDone(moves: moves, inserted: restored, position: 1)
            },
            message: { done in
                isReorder
                    ? DropWords.reorderedMessage(count: done.moves.count, position: done.position, playlist: name)
                    : DropWords.insertedMessage(added: done.inserted.count, moved: done.moves.count,
                                                position: done.position, playlist: name)
            }
        )
    }

    /// The moves whose track is still in the playlist (only those go back or forth: a moved
    /// position is never written for a track that was removed meanwhile — that would add it).
    private static func presentMoves(_ moves: [PlacementMove], playlistID: Int64,
                                     repository: PlaylistRepository) async throws -> [PlacementMove] {
        guard !moves.isEmpty else { return [] }
        guard let current = try await repository.snapshot(id: playlistID) else {
            throw UndoTargetMissing(quotedName: "the playlist")
        }
        let present = Set(current.entries.map(\.trackId))
        return moves.filter { present.contains($0.trackID) }
    }

    /// The tracks of `playlistIDs`, each playlist in its order, one after the other, each once.
    func tracks(ofPlaylists playlistIDs: [Int64]) async -> [Int64] {
        guard let repository = dependencies.playlists() else { return [] }
        var ids: [Int64] = []
        for id in playlistIDs {
            let tracks = (try? await repository.fetchTracks(playlistId: id)) ?? []
            ids.append(contentsOf: tracks.compactMap(\.id))
        }
        return Self.uniqued(ids)
    }

    // MARK: New playlist named after a dropped folder

    /// Like New Playlist from Selection, named `name` (numbered when taken; `Untitled Playlist`
    /// without one) and put into rename mode in the sidebar. Doesn't navigate.
    @discardableResult
    func newPlaylist(named name: String?, fromTrackIDs trackIDs: [Int64]) async -> Playlist? {
        guard let name, !name.isEmpty else { return await newPlaylist(fromTrackIDs: trackIDs) }
        let ordered = Self.uniqued(trackIDs)
        guard !ordered.isEmpty, let repository = dependencies.playlists() else { return nil }
        let effects = self.effects
        let created = try? await undo.perform(
            "New Playlist",
            failure: "Couldn’t create the playlist",
            do: { () async throws -> Playlist? in
                let playlist = try await repository.createNumbered(baseName: name, trackIds: ordered)
                await effects.changed(playlist.id, repository: repository)
                return playlist
            },
            undo: { playlist in try await effects.delete(playlist.id, repository: repository) },
            redo: { snapshot in try await effects.restore(snapshot, repository: repository).playlist },
            message: { "Created “\($0.name)” with \(StatusBarText.tracks(ordered.count))" }
        )
        if let id = created?.id {
            effects.window.sidebar?.requestRename(playlist: id)
        }
        return created
    }

    // MARK: Sync profile content (D-LIB-TO-SYNC, D-SYNC-*-TO-PROFILE)

    /// Adds the tracks to the profile's content; tracks already in it are skipped and counted.
    /// Undo removes exactly the ones this added. The open profile page is not switched.
    func addTracks(_ trackIDs: [Int64], toSyncProfile profileID: Int64, name: String) async {
        let ordered = Self.uniqued(trackIDs)
        guard !ordered.isEmpty, let repository = dependencies.syncProfiles() else { return }
        let didChange = dependencies.syncContentDidChange
        do {
            let added = try await undo.perform(
                DropWords.addActionName(name),
                failure: "Couldn’t add \(StatusBarText.tracks(ordered.count)) to “\(name)”",
                do: { () async throws -> [Int64]? in
                    let present = Set(try await repository.fetchProfileTracks(profileId: profileID).compactMap(\.id))
                    let new = ordered.filter { !present.contains($0) }
                    guard !new.isEmpty else { return nil }
                    for id in new { try await repository.addTrack(profileId: profileID, trackId: id) }
                    await didChange(profileID)
                    return new
                },
                undo: { added in
                    for id in added { try await repository.removeTrack(profileId: profileID, trackId: id) }
                    await didChange(profileID)
                    return added
                },
                redo: { removed in
                    for id in removed { try await repository.addTrack(profileId: profileID, trackId: id) }
                    await didChange(profileID)
                    return removed
                },
                message: { DropWords.addedToProfile(tracks: $0.count, alreadyPresent: ordered.count - $0.count, profile: name) }
            )
            if added == nil {
                effects.window.statusBar?.post(DropWords.alreadyInProfile(count: ordered.count, kind: "track", profile: name))
            }
        } catch {
            // Reported in the status bar by the center.
        }
    }

    /// Adds the playlists to the profile (the playlist itself, so later changes sync too).
    func addPlaylists(_ playlistIDs: [Int64], toSyncProfile profileID: Int64, name: String) async {
        let ordered = Self.uniqued(playlistIDs)
        guard !ordered.isEmpty, let repository = dependencies.syncProfiles(),
              let playlists = dependencies.playlists() else { return }
        let didChange = dependencies.syncContentDidChange
        var names: [Int64: String] = [:]
        for id in ordered { names[id] = await playlistName(id, repository: playlists) }
        let nameByID = names
        do {
            let added = try await undo.perform(
                DropWords.addActionName(name),
                failure: "Couldn’t add \(StatusBarText.playlists(ordered.count)) to “\(name)”",
                do: { () async throws -> [Int64]? in
                    let present = Set(try await repository.fetchProfilePlaylists(profileId: profileID).compactMap(\.id))
                    let new = ordered.filter { !present.contains($0) }
                    guard !new.isEmpty else { return nil }
                    for id in new { try await repository.addPlaylist(profileId: profileID, playlistId: id) }
                    await didChange(profileID)
                    return new
                },
                undo: { added in
                    for id in added { try await repository.removePlaylist(profileId: profileID, playlistId: id) }
                    await didChange(profileID)
                    return added
                },
                redo: { removed in
                    for id in removed { try await repository.addPlaylist(profileId: profileID, playlistId: id) }
                    await didChange(profileID)
                    return removed
                },
                message: { added in DropWords.addedPlaylistsToProfile(names: added.map { nameByID[$0] ?? "the playlist" }, profile: name) }
            )
            if added == nil {
                effects.window.statusBar?.post(DropWords.alreadyInProfile(count: ordered.count, kind: "playlist", profile: name))
            }
        } catch {
            // Reported in the status bar by the center.
        }
    }

    // MARK: Playlist cover (D-PL-COVER-TO-CARD, D-PLD-COVER-TO-HEADER)

    /// Sets a custom cover from a dropped image as one step (`Set Cover`). Undo puts the earlier
    /// cover back exactly — its picture and whether it was automatic or chosen. Returns the
    /// refusal sentence when the image can't be used (shown on the cover, UC-SURF-04); nothing
    /// is registered then.
    func setCover(_ source: CoverSource, ofPlaylist playlistID: Int64, name: String) async -> String? {
        guard let covers = dependencies.covers() else { return nil }
        let image: NSImage?
        let fileName: String?
        switch source {
        case .file(let url):
            image = NSImage(contentsOf: url)
            fileName = url.lastPathComponent
        case .data(let data):
            image = NSImage(data: data)
            fileName = nil
        }
        guard let image, image.isValid, image.size.width > 0, image.size.height > 0 else {
            return DropWords.notACover(fileName: fileName)
        }
        do {
            _ = try await undo.perform(
                DropWords.setCoverActionName,
                failure: "Couldn’t set the cover of “\(name)”",
                do: { () async throws -> PlaylistCoverService.CoverState? in
                    let before = try await covers.coverState(playlistId: playlistID)
                    try await covers.applyCustomCover(playlistId: playlistID, image: image)
                    return before
                },
                undo: { before in
                    let after = try await covers.coverState(playlistId: playlistID)
                    try await covers.restoreCoverState(before, playlistId: playlistID)
                    return after
                },
                redo: { after in
                    let before = try await covers.coverState(playlistId: playlistID)
                    try await covers.restoreCoverState(after, playlistId: playlistID)
                    return before
                },
                message: { _ in DropWords.coverSetMessage(name) }
            )
        } catch {
            // Reported in the status bar by the center.
        }
        return nil
    }
}

// MARK: - Sync profile content and device changes (W3-SYNC, DEC-041, DEC-050)

/// Removing content from a profile (no alert — A-SYNC-REMOVECONTENT is replaced by Undo),
/// Duplicate, and applying playlist changes read from a device: one undo step each.
extension ShellEdits {
    /// `Removed “Warm-up” from “iPod Classic” — its files leave the device at the next sync`.
    /// Undo puts exactly these links back.
    func removePlaylists(_ playlistIDs: [Int64], fromSyncProfile profileID: Int64, name: String,
                         playlistNames: [Int64: String] = [:]) async {
        let ordered = Self.uniqued(playlistIDs)
        guard !ordered.isEmpty, let repository = dependencies.syncProfiles() else { return }
        let didChange = dependencies.syncContentDidChange
        _ = try? await undo.perform(
            SyncWords.removeActionName(name),
            failure: "Couldn’t remove \(StatusBarText.playlists(ordered.count)) from “\(name)”",
            do: { () async throws -> [Int64]? in
                let present = Set(try await repository.fetchProfilePlaylists(profileId: profileID).compactMap(\.id))
                let removed = ordered.filter(present.contains)
                guard !removed.isEmpty else { return nil }
                for id in removed { try await repository.removePlaylist(profileId: profileID, playlistId: id) }
                await didChange(profileID)
                return removed
            },
            undo: { removed in
                for id in removed { try await repository.addPlaylist(profileId: profileID, playlistId: id) }
                await didChange(profileID)
                return removed
            },
            redo: { added in
                for id in added { try await repository.removePlaylist(profileId: profileID, playlistId: id) }
                await didChange(profileID)
                return added
            },
            message: { removed in
                SyncWords.removedFromProfile(names: removed.compactMap { playlistNames[$0] },
                                             count: removed.count, kind: "playlist", profile: name)
            }
        )
    }

    /// Tracks added one by one (the Tracks list of the profile).
    func removeTracks(_ trackIDs: [Int64], fromSyncProfile profileID: Int64, name: String,
                      trackNames: [Int64: String] = [:]) async {
        let ordered = Self.uniqued(trackIDs)
        guard !ordered.isEmpty, let repository = dependencies.syncProfiles() else { return }
        let didChange = dependencies.syncContentDidChange
        _ = try? await undo.perform(
            SyncWords.removeActionName(name),
            failure: "Couldn’t remove \(StatusBarText.tracks(ordered.count)) from “\(name)”",
            do: { () async throws -> [Int64]? in
                let present = Set(try await repository.fetchProfileTracks(profileId: profileID).compactMap(\.id))
                let removed = ordered.filter(present.contains)
                guard !removed.isEmpty else { return nil }
                for id in removed { try await repository.removeTrack(profileId: profileID, trackId: id) }
                await didChange(profileID)
                return removed
            },
            undo: { removed in
                for id in removed { try await repository.addTrack(profileId: profileID, trackId: id) }
                await didChange(profileID)
                return removed
            },
            redo: { added in
                for id in added { try await repository.removeTrack(profileId: profileID, trackId: id) }
                await didChange(profileID)
                return added
            },
            message: { removed in
                SyncWords.removedFromProfile(names: removed.compactMap { trackNames[$0] },
                                             count: removed.count, kind: "track", profile: name)
            }
        )
    }

    /// Duplicate: `Created “iPod Classic copy”` with Undo (which deletes the copy — it has no
    /// sync history yet). Nothing navigates (P3).
    func duplicateSyncProfile(_ profileID: Int64, name: String) async {
        guard let repository = dependencies.syncProfiles() else { return }
        let didChange = dependencies.syncProfileDidChange
        _ = try? await undo.perform(
            "Duplicate “\(name)”",
            failure: "Couldn’t duplicate “\(name)”",
            do: { () async throws -> SyncProfile? in
                let copy = try await repository.duplicate(id: profileID)
                await didChange(profileID)
                return copy
            },
            undo: { copy in
                if let id = copy.id { try await repository.delete(id: id) }
                await didChange(profileID)
                return ()
            },
            redo: { _ in
                let copy = try await repository.duplicate(id: profileID)
                await didChange(profileID)
                return copy
            },
            message: { "Created “\($0.name)”" }
        )
    }

    /// Read Playlist Changes from Device ▸ Apply: every checked change of every included card in
    /// **one** undo step (UC-UNDO-02/08). A merge, never a replace (PP-SYNC-04). A card that
    /// can't be applied keeps its error and the others go ahead.
    ///
    /// - Returns: the cards that were applied, and the error sentence per card that wasn't.
    @discardableResult
    func applyDeviceChanges(
        _ items: [(card: DevicePlaylistCard, selection: DevicePlaylistSelection)],
        service: DevicePlaylistChangeService,
        profileName: String
    ) async -> (applied: Set<String>, errors: [String: String]) {
        guard let playlists = dependencies.playlists() else { return ([], [:]) }
        let effects = self.effects
        var applied = Set<String>()
        var errors: [String: String] = [:]
        let summary = try? await undo.performGroup(
            "Apply Changes from “\(profileName)”",
            failure: "Couldn’t apply the changes from “\(profileName)”",
            { group -> DeviceChangesSummary in
                var summary = DeviceChangesSummary()
                for (card, selection) in items where selection.include {
                    do {
                        let done: DevicePlaylistApplied? = try await group.perform(
                            do: { try await service.apply(card, selection: selection) },
                            undo: { done -> DevicePlaylistUndone in
                                guard let done else { return .nothing }
                                switch done {
                                case .updated(let id, _, let before, _, _):
                                    try await service.replaceRows(playlistID: id, with: before)
                                    await effects.changed(id, repository: playlists)
                                    return .rows(done)
                                case .created(let playlist, _):
                                    // The new playlist goes; Redo brings back the same one (same id).
                                    return .deleted(try await effects.delete(playlist.id, repository: playlists))
                                }
                            },
                            redo: { undone -> DevicePlaylistApplied? in
                                switch undone {
                                case .nothing:
                                    return nil
                                case .rows(let done):
                                    if case .updated(let id, _, _, let after, _) = done {
                                        try await service.replaceRows(playlistID: id, with: after)
                                        await effects.changed(id, repository: playlists)
                                    }
                                    return done
                                case .deleted(let snapshot):
                                    let restored = try await effects.restore(snapshot, repository: playlists)
                                    return .created(restored.playlist, trackCount: snapshot.entries.count)
                                }
                            }
                        )
                        guard let done else { continue }
                        applied.insert(card.id)
                        switch done {
                        case .updated(let id, _, _, _, let changes):
                            summary.changes += changes
                            summary.playlists += 1
                            await effects.changed(id, repository: playlists)
                        case .created(let playlist, _):
                            summary.created.append(playlist.name)
                            await effects.changed(playlist.id, repository: playlists)
                        }
                    } catch {
                        errors[card.id] = UndoFailure.sentence("Couldn’t apply the changes to “\(card.target.name)”", error) + "."
                    }
                }
                return summary
            },
            message: { $0.message(profile: profileName) }
        )
        _ = summary
        return (applied, errors)
    }
}

/// What an undo of one card left, for its redo.
enum DevicePlaylistUndone: Sendable {
    case nothing
    case rows(DevicePlaylistApplied)
    case deleted(PlaylistSnapshot)
}

/// What one Apply did, for its confirmation.
struct DeviceChangesSummary: Sendable {
    var changes = 0
    var playlists = 0
    var created: [String] = []

    /// `Applied 5 changes to 2 playlists and created “Gym” from “iPod Classic”`.
    func message(profile: String) -> String {
        var parts: [String] = []
        if changes > 0 {
            parts.append("applied \(changes.formatted(.number)) \(changes == 1 ? "change" : "changes") to \(StatusBarText.playlists(playlists))")
        }
        if created.count == 1 {
            parts.append("created “\(created[0])”")
        } else if created.count > 1 {
            parts.append("created \(StatusBarText.playlists(created.count))")
        }
        let text = parts.joined(separator: " and ")
        return (text.prefix(1).uppercased() + text.dropFirst()) + " from “\(profile)”"
    }
}

/// Status-bar and undo words of sync profiles (UC-UNDO-07, UC-COPY-12).
enum SyncWords {
    static func removeActionName(_ profile: String) -> String { "Remove from “\(profile)”" }

    /// `Removed “Warm-up” from “iPod Classic” — its files leave the device at the next sync`.
    static func removedFromProfile(names: [String], count: Int, kind: String, profile: String) -> String {
        let subject = count == 1 && names.count == 1
            ? "“\(names[0])”"
            : "\(count.formatted(.number)) \(kind)\(count == 1 ? "" : "s")"
        let consequence = count == 1 && kind == "track" ? "its file leaves" : "the files leave"
        return "Removed \(subject) from “\(profile)” — \(consequence) the device at the next sync"
    }
}
