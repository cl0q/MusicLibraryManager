import AppKit
import Foundation

// MARK: - Undoable playlist and folder edits of W3-PL (UC-UNDO-02, UC-UNDO-07, DEC-041)

/// Words of the W3-PL edits (UC-STATUS-05 shapes; the folder sentences are `playlists.html`'s).
enum PlaylistEditWords {
    static let newFolderAction = "New Playlist Folder"
    static let renameFolderAction = "Rename Playlist Folder"

    static func folderCreated(_ name: String) -> String {
        "Created the playlist folder “\(name)” — drag playlists onto it"
    }

    static func folderDeleted(_ name: String, playlists: Int) -> String {
        guard playlists > 0 else { return "Deleted the folder “\(name)”" }
        let moved = playlists == 1 ? "its playlist moved out of it" : "its \(playlists.formatted(.number)) playlists moved out of it"
        return "Deleted the folder “\(name)” — \(moved), none was deleted"
    }

    /// `Move to “Sets”` · `Move to No Folder` · `Reorder Playlists` (UC-UNDO-07).
    static func moveAction(folderName: String?, isReorder: Bool) -> String {
        if isReorder { return "Reorder Playlists" }
        return folderName.map { "Move to “\($0)”" } ?? "Move to No Folder"
    }

    /// `Moved “Sunday records” to the folder “Sets”` · `Moved 3 playlists out of “Sets”` ·
    /// `Moved “Warm-up”`.
    static func moved(names: [String], toFolder folder: String?, outOf previous: String?) -> String {
        let subject = names.count == 1 ? "“\(names[0])”" : StatusBarText.playlists(names.count)
        if let folder { return "Moved \(subject) to the folder “\(folder)”" }
        if let previous { return "Moved \(subject) out of “\(previous)”" }
        return "Moved \(subject)"
    }

    static let useAutomaticCoverAction = "Use Automatic Cover"
    static func automaticCover(_ playlist: String) -> String { "Using the automatic cover for “\(playlist)”" }

    static func linkAction(_ playlist: String) -> String { "Link “\(playlist)”" }
    /// `Linked “Warm-up” to SoundCloud — nothing was added or removed` (S-PLD-LINK.E05).
    static func linked(_ playlist: String, source: String) -> String {
        "Linked “\(playlist)” to \(source) — nothing was added or removed"
    }

    static let importM3UAction = "Import M3U"
    /// `Added 38 tracks to “Warm-up” · 4 already there · 6 not found` (A-PLD-IMPORTDONE merged).
    static func m3uImported(added: Int, alreadyThere: Int, notFound: Int, playlist: String) -> String {
        var text = "Added \(StatusBarText.tracks(added)) to “\(playlist)”"
        if alreadyThere > 0 { text += " · \(alreadyThere.formatted(.number)) already there" }
        if notFound > 0 { text += " · \(notFound.formatted(.number)) not found" }
        return text
    }

    static func m3uCreated(_ playlist: String, tracks: Int, notFound: Int) -> String {
        var text = "Created “\(playlist)” with \(StatusBarText.tracks(tracks))"
        if notFound > 0 { text += " · \(notFound.formatted(.number)) not found" }
        return text
    }
}

/// What a link change replaced.
struct PlaylistSourceLink: Equatable, Sendable {
    let sourceID: Int64?
    let externalID: String?
}

extension ShellEdits {
    private var folderRepository: PlaylistFolderRepository? { dependencies.playlists()?.folders }

    // MARK: New Playlist Folder (⌥⌘N, S-PLFOLDER-NEW)

    /// Creates `untitled folder` (numbered when taken) first among the top-level rows and puts
    /// its name into edit mode. Undo removes it; Redo brings back the same folder.
    @discardableResult
    func newPlaylistFolder() async -> PlaylistFolder? {
        guard let repository = dependencies.playlists() else { return nil }
        let folders = repository.folders
        let effects = self.effects
        let created = try? await undo.perform(
            PlaylistEditWords.newFolderAction,
            failure: "Couldn’t create the playlist folder",
            do: { () async throws -> PlaylistFolder? in
                let folder = try await folders.createFolder()
                await effects.changed(nil, repository: repository)
                return folder
            },
            undo: { folder in
                let snapshot = try await folders.deleteFolderReturningSnapshot(id: folder.id ?? -1)
                await effects.changed(nil, repository: repository)
                return snapshot
            },
            redo: { snapshot in
                let folder = try await folders.restoreFolder(snapshot)
                await effects.changed(nil, repository: repository)
                return folder
            },
            message: { PlaylistEditWords.folderCreated($0.name) }
        )
        if let id = created?.id {
            effects.window.sidebar?.requestRename(folder: id)
        }
        return created
    }

    /// `New Playlist Folder…` in Move to Folder ▸ (CM-SUB-MOVE): a new folder with the playlists
    /// in it, one step; its name goes into edit mode.
    func newPlaylistFolder(moving playlistIDs: [Int64]) async {
        guard !playlistIDs.isEmpty, let repository = dependencies.playlists() else { return }
        let folders = repository.folders
        let effects = self.effects
        struct Done: Sendable { let folder: PlaylistFolder; let change: PlaylistOrderChange }
        let done = try? await undo.perform(
            PlaylistEditWords.newFolderAction,
            failure: "Couldn’t create the playlist folder",
            do: { () async throws -> Done? in
                let folder = try await folders.createFolder()
                let change = try await folders.move(playlistIDs.map(PlaylistSidebarItemID.playlist), into: folder.id, before: nil)
                await effects.changed(nil, repository: repository)
                return Done(folder: folder, change: change)
            },
            undo: { done -> PlaylistFolderSnapshot in
                _ = try await folders.revert(done.change.inverted)
                let snapshot = try await folders.deleteFolderReturningSnapshot(id: done.folder.id ?? -1)
                await effects.changed(nil, repository: repository)
                return snapshot
            },
            redo: { snapshot in
                let folder = try await folders.restoreFolder(snapshot)
                let change = try await folders.move(playlistIDs.map(PlaylistSidebarItemID.playlist), into: folder.id, before: nil)
                await effects.changed(nil, repository: repository)
                return Done(folder: folder, change: change)
            },
            message: { PlaylistEditWords.folderCreated($0.folder.name) }
        )
        if let id = done?.folder.id {
            effects.window.sidebar?.requestRename(folder: id)
        }
    }

    // MARK: Rename / delete a folder

    /// One undo step (`Rename Playlist Folder`); throws so the inline field shows why (UC-SHEET-17).
    func renamePlaylistFolder(_ folderID: Int64, from oldName: String, to newName: String) async throws {
        guard let repository = dependencies.playlists() else { throw PlaylistFolderError.folderNotFound }
        let folders = repository.folders
        let effects = self.effects
        try await undo.perform(
            PlaylistEditWords.renameFolderAction,
            message: "Renamed “\(oldName)” to “\(newName)”",
            failure: nil,
            do: {
                try await folders.renameFolder(id: folderID, to: newName)
                await effects.changed(nil, repository: repository)
            },
            undo: {
                try await folders.renameFolder(id: folderID, to: oldName)
                await effects.changed(nil, repository: repository)
            }
        )
    }

    /// Deletes the folder — its playlists move up to the top level, none is deleted
    /// (UC-SIDE-08). Undoable, so nothing asks first (UC-UNDO-02/04).
    func deletePlaylistFolder(_ folderID: Int64, name: String) async {
        guard let repository = dependencies.playlists() else { return }
        let folders = repository.folders
        let effects = self.effects
        _ = try? await undo.perform(
            "Delete “\(name)”",
            failure: "Couldn’t delete the folder “\(name)”",
            do: { () async throws -> PlaylistFolderSnapshot? in
                let snapshot = try await folders.deleteFolderReturningSnapshot(id: folderID)
                await effects.changed(nil, repository: repository)
                return snapshot
            },
            undo: { snapshot in
                let folder = try await folders.restoreFolder(snapshot)
                await effects.changed(nil, repository: repository)
                return folder.id ?? folderID
            },
            redo: { restoredID in
                let snapshot = try await folders.deleteFolderReturningSnapshot(id: restoredID)
                await effects.changed(nil, repository: repository)
                return snapshot
            },
            message: { PlaylistEditWords.folderDeleted(name, playlists: $0.members.count) }
        )
    }

    // MARK: Move and reorder (D-PL-PLAYLIST-TO-FOLDER, D-PL-CARD-REORDER, CM-SUB-MOVE)

    /// Places rows into `folderID` (nil = top level) before `before` (nil = at the end) as one
    /// step. Undo puts every moved row back exactly; nothing happens when nothing moves.
    func movePlaylistItems(_ items: [PlaylistSidebarItemID], into folderID: Int64?, before: PlaylistSidebarItemID?) async {
        guard !items.isEmpty, let repository = dependencies.playlists() else { return }
        let folders = repository.folders
        let effects = self.effects
        let sidebar = effects.window.sidebar
        let tree = sidebar?.tree ?? .empty
        let targetName = folderID.flatMap { sidebar?.folderName($0) }
        let playlistIDs = items.compactMap { item -> Int64? in
            if case .playlist(let id) = item { return id }
            return nil
        }
        let previousFolders = Set(playlistIDs.compactMap { tree.folder(containing: $0)?.id })
        // Every row stays in the container it is in: a reorder.
        let isReorder = playlistIDs.allSatisfy { tree.folder(containing: $0)?.id == folderID }
        let names = items.compactMap { item -> String? in
            switch item {
            case .playlist(let id): sidebar?.playlistName(id)
            case .folder(let id): sidebar?.folderName(id)
            }
        }
        let previousName = previousFolders.count == 1 ? previousFolders.first.flatMap { sidebar?.folderName($0) } : nil
        _ = try? await undo.perform(
            PlaylistEditWords.moveAction(folderName: targetName, isReorder: isReorder),
            failure: "Couldn’t move \(names.count == 1 ? "“\(names[0])”" : StatusBarText.playlists(names.count))",
            do: { () async throws -> PlaylistOrderChange? in
                let change = try await folders.move(items, into: folderID, before: before)
                guard !change.isEmpty else { return nil }
                await effects.changed(nil, repository: repository)
                return change
            },
            undo: { change in
                let applied = try await folders.revert(change)
                guard !applied.before.isEmpty else {
                    throw UndoNothingLeft(note: "Nothing to undo — the playlists were moved again")
                }
                await effects.changed(nil, repository: repository)
                return applied
            },
            redo: { applied in
                let again = try await folders.revert(applied)
                guard !again.before.isEmpty else {
                    throw UndoNothingLeft(note: "Nothing to redo — the playlists were moved again")
                }
                await effects.changed(nil, repository: repository)
                return again
            },
            message: { _ in
                PlaylistEditWords.moved(names: names, toFolder: isReorder ? nil : targetName,
                                        outOf: isReorder || folderID != nil ? nil : previousName)
            }
        )
    }

    // MARK: New playlist inside a folder (P-SIDEBAR.N03/menu, tracks dropped on a folder)

    /// `New Playlist in Folder` (no tracks: rename mode, opens it like ⌘N) or tracks dropped on a
    /// folder (`New playlist inside`, UC-DND matrix; named inline, doesn't navigate).
    @discardableResult
    func newPlaylist(inFolder folderID: Int64, trackIDs: [Int64] = []) async -> Playlist? {
        guard let repository = dependencies.playlists() else { return nil }
        let ordered = Self.uniqued(trackIDs)
        let effects = self.effects
        let created = try? await undo.perform(
            ordered.isEmpty ? "New Playlist" : "New Playlist from Selection",
            failure: "Couldn’t create the playlist",
            do: { () async throws -> Playlist? in
                let playlist = try await repository.createNumbered(baseName: Self.untitledPlaylistName,
                                                                   trackIds: ordered, inFolder: folderID)
                await effects.changed(playlist.id, repository: repository)
                return playlist
            },
            undo: { playlist in try await effects.delete(playlist.id, repository: repository) },
            redo: { snapshot in try await effects.restore(snapshot, repository: repository).playlist },
            message: { ordered.isEmpty ? "Created “\($0.name)”" : "Created “\($0.name)” with \(StatusBarText.tracks(ordered.count))" }
        )
        if let id = created?.id {
            effects.window.sidebar?.setFolderExpanded(folderID, true)
            if ordered.isEmpty { effects.window.navigation?.select(.playlist(id)) }
            effects.window.sidebar?.requestRename(playlist: id)
        }
        return created
    }

    // MARK: Cover (Choose Cover… reuses `setCover`; Use Automatic Cover)

    /// Back to the automatic cover as one step; undo puts the custom picture back exactly.
    func useAutomaticCover(ofPlaylist playlistID: Int64, name: String) async {
        guard let covers = dependencies.covers() else { return }
        _ = try? await undo.perform(
            PlaylistEditWords.useAutomaticCoverAction,
            failure: "Couldn’t change the cover of “\(name)”",
            do: { () async throws -> PlaylistCoverService.CoverState? in
                let before = try await covers.coverState(playlistId: playlistID)
                guard before.isCustom else { return nil }
                await covers.resetToAuto(playlistId: playlistID)
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
            message: { _ in PlaylistEditWords.automaticCover(name) }
        )
    }

    // MARK: Link Source… (S-PLD-LINK)

    /// Writes the playlist's source link as one step (`Link “Warm-up”`); undo restores the link
    /// it had before. Adds and removes no track (S-PLD-LINK).
    func linkPlaylist(_ playlistID: Int64, name: String, to link: PlaylistSourceLink, sourceName: String) async throws {
        guard let repository = dependencies.playlists() else { throw PlaylistRepositoryError.playlistNotFound }
        let effects = self.effects
        _ = try await undo.perform(
            PlaylistEditWords.linkAction(name),
            failure: nil,
            do: { () async throws -> PlaylistSourceLink? in
                guard let playlist = try await repository.fetch(id: playlistID) else { throw UndoTargetMissing(quotedName: "“\(name)”") }
                let before = PlaylistSourceLink(sourceID: playlist.sourceId, externalID: playlist.externalId)
                try await repository.updateSourceLink(id: playlistID, sourceId: link.sourceID, externalId: link.externalID)
                await effects.changed(playlistID, repository: repository)
                return before
            },
            undo: { before in
                guard try await repository.fetch(id: playlistID) != nil else { throw UndoTargetMissing(quotedName: "“\(name)”") }
                try await repository.updateSourceLink(id: playlistID, sourceId: before.sourceID, externalId: before.externalID)
                await effects.changed(playlistID, repository: repository)
                return link
            },
            redo: { link in
                guard let playlist = try await repository.fetch(id: playlistID) else { throw UndoTargetMissing(quotedName: "“\(name)”") }
                let before = PlaylistSourceLink(sourceID: playlist.sourceId, externalID: playlist.externalId)
                try await repository.updateSourceLink(id: playlistID, sourceId: link.sourceID, externalId: link.externalID)
                await effects.changed(playlistID, repository: repository)
                return before
            },
            message: { _ in PlaylistEditWords.linked(name, source: sourceName) }
        )
    }

    // MARK: M3U (S-PLD-M3U-PREVIEW, PP-PLAYLISTS-01)

    /// Appends the matched tracks to *this* playlist (never one chosen by the file's name) as
    /// one step; undo removes exactly the rows it added.
    func importM3U(_ plan: M3UImportPlan, intoPlaylist playlistID: Int64, name: String) async {
        guard !plan.toAdd.isEmpty, let repository = dependencies.playlists() else { return }
        let effects = self.effects
        _ = try? await undo.perform(
            PlaylistEditWords.importM3UAction,
            failure: "Couldn’t add the tracks to “\(name)”",
            do: { () async throws -> PlaylistAppendResult? in
                let result = try await repository.appendTracksReturningEntries(playlistId: playlistID, trackIds: plan.toAdd)
                guard !result.entries.isEmpty else { return nil }
                await effects.changed(playlistID, repository: repository)
                return result
            },
            undo: { added in
                let removed = try await repository.removeEntries(added.entries)
                guard !removed.isEmpty else { throw UndoNothingLeft(note: "Nothing to undo — the tracks are no longer in “\(name)”") }
                await effects.changed(playlistID, repository: repository)
                return removed
            },
            redo: { removed in
                let restored = try await repository.restoreEntries(removed)
                guard !restored.isEmpty else { throw UndoNothingLeft(note: "Nothing to redo — the tracks can’t go back into “\(name)”") }
                await effects.changed(playlistID, repository: repository)
                return PlaylistAppendResult(entries: restored, alreadyPresent: 0)
            },
            message: { result in
                PlaylistEditWords.m3uImported(added: result.entries.count,
                                              alreadyThere: plan.alreadyPresent + result.alreadyPresent,
                                              notFound: plan.notFound.count, playlist: name)
            }
        )
    }

    /// The Add menu's `Import M3U…` / an `.m3u` dropped on the Playlists section: a new playlist
    /// named after the file, in one step (undo removes it). Doesn't navigate.
    @discardableResult
    func importM3UAsNewPlaylist(_ plan: M3UImportPlan, named name: String, inFolder folderID: Int64? = nil) async -> Playlist? {
        guard let repository = dependencies.playlists() else { return nil }
        let effects = self.effects
        return try? await undo.perform(
            PlaylistEditWords.importM3UAction,
            failure: "Couldn’t create the playlist",
            do: { () async throws -> Playlist? in
                let playlist = try await repository.createNumbered(baseName: name, trackIds: plan.toAdd, inFolder: folderID)
                await effects.changed(playlist.id, repository: repository)
                return playlist
            },
            undo: { playlist in try await effects.delete(playlist.id, repository: repository) },
            redo: { snapshot in try await effects.restore(snapshot, repository: repository).playlist },
            message: { PlaylistEditWords.m3uCreated($0.name, tracks: plan.toAdd.count, notFound: plan.notFound.count) }
        )
    }
}
