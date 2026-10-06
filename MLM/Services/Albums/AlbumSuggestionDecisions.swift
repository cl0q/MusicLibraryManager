import Foundation
import GRDB

// MARK: - The join part of Accept

/// What accepting one suggestion did to the album tables — exactly, so Undo and Redo put it back.
struct AlbumAcceptLink: Sendable, Equatable {
    var trackID: Int64
    var albumID: Int64
    /// The album row this accept created (nil = it existed).
    var createdAlbum: Album?
    /// `tracks.album_id` before.
    var previousAlbumID: Int64?
    /// The join row this accept inserted (nil = the track was already a member).
    var insertedRow: AlbumTrack?
    /// The suggestion row as it was (pending) and as it became (accepted).
    var before: AlbumSuggestionRow
    var after: AlbumSuggestionRow
}

enum AlbumSuggestionLinks {
    /// Finds or creates the album, links the track, appends it with the suggested disc and track
    /// number (never written to the file, IMP-030) and marks the row accepted — one transaction.
    /// A track that is gone is skipped.
    static func accept(_ db: Database, items: [AlbumSuggestionItem], decidedAt: String) throws -> [AlbumAcceptLink] {
        var links: [AlbumAcceptLink] = []
        for item in items {
            let trackID = item.id
            guard let track = try Track.fetchOne(db, key: trackID) else { continue }
            let suggestion = item.row.suggestion
            let albumArtist = suggestion.albumArtist.isEmpty ? track.albumArtist : suggestion.albumArtist
            let albumsBefore = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") ?? 0
            let albumID = try AlbumKey.findOrCreate(db, artist: track.artist, albumArtist: albumArtist,
                                                    title: suggestion.albumTitle, year: suggestion.year)
            let created = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums") ?? 0) > albumsBefore
                ? try Album.fetchOne(db, key: albumID) : nil
            let previous = track.albumId
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ?", arguments: [albumID, trackID])
            var inserted: AlbumTrack?
            let member = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM album_tracks WHERE album_id = ? AND track_id = ?)",
                                           arguments: [albumID, trackID]) ?? false
            if !member {
                let (keys, disc) = try AlbumTrackRepository.positionKeys(
                    db, albumID: albumID, count: 1, at: nil, disc: suggestion.disc, excluding: [])
                let row = AlbumTrack(albumId: albumID, trackId: trackID, disc: disc, position: keys[0], trackNumber: suggestion.trackNumber)
                try row.insert(db)
                inserted = row
                if suggestion.trackNumber != nil { _ = try AlbumTrackRepository.resortIfNumbered(db, albumID: albumID) }
            }
            var accepted = item.row
            accepted.status = .accepted
            accepted.decidedAt = decidedAt
            try AlbumSuggestionRepository.upsert(db, [accepted])
            links.append(AlbumAcceptLink(trackID: trackID, albumID: albumID, createdAlbum: created, previousAlbumID: previous,
                                         insertedRow: inserted, before: item.row, after: accepted))
        }
        return links
    }

    /// Undo of `accept`: the join row goes, the link and the suggestion row are as they were, an
    /// album this accept created goes when nothing else is in it.
    static func revert(_ db: Database, _ links: [AlbumAcceptLink]) throws {
        for link in links.reversed() {
            if link.insertedRow != nil {
                try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ? AND track_id = ?", arguments: [link.albumID, link.trackID])
            }
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ? AND album_id = ?",
                           arguments: [link.previousAlbumID, link.trackID, link.albumID])
            if let album = link.createdAlbum, let id = album.id {
                let used = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM album_tracks WHERE album_id = ?) OR EXISTS(SELECT 1 FROM tracks WHERE album_id = ?)
                    """, arguments: [id, id]) ?? false
                if !used { try db.execute(sql: "DELETE FROM albums WHERE id = ?", arguments: [id]) }
            }
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)", arguments: [link.trackID]) ?? false {
                try AlbumSuggestionRepository.upsert(db, [link.before])
            }
        }
    }

    /// Redo of `accept`: the same album row (same id), join row and link again.
    static func reapply(_ db: Database, _ links: [AlbumAcceptLink]) throws {
        for link in links {
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)", arguments: [link.trackID]) ?? false else { continue }
            if let album = link.createdAlbum {
                let exists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM albums WHERE id = ?)", arguments: [link.albumID]) ?? false
                if !exists { try album.insert(db) }
            }
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ?", arguments: [link.albumID, link.trackID])
            if let row = link.insertedRow {
                try db.execute(sql: "DELETE FROM album_tracks WHERE album_id = ? AND track_id = ?", arguments: [link.albumID, link.trackID])
                try row.insert(db)
            }
            try AlbumSuggestionRepository.upsert(db, [link.after])
        }
    }
}

// MARK: - Decisions

/// What a decision on suggestions did (the status-bar sentence is built from it).
struct AlbumAcceptOutcome: Sendable, Equatable {
    var count: Int
    var firstTitle: String
    var album: String
    var year: Int?
    /// Tag changes waiting for the drive after this step.
    var waiting: Int?
}

/// Accept, Reject, No Album, Suggest Again — each one `UndoCenter` step (UC-UNDO-08), none behind
/// a question except the bulk Accept (A-REV-ALBBULK, asked by the view). Accept writes through
/// `TrackTagEdit`, so it honours `Write tags to files` and waits for the drive (UC-JOB-10); the
/// join and the decision are in the same step.
@MainActor
final class AlbumSuggestionDecisions {
    struct Dependencies {
        var repository: AlbumSuggestionRepository
        var tagEdit: @MainActor () -> TrackTagEdit
        var volumeName: @MainActor () -> String?
        var now: @MainActor () -> Date
        /// Lists and the badge refresh.
        var didChange: @MainActor () -> Void

        @MainActor
        static func live(_ container: DependencyContainer = .shared) -> Dependencies? {
            guard let manager = container.databaseManager else { return nil }
            return Dependencies(
                repository: AlbumSuggestionRepository(database: manager.pool),
                tagEdit: { TrackTagEdit.live(undo: nil) },
                volumeName: { LibraryDriveState.current(container).volumeName },
                now: Date.init,
                didChange: AlbumSuggestionDecisions.postChange)
        }
    }

    let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    static func postChange() {
        NotificationCenter.default.post(name: .reviewQueueDidChange, object: nil)
        NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil)
    }

    private var stamp: String { ISO8601DateFormatter().string(from: dependencies.now()) }

    // MARK: Accept

    /// The suggestions that can be accepted: pending, with an album.
    static func acceptable(_ items: [AlbumSuggestionItem]) -> [AlbumSuggestionItem] {
        items.filter { $0.row.status == .pending && $0.row.suggestion.albumTitle != "" }
    }

    /// `Accept` (Return) and the bulk `Accept ‹n› Suggestions`: Album, Album artist (when the
    /// suggestion has one), Year (when it has one), the album row and the join — one undo step
    /// (`Set Album`). Returns whether anything was accepted.
    @discardableResult
    func accept(_ requested: [AlbumSuggestionItem], undo: UndoCenter) async -> Bool {
        let items = Self.acceptable(requested)
        guard !items.isEmpty else { return false }
        let deps = dependencies
        let decidedAt = stamp
        let single = items.count == 1 ? items[0] : nil
        do {
            _ = try await undo.performGroup(
                "Set Album", failure: single == nil ? "Couldn’t set the albums" : "Couldn’t set the album",
                { group in
                    let edit = deps.tagEdit()
                    var waiting: Int?
                    // Tracks that get the same values are one tag edit.
                    var buckets: [String: (suggestion: AlbumSuggestion, ids: [Int64])] = [:]
                    var order: [String] = []
                    for item in items {
                        let s = item.row.suggestion
                        let key = [s.albumTitle, s.albumArtist, s.year.map(String.init) ?? ""].joined(separator: "\u{1F}")
                        if buckets[key] == nil { order.append(key); buckets[key] = (s, []) }
                        buckets[key]?.ids.append(item.id)
                    }
                    for key in order {
                        guard let bucket = buckets[key] else { continue }
                        var steps: [TrackTagEdit.Step?] = []
                        steps.append(try await edit.perform(.text(bucket.suggestion.albumTitle), field: .album, trackIDs: bucket.ids, in: group))
                        if !bucket.suggestion.albumArtist.isEmpty {
                            steps.append(try await edit.perform(.text(bucket.suggestion.albumArtist), field: .albumArtist, trackIDs: bucket.ids, in: group))
                        }
                        if let year = bucket.suggestion.year {
                            steps.append(try await edit.perform(.number(year), field: .year, trackIDs: bucket.ids, in: group))
                        }
                        for case let step? in steps { waiting = max(waiting ?? 0, step.waiting ?? 0) }
                    }
                    let database = deps.repository.database
                    try await group.perform(
                        do: { () async throws -> [AlbumAcceptLink] in
                            let links = try await database.write { db in try AlbumSuggestionLinks.accept(db, items: items, decidedAt: decidedAt) }
                            deps.didChange()
                            return links
                        },
                        undo: { (links: [AlbumAcceptLink]) async throws -> [AlbumAcceptLink] in
                            try await database.write { db in try AlbumSuggestionLinks.revert(db, links) }
                            deps.didChange()
                            return links
                        },
                        redo: { (links: [AlbumAcceptLink]) async throws -> [AlbumAcceptLink] in
                            try await database.write { db in try AlbumSuggestionLinks.reapply(db, links) }
                            deps.didChange()
                            return links
                        })
                    let first = single ?? items[0]
                    return AlbumAcceptOutcome(count: items.count, firstTitle: first.track.title,
                                              album: first.row.suggestion.albumTitle, year: first.row.suggestion.year,
                                              waiting: (waiting ?? 0) > 0 ? waiting : nil)
                },
                message: { outcome in Self.acceptMessage(outcome, volume: deps.volumeName()) })
            deps.didChange()
            return true
        } catch {
            return false
        }
    }

    /// `Set album “Good Lies” (2022) for “So U Know”` · `Set the album for 812 tracks`, plus
    /// `· 3 tag changes waiting for “Lexxar”` while the drive is away.
    static func acceptMessage(_ outcome: AlbumAcceptOutcome, volume: String?) -> String {
        var text: String
        if outcome.count == 1 {
            let year = outcome.year.map { " (\($0))" } ?? ""
            text = "Set album “\(outcome.album)”\(year) for “\(outcome.firstTitle)”"
        } else {
            text = "Set the album for \(outcome.count.formatted(.number)) tracks"
        }
        if let waiting = outcome.waiting, waiting > 0 {
            text += " · " + TrackTagEdit.waitingText(waiting, volume: volume)
        }
        return text
    }

    // MARK: Reject

    /// What Reject does to a row: the best other suggestion takes its place (the row stays
    /// pending); with none left the row is `rejected`.
    static func rejected(_ row: AlbumSuggestionRow, decidedAt: String) -> AlbumSuggestionRow {
        var next = row
        if let best = row.alternatives.max(by: { $0.match < $1.match }), let index = row.alternatives.firstIndex(of: best) {
            next.suggestion = best
            next.alternatives.remove(at: index)
        } else {
            next.status = .rejected
            next.decidedAt = decidedAt
        }
        return next
    }

    /// `Reject` (⌫): one undo step (`Reject Suggestion`).
    @discardableResult
    func reject(_ requested: [AlbumSuggestionItem], undo: UndoCenter) async -> Bool {
        let items = requested.filter { $0.row.status == .pending }
        guard !items.isEmpty else { return false }
        let deps = dependencies
        let decidedAt = stamp
        let after = items.map { Self.rejected($0.row, decidedAt: decidedAt) }
        let before = items.map(\.row)
        let showsNext = after.contains { $0.status == .pending }
        let title = items.count == 1 ? items[0].track.title : nil
        do {
            _ = try await undo.perform(
                "Reject Suggestion", failure: "Couldn’t reject the suggestion",
                do: { () async throws -> [AlbumSuggestionRow]? in
                    try await deps.repository.restore(after)
                    deps.didChange()
                    return before
                },
                undo: { (rows: [AlbumSuggestionRow]) async throws -> [AlbumSuggestionRow] in
                    try await deps.repository.restore(rows)
                    deps.didChange()
                    return after
                },
                redo: { (rows: [AlbumSuggestionRow]) async throws -> [AlbumSuggestionRow] in
                    try await deps.repository.restore(rows)
                    deps.didChange()
                    return before
                },
                message: { _ in Self.rejectMessage(count: items.count, title: title, showsNext: showsNext) })
            return true
        } catch {
            return false
        }
    }

    static func rejectMessage(count: Int, title: String?, showsNext: Bool) -> String {
        if count == 1, let title {
            return showsNext ? "Rejected — showing the next suggestion for “\(title)”" : "Rejected the suggestion for “\(title)”"
        }
        return "Rejected \(count.formatted(.number)) suggestions"
    }

    // MARK: No Album

    /// What No Album / Suggest Again changed, for the inverse.
    struct FlagChange: Sendable {
        var flagged: [Int64]
        var rows: [AlbumSuggestionRow]
        var removeRows: [Int64]
    }

    /// `No Album`: `tracks.no_album = 1` and the row `no_album` — the track leaves the lookup,
    /// the suggestions and the `without album` count for good. One undo step (`Mark as No Album`).
    @discardableResult
    func markNoAlbum(_ items: [AlbumSuggestionItem], undo: UndoCenter) async -> Bool {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return false }
        let deps = dependencies
        let decidedAt = stamp
        let title = items.count == 1 ? items[0].track.title : nil
        do {
            _ = try await undo.perform(
                "Mark as No Album", failure: "Couldn’t mark the track as No album",
                do: { () async throws -> FlagChange? in
                    let change = try await deps.repository.database.write { db -> FlagChange in
                        let flagged = try AlbumSuggestionRepository.setNoAlbum(db, true, trackIDs: ids)
                        let rows = try AlbumSuggestionRepository.setStatus(db, .noAlbum, trackIDs: ids, decidedAt: decidedAt)
                        return FlagChange(flagged: flagged, rows: rows, removeRows: [])
                    }
                    deps.didChange()
                    return change.flagged.isEmpty && change.rows.isEmpty ? nil : change
                },
                undo: { (change: FlagChange) async throws -> FlagChange in
                    try await deps.repository.database.write { db in
                        _ = try AlbumSuggestionRepository.setNoAlbum(db, false, trackIDs: change.flagged)
                        try AlbumSuggestionRepository.upsert(db, change.rows)
                    }
                    deps.didChange()
                    return change
                },
                redo: { (change: FlagChange) async throws -> FlagChange in
                    try await deps.repository.database.write { db in
                        _ = try AlbumSuggestionRepository.setNoAlbum(db, true, trackIDs: change.flagged)
                        _ = try AlbumSuggestionRepository.setStatus(db, .noAlbum, trackIDs: change.rows.map(\.trackID), decidedAt: decidedAt)
                    }
                    deps.didChange()
                    return change
                },
                message: { _ in Self.noAlbumMessage(count: ids.count, title: title) })
            return true
        } catch {
            return false
        }
    }

    static func noAlbumMessage(count: Int, title: String?) -> String {
        if count == 1, let title { return "“\(title)” is confirmed as No album — it won’t be suggested again" }
        return "\(count.formatted(.number)) tracks are confirmed as No album — they won’t be suggested again"
    }

    /// `Suggest Again` (on a track confirmed `No album`): the flag and the row go, the next
    /// lookup asks about the track again. One undo step (`Suggest Again`).
    @discardableResult
    func suggestAgain(_ items: [AlbumSuggestionItem], undo: UndoCenter) async -> Bool {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return false }
        let deps = dependencies
        let title = items.count == 1 ? items[0].track.title : nil
        do {
            _ = try await undo.perform(
                "Suggest Again", failure: "Couldn’t reset the track",
                do: { () async throws -> FlagChange? in
                    let change = try await deps.repository.database.write { db -> FlagChange in
                        let rows = try ids.compactMap { try AlbumSuggestionRepository.row(db, trackID: $0) }
                        let flagged = try AlbumSuggestionRepository.setNoAlbum(db, false, trackIDs: ids)
                        for id in ids { try db.execute(sql: "DELETE FROM album_suggestions WHERE track_id = ?", arguments: [id]) }
                        return FlagChange(flagged: flagged, rows: rows, removeRows: ids)
                    }
                    deps.didChange()
                    return change.flagged.isEmpty && change.rows.isEmpty ? nil : change
                },
                undo: { (change: FlagChange) async throws -> FlagChange in
                    try await deps.repository.database.write { db in
                        _ = try AlbumSuggestionRepository.setNoAlbum(db, true, trackIDs: change.flagged)
                        try AlbumSuggestionRepository.upsert(db, change.rows)
                    }
                    deps.didChange()
                    return change
                },
                redo: { (change: FlagChange) async throws -> FlagChange in
                    try await deps.repository.database.write { db in
                        _ = try AlbumSuggestionRepository.setNoAlbum(db, false, trackIDs: change.flagged)
                        for id in change.removeRows { try db.execute(sql: "DELETE FROM album_suggestions WHERE track_id = ?", arguments: [id]) }
                    }
                    deps.didChange()
                    return change
                },
                message: { _ in
                    title.map { "“\($0)” will be looked up again" } ?? "\(ids.count.formatted(.number)) tracks will be looked up again"
                })
            return true
        } catch {
            return false
        }
    }

    // MARK: Choose another

    /// Choosing one of the alternatives makes it the row's suggestion. Nothing else is written
    /// until Accept (V-REV.N11), so there is nothing to undo.
    @discardableResult
    func choose(alternativeAt index: Int, for item: AlbumSuggestionItem) async -> Bool {
        let chosen = try? await dependencies.repository.choose(alternativeAt: index, trackID: item.id)
        if chosen != nil { dependencies.didChange() }
        return chosen != nil
    }
}
