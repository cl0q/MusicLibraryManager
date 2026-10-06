import Foundation

// The undoable album edits the pages add to `ShellEdits` (W4-2, UC-UNDO-02): Edit Order's Done
// with discs and numbers, Choose Cover… / an image drop, and Choose Edition. One gesture = one
// step, named per UC-UNDO-07, confirmed in the status bar with Undo.

extension ShellEdits {
    // MARK: Edit Order (IMP-081)

    /// Done in Edit Order: the order the rows show becomes the album's — discs as dragged,
    /// numbers 1, 2, 3… within each disc (`AlbumOrderEditor.numbered`). One step,
    /// `Reorder “‹album›”`; undo restores the earlier rows exactly. Nil when nothing changed.
    ///
    /// `setAlbumOrder` (W4-1) is a thin wrapper over this: it keeps every row's disc.
    @discardableResult
    func setAlbumLayout(albumID: Int64, _ ordered: [(trackID: Int64, disc: Int, number: Int)]) async throws -> AlbumEditResult? {
        guard let repository = dependencies.albumTracks(), let albums = dependencies.albums(),
              let album = try await albums.fetch(id: albumID) else { throw UndoTargetMissing(quotedName: "The album") }
        let name = album.title
        return try await undo.perform(
            "Reorder “\(name)”",
            failure: "Couldn’t reorder “\(name)”",
            do: { () async throws -> AlbumEditResult? in
                let before = try await repository.snapshot(albumID: albumID)
                guard try await repository.applyLayout(albumID: albumID, ordered) else { return nil }
                let after = try await repository.snapshot(albumID: albumID)
                NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                return AlbumEditResult(albumID: albumID, name: name, before: before, after: after)
            },
            undo: { done in
                try await repository.restore(done.before)
                NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                return done
            },
            redo: { done in
                try await repository.restore(done.after)
                NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                return done
            },
            message: { "Reordered “\($0.name)”" }
        )
    }

    // MARK: Cover (IMP-078)

    /// `Set Cover`: copies the image into the covers folder and points the album at it. Undo
    /// restores the earlier `cover_path`. Returns the refusal sentence when the image can't be
    /// used (nothing is written or registered then).
    func setAlbumCover(_ source: CoverSource, albumID: Int64, name: String, coversDirectory: URL?) async -> String? {
        guard let albums = dependencies.albums() else { return nil }
        let reference: String
        do {
            reference = try AlbumCoverFiles.store(source, albumID: albumID, in: coversDirectory)
        } catch {
            if case .file(let url) = source { return DropWords.notACover(fileName: url.lastPathComponent) }
            return DropWords.notACover(fileName: nil)
        }
        do {
            _ = try await undo.perform(
                DropWords.setCoverActionName,
                failure: "Couldn’t set the cover of “\(name)”",
                do: { () async throws -> String?? in
                    let before = try await albums.setCoverPath(albumID: albumID, to: reference)
                    Self.coverDidChange(albumID)
                    return .some(before)
                },
                undo: { before in
                    let current = try await albums.setCoverPath(albumID: albumID, to: before)
                    Self.coverDidChange(albumID)
                    return current
                },
                redo: { _ in
                    let before = try await albums.setCoverPath(albumID: albumID, to: reference)
                    Self.coverDidChange(albumID)
                    return before
                },
                message: { _ in DropWords.coverSetMessage(name) }
            )
        } catch {
            // Reported in the status bar by the center.
        }
        return nil
    }

    @MainActor
    private static func coverDidChange(_ albumID: Int64) {
        AlbumCoverLoader.shared.forget(albumID: albumID)
        NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil, userInfo: ["albumId": albumID])
    }

    // MARK: Edition (DEC-020)

    /// `Choose Edition`: the picked edition is shown from now on (`user_album_variant_pref`).
    /// Undo puts the earlier preference back — or none.
    func chooseEdition(base: Int64, selected: Int64, edition: String, albumTitle: String) async {
        guard let albums = dependencies.albums() else { return }
        do {
            _ = try await undo.perform(
                "Choose Edition",
                failure: "Couldn’t change the preferred edition of “\(albumTitle)”",
                do: { () async throws -> Int64?? in
                    let before = try await albums.fetchVariantPref(baseAlbumId: base)
                    guard before != selected else { return nil }
                    try await albums.setVariantPref(baseAlbumId: base, selectedAlbumId: selected)
                    NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                    return .some(before)
                },
                undo: { before in
                    if let before {
                        try await albums.setVariantPref(baseAlbumId: base, selectedAlbumId: before)
                    } else {
                        try await albums.clearVariantPref(baseAlbumId: base)
                    }
                    NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                    return ()
                },
                redo: { _ in
                    let before = try await albums.fetchVariantPref(baseAlbumId: base)
                    try await albums.setVariantPref(baseAlbumId: base, selectedAlbumId: selected)
                    NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                    return before
                },
                message: { _ in AlbumText.editionChosen(edition: edition, album: albumTitle) }
            )
        } catch {
            // Reported in the status bar by the center.
        }
    }
}
