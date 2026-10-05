import Foundation
import GRDB

/// One track's value of one field before (or after) a tag edit — what undo/redo put back.
struct TrackTagSnapshot: Sendable, Hashable, Codable {
    let trackID: Int64
    let value: TrackTagValue
}

/// What a tag edit (or its undo/redo) changed in the database.
struct TrackTagChangeResult: Sendable, Hashable {
    /// The changed tracks' values *before* the change, in the order of the request.
    var previous: [TrackTagSnapshot]
    /// Tracks whose file tags are now stale (queued in `pending_tag_writes`).
    var queuedForFiles: Int
    /// Files whose format can't take this field, by format display name (`WAV`: 2).
    var unsupported: [String: Int]

    var changedCount: Int { previous.count }
}

/// A waiting tag write (`pending_tag_writes`, migration v44).
struct PendingTagWrite: Sendable, Hashable {
    let trackID: Int64
    /// Fields whose file tags are stale; the write takes their current database values.
    var fields: Set<TrackTagField>
    /// ISO 8601 time of the first edit not yet written.
    var staleSince: String
    /// Bumped by every new edit; a write clears the row only for the revision it read.
    var revision: Int
    var attempts: Int
    var lastAttemptAt: String?
    /// Plain reason of the last failed attempt.
    var lastError: String?
    /// The last failure won't go away by retrying; skipped until the next edit.
    var blocked: Bool
}

/// Tag edits and the queue of tag writes (W2-E). Separate from `TrackRepository` so the
/// undoable tag edit (`TrackTagEdit`) and the writer queue (`TagWriteQueue`) share one place
/// that keeps `search_text` and the pending rows consistent with the edit in **one
/// transaction**.
///
/// Foreign keys are disabled: rows of deleted tracks are removed by
/// `removeOrphanedPendingWrites()` (called before every flush) and never read — every read
/// joins `tracks`.
final class TrackTagRepository: Sendable {
    private let database: any DatabaseWriter
    private let now: @Sendable () -> Date

    init(database: any DatabaseWriter, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.now = now
    }

    // MARK: - Tracks

    /// Tracks by id, in the order of `ids` (missing ids are left out). Batched.
    func fetchTracks(ids: [Int64]) async throws -> [Track] {
        let unique = Self.uniqued(ids)
        guard !unique.isEmpty else { return [] }
        let found = try await database.read { db in
            try Self.tracks(db, ids: unique)
        }
        return unique.compactMap { found[$0] }
    }

    private static func tracks(_ db: Database, ids: [Int64]) throws -> [Int64: Track] {
        var result: [Int64: Track] = [:]
        result.reserveCapacity(ids.count)
        for batch in ids.chunked(into: 500) {
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            for track in try Track.fetchAll(db, sql: "SELECT * FROM tracks WHERE id IN (\(placeholders))", arguments: StatementArguments(batch)) {
                if let id = track.id { result[id] = track }
            }
        }
        return result
    }

    // MARK: - Edits

    /// Set `field` to `value` on every track of `trackIDs` that exists and differs — one
    /// transaction, `search_text` kept in step. With `queueFileWrites`, the changed tracks
    /// that have a file in a writable format are marked stale for `field`.
    ///
    /// - Returns: the changed tracks' previous values (empty: nothing changed).
    func apply(
        _ value: TrackTagValue,
        to field: TrackTagField,
        trackIDs: [Int64],
        queueFileWrites: Bool
    ) async throws -> TrackTagChangeResult {
        let ids = Self.uniqued(trackIDs)
        guard !ids.isEmpty else { return TrackTagChangeResult(previous: [], queuedForFiles: 0, unsupported: [:]) }
        let stamp = Self.iso(now())
        return try await database.write { db in
            let tracks = try Self.tracks(db, ids: ids)
            var previous: [TrackTagSnapshot] = []
            var changed: [Track] = []
            for id in ids {
                guard var track = tracks[id] else { continue }
                let old = TrackTagValue.stored(field, of: track)
                guard old.databaseValue(for: field) != value.databaseValue(for: field) else { continue }
                previous.append(TrackTagSnapshot(trackID: id, value: old))
                value.apply(field, to: &track)
                try Self.write(field, value, of: track, db: db)
                changed.append(track)
            }
            let marking = queueFileWrites
                ? try Self.markStale(changed, field: field, stamp: stamp, db: db)
                : (queued: 0, unsupported: [:])
            return TrackTagChangeResult(previous: previous, queuedForFiles: marking.queued, unsupported: marking.unsupported)
        }
    }

    /// Put back exact per-track values of `field` (undo and redo) — one transaction. Tracks
    /// that no longer exist are skipped.
    ///
    /// - Returns: the values the restored tracks had just before (for the opposite direction).
    func restore(
        _ snapshots: [TrackTagSnapshot],
        field: TrackTagField,
        queueFileWrites: Bool
    ) async throws -> TrackTagChangeResult {
        guard !snapshots.isEmpty else { return TrackTagChangeResult(previous: [], queuedForFiles: 0, unsupported: [:]) }
        let stamp = Self.iso(now())
        return try await database.write { db in
            let tracks = try Self.tracks(db, ids: snapshots.map(\.trackID))
            var previous: [TrackTagSnapshot] = []
            var changed: [Track] = []
            for snapshot in snapshots {
                guard var track = tracks[snapshot.trackID] else { continue }
                previous.append(TrackTagSnapshot(trackID: snapshot.trackID, value: .stored(field, of: track)))
                snapshot.value.apply(field, to: &track)
                try Self.write(field, snapshot.value, of: track, db: db)
                changed.append(track)
            }
            let marking = queueFileWrites
                ? try Self.markStale(changed, field: field, stamp: stamp, db: db)
                : (queued: 0, unsupported: [:])
            return TrackTagChangeResult(previous: previous, queuedForFiles: marking.queued, unsupported: marking.unsupported)
        }
    }

    private static func write(_ field: TrackTagField, _ value: TrackTagValue, of track: Track, db: Database) throws {
        guard let id = track.id else { return }
        try db.execute(
            sql: "UPDATE tracks SET \(field.column) = ?, search_text = ? WHERE id = ?",
            arguments: [value.databaseValue(for: field), DatabaseManager.foldedSearchText(track.rawSearchText), id]
        )
    }

    // MARK: - Pending writes

    /// Mark the files of `tracks` stale for `field`. Tracks without a file (not downloaded)
    /// have nothing to write; formats that can't take the field are counted, not queued.
    private static func markStale(
        _ tracks: [Track],
        field: TrackTagField,
        stamp: String,
        db: Database
    ) throws -> (queued: Int, unsupported: [String: Int]) {
        var queued = 0
        var unsupported: [String: Int] = [:]
        for track in tracks {
            guard let id = track.id, let path = track.organizedPath, !path.isEmpty else { continue }
            let ext = (path as NSString).pathExtension
            guard let format = TagFileFormat(pathExtension: ext), format.writableFields.contains(field) else {
                let name = TagFileFormat(pathExtension: ext).map { "\(field.titleCaseName) can’t be written to \($0.displayName) files" }
                    ?? "\(TagFileFormat.displayName(pathExtension: ext)) isn’t supported"
                unsupported[name, default: 0] += 1
                continue
            }
            try markStale(trackID: id, fields: [field], stamp: stamp, db: db)
            queued += 1
        }
        return (queued, unsupported)
    }

    /// Union `fields` into the track's row (creating it), bump its revision and clear any
    /// earlier failure: a new edit deserves a new attempt.
    static func markStale(trackID: Int64, fields: Set<TrackTagField>, stamp: String, db: Database) throws {
        if let row = try Row.fetchOne(db, sql: "SELECT fields FROM pending_tag_writes WHERE track_id = ?", arguments: [trackID]) {
            let merged = TrackTagField.decode(row["fields"]).union(fields)
            try db.execute(sql: """
                UPDATE pending_tag_writes
                SET fields = ?, revision = revision + 1, attempts = 0, blocked = 0, last_error = NULL
                WHERE track_id = ?
                """, arguments: [TrackTagField.encode(merged), trackID])
        } else {
            try db.execute(sql: """
                INSERT INTO pending_tag_writes (track_id, fields, stale_since, revision, attempts, blocked)
                VALUES (?, ?, ?, 1, 0, 0)
                """, arguments: [trackID, TrackTagField.encode(fields), stamp])
        }
    }

    /// Mark tracks stale for `fields` outside an edit (e.g. a package that changed tags in its
    /// own transaction). Tracks without a file are skipped.
    func markStale(trackIDs: [Int64], fields: Set<TrackTagField>) async throws {
        let ids = Self.uniqued(trackIDs)
        guard !ids.isEmpty, !fields.isEmpty else { return }
        let stamp = Self.iso(now())
        try await database.write { db in
            let tracks = try Self.tracks(db, ids: ids)
            for id in ids {
                guard let path = tracks[id]?.organizedPath, !path.isEmpty else { continue }
                try Self.markStale(trackID: id, fields: fields, stamp: stamp, db: db)
            }
        }
    }

    private static let pendingColumns = """
        p.track_id, p.fields, p.stale_since, p.revision, p.attempts, p.last_attempt_at, p.last_error, p.blocked
        """

    private static func pending(_ row: Row) -> PendingTagWrite {
        PendingTagWrite(
            trackID: row["track_id"],
            fields: TrackTagField.decode(row["fields"]),
            staleSince: row["stale_since"],
            revision: row["revision"],
            attempts: row["attempts"],
            lastAttemptAt: row["last_attempt_at"],
            lastError: row["last_error"],
            blocked: (row["blocked"] as Int?) == 1
        )
    }

    /// Waiting writes of existing tracks, oldest first. `excluding`: tracks already tried in
    /// this run.
    func pendingWrites(limit: Int, includeBlocked: Bool = false, excluding: Set<Int64> = []) async throws -> [PendingTagWrite] {
        let excluded = Array(excluding)
        return try await database.read { db in
            var sql = """
                SELECT \(Self.pendingColumns) FROM pending_tag_writes p
                JOIN tracks t ON t.id = p.track_id
                WHERE 1 = 1
                """
            var arguments: [DatabaseValueConvertible] = []
            if !includeBlocked { sql += " AND p.blocked = 0" }
            if !excluded.isEmpty {
                sql += " AND p.track_id NOT IN (\(Array(repeating: "?", count: excluded.count).joined(separator: ", ")))"
                arguments += excluded.map { $0 as DatabaseValueConvertible }
            }
            sql += " ORDER BY p.stale_since, p.track_id LIMIT ?"
            arguments.append(limit)
            return try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)).map(Self.pending)
        }
    }

    /// The waiting write of one track (nil: its file tags are current).
    func pendingWrite(trackID: Int64) async throws -> PendingTagWrite? {
        try await database.read { db in
            try Row.fetchOne(db, sql: """
                SELECT \(Self.pendingColumns) FROM pending_tag_writes p
                JOIN tracks t ON t.id = p.track_id
                WHERE p.track_id = ?
                """, arguments: [trackID]).map(Self.pending)
        }
    }

    /// Of `trackIDs`, those whose file tags wait to be written (not blocked).
    func pendingTrackIDs(among trackIDs: [Int64]) async throws -> Set<Int64> {
        let ids = Self.uniqued(trackIDs)
        guard !ids.isEmpty else { return [] }
        return try await database.read { db in
            var result: Set<Int64> = []
            for batch in ids.chunked(into: 500) {
                let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                result.formUnion(try Int64.fetchAll(db, sql: """
                    SELECT p.track_id FROM pending_tag_writes p JOIN tracks t ON t.id = p.track_id
                    WHERE p.blocked = 0 AND p.track_id IN (\(placeholders))
                    """, arguments: StatementArguments(batch)))
            }
            return result
        }
    }

    /// Tracks whose file tags wait to be written (blocked rows excluded).
    func pendingCount() async throws -> Int {
        try await database.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM pending_tag_writes p JOIN tracks t ON t.id = p.track_id WHERE p.blocked = 0
                """) ?? 0
        }
    }

    /// The write of `revision` reached the file: the row goes — unless an edit came in
    /// meanwhile (then the next flush writes the newer values).
    @discardableResult
    func completeWrite(trackID: Int64, revision: Int) async throws -> Bool {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM pending_tag_writes WHERE track_id = ? AND revision = ?", arguments: [trackID, revision])
            return db.changesCount > 0
        }
    }

    /// A write attempt failed: count it and keep the reason. `blocked` rows wait for the next
    /// edit. An edit that came in meanwhile (newer revision) keeps its clean slate.
    func recordFailure(trackID: Int64, revision: Int, reason: String, blocked: Bool) async throws {
        let stamp = Self.iso(now())
        try await database.write { db in
            try db.execute(sql: """
                UPDATE pending_tag_writes
                SET attempts = attempts + 1, last_attempt_at = ?, last_error = ?, blocked = ?
                WHERE track_id = ? AND revision = ?
                """, arguments: [stamp, reason, blocked ? 1 : 0, trackID, revision])
        }
    }

    /// Manual cascade (foreign keys are off): rows of tracks that no longer exist.
    @discardableResult
    func removeOrphanedPendingWrites() async throws -> Int {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM pending_tag_writes WHERE track_id NOT IN (SELECT id FROM tracks)")
            return db.changesCount
        }
    }

    // MARK: - Helpers

    static func uniqued(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }

    static func iso(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

// MARK: - Setting: Write tags to files

/// Settings ▸ Library ▸ `Write tags to files`. Stored per library in its database
/// (`app_config`). **Fails closed:** only an explicit stored `"1"` means on; absent, any other
/// value, an unreadable config or no library open means off (W2-E review: off until the
/// owner decides the default, B3-PLAN §5 question 6).
enum TagWriteSetting {
    /// `app_config` key; `"1"` = on, anything else or absent = off.
    static let key = "write_tags_to_files"
    static let onValue = "1"

    static func isEnabled(_ config: ConfigRepository?) async -> Bool {
        guard let config else { return false }
        do {
            return try await config.get(key: key) == onValue
        } catch {
            return false
        }
    }

    static func setEnabled(_ enabled: Bool, config: ConfigRepository) async throws {
        try await config.set(key: key, value: enabled ? onValue : "0")
    }
}
