import Foundation
import GRDB

/// Source names that were written into the Album field by older imports (`SoundCloud`,
/// `YouTube`, … ROADMAP C3): a source is where a track came from, never an album (IMP-085).
enum SourceAlbumNames {
    /// The names `Clear Source Names from Album` knows, as shown in the alert.
    static let names = ["SoundCloud", "YouTube", "Spotify", "DAB", "Qobuz", "Last.fm", "soundcloud likes", "youtube likes", "Downloads"]

    /// Compared case-insensitively and trimmed.
    static let keys: Set<String> = Set(names.map { $0.lowercased() })

    static func isSourceName(_ album: String) -> Bool {
        keys.contains(album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// `WHERE`-ready predicate over `tracks.album`.
    static let sql: String = {
        let list = keys.sorted().map { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }.joined(separator: ", ")
        return "LOWER(TRIM(tracks.album)) IN (\(list))"
    }()

    /// The `sources.name` an album word stands for: `soundcloud likes` and `SoundCloud` are
    /// `soundcloud`; `Downloads` names no source.
    static func sourceName(forAlbum album: String) -> String? {
        switch album.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "soundcloud", "soundcloud likes": "soundcloud"
        case "youtube", "youtube likes": "youtube"
        case "spotify": "spotify"
        case "dab": "dab"
        case "qobuz": "qobuz"
        case "last.fm": "last.fm"
        default: nil
        }
    }

    /// The id a track's stored original path carries for `source` (`soundcloud://123`,
    /// `youtube://abc`, `spotify:track:xyz`); nil when it carries none.
    static func externalID(originalPath: String, source: String) -> String? {
        let path = originalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix: String
        switch source {
        case "soundcloud": prefix = "soundcloud://"
        case "youtube": prefix = "youtube://"
        case "spotify": prefix = "spotify:track:"
        default: return nil
        }
        guard path.lowercased().hasPrefix(prefix) else { return nil }
        let id = String(path.dropFirst(prefix.count))
        return id.isEmpty ? nil : id
    }
}

/// A track the cleanup will touch.
struct SourceNamedTrack: Sendable, Equatable {
    var id: Int64
    var album: String
    var originalPath: String
}

/// What the cleanup wrote besides the Album field, exactly, so Undo and Redo put it back.
struct SourceCleanupProvenance: Sendable, Equatable {
    struct Link: Sendable, Equatable {
        var trackID: Int64
        var sourceID: Int64
        var externalID: String
        var addedAt: String
    }

    /// `track_sources` rows this cleanup inserted.
    var inserted: [Link] = []
    /// Tracks whose source could not be recorded in `track_sources` → the album word they had.
    var logged: [String: String] = [:]
    /// `app_config` `albums.sourceCleanup.log` before and after (nil = no entry).
    var logBefore: String?
    var logAfter: String?
}

/// `Clear Source Names from Album` (IMP-085): the Album field of tracks that hold a source name
/// is blanked through `TrackTagEdit` (one undo step with the provenance), and where the track
/// came from stays recorded — a missing `track_sources` row is inserted when a `sources` row of
/// that name and an external id exist (`sources` rows are never created), otherwise
/// `{"‹trackID›": "‹name›"}` is merged into the `app_config` entry `albums.sourceCleanup.log`.
struct SourceAlbumCleanup: Sendable {
    static let logKey = "albums.sourceCleanup.log"

    let database: any DatabaseWriter

    /// Tracks whose album is a source name.
    static func count(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks WHERE \(SourceAlbumNames.sql)") ?? 0
    }

    func affected() async throws -> [SourceNamedTrack] {
        try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT id, album, original_path FROM tracks WHERE \(SourceAlbumNames.sql) ORDER BY id").map {
                SourceNamedTrack(id: $0["id"], album: $0["album"], originalPath: $0["original_path"])
            }
        }
    }

    /// Records where the tracks came from (one transaction).
    func recordProvenance(for tracks: [SourceNamedTrack], addedAt: String) async throws -> SourceCleanupProvenance {
        try await database.write { db in
            var result = SourceCleanupProvenance()
            result.logBefore = try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = ?", arguments: [Self.logKey])
            for track in tracks {
                // Already linked to a source: where it came from is recorded.
                let linked = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM track_sources WHERE track_id = ?)", arguments: [track.id]) ?? false
                if linked { continue }
                if let name = SourceAlbumNames.sourceName(forAlbum: track.album),
                   let externalID = SourceAlbumNames.externalID(originalPath: track.originalPath, source: name),
                   let sourceID = try Int64.fetchOne(db, sql: "SELECT id FROM sources WHERE name = ? ORDER BY id LIMIT 1", arguments: [name]) {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, ?, ?)
                        """, arguments: [track.id, sourceID, externalID, addedAt])
                    if db.changesCount > 0 {
                        result.inserted.append(.init(trackID: track.id, sourceID: sourceID, externalID: externalID, addedAt: addedAt))
                        continue
                    }
                }
                result.logged[String(track.id)] = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !result.logged.isEmpty {
                var merged = (result.logBefore.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) }) ?? [:]
                merged.merge(result.logged) { _, new in new }
                let data = try JSONEncoder().encode(merged)
                result.logAfter = String(decoding: data, as: UTF8.self)
                try Self.writeLog(db, result.logAfter)
            } else {
                result.logAfter = result.logBefore
            }
            return result
        }
    }

    /// Undo: the inserted `track_sources` rows go, the log is as it was.
    func revert(_ provenance: SourceCleanupProvenance) async throws {
        try await database.write { db in
            for link in provenance.inserted {
                try db.execute(sql: "DELETE FROM track_sources WHERE track_id = ? AND source_id = ?", arguments: [link.trackID, link.sourceID])
            }
            try Self.writeLog(db, provenance.logBefore)
        }
    }

    /// Redo: the same rows and the same log again.
    func reapply(_ provenance: SourceCleanupProvenance) async throws {
        try await database.write { db in
            for link in provenance.inserted {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO track_sources (track_id, source_id, external_id, added_at) VALUES (?, ?, ?, ?)
                    """, arguments: [link.trackID, link.sourceID, link.externalID, link.addedAt])
            }
            try Self.writeLog(db, provenance.logAfter)
        }
    }

    private static func writeLog(_ db: Database, _ value: String?) throws {
        if let value {
            try db.execute(sql: "INSERT OR REPLACE INTO app_config (key, value, updated_at) VALUES (?, ?, datetime('now'))", arguments: [logKey, value])
        } else {
            try db.execute(sql: "DELETE FROM app_config WHERE key = ?", arguments: [logKey])
        }
    }

    // MARK: The step

    /// What a cleanup did, for its confirmation.
    struct Outcome: Sendable, Equatable {
        var count: Int
        var recorded: Int
        var logged: Int
        var waiting: Int?
    }

    /// The whole job as one undo step (`Clear Source Names`): the Album field of `tracks` through
    /// `TrackTagEdit` (database, and the files when the user enabled tag writing — queued while the
    /// drive is away) and the provenance. Returns nil when there was nothing to clear.
    @MainActor
    func run(tracks: [SourceNamedTrack], tagEdit: TrackTagEdit, undo: UndoCenter, volumeName: @MainActor @escaping () -> String?,
             now: Date = Date()) async throws -> Outcome? {
        guard !tracks.isEmpty else { return nil }
        let stamp = ISO8601DateFormatter().string(from: now)
        let cleanup = self
        return try await undo.performGroup(
            "Clear Source Names", failure: "Couldn’t clear the source names",
            { group in
                // Provenance first: the Album field is what tells which source it was.
                let provenance = try await group.perform(
                    do: { try await cleanup.recordProvenance(for: tracks, addedAt: stamp) },
                    undo: { provenance in try await cleanup.revert(provenance); return provenance },
                    redo: { provenance in try await cleanup.reapply(provenance); return provenance })
                let step = try await tagEdit.perform(.text(""), field: .album, trackIDs: tracks.map(\.id), in: group)
                return Outcome(count: step?.snapshots.count ?? tracks.count, recorded: provenance.inserted.count,
                               logged: provenance.logged.count, waiting: (step?.waiting ?? 0) > 0 ? step?.waiting : nil)
            },
            message: { outcome in Self.message(outcome, volume: volumeName()) })
    }

    /// `Cleared the source name from 812 tracks · 3 tag changes waiting for “Lexxar”`.
    @MainActor
    static func message(_ outcome: Outcome, volume: String?) -> String {
        let tracks = outcome.count == 1 ? "1 track" : "\(outcome.count.formatted(.number)) tracks"
        var text = "Cleared the source name from \(tracks)"
        if let waiting = outcome.waiting, waiting > 0 { text += " · " + TrackTagEdit.waitingText(waiting, volume: volume) }
        return text
    }

    // MARK: Words (the confirmation alert)

    static func alertTitle(_ count: Int) -> String {
        count == 1 ? "Clear the source name from 1 track?" : "Clear the source name from \(count.formatted(.number)) tracks?"
    }

    static let alertMessage = "“SoundCloud”, “YouTube” … are not albums. The Album field of these tracks is cleared; where they came from stays recorded."

    static func alertButton(_ count: Int) -> String {
        count == 1 ? "Clear 1 Album" : "Clear \(count.formatted(.number)) Albums"
    }

    static let nothingToClear = "No track has a source name as album."
}
