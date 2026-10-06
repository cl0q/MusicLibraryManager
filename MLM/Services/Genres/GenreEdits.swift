import Foundation

/// Every genre change of the Genres place as **one tag edit** (`TrackTagEdit`, W2-E): one undo
/// step that restores each track's exact previous value, track lists refreshed through
/// `.trackMetadataDidChange`, file tags queued only while `Write tags to files` is on — never a
/// direct `UPDATE`, never a file write of its own (DEC-041, UC-UNDO-02/07/08).
///
/// One gesture = one `perform` over all affected tracks, because every genre command sets one
/// value: Rename (all tracks of a genre), Merge (all tracks of the merged genres), a drop on a
/// genre row, `Save n Changes` (the staged tracks) and Remove from ‹Genre› (no genre).
@MainActor
struct GenreEdits {
    let tagEdit: TrackTagEdit
    let repository: GenreRepository

    static func live(undo: UndoCenter?, container: DependencyContainer = .shared) -> GenreEdits? {
        guard let repository = GenreRepository.live(container) else { return nil }
        return GenreEdits(tagEdit: .live(undo: undo), repository: repository)
    }

    /// Rename Genre: every track of `genre` gets `newName`. nil when nothing changed.
    /// `reportsFailure: false` — the rename field says it (UC-SHEET-17), not the status bar.
    @discardableResult
    func rename(_ genre: GenreSummary, to newName: String, reportsFailure: Bool = true) async throws -> TrackTagEdit.Step? {
        guard let name = GenreName.cleaned(newName) else { return nil }
        let ids = try await repository.trackIDs(genreKeys: [genre.key])
        let old = genre.name
        return try await tagEdit.perform(
            .text(name), field: .genre, trackIDs: ids,
            failure: reportsFailure ? "Couldn’t rename “\(old)”" : nil,
            wording: .init(actionName: "Rename Genre", headline: { _ in "Renamed “\(old)” to “\(name)”" })
        )
    }

    /// Merge Genres…: every track of `genres` gets `name` (`Merged 3 genres into “Hip-Hop” — 46
    /// tracks changed`). nil when nothing changed. `reportsFailure: false` — the sheet says it
    /// above its buttons (UC-SHEET-05).
    @discardableResult
    func merge(_ genres: [GenreSummary], into newName: String, reportsFailure: Bool = true) async throws -> TrackTagEdit.Step? {
        guard let name = GenreName.cleaned(newName), genres.count >= 2 else { return nil }
        let ids = try await repository.trackIDs(genreKeys: Set(genres.map(\.key)))
        let count = genres.count
        return try await tagEdit.perform(
            .text(name), field: .genre, trackIDs: ids,
            failure: reportsFailure ? "Couldn’t merge the genres" : nil,
            wording: .init(actionName: "Merge Genres", headline: { changed in
                "Merged \(count) genres into “\(name)” — \(StatusBarText.tracks(changed)) changed"
            })
        )
    }

    /// Tracks dropped on a genre row: `Set genre of 3 tracks to “Techno”`.
    @discardableResult
    func setGenre(of trackIDs: [Int64], to genreName: String) async throws -> TrackTagEdit.Step? {
        guard let name = GenreName.cleaned(genreName) else { return nil }
        return try await tagEdit.perform(
            .text(name), field: .genre, trackIDs: trackIDs,
            failure: "Couldn’t set the genre",
            wording: .init(actionName: "Set Genre", headline: { changed in
                "Set genre of \(StatusBarText.tracks(changed)) to “\(name)”"
            })
        )
    }

    /// `Save n Changes`: the staged tracks join the genre (`Saved — 3 tracks are now “Techno”`).
    @discardableResult
    func saveStaged(_ trackIDs: [Int64], genreName: String) async throws -> TrackTagEdit.Step? {
        guard let name = GenreName.cleaned(genreName) else { return nil }
        return try await tagEdit.perform(
            .text(name), field: .genre, trackIDs: trackIDs,
            failure: "Couldn’t save the changes",
            wording: .init(actionName: "Add to “\(name)”", headline: { changed in
                "Saved — \(changed == 1 ? "1 track is" : "\(changed.formatted(.number)) tracks are") now “\(name)”"
            })
        )
    }

    /// Remove from “‹Genre›” (⌫ in the genre's track table): the tracks get no genre.
    @discardableResult
    func remove(_ trackIDs: [Int64], fromGenre genreName: String) async throws -> TrackTagEdit.Step? {
        try await tagEdit.perform(
            .text(nil), field: .genre, trackIDs: trackIDs,
            failure: "Couldn’t remove the tracks from “\(genreName)”",
            wording: .init(actionName: "Remove from “\(genreName)”", headline: { changed in
                "Removed \(StatusBarText.tracks(changed)) from “\(genreName)”"
            })
        )
    }
}
