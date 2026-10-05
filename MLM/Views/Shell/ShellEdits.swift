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

        static func live(_ container: DependencyContainer) -> Dependencies {
            Dependencies(
                playlists: { container.playlistRepository },
                syncProfiles: { container.syncRepository },
                syncProfileDidChange: { id in
                    guard let sync = container.syncViewModel else { return }
                    await sync.loadProfiles()
                    if sync.selectedProfile?.id == id {
                        sync.selectedProfile = sync.profiles.first { $0.id == id }
                    }
                }
            )
        }
    }

    /// Default name of a new playlist (UC §23 C5).
    static let untitledPlaylistName = "Untitled Playlist"

    private let dependencies: Dependencies
    private let undo: UndoCenter
    private let effects: PlaylistEffects

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
    func addTracks(_ trackIDs: [Int64], toPlaylist playlistID: Int64) async {
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
                message: { Self.addedMessage(added: $0.entries.count, alreadyPresent: $0.alreadyPresent, playlist: name) }
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
