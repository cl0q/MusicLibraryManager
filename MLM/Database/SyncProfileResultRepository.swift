import Foundation
import GRDB

// MARK: - Per-profile sync results (v47, PP-SYNC-02)

/// What happened to a track a sync could not copy (Last sync ▸ failed rows).
struct SyncResultFailure: Codable, Equatable, Hashable, Sendable, Identifiable {
    let trackID: Int64
    let title: String
    let artist: String
    /// The cause in plain words (`The device is full`).
    let reason: String
    /// Where the file was to be written on the device.
    let devicePath: String

    var id: Int64 { trackID }

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id", title, artist, reason
        case devicePath = "device_path"
    }
}

/// Why a track of the profile is not copied (Plan ▸ Skip, Last sync), never silently "pending".
enum SyncSkipReason: String, Codable, Equatable, Hashable, Sendable {
    case notDownloaded = "not_downloaded"
    case downloadFailed = "download_failed"
    case fileMissing = "file_missing"
    /// The library folder's disk is not connected (never a track state — DEC-014).
    case libraryDriveAway = "library_drive_away"

    /// The §15.4 word (`Not downloaded`, `Download failed`, `File missing`).
    var word: String {
        switch self {
        case .notDownloaded: "Not downloaded"
        case .downloadFailed: "Download failed"
        case .fileMissing: "File missing"
        case .libraryDriveAway: "Library drive not connected"
        }
    }
}

/// A track a sync skipped, with the reason.
struct SyncResultSkip: Codable, Equatable, Hashable, Sendable, Identifiable {
    let trackID: Int64
    let title: String
    let artist: String
    let reason: SyncSkipReason

    var id: Int64 { trackID }

    enum CodingKeys: String, CodingKey {
        case trackID = "track_id", title, artist, reason
    }
}

/// The plan a sync started from (`Add 214 · Remove 12 · Skip 9 · 3.1 GB of 12 GB free`).
struct SyncPlanSummary: Codable, Equatable, Hashable, Sendable {
    var add: Int
    var remove: Int
    var skip: Int
    /// Bytes the files to add take on the device.
    var addBytes: Int64
    /// Bytes the files to remove free (only when Clean up is on).
    var removeBytes: Int64
    /// Free space on the device when the plan was computed.
    var freeBytes: Int64
    var cleanUp: Bool
    /// Everything in the profile, a track in several playlists counted once.
    var totalTracks: Int

    enum CodingKeys: String, CodingKey {
        case add, remove, skip
        case addBytes = "add_bytes"
        case removeBytes = "remove_bytes"
        case freeBytes = "free_bytes"
        case cleanUp = "clean_up"
        case totalTracks = "total_tracks"
    }

    init(add: Int, remove: Int, skip: Int, addBytes: Int64, removeBytes: Int64 = 0,
         freeBytes: Int64, cleanUp: Bool, totalTracks: Int = 0) {
        self.add = add
        self.remove = remove
        self.skip = skip
        self.addBytes = addBytes
        self.removeBytes = removeBytes
        self.freeBytes = freeBytes
        self.cleanUp = cleanUp
        self.totalTracks = totalTracks
    }
}

/// One profile's last sync (`sync_profile_results`, v47).
struct SyncProfileResult: Equatable, Sendable {
    enum Outcome: String, Sendable {
        /// No run recorded yet (a row that only remembers `last_connected_at`).
        case none
        case running
        /// The device was removed during the run; it waits and resumes copying what is missing.
        case interrupted
        case completed
        case cancelled
        case failed
    }

    var profileID: Int64
    var startedAt: Date?
    var endedAt: Date?
    var outcome: Outcome
    var plannedCount: Int
    var copiedCount: Int
    var removedCount: Int
    var failedCount: Int
    var skippedCount: Int
    var failures: [SyncResultFailure]
    var skipped: [SyncResultSkip]
    var plan: SyncPlanSummary?
    /// The whole run failed (`Insufficient space`, a playlist file couldn't be written).
    var failureCause: String?
    var operationID: UUID?
    var lastInterruptedAt: Date?
    var lastConnectedAt: Date?

    init(profileID: Int64, startedAt: Date? = nil, endedAt: Date? = nil, outcome: Outcome = .none,
         plannedCount: Int = 0, copiedCount: Int = 0, removedCount: Int = 0, failedCount: Int = 0,
         skippedCount: Int = 0, failures: [SyncResultFailure] = [], skipped: [SyncResultSkip] = [],
         plan: SyncPlanSummary? = nil, failureCause: String? = nil, operationID: UUID? = nil,
         lastInterruptedAt: Date? = nil, lastConnectedAt: Date? = nil) {
        self.profileID = profileID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.plannedCount = plannedCount
        self.copiedCount = copiedCount
        self.removedCount = removedCount
        self.failedCount = failedCount
        self.skippedCount = skippedCount
        self.failures = failures
        self.skipped = skipped
        self.plan = plan
        self.failureCause = failureCause
        self.operationID = operationID
        self.lastInterruptedAt = lastInterruptedAt
        self.lastConnectedAt = lastConnectedAt
    }

    /// A run was recorded (not only the connection date).
    var hasRun: Bool { outcome != .none }
}

/// Reads and writes `sync_profile_results` (v47). Every write touches exactly one profile's row,
/// so a result can never show up on, or be retried into, another profile (PP-SYNC-02).
final class SyncProfileResultRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: Dates (ISO 8601, UTC)

    static func string(_ date: Date) -> String {
        date.formatted(.iso8601)
    }

    static func date(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        return try? Date(string, strategy: .iso8601)
    }

    // MARK: Read

    func fetchAll() async throws -> [Int64: SyncProfileResult] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM sync_profile_results")
            var results: [Int64: SyncProfileResult] = [:]
            for row in rows {
                let result = Self.decode(row)
                results[result.profileID] = result
            }
            return results
        }
    }

    func fetch(profileID: Int64) async throws -> SyncProfileResult? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM sync_profile_results WHERE profile_id = ?",
                             arguments: [profileID]).map(Self.decode)
        }
    }

    // MARK: Write

    /// A run starts: replaces the profile's previous result (keeps `last_connected_at`).
    func begin(profileID: Int64, startedAt: Date, plannedCount: Int, plan: SyncPlanSummary?,
               operationID: UUID?) async throws {
        let planJSON = try plan.map(Self.json)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profile_results (profile_id, started_at, ended_at, outcome, planned_count,
                    copied_count, removed_count, failed_count, skipped_count, failures, skipped,
                    plan_summary, failure_cause, operation_id, last_interrupted_at)
                VALUES (?, ?, NULL, 'running', ?, 0, 0, 0, 0, NULL, NULL, ?, NULL, ?, NULL)
                ON CONFLICT(profile_id) DO UPDATE SET
                    started_at = excluded.started_at, ended_at = NULL, outcome = 'running',
                    planned_count = excluded.planned_count, copied_count = 0, removed_count = 0,
                    failed_count = 0, skipped_count = 0, failures = NULL, skipped = NULL,
                    plan_summary = excluded.plan_summary, failure_cause = NULL,
                    operation_id = excluded.operation_id, last_interrupted_at = NULL
            """, arguments: [profileID, Self.string(startedAt), plannedCount, planJSON, operationID?.uuidString])
        }
    }

    /// Copies so far, while running (an interruption or a quit keeps an honest count).
    func recordProgress(profileID: Int64, copiedCount: Int) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE sync_profile_results SET copied_count = ? WHERE profile_id = ?",
                           arguments: [copiedCount, profileID])
        }
    }

    /// The device was removed: the run waits (`interrupted`) with what it copied so far.
    func recordInterruption(profileID: Int64, copiedCount: Int, at date: Date) async throws {
        try await database.write { db in
            try db.execute(sql: """
                UPDATE sync_profile_results
                SET outcome = 'interrupted', copied_count = ?, last_interrupted_at = ?
                WHERE profile_id = ?
            """, arguments: [copiedCount, Self.string(date), profileID])
        }
    }

    /// The device is back and the same run continues.
    func recordResumed(profileID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "UPDATE sync_profile_results SET outcome = 'running' WHERE profile_id = ?",
                           arguments: [profileID])
        }
    }

    /// The run ended (completed, cancelled or failed).
    func finish(profileID: Int64, outcome: SyncProfileResult.Outcome, endedAt: Date, copiedCount: Int,
                removedCount: Int, failures: [SyncResultFailure], skipped: [SyncResultSkip],
                failureCause: String? = nil) async throws {
        let failuresJSON = try Self.json(failures)
        let skippedJSON = try Self.json(skipped)
        try await database.write { db in
            try db.execute(sql: """
                UPDATE sync_profile_results
                SET outcome = ?, ended_at = ?, copied_count = ?, removed_count = ?, failed_count = ?,
                    skipped_count = ?, failures = ?, skipped = ?, failure_cause = ?
                WHERE profile_id = ?
            """, arguments: [outcome.rawValue, Self.string(endedAt), copiedCount, removedCount, failures.count,
                             skipped.count, failuresJSON, skippedJSON, failureCause, profileID])
        }
    }

    /// Retry Failed of this profile: the retried tracks that copied leave the failures, the ones
    /// that failed again keep their (new) reason; the copied count grows.
    func applyRetry(profileID: Int64, copiedTrackIDs: Set<Int64>, stillFailing: [SyncResultFailure]) async throws {
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM sync_profile_results WHERE profile_id = ?",
                                             arguments: [profileID]) else { return }
            let current = Self.decode(row)
            let retried = copiedTrackIDs.union(stillFailing.map(\.trackID))
            var failures = current.failures.filter { !retried.contains($0.trackID) }
            failures.append(contentsOf: stillFailing)
            try db.execute(sql: """
                UPDATE sync_profile_results SET failures = ?, failed_count = ?, copied_count = ?
                WHERE profile_id = ?
            """, arguments: [try Self.json(failures), failures.count,
                             current.copiedCount + copiedTrackIDs.count, profileID])
        }
    }

    /// The destination was seen connected (kept across runs).
    func recordConnected(profileID: Int64, at date: Date) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO sync_profile_results (profile_id, last_connected_at) VALUES (?, ?)
                ON CONFLICT(profile_id) DO UPDATE SET last_connected_at = excluded.last_connected_at
            """, arguments: [profileID, Self.string(date)])
        }
    }

    /// Manual cascade (foreign keys stay disabled): `SyncRepository.delete` calls the same SQL in
    /// its transaction.
    func delete(profileID: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM sync_profile_results WHERE profile_id = ?", arguments: [profileID])
        }
    }

    // MARK: Coding

    private static func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    private static func decodeJSON<T: Decodable>(_ type: T.Type, _ text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func decode(_ row: Row) -> SyncProfileResult {
        let outcome = SyncProfileResult.Outcome(rawValue: row["outcome"] ?? "none") ?? .none
        let operation: String? = row["operation_id"]
        return SyncProfileResult(
            profileID: row["profile_id"],
            startedAt: date(row["started_at"]),
            endedAt: date(row["ended_at"]),
            outcome: outcome,
            plannedCount: row["planned_count"] ?? 0,
            copiedCount: row["copied_count"] ?? 0,
            removedCount: row["removed_count"] ?? 0,
            failedCount: row["failed_count"] ?? 0,
            skippedCount: row["skipped_count"] ?? 0,
            failures: decodeJSON([SyncResultFailure].self, row["failures"]) ?? [],
            skipped: decodeJSON([SyncResultSkip].self, row["skipped"]) ?? [],
            plan: decodeJSON(SyncPlanSummary.self, row["plan_summary"]),
            failureCause: row["failure_cause"],
            operationID: operation.flatMap(UUID.init(uuidString:)),
            lastInterruptedAt: date(row["last_interrupted_at"]),
            lastConnectedAt: date(row["last_connected_at"])
        )
    }
}
