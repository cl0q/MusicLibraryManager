import Foundation
import GRDB

// Merge with Another Album (S-ALB-MERGE, IMP-094): the consequence in numbers, the merge itself
// and its exact undo. Possible duplicates among the moved tracks are not decided here — they are
// left for Review ▸ Duplicates (the scan is not called).

// MARK: - Mode and plan

/// What the other album is.
enum AlbumMergeMode: Equatable, Sendable {
    /// The same album: its tracks join this album's list and the other row goes.
    case sameAlbum
    /// Another edition: it stays an album of its own, connected as `variant_of` with this kind.
    case edition(name: String)
}

/// What a merge would do, in numbers (`AlbumMergeText.consequence`).
struct AlbumMergePlan: Equatable, Sendable {
    /// Listed tracks of the other album that are not on this album yet — they move.
    var moving: Int
    /// Of those, the ones that look like a track already here (same title, case folded).
    var duplicates: Int
    /// The title of the first such track as it is on this album.
    var firstDuplicateTitle: String?

    /// - Parameters:
    ///   - here: this album's listed tracks.
    ///   - other: the other album's listed tracks, in its order.
    static func make(here: [Track], other: [Track]) -> AlbumMergePlan {
        let hereIDs = Set(here.compactMap(\.id))
        var titles: [String: String] = [:]
        for track in here {
            let key = SearchFilter.fold(track.title).trimmingCharacters(in: .whitespacesAndNewlines)
            if !key.isEmpty, titles[key] == nil { titles[key] = track.title }
        }
        var plan = AlbumMergePlan(moving: 0, duplicates: 0, firstDuplicateTitle: nil)
        for track in other where track.id.map({ !hereIDs.contains($0) }) ?? true {
            plan.moving += 1
            let key = SearchFilter.fold(track.title).trimmingCharacters(in: .whitespacesAndNewlines)
            if let shown = titles[key] {
                plan.duplicates += 1
                if plan.firstDuplicateTitle == nil { plan.firstDuplicateTitle = shown }
            }
        }
        return plan
    }
}

enum AlbumMergeText {
    static let mergeAs = "Merge as"
    static let sameAlbumTitle = "The other album is the same album"
    static let editionTitle = "The other album is another edition of this album"
    static let editionNameLabel = "Edition name"
    static let defaultEditionName = "Deluxe"
    static let button = "Merge Albums"

    static func title(_ album: String) -> String { "Merge “\(album)” with Another Album" }

    /// The edition name offered first: the other album's title when it differs from this one's,
    /// else `Deluxe`.
    static func editionNameDefault(this: String, other: String?) -> String {
        guard let other = other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty,
              AlbumKey.normalize(other) != AlbumKey.normalize(this) else { return defaultEditionName }
        return other
    }

    /// The sentence before the button. Same album: `3 tracks move to “Low Season”. 1 of them looks
    /// like a track that is already here (“Clipper”) and will be listed in Review ▸ Duplicates.
    /// “low season” is removed from Albums. Track order is not changed. You can undo the merge.`
    /// Edition: `“Low Season (Deluxe)” stays an album of its own and appears in the edition picker
    /// and under Other versions as “Deluxe”. You can undo this.`
    static func consequence(plan: AlbumMergePlan, mode: AlbumMergeMode, this: String, other: String) -> String {
        switch mode {
        case .edition(let name):
            return "“\(other)” stays an album of its own and appears in the edition picker and under Other versions as “\(name)”. You can undo this."
        case .sameAlbum:
            let moves = plan.moving == 1 ? "1 track moves" : "\(plan.moving.formatted(.number)) tracks move"
            var text = "\(moves) to “\(this)”."
            if plan.duplicates > 0 {
                let first = plan.firstDuplicateTitle.map { " (“\($0)”)" } ?? ""
                if plan.duplicates == 1 {
                    text += " 1 of them looks like a track that is already here\(first) and will be listed in Review ▸ Duplicates."
                } else {
                    text += " \(plan.duplicates.formatted(.number)) of them look like tracks that are already here\(first) and will be listed in Review ▸ Duplicates."
                }
            }
            text += " “\(other)” is removed from Albums. Track order is not changed. You can undo the merge."
            return text
        }
    }

    /// Above the button while the edition name can't be used.
    static let editionNameRequired = "Enter a name for the edition."

    static func editionNameTaken(_ name: String) -> String {
        "“\(name)” is already an edition of an album with this title and artist. Choose another name."
    }

    static func merged(other: String, this: String, mode: AlbumMergeMode) -> String {
        switch mode {
        case .sameAlbum: "Merged “\(other)” into “\(this)”"
        case .edition(let name): "“\(other)” is now the edition “\(name)” of “\(this)”"
        }
    }
}

// MARK: - The merge in the database

/// A variant preference row, as stored.
struct AlbumPrefRow: Sendable, Equatable {
    var userID: String
    var baseID: Int64
    var selectedID: Int64
    var updatedAt: String
}

/// Everything a merge changed, exactly as it was — what an undo puts back.
struct AlbumMergeRecord: Sendable, Equatable {
    let thisID: Int64
    let otherID: Int64
    let mode: AlbumMergeMode
    let thisSnapshot: AlbumTrackSnapshot
    let otherSnapshot: AlbumTrackSnapshot
    let otherRow: Album
    /// The editions of the other album (their `variant_of` moved to this album).
    let variantIDs: [Int64]
    /// Every preference row that named either album, before.
    let prefs: [AlbumPrefRow]
    /// Tracks of the other album that this album had already (their rows were dropped).
    let skipped: Int
    /// Rows that moved onto this album.
    let moved: Int
}

enum AlbumMergeError: Error, Equatable {
    case albumNotFound
    case sameAlbum
    /// The edition name collides with an album of the same artist and title.
    case editionNameTaken
}

enum AlbumMergeStore {
    private static func prefs(_ db: Database, _ ids: [Int64]) throws -> [AlbumPrefRow] {
        let marks = ids.map { _ in "?" }.joined(separator: ", ")
        return try Row.fetchAll(db, sql: """
            SELECT * FROM user_album_variant_pref
            WHERE base_album_id IN (\(marks)) OR selected_album_id IN (\(marks)) ORDER BY user_id, base_album_id
            """, arguments: StatementArguments(ids + ids)).map {
            AlbumPrefRow(userID: $0["user_id"], baseID: $0["base_album_id"], selectedID: $0["selected_album_id"], updatedAt: $0["updated_at"])
        }
    }

    /// Merges `otherID` into `thisID` in one transaction.
    ///
    /// Same album: the other album's rows are appended after this album's (discs kept, rows of
    /// tracks already here skipped — the primary key), `tracks.album_id` follows, the other's
    /// editions and variant preferences move to this album, the other row is deleted.
    /// Edition: `variant_of = this`, `variant_kind = name`; nothing else moves.
    static func merge(_ db: Database, into thisID: Int64, from otherID: Int64, mode: AlbumMergeMode) throws -> AlbumMergeRecord {
        guard thisID != otherID else { throw AlbumMergeError.sameAlbum }
        guard try Album.fetchOne(db, key: thisID) != nil, let otherRow = try Album.fetchOne(db, key: otherID) else {
            throw AlbumMergeError.albumNotFound
        }
        let thisSnapshot = try AlbumTrackRepository.snapshot(db, albumID: thisID)
        let otherSnapshot = try AlbumTrackRepository.snapshot(db, albumID: otherID)
        let variantIDs = try Int64.fetchAll(db, sql: "SELECT id FROM albums WHERE variant_of = ? ORDER BY id", arguments: [otherID])
        let touchedPrefs = try prefs(db, [thisID, otherID])
        var skipped = 0
        var moved = 0

        switch mode {
        case .edition(let name):
            let clash = try Album.fetchAll(db, sql: """
                SELECT * FROM albums WHERE id <> ? AND title_normalized = ? AND LOWER(IFNULL(variant_kind, '')) = LOWER(?)
                """, arguments: [otherID, otherRow.titleNormalized, name]).contains {
                AlbumKey.artistKey($0.albumArtist) == AlbumKey.artistKey(otherRow.albumArtist)
            }
            if clash { throw AlbumMergeError.editionNameTaken }
            try db.execute(sql: "UPDATE albums SET variant_of = ?, variant_kind = ? WHERE id = ?", arguments: [thisID, name, otherID])
            try db.execute(sql: "UPDATE albums SET variant_of = ? WHERE variant_of = ?", arguments: [thisID, otherID])
            // The other album is not the base of a group any more.
            try db.execute(sql: "DELETE FROM user_album_variant_pref WHERE base_album_id = ?", arguments: [otherID])

        case .sameAlbum:
            let have = Set(thisSnapshot.rows.map(\.trackId))
            let arriving = otherSnapshot.rows.filter { !have.contains($0.trackId) }
            skipped = otherSnapshot.rows.count - arriving.count
            moved = arriving.count
            if !arriving.isEmpty {
                // This album's rows, then the arriving ones, kept in their discs.
                let combined = (thisSnapshot.rows + arriving).enumerated().sorted { a, b in
                    a.element.disc != b.element.disc ? a.element.disc < b.element.disc : a.offset < b.offset
                }.map(\.element)
                let keys = FractionalIndexer.evenlySpaced(count: combined.count)
                for (row, key) in zip(combined, keys) {
                    if row.albumId == thisID {
                        if row.position != key {
                            try db.execute(sql: "UPDATE album_tracks SET position = ? WHERE album_id = ? AND track_id = ?",
                                           arguments: [key, thisID, row.trackId])
                        }
                    } else {
                        try AlbumTrack(albumId: thisID, trackId: row.trackId, disc: row.disc, position: key, trackNumber: row.trackNumber).insert(db)
                    }
                }
            }
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE album_id = ?", arguments: [thisID, otherID])
            try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ?", arguments: [otherID])
            try db.execute(sql: "UPDATE albums SET variant_of = ? WHERE variant_of = ?", arguments: [thisID, otherID])
            // Preferences: one that selected the other album is gone with it; the other's group
            // preference moves to this album unless this album's group already has one.
            try db.execute(sql: "DELETE FROM user_album_variant_pref WHERE selected_album_id = ?", arguments: [otherID])
            for pref in touchedPrefs where pref.baseID == otherID && pref.selectedID != otherID {
                let has = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM user_album_variant_pref WHERE user_id = ? AND base_album_id = ?)",
                                            arguments: [pref.userID, thisID]) ?? false
                if has {
                    try db.execute(sql: "DELETE FROM user_album_variant_pref WHERE user_id = ? AND base_album_id = ?", arguments: [pref.userID, otherID])
                } else {
                    try db.execute(sql: "UPDATE user_album_variant_pref SET base_album_id = ? WHERE user_id = ? AND base_album_id = ?",
                                   arguments: [thisID, pref.userID, otherID])
                }
            }
            try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [otherID])
        }
        return AlbumMergeRecord(thisID: thisID, otherID: otherID, mode: mode, thisSnapshot: thisSnapshot, otherSnapshot: otherSnapshot,
                                otherRow: otherRow, variantIDs: variantIDs, prefs: touchedPrefs, skipped: skipped, moved: moved)
    }

    /// Puts every row back as the record had it (rows of tracks that left the library meanwhile
    /// are skipped).
    static func revert(_ db: Database, _ record: AlbumMergeRecord) throws {
        let row = record.otherRow
        switch record.mode {
        case .sameAlbum:
            let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM albums WHERE id = ?)", arguments: [record.otherID]) ?? false
            if !exists { try row.insert(db) }
        case .edition:
            try db.execute(sql: "UPDATE albums SET variant_of = ?, variant_kind = ? WHERE id = ?",
                           arguments: [row.variantOf, row.variantKind, record.otherID])
        }
        for id in record.variantIDs {
            try db.execute(sql: "UPDATE albums SET variant_of = ? WHERE id = ?", arguments: [record.otherID, id])
        }
        try db.execute(sql: "DELETE FROM album_tracks WHERE album_id IN (?, ?)", arguments: [record.thisID, record.otherID])
        for snapshot in [record.thisSnapshot, record.otherSnapshot] {
            for join in snapshot.rows where try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)", arguments: [join.trackId]) ?? false {
                try join.insert(db)
            }
            for id in snapshot.linkedTrackIDs {
                try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ?", arguments: [snapshot.albumID, id])
            }
        }
        try db.execute(sql: """
            DELETE FROM user_album_variant_pref WHERE base_album_id IN (?, ?) OR selected_album_id IN (?, ?)
            """, arguments: [record.thisID, record.otherID, record.thisID, record.otherID])
        for pref in record.prefs {
            try db.execute(sql: """
                INSERT OR REPLACE INTO user_album_variant_pref (user_id, base_album_id, selected_album_id, updated_at) VALUES (?, ?, ?, ?)
                """, arguments: [pref.userID, pref.baseID, pref.selectedID, pref.updatedAt])
        }
    }
}

// MARK: - Reads

extension AlbumRepository {
    /// The numbers of a merge: this album's and the other's listed tracks compared.
    func mergePlan(into thisID: Int64, from otherID: Int64) async throws -> AlbumMergePlan {
        let joins = AlbumTrackRepository(database: database)
        let here = try await joins.tracks(of: thisID)
        let other = try await joins.tracks(of: otherID)
        return AlbumMergePlan.make(here: here, other: other)
    }

    /// Whether another album already has the other's title and album artist with this edition
    /// kind (the merge as an edition would collide).
    func editionNameIsTaken(_ name: String, forAlbum otherID: Int64) async throws -> Bool {
        guard let other = try await fetch(id: otherID) else { return false }
        let wanted = AlbumKey.artistKey(other.albumArtist)
        return try await database.read { db in
            try Album.fetchAll(db, sql: """
                SELECT * FROM albums WHERE id <> ? AND title_normalized = ? AND LOWER(IFNULL(variant_kind, '')) = LOWER(?)
                """, arguments: [otherID, other.titleNormalized, name]).contains { AlbumKey.artistKey($0.albumArtist) == wanted }
        }
    }
}

// MARK: - The undo step

extension ShellEdits {
    /// `Merge Albums`: one undo step. Undo restores the exact rows (`AlbumMergeRecord`); redo
    /// merges again from that state. Possible duplicates are left to Review ▸ Duplicates.
    @discardableResult
    func mergeAlbums(into thisID: Int64, from otherID: Int64, mode: AlbumMergeMode) async throws -> AlbumMergeRecord? {
        guard let albums = dependencies.albums() else { throw UndoTargetMissing(quotedName: "The album") }
        guard let this = try await albums.fetch(id: thisID), let other = try await albums.fetch(id: otherID) else {
            throw UndoTargetMissing(quotedName: "The album")
        }
        let database = albums.database
        let thisTitle = this.title
        let otherTitle = other.title
        return try await undo.perform(
            "Merge Albums",
            failure: "Couldn’t merge “\(otherTitle)” into “\(thisTitle)”",
            do: { () async throws -> AlbumMergeRecord? in
                let record = try await database.write { db in try AlbumMergeStore.merge(db, into: thisID, from: otherID, mode: mode) }
                NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                return record
            },
            undo: { record in
                try await database.write { db in try AlbumMergeStore.revert(db, record) }
                NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                return record
            },
            redo: { record in
                let again = try await database.write { db in try AlbumMergeStore.merge(db, into: thisID, from: otherID, mode: mode) }
                NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
                return again
            },
            message: { _ in AlbumMergeText.merged(other: otherTitle, this: thisTitle, mode: mode) })
    }
}
