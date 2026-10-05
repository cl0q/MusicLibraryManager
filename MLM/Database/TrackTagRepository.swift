import Foundation
import GRDB

/// What a file should carry for one field (W2-E review B1). A file only ever receives a value
/// the user typed in MLM, or — after undo back to the pre-MLM state — the exact value it had
/// before MLM's first write. Never a value derived from an import-normalised column.
enum TagFileIntent: Sendable, Hashable, Codable {
    /// The user's typed value; nil = the user cleared the field (no tag).
    case typed(String?)
    /// The file's own value from before MLM's first write of this field.
    case original

    /// The value the file receives for a committed `value`: typed text as typed, a cleared field
    /// (or no number) as no tag.
    static func typedValue(_ value: TrackTagValue) -> TagFileIntent {
        switch value {
        case .text(let text):
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .typed(trimmed.isEmpty ? nil : trimmed)
        case .number(let number):
            return .typed(number.flatMap { $0 > 0 ? String($0) : nil })
        }
    }
}

/// One track's value of one field before (or after) a tag edit — what undo/redo put back: the
/// database value and what its file was meant to carry.
struct TrackTagSnapshot: Sendable, Hashable, Codable {
    let trackID: Int64
    let value: TrackTagValue
    var fileIntent: TagFileIntent = .original
}

/// A field's file state (`tag_write_fields`, migration v53).
struct TagFieldState: Sendable, Hashable {
    let field: TrackTagField
    var intent: TagFileIntent
    /// nil = not captured yet (MLM hasn't written this field of this file).
    var original: CapturedOriginal?

    /// The file's value before MLM's first write: `value` nil = the tag was absent.
    struct CapturedOriginal: Sendable, Hashable {
        let value: String?
    }
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
    /// Fields whose file tags are stale; what to write is each field's `TagFieldState`.
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
    /// that have a file in a writable format get the typed value as their file intent and are
    /// marked stale for `field`.
    ///
    /// - Returns: the changed tracks' previous values and file intents (empty: nothing changed).
    func apply(
        _ value: TrackTagValue,
        to field: TrackTagField,
        trackIDs: [Int64],
        queueFileWrites: Bool
    ) async throws -> TrackTagChangeResult {
        let ids = Self.uniqued(trackIDs)
        guard !ids.isEmpty else { return TrackTagChangeResult(previous: [], queuedForFiles: 0, unsupported: [:]) }
        let stamp = Self.iso(now())
        let intent = TagFileIntent.typedValue(value)
        return try await database.write { db in
            let tracks = try Self.tracks(db, ids: ids)
            var previous: [TrackTagSnapshot] = []
            var changed: [Track] = []
            for id in ids {
                guard var track = tracks[id] else { continue }
                let old = TrackTagValue.stored(field, of: track)
                guard old.databaseValue(for: field) != value.databaseValue(for: field) else { continue }
                let oldIntent = try Self.fieldState(db, trackID: id, field: field)?.intent ?? .original
                previous.append(TrackTagSnapshot(trackID: id, value: old, fileIntent: oldIntent))
                value.apply(field, to: &track)
                try Self.write(field, value, of: track, db: db)
                changed.append(track)
            }
            var marking: (queued: Int, unsupported: [String: Int]) = (0, [:])
            if queueFileWrites {
                marking = try Self.queue(changed.map { ($0, intent) }, field: field, stamp: stamp, db: db)
            }
            return TrackTagChangeResult(previous: previous, queuedForFiles: marking.queued, unsupported: marking.unsupported)
        }
    }

    /// Put back exact per-track values of `field` (undo and redo) — one transaction. Tracks
    /// that no longer exist are skipped. With `queueFileWrites` each file gets the snapshot's
    /// intent back: a typed value is written again; `.original` restores the file's captured
    /// pre-MLM value — or, when MLM never wrote that field, nothing is written at all.
    ///
    /// - Returns: the values and intents the restored tracks had just before (for the opposite
    ///   direction).
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
            var restoredFiles: [(Track, TagFileIntent)] = []
            for snapshot in snapshots {
                guard var track = tracks[snapshot.trackID] else { continue }
                let state = try Self.fieldState(db, trackID: snapshot.trackID, field: field)
                previous.append(TrackTagSnapshot(trackID: snapshot.trackID, value: .stored(field, of: track),
                                                 fileIntent: state?.intent ?? .original))
                snapshot.value.apply(field, to: &track)
                try Self.write(field, snapshot.value, of: track, db: db)
                // `.original` with no state: MLM never touched this field of the file.
                if case .original = snapshot.fileIntent, state == nil { continue }
                restoredFiles.append((track, snapshot.fileIntent))
            }
            var marking: (queued: Int, unsupported: [String: Int]) = (0, [:])
            if queueFileWrites {
                marking = try Self.queue(restoredFiles, field: field, stamp: stamp, db: db)
            }
            return TrackTagChangeResult(previous: previous, queuedForFiles: marking.queued, unsupported: marking.unsupported)
        }
    }

    /// `album_id` is left as it is on an album edit — exactly what the old save path
    /// (`TrackRepository.update` with the row's album id) did; albums become entities in W4.
    private static func write(_ field: TrackTagField, _ value: TrackTagValue, of track: Track, db: Database) throws {
        guard let id = track.id else { return }
        try db.execute(
            sql: "UPDATE tracks SET \(field.column) = ?, search_text = ? WHERE id = ?",
            arguments: [value.databaseValue(for: field), DatabaseManager.foldedSearchText(track.rawSearchText), id]
        )
    }

    // MARK: - File intents and pending writes

    /// Give each track's file `intent` for `field` and mark it stale. Tracks without a file
    /// (not downloaded) have nothing to write; formats that can't take the field are counted,
    /// not queued.
    private static func queue(
        _ items: [(Track, TagFileIntent)],
        field: TrackTagField,
        stamp: String,
        db: Database
    ) throws -> (queued: Int, unsupported: [String: Int]) {
        var queued = 0
        var unsupported: [String: Int] = [:]
        for (track, intent) in items {
            guard let id = track.id, let path = track.organizedPath, !path.isEmpty else { continue }
            let ext = (path as NSString).pathExtension
            guard let format = TagFileFormat(pathExtension: ext), format.writableFields.contains(field) else {
                let name = TagFileFormat(pathExtension: ext).map { "\(field.titleCaseName) can’t be written to \($0.displayName) files" }
                    ?? "\(TagFileFormat.displayName(pathExtension: ext)) isn’t supported"
                unsupported[name, default: 0] += 1
                continue
            }
            try setIntent(intent, trackID: id, field: field, db: db)
            try markStale(trackID: id, fields: [field], stamp: stamp, db: db)
            queued += 1
        }
        return (queued, unsupported)
    }

    private static func setIntent(_ intent: TagFileIntent, trackID: Int64, field: TrackTagField, db: Database) throws {
        let kind: String
        let typed: String?
        switch intent {
        case .typed(let value): kind = "typed"; typed = value
        case .original: kind = "original"; typed = nil
        }
        try db.execute(sql: """
            INSERT INTO tag_write_fields (track_id, field, intent, typed_value, original_state)
            VALUES (?, ?, ?, ?, 'unknown')
            ON CONFLICT(track_id, field) DO UPDATE SET intent = excluded.intent, typed_value = excluded.typed_value
            """, arguments: [trackID, field.rawValue, kind, typed])
    }

    private static func fieldState(_ db: Database, trackID: Int64, field: TrackTagField) throws -> TagFieldState? {
        try Row.fetchOne(db, sql: """
            SELECT field, intent, typed_value, original_state, original_value FROM tag_write_fields
            WHERE track_id = ? AND field = ?
            """, arguments: [trackID, field.rawValue]).flatMap(Self.fieldState)
    }

    private static func fieldState(_ row: Row) -> TagFieldState? {
        guard let field = TrackTagField(rawValue: row["field"]) else { return nil }
        let intent: TagFileIntent = (row["intent"] as String) == "typed" ? .typed(row["typed_value"]) : .original
        let original: TagFieldState.CapturedOriginal?
        switch row["original_state"] as String {
        case "present": original = .init(value: row["original_value"] as String? ?? "")
        case "absent": original = .init(value: nil)
        default: original = nil
        }
        return TagFieldState(field: field, intent: intent, original: original)
    }

    /// The file states of a track's fields.
    func fieldStates(trackID: Int64) async throws -> [TrackTagField: TagFieldState] {
        try await database.read { db in
            var states: [TrackTagField: TagFieldState] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT field, intent, typed_value, original_state, original_value FROM tag_write_fields WHERE track_id = ?
                """, arguments: [trackID]) {
                if let state = Self.fieldState(row) { states[state.field] = state }
            }
            return states
        }
    }

    /// Keep the file's values from before MLM's first write (called by the writer after it
    /// read the file and **before** it writes). Already captured values are never replaced.
    func recordOriginals(trackID: Int64, values: [TrackTagField: String?]) async throws {
        guard !values.isEmpty else { return }
        let stamp = Self.iso(now())
        try await database.write { db in
            for (field, value) in values {
                try db.execute(sql: """
                    UPDATE tag_write_fields SET original_state = ?, original_value = ?, original_captured_at = ?
                    WHERE track_id = ? AND field = ? AND original_state = 'unknown'
                    """, arguments: [value == nil ? "absent" : "present", value, stamp, trackID, field.rawValue])
            }
        }
    }

    /// The file carries its pre-MLM value again (or never got another): forget those fields.
    /// Only rows still meant to be `.original` go.
    func forgetRestoredFields(trackID: Int64, fields: Set<TrackTagField>) async throws {
        guard !fields.isEmpty else { return }
        try await database.write { db in
            for field in fields {
                try db.execute(sql: "DELETE FROM tag_write_fields WHERE track_id = ? AND field = ? AND intent = 'original'",
                               arguments: [trackID, field.rawValue])
            }
        }
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

    /// Queue an explicit typed value for the files of `trackIDs` (a package that changed the
    /// database itself, e.g. a genre merge, passes the value the user chose). There is no
    /// "write whatever the database has" entry point: file values come only from typed values.
    @discardableResult
    func queueTypedValue(_ value: TrackTagValue, field: TrackTagField, trackIDs: [Int64]) async throws -> (queued: Int, unsupported: [String: Int]) {
        let ids = Self.uniqued(trackIDs)
        guard !ids.isEmpty else { return (0, [:]) }
        let stamp = Self.iso(now())
        let intent = TagFileIntent.typedValue(value)
        return try await database.write { db in
            let tracks = try Self.tracks(db, ids: ids)
            return try Self.queue(ids.compactMap { tracks[$0] }.map { ($0, intent) }, field: field, stamp: stamp, db: db)
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

    /// Waiting writes of existing tracks with ids above `afterTrackID`, by track id (a flush
    /// pages through them; nothing is held in an unbounded `NOT IN` list).
    func pendingWrites(limit: Int, includeBlocked: Bool = false, afterTrackID: Int64? = nil) async throws -> [PendingTagWrite] {
        try await database.read { db in
            var sql = """
                SELECT \(Self.pendingColumns) FROM pending_tag_writes p
                JOIN tracks t ON t.id = p.track_id
                WHERE p.track_id > ?
                """
            if !includeBlocked { sql += " AND p.blocked = 0" }
            sql += " ORDER BY p.track_id LIMIT ?"
            return try Row.fetchAll(db, sql: sql, arguments: [afterTrackID ?? Int64.min, limit]).map(Self.pending)
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

    /// An analysed BPM goes in only where none is stored at write time (`COALESCE`), so a BPM
    /// typed while the analysis ran is kept (S5). It never queues a file write.
    @discardableResult
    func fillBPMIfEmpty(trackID: Int64, bpm: Int) async throws -> Bool {
        guard bpm > 0 else { return false }
        return try await database.write { db in
            // BPM isn't part of `search_text`.
            try db.execute(sql: "UPDATE tracks SET bpm = COALESCE(bpm, ?) WHERE id = ? AND bpm IS NULL", arguments: [bpm, trackID])
            return db.changesCount > 0
        }
    }

    /// `Try Again` in Info ▸ File: a blocked write gets another attempt.
    func unblock(trackID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE pending_tag_writes SET blocked = 0, attempts = 0 WHERE track_id = ?", arguments: [trackID])
        }
    }

    /// Manual cascade (foreign keys are off): rows of tracks that no longer exist, in both
    /// tag-write tables.
    @discardableResult
    func removeOrphanedPendingWrites() async throws -> Int {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM pending_tag_writes WHERE track_id NOT IN (SELECT id FROM tracks)")
            let pending = db.changesCount
            try db.execute(sql: "DELETE FROM tag_write_fields WHERE track_id NOT IN (SELECT id FROM tracks)")
            return pending + db.changesCount
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
