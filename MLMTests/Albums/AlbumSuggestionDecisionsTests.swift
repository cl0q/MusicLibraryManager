import Foundation
import GRDB
import Testing
@testable import MLM

/// Accept / Reject / No Album / Suggest Again and the Review ▸ Albums model (W4-3, IMP-084,
/// UC-UNDO-05). Temporary databases, an undo center on its own manager, a fake tag writer.
@Suite("AlbumSuggestionDecisionsTests", .serialized)
@MainActor
struct AlbumSuggestionDecisionsTests {
    struct Env {
        let db: DatabaseQueue
        let repository: AlbumSuggestionRepository
        let decisions: AlbumSuggestionDecisions
        let undo: UndoCenter
        let manager: UndoManager
        let status: StatusBarCenter
        let model: ReviewAlbumsModel
        let changes: Changes
    }

    final class Changes: @unchecked Sendable {
        var count = 0
    }

    static func env(writesEnabled: Bool = false, reachable: Bool = true, volume: String? = nil) throws -> Env {
        let db = try DatabaseManager.inMemory()
        let tagRepository = TrackTagRepository(database: db)
        let queue = TagWriteQueue(dependencies: .init(
            repository: { tagRepository }, libraryRoot: { "/lib" }, isEnabled: { writesEnabled },
            writer: NullTagWriter(), statusBar: { nil }))
        let edit = TrackTagEdit(dependencies: .init(
            repository: { tagRepository }, writesEnabled: { writesEnabled }, isLibraryFolderReachable: { reachable },
            volumeName: { volume }, queue: queue, tracksDidChange: { _ in }), undo: nil)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let repository = AlbumSuggestionRepository(database: db)
        let changes = Changes()
        let decisions = AlbumSuggestionDecisions(dependencies: .init(
            repository: repository, tagEdit: { edit }, volumeName: { volume },
            now: { Date(timeIntervalSince1970: 1_800_000_000) }, didChange: { changes.count += 1 }))
        let lookup = AlbumLookupRunner(
            center: ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0),
            repository: { repository }, libraryRoot: { nil }, config: { ConfigRepository(database: db) },
            suggester: TagAlbumSuggester(), didChange: {})
        let model = ReviewAlbumsModel(
            dependencies: .init(repository: repository, decisions: decisions,
                                noAlbumCount: { (try? await TrackScopeQueries(database: db).noAlbumCount()) ?? 0 },
                                writesTags: { writesEnabled }),
            lookup: lookup)
        return Env(db: db, repository: repository, decisions: decisions, undo: undo, manager: manager, status: status,
                   model: model, changes: changes)
    }

    @discardableResult
    static func track(_ env: Env, _ title: String, artist: String = "Overmono", album: String = "",
                      suggestion: AlbumSuggestion?, alternatives: [AlbumSuggestion] = []) async throws -> Int64 {
        let id: Int64 = try await env.db.write { db in
            try AlbumTracksMigrationTests.insertTrack(db, title: title, artist: artist, album: album)
        }
        if let suggestion {
            try await env.repository.upsert([AlbumSuggestionRow(trackID: id, suggestion: suggestion, alternatives: alternatives,
                                                                 status: .pending, decidedAt: nil)])
        }
        return id
    }

    static func suggestion(_ title: String = "Good Lies", year: Int? = 2022, number: Int? = 3, match: Double = 95,
                           albumArtist: String = "Overmono") -> AlbumSuggestion {
        AlbumSuggestion(albumTitle: title, albumArtist: albumArtist, year: year, trackNumber: number, disc: nil, source: "Folder name", match: match)
    }

    func undoStep(_ env: Env) async {
        env.manager.undo()
        await env.undo.waitUntilIdle()
    }

    func redoStep(_ env: Env) async {
        env.manager.redo()
        await env.undo.waitUntilIdle()
    }

    static func trackRow(_ env: Env, _ id: Int64) async throws -> (album: String, albumArtist: String, year: Int?, albumID: Int64?) {
        try await env.db.read { db in
            let row = try #require(try Row.fetchOne(db, sql: "SELECT album, album_artist, year, album_id FROM tracks WHERE id = ?", arguments: [id]))
            return (row["album"], row["album_artist"], row["year"], row["album_id"])
        }
    }

    // MARK: Accept

    @Test func acceptSetsTheTagsTheAlbumAndTheJoinInOneStep() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "So U Know", suggestion: Self.suggestion())
        await env.model.reload()
        await env.model.accept([id], undo: env.undo)
        let after = try await Self.trackRow(env, id)
        #expect(after.album == "Good Lies" && after.albumArtist == "Overmono" && after.year == 2022)
        let albumID = try #require(after.albumID)
        let join = try await env.db.read { db in try AlbumTrack.fetchAll(db, sql: "SELECT * FROM album_tracks WHERE album_id = ?", arguments: [albumID]) }
        #expect(join.map(\.trackId) == [id] && join.first?.trackNumber == 3)
        let row = try #require(try await env.repository.row(trackID: id))
        #expect(row.status == .accepted && row.decidedAt != nil)
        #expect(env.manager.undoActionName == "Set Album")
        #expect(env.status.message?.text == "Set album “Good Lies” (2022) for “So U Know”")
        #expect(env.model.counts.pending == 0 && env.model.items.isEmpty)
    }

    @Test func oneUndoPutsEverythingBackAndRedoDoesItAgain() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "So U Know", suggestion: Self.suggestion())
        await env.model.reload()
        await env.model.accept([id], undo: env.undo)
        await undoStep(env)
        let undone = try await Self.trackRow(env, id)
        #expect(undone.album == "", "the album text is as it was")
        #expect(undone.year == nil && undone.albumID == nil)
        let albums = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE title = 'Good Lies'") }
        let joins = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM album_tracks WHERE track_id = ?", arguments: [id]) }
        #expect(albums == 0 && joins == 0, "an album the accept created goes with it")
        let row = try #require(try await env.repository.row(trackID: id))
        #expect(row.status == .pending && row.decidedAt == nil)
        await env.model.reload()
        #expect(env.model.items.map(\.id) == [id], "the suggestion is back")

        await redoStep(env)
        let redone = try await Self.trackRow(env, id)
        #expect(redone.album == "Good Lies" && redone.year == 2022 && redone.albumID != nil)
        #expect(try await env.repository.row(trackID: id)?.status == .accepted)
    }

    @Test func acceptingIntoAnExistingAlbumAppendsAndUndoKeepsTheAlbum() async throws {
        let env = try Self.env()
        let (albumID, existing): (Int64, Int64) = try await env.db.write { db in
            try db.execute(sql: """
                INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('Overmono', 'Overmono', 'Good Lies', 'goodlies')
                """)
            let albumID = db.lastInsertedRowID
            let existing = try AlbumTracksMigrationTests.insertTrack(db, title: "Existing", album: "Good Lies", albumID: albumID)
            try db.execute(sql: "INSERT INTO album_tracks VALUES (?, ?, 1, 'a1', 1)", arguments: [albumID, existing])
            return (albumID, existing)
        }
        let id = try await Self.track(env, "New", suggestion: Self.suggestion(number: 2))
        await env.model.reload()
        #expect(env.model.existingAlbums[id] == albumID, "Show Suggested Album is available")
        await env.model.accept([id], undo: env.undo)
        let rows = try await AlbumTrackRepository(database: env.db).rows(of: albumID)
        #expect(rows.map(\.trackId) == [existing, id])
        #expect(rows.map(\.trackNumber) == [1, 2])
        await undoStep(env)
        let after = try await AlbumTrackRepository(database: env.db).rows(of: albumID)
        #expect(after.map(\.trackId) == [existing])
        let stillThere = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE id = ?", arguments: [albumID]) }
        #expect(stillThere == 1)
    }

    @Test func aTrackThatWasInTheLibraryUnderAnotherAlbumIDIsRelinkedAndRestored() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "Song", suggestion: Self.suggestion())
        let stale: Int64 = try await env.db.write { db in
            try db.execute(sql: "INSERT INTO albums (artist, album_artist, title, title_normalized) VALUES ('X', 'X', 'Stale', 'stale')")
            let stale = db.lastInsertedRowID
            try db.execute(sql: "UPDATE tracks SET album_id = ? WHERE id = ?", arguments: [stale, id])
            return stale
        }
        await env.model.reload()
        await env.model.accept([id], undo: env.undo)
        #expect(try await Self.trackRow(env, id).albumID != stale)
        await undoStep(env)
        #expect(try await Self.trackRow(env, id).albumID == stale)
    }

    @Test func acceptOnlyTouchesYearAndAlbumArtistWhenTheSuggestionHasThem() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "Song", suggestion: Self.suggestion(year: nil, number: nil, albumArtist: ""))
        try await env.db.write { db in try db.execute(sql: "UPDATE tracks SET year = 1999, album_artist = 'Keep' WHERE id = ?", arguments: [id]) }
        await env.model.reload()
        await env.model.accept([id], undo: env.undo)
        let after = try await Self.trackRow(env, id)
        #expect(after.album == "Good Lies" && after.year == 1999 && after.albumArtist == "Keep")
    }

    @Test func acceptWritesTheFilesOnlyWhenTheSettingIsOnAndWaitsForTheDrive() async throws {
        let off = try Self.env(writesEnabled: false)
        let a = try await Self.track(off, "A", suggestion: Self.suggestion())
        await off.model.reload()
        await off.model.accept([a], undo: off.undo)
        let queuedOff = try await off.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_tag_writes") }
        #expect(queuedOff == 0, "tag writing is off: the database only")

        let away = try Self.env(writesEnabled: true, reachable: false, volume: "Lexxar")
        let b = try await Self.track(away, "B", suggestion: Self.suggestion())
        try await away.db.write { db in try db.execute(sql: "UPDATE tracks SET organized_path = 'Overmono/B.flac' WHERE id = ?", arguments: [b]) }
        await away.model.reload()
        await away.model.accept([b], undo: away.undo)
        let queued = try await away.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pending_tag_writes") }
        #expect(queued == 1, "queued for the files")
        #expect(away.status.message?.text.contains("waiting for “Lexxar”") == true)
        #expect(away.status.message?.text.hasPrefix("Set album “Good Lies” (2022) for “B”") == true)
    }

    @Test func aRowWithoutASuggestionOrAlreadyDecidedIsNotAccepted() async throws {
        let env = try Self.env()
        let none = try await Self.track(env, "None", suggestion: nil)
        try await env.repository.upsert([AlbumSuggestionRow.looked(up: none, candidates: [])])
        let decided = try await Self.track(env, "Decided", suggestion: Self.suggestion())
        try await env.repository.setStatus(.rejected, trackIDs: [decided])
        let items = try await env.repository.pending(filter: .noMatch)
        let accepted = await env.decisions.accept(items, undo: env.undo)
        #expect(!accepted)
        #expect(env.manager.undoActionName.isEmpty, "no step for nothing")
    }

    // MARK: Bulk (A-REV-ALBBULK)

    @Test func theBulkAcceptTakesOnlyMatchesAboveNinetyAsOneStep() async throws {
        let env = try Self.env()
        let high1 = try await Self.track(env, "H1", suggestion: Self.suggestion("Album A", match: 95))
        let high2 = try await Self.track(env, "H2", suggestion: Self.suggestion("Album A", match: 91))
        let edge = try await Self.track(env, "Edge", suggestion: Self.suggestion("Album B", match: 90))
        let low = try await Self.track(env, "Low", suggestion: Self.suggestion("Album C", match: 60))
        await env.model.reload()
        #expect(Set(env.model.bulkItems.map(\.id)) == [high1, high2], "strictly above 90 %")
        #expect(env.model.bulkButtonTitle == "Accept All Above 90 % (2)…")
        await env.model.acceptAllAbove(undo: env.undo)
        #expect(env.status.message?.text == "Set the album for 2 tracks")
        let high1Album = try await Self.trackRow(env, high1).album
        let high2Album = try await Self.trackRow(env, high2).album
        #expect(high1Album == "Album A" && high2Album == "Album A")
        let edgeAlbum = try await Self.trackRow(env, edge).album
        let lowAlbum = try await Self.trackRow(env, low).album
        #expect(edgeAlbum.isEmpty && lowAlbum.isEmpty)
        let albums = try await env.db.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM albums WHERE title = 'Album A'") }
        #expect(albums == 1, "tracks of one album share its row")

        await undoStep(env)
        let high1Undone = try await Self.trackRow(env, high1).album
        let high2Undone = try await Self.trackRow(env, high2).album
        #expect(high1Undone.isEmpty && high2Undone.isEmpty)
        let pendingAgain = try await env.repository.counts().pending
        #expect(pendingAgain == 4, "one undo brings every suggestion back")
        #expect(env.manager.canRedo)
    }

    @Test func theBulkAlertWordsFollowTheSettingAndTheDrive() {
        #expect(ReviewAlbumsModel.bulkTitle(812) == "Set the album for \(812.formatted(.number)) tracks?")
        #expect(ReviewAlbumsModel.bulkButton(812) == "Accept \(812.formatted(.number)) Suggestions")
        #expect(ReviewAlbumsModel.bulkTitle(1) == "Set the album for 1 track?")
        #expect(ReviewAlbumsModel.bulkButton(1) == "Accept 1 Suggestion")
        let full = ReviewAlbumsModel.bulkMessage(writesTags: true, offlineVolume: "Lexxar")
        #expect(full == "Every suggestion with a match above 90 % is accepted: Album, Album artist, Year and track number are set, and the changes are written to the files (queued while “Lexxar” is not connected). You can undo this in one step.")
        let connected = ReviewAlbumsModel.bulkMessage(writesTags: true, offlineVolume: nil)
        #expect(connected == "Every suggestion with a match above 90 % is accepted: Album, Album artist, Year and track number are set, and the changes are written to the files. You can undo this in one step.")
        let off = ReviewAlbumsModel.bulkMessage(writesTags: false, offlineVolume: "Lexxar")
        #expect(off == "Every suggestion with a match above 90 % is accepted: Album, Album artist, Year and track number are set. You can undo this in one step.")
    }

    // MARK: Reject

    @Test func rejectShowsTheNextSuggestionAndUndoRestoresTheRow() async throws {
        let env = try Self.env()
        let alternatives = [Self.suggestion("Second", match: 70), Self.suggestion("Third", match: 80)]
        let id = try await Self.track(env, "Song", suggestion: Self.suggestion("First", match: 95), alternatives: alternatives)
        await env.model.reload()
        await env.model.reject([id], undo: env.undo)
        let next = try #require(try await env.repository.row(trackID: id))
        #expect(next.status == .pending && next.suggestion.albumTitle == "Third", "the best other suggestion")
        #expect(next.alternatives.map(\.albumTitle) == ["Second"])
        #expect(env.manager.undoActionName == "Reject Suggestion")
        #expect(env.status.message?.text == "Rejected — showing the next suggestion for “Song”")
        await undoStep(env)
        let back = try #require(try await env.repository.row(trackID: id))
        #expect(back.suggestion.albumTitle == "First" && back.alternatives.map(\.albumTitle) == ["Second", "Third"])
    }

    @Test func rejectingTheLastSuggestionRejectsTheRow() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "Song", suggestion: Self.suggestion())
        await env.model.reload()
        await env.model.reject([id], undo: env.undo)
        let row = try #require(try await env.repository.row(trackID: id))
        #expect(row.status == .rejected && row.decidedAt != nil)
        #expect(env.model.items.isEmpty)
        #expect(env.status.message?.text == "Rejected the suggestion for “Song”")
        await undoStep(env)
        #expect(try await env.repository.row(trackID: id)?.status == .pending)
    }

    // MARK: No Album

    @Test func noAlbumLeavesTheCountAndTheLookupForGoodAndUndoBringsItBack() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "Boiler Room set", suggestion: Self.suggestion())
        let other = try await Self.track(env, "Other", suggestion: Self.suggestion())
        await env.model.reload()
        #expect(env.model.tracksWithoutAlbum == 2)
        await env.model.markNoAlbum([id], undo: env.undo)
        #expect(env.model.tracksWithoutAlbum == 1, "a confirmed track stops counting as without album")
        #expect(env.model.counts.noAlbum == 1 && env.model.counts.pending == 1)
        let candidates = try await env.repository.candidatesForLookup().compactMap(\.id)
        #expect(!candidates.contains(id))
        let row = try #require(try await env.repository.row(trackID: id))
        #expect(row.status == .noAlbum)
        #expect(env.manager.undoActionName == "Mark as No Album")
        #expect(env.status.message?.text == "“Boiler Room set” is confirmed as No album — it won’t be suggested again")
        _ = other

        await undoStep(env)
        await env.model.reload()
        #expect(env.model.tracksWithoutAlbum == 2 && env.model.counts.noAlbum == 0)
        #expect(try await env.repository.row(trackID: id)?.status == .pending)
    }

    @Test func suggestAgainClearsTheFlagAndTheRowSoTheNextLookupAsksAgain() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "Set", suggestion: Self.suggestion())
        await env.model.reload()
        await env.model.markNoAlbum([id], undo: env.undo)
        await env.model.setFilter(.noAlbum)
        let item = try #require(env.model.items.first)
        #expect(item.id == id)
        await env.model.suggestAgain([id], undo: env.undo)
        #expect(try await env.repository.row(trackID: id) == nil)
        let candidates = try await env.repository.candidatesForLookup().compactMap(\.id)
        #expect(candidates == [id])
        #expect(env.manager.undoActionName == "Suggest Again")
        await undoStep(env)
        #expect(try await env.repository.row(trackID: id)?.status == .noAlbum)
        let noAlbum = try await env.repository.counts().noAlbum
        #expect(noAlbum == 1)
    }

    // MARK: Choose another

    @Test func choosingAnAlternativeChangesOnlyTheRow() async throws {
        let env = try Self.env()
        let id = try await Self.track(env, "Song", suggestion: Self.suggestion("First", match: 95),
                                      alternatives: [Self.suggestion("Second", year: 1995, match: 71)])
        await env.model.reload()
        await env.model.choose(alternativeAt: 0, for: id)
        let item = try #require(env.model.item(withID: id))
        #expect(item.row.suggestion.albumTitle == "Second" && item.row.alternatives.map(\.albumTitle) == ["First"])
        #expect(try await Self.trackRow(env, id).album == "", "nothing is written until Accept")
        #expect(env.manager.undoActionName.isEmpty)
    }

    // MARK: Words

    @Test func headerAndRowWords() {
        #expect(ReviewAlbumsModel.headerLine(withoutAlbum: 6341, ready: 1204)
                == "\(6341.formatted(.number)) tracks without album · \(1204.formatted(.number)) suggestions ready")
        #expect(ReviewAlbumsModel.headerLine(withoutAlbum: 1, ready: 1) == "1 track without album · 1 suggestion ready")
        #expect(ReviewAlbumsModel.suggestionLine(Self.suggestion("Good Lies", match: 90.4)) == "Suggested: “Good Lies” — Folder name, 90 % match")
        #expect(ReviewAlbumsModel.alternativeLine(Self.suggestion("Classics", year: 1995, match: 71)) == "Classics · 1995 — Folder name · 71 %")
    }

    @Test func theFilterListsFollowTheFilter() async throws {
        let env = try Self.env()
        let pending = try await Self.track(env, "P", suggestion: Self.suggestion())
        let none = try await Self.track(env, "N", suggestion: nil)
        try await env.repository.upsert([AlbumSuggestionRow.looked(up: none, candidates: [])])
        await env.model.reload()
        #expect(env.model.items.map(\.id) == [pending] && env.model.filter == .suggestions)
        await env.model.setFilter(.noMatch)
        #expect(env.model.items.map(\.id) == [none])
        #expect(env.model.statusText(rows: 1) == "1 track without a match")
        await env.model.setFilter(.suggestions)
        #expect(env.model.statusText(rows: 812) == "\(812.formatted(.number)) suggestions")
        #expect(env.model.hasLookedUp)
    }
}
