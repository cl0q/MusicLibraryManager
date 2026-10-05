import Foundation
import GRDB

/// Persisted Activity operations of the open library (W3-ACT, UC-JOB-02, DEC-044): table
/// `activity_operations`, migration `v46_activity_operations`.
///
/// One row per operation. Running operations are inserted when they start, finished ones are
/// replaced with their result; at launch `closeInterrupted` closes what was still running when
/// MLM quit. The result (counts, failures grouped by cause with their track ids, per-item
/// outcomes) is one JSON column. No foreign keys (they stay disabled): subjects that no longer
/// exist are flagged by `markMissingSubjects()` — a manual check against `playlists` and
/// `sync_profiles` — and their links become plain text.
///
/// Per-track download failures are **not** copied here: `tracks.download_failure` (and
/// `.retry_queue.json`) stay the source of a track's failure state. A row only names the
/// failed track ids; `failingTrackIDs(in:)` asks `tracks` which of them still fail, with the
/// same predicate the `Download failed` scope counts (`TrackAvailabilitySQL.failed`).
final class ActivityOperationRepository: ActivityHistoryStore, ActivityFailureSource, Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: - ActivityHistoryStore

    func save(_ record: ActivityOperationRecord) async throws {
        let row = Self.arguments(for: record)
        try await database.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO activity_operations (
                    id, kind, title, subject_kind, subject_id, subject_name, subject_detail,
                    subject_track_ids, subject_missing, state, is_automatic, started_at, ended_at,
                    result, needs_attention, dismissed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: row)
        }
    }

    func load(now: Date) async throws -> [ActivityOperationRecord] {
        let records = try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM activity_operations
                ORDER BY COALESCE(ended_at, started_at) DESC
                """).compactMap(Self.record(from:))
        }
        return ActivityRetentionRule.apply(records, now: now)
    }

    func closeInterrupted(at date: Date) async throws -> Int {
        let ended = Self.string(from: date)
        return try await database.write { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, result FROM activity_operations WHERE state IN ('queued', 'running', 'paused')
                """)
            for row in rows {
                let id: String = row["id"]
                var result = (row["result"] as String?).flatMap(Self.decodeResult) ?? .empty
                result.summary = ActivityInterruption.summary
                try db.execute(sql: """
                    UPDATE activity_operations SET state = 'cancelled', ended_at = ?, result = ? WHERE id = ?
                    """, arguments: [ended, Self.encodeResult(result), id])
            }
            return rows.count
        }
    }

    func prune(now: Date) async throws {
        let records = try await database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM activity_operations").compactMap(Self.record(from:))
        }
        let kept = Set(ActivityRetentionRule.apply(records, now: now).map(\.id))
        let drop = records.map(\.id).filter { !kept.contains($0) }
        guard !drop.isEmpty else { return }
        try await database.write { db in
            for chunk in stride(from: 0, to: drop.count, by: 500) {
                let ids = drop[chunk..<min(chunk + 500, drop.count)].map(\.uuidString)
                let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
                try db.execute(sql: "DELETE FROM activity_operations WHERE id IN (\(marks))",
                               arguments: StatementArguments(ids))
            }
        }
    }

    func delete(id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM activity_operations WHERE id = ?", arguments: [id.uuidString])
        }
    }

    func markDismissed(ids: [UUID], at date: Date) async throws {
        guard !ids.isEmpty else { return }
        let stamp = Self.string(from: date)
        try await database.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE activity_operations SET dismissed_at = ? WHERE id = ?",
                               arguments: [stamp, id.uuidString])
            }
        }
    }

    func clearAttention(id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE activity_operations SET needs_attention = 0 WHERE id = ?",
                           arguments: [id.uuidString])
        }
    }

    func markMissingSubjects() async throws -> Int {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE activity_operations SET subject_missing = 1
                WHERE subject_missing = 0 AND subject_kind = 'playlist'
                  AND (subject_id IS NULL OR subject_id NOT IN (SELECT id FROM playlists))
                """)
            var changed = db.changesCount
            try db.execute(sql: """
                UPDATE activity_operations SET subject_missing = 1
                WHERE subject_missing = 0 AND subject_kind = 'syncProfile'
                  AND (subject_id IS NULL OR subject_id NOT IN (SELECT id FROM sync_profiles))
                """)
            changed += db.changesCount
            return changed
        }
    }

    // MARK: - ActivityFailureSource

    /// The ids among `trackIDs` that are in the `Download failed` state now — the same SQL
    /// predicate the `Download failed` scope and the playlist header count.
    func failingTrackIDs(in trackIDs: [Int64]) async throws -> Set<Int64> {
        guard !trackIDs.isEmpty else { return [] }
        let unique = Array(Set(trackIDs))
        return try await database.read { db in
            var failing: Set<Int64> = []
            for chunk in stride(from: 0, to: unique.count, by: 500) {
                let ids = Array(unique[chunk..<min(chunk + 500, unique.count)])
                let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
                let found = try Int64.fetchAll(db, sql: """
                    SELECT id FROM tracks WHERE id IN (\(marks)) AND \(TrackAvailabilitySQL.failed)
                    """, arguments: StatementArguments(ids))
                failing.formUnion(found)
            }
            return failing
        }
    }

    // MARK: - Row mapping

    private static func arguments(for record: ActivityOperationRecord) -> StatementArguments {
        let trackIDs = record.subject.trackIDs.isEmpty
            ? nil
            : (try? String(data: JSONEncoder().encode(record.subject.trackIDs), encoding: .utf8)) ?? nil
        return [
            record.id.uuidString,
            record.kind.rawValue,
            record.title,
            record.subject.kind.rawValue,
            record.subject.id,
            record.subject.name,
            record.subject.detail,
            trackIDs,
            record.subject.isMissing ? 1 : 0,
            record.state.rawValue,
            record.isAutomatic ? 1 : 0,
            string(from: record.startedAt),
            record.endedAt.map(string(from:)),
            record.result.map(encodeResult),
            record.needsAttention ? 1 : 0,
            record.dismissedAt.map(string(from:)),
        ]
    }

    static func record(from row: Row) -> ActivityOperationRecord? {
        guard let idText: String = row["id"], let id = UUID(uuidString: idText),
              let kindText: String = row["kind"], let kind = ActivityKind(rawValue: kindText),
              let stateText: String = row["state"], let state = ActivityState(rawValue: stateText),
              let startedText: String = row["started_at"], let startedAt = date(from: startedText)
        else { return nil }
        let subjectKind = (row["subject_kind"] as String?).flatMap(ActivitySubject.Kind.init(rawValue:)) ?? .none
        let trackIDs: [Int64] = (row["subject_track_ids"] as String?)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([Int64].self, from: $0) } ?? []
        let subject = ActivitySubject(
            kind: subjectKind,
            id: row["subject_id"],
            name: row["subject_name"],
            detail: row["subject_detail"],
            trackIDs: trackIDs,
            isMissing: (row["subject_missing"] as Int? ?? 0) != 0
        )
        return ActivityOperationRecord(
            id: id,
            kind: kind,
            title: row["title"] ?? "",
            subject: subject,
            state: state,
            isAutomatic: (row["is_automatic"] as Int? ?? 0) != 0,
            startedAt: startedAt,
            endedAt: (row["ended_at"] as String?).flatMap(date(from:)),
            result: (row["result"] as String?).flatMap(decodeResult),
            needsAttention: (row["needs_attention"] as Int? ?? 0) != 0,
            dismissedAt: (row["dismissed_at"] as String?).flatMap(date(from:))
        )
    }

    private static func encodeResult(_ result: ActivityResult) -> String {
        (try? String(data: JSONEncoder().encode(result), encoding: .utf8)) ?? "{}"
    }

    private static func decodeResult(_ text: String) -> ActivityResult? {
        text.data(using: .utf8).flatMap { try? JSONDecoder().decode(ActivityResult.self, from: $0) }
    }

    /// ISO 8601 with fractional seconds, always UTC — sorts as text.
    static func string(from date: Date) -> String {
        timestampStyle.format(date)
    }

    static func date(from text: String) -> Date? {
        if let date = try? timestampStyle.parse(text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    private static let timestampStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
}
