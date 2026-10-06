import Foundation
import GRDB

// MARK: - Values (W3-REV, IMP-051)

enum ReviewDecisionKind: String, Codable, Sendable {
    case duplicate
    case conflict
}

enum ReviewDecisionAction: String, Codable, Sendable {
    case keepRecommended = "keep_recommended"
    case keepSelected = "keep_selected"
    case keepAll = "keep_all"
    case merge
    case keepBoth = "keep_both"
}

/// What happens to the versions that are not kept (`Unkept versions:` radio, V-REV.N03).
enum UnkeptMode: String, Codable, Sendable {
    case hidden
    case trash
}

/// An unordered pair of track ids (`a < b`).
struct ReviewPair: Hashable, Sendable {
    let a: Int64
    let b: Int64

    init(_ x: Int64, _ y: Int64) {
        a = min(x, y)
        b = max(x, y)
    }

    /// Every pair of a group's members.
    static func pairs(of ids: [Int64]) -> [ReviewPair] {
        let sorted = Array(Set(ids)).sorted()
        var result: [ReviewPair] = []
        for i in sorted.indices {
            for j in sorted.indices where j > i { result.append(ReviewPair(sorted[i], sorted[j])) }
        }
        return result
    }

    /// A group is proposed again only while it has a pair no decision covers.
    static func hasUndecidedPair(_ ids: [Int64], decided: Set<ReviewPair>) -> Bool {
        pairs(of: ids).contains { !decided.contains($0) }
    }
}

/// The exact state a decision changed, stored as JSON so Undo and Restore can put it back.
struct ReviewDecisionConsequences: Codable, Equatable, Sendable {
    struct Flag: Codable, Equatable, Sendable {
        var trackId: Int64
        var isDuplicate: Int
        var variantOf: Int64?
    }

    struct PlaylistRow: Codable, Equatable, Sendable {
        enum Change: String, Codable, Sendable { case repointed, deleted }
        var id: Int64
        var playlistId: Int64
        /// The track the row had before (the unkept version).
        var trackId: Int64
        var position: String
        var addedAt: String?
        var change: Change
    }

    struct SyncRow: Codable, Equatable, Sendable {
        var profileId: Int64
        var trackId: Int64
        var change: PlaylistRow.Change
    }

    struct Trashed: Codable, Equatable, Sendable {
        var trackId: Int64
        var from: String
        var trashURL: String
    }

    struct TagChange: Codable, Equatable, Sendable {
        var trackId: Int64
        /// `TrackTagField.rawValue`.
        var field: String
        var old: TrackTagValue
    }

    var flags: [Flag] = []
    var playlistRows: [PlaylistRow] = []
    var syncRows: [SyncRow] = []
    var trashed: [Trashed] = []
    var tags: [TagChange] = []
    /// Fields a merge changed (`Album`, `Year`), for the Resolved outcome.
    var changedFields: [String] = []
    var keptFormat: String?
    var hiddenCount = 0
    /// Files that couldn't be moved to the Trash.
    var trashFailures = 0

    var repointedPlaylistEntries: Int { playlistRows.count }
    var repointedSyncRows: Int { syncRows.count }
}

struct ReviewDecisionRequest: Sendable {
    var groupKey: String
    var kind: ReviewDecisionKind
    var action: ReviewDecisionAction
    /// Every track of the group.
    var memberIDs: [Int64]
    var keptTrackID: Int64?
    var unkeptMode: UnkeptMode?
    /// Tag values before a merge (recorded for Undo).
    var tags: [ReviewDecisionConsequences.TagChange] = []
    var changedFields: [String] = []
}

struct ReviewDecisionOutcome: Equatable, Sendable {
    var decisionID: Int64
    var unkeptTrackIDs: [Int64]
    var keptFormat: String?
    var consequences: ReviewDecisionConsequences

    var hiddenCount: Int { consequences.hiddenCount }
    var repointedEntries: Int { consequences.repointedPlaylistEntries + consequences.repointedSyncRows }
}

/// One stored decision.
struct ReviewDecisionRecord: Equatable, Sendable, Identifiable {
    var id: Int64
    var groupKey: String
    var kind: ReviewDecisionKind
    var action: ReviewDecisionAction
    var keptTrackID: Int64?
    var unkeptMode: UnkeptMode?
    var consequences: ReviewDecisionConsequences
    var decidedAt: String
}

enum ReviewDecisionError: LocalizedError, Equatable {
    case nothingPending
    case invalidKeep
    case noDecision

    var errorDescription: String? {
        switch self {
        case .nothingPending: "This group has already been decided."
        case .invalidKeep: "Choose one version to keep before deciding this group."
        case .noDecision: "Earlier decision cannot be restored"
        }
    }
}

// MARK: - Repository

/// Sticky Review decisions (v48): one transaction per decision — flags, re-pointed playlist and
/// sync rows, the decided pairs, the decision row and the queue status — and the exact inverse.
/// File moves (Trash) and tag writes are not here: they follow the commit
/// (`ReviewConsequences`, `TrackTagEdit`) and are recorded afterwards.
final class ReviewDecisionRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    // MARK: Reading

    /// Every decided pair.
    func decidedPairs() async throws -> Set<ReviewPair> {
        try await database.read { db in try Self.decidedPairs(db) }
    }

    static func decidedPairs(_ db: Database) throws -> Set<ReviewPair> {
        guard try db.tableExists("review_decided_pairs") else { return [] }
        let rows = try Row.fetchAll(db, sql: "SELECT track_a, track_b FROM review_decided_pairs")
        return Set(rows.map { ReviewPair($0["track_a"] as Int64, $0["track_b"] as Int64) })
    }

    /// Every pair of the group is covered by a decision.
    func isDecided(group memberIDs: [Int64]) async throws -> Bool {
        let decided = try await decidedPairs()
        return !ReviewPair.hasUndecidedPair(memberIDs, decided: decided)
    }

    /// The live decision of each group key.
    func decisions() async throws -> [String: ReviewDecisionRecord] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM review_decisions ORDER BY id")
            var result: [String: ReviewDecisionRecord] = [:]
            for row in rows {
                if let record = Self.record(row) { result[record.groupKey] = record }
            }
            return result
        }
    }

    func decision(id: Int64) async throws -> ReviewDecisionRecord? {
        try await database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM review_decisions WHERE id = ?", arguments: [id]).flatMap(Self.record)
        }
    }

    private static func record(_ row: Row) -> ReviewDecisionRecord? {
        guard let kind = ReviewDecisionKind(rawValue: row["kind"]),
              let action = ReviewDecisionAction(rawValue: row["decision"]) else { return nil }
        let json: String = row["consequences_json"]
        let consequences = (try? JSONDecoder().decode(ReviewDecisionConsequences.self, from: Data(json.utf8)))
            ?? ReviewDecisionConsequences()
        return ReviewDecisionRecord(
            id: row["id"], groupKey: row["group_key"], kind: kind, action: action,
            keptTrackID: row["kept_track_id"],
            unkeptMode: (row["unkept_mode"] as String?).flatMap(UnkeptMode.init(rawValue:)),
            consequences: consequences, decidedAt: row["decided_at"])
    }

    /// The tracks with these ids (a group's members), in id order.
    func tracks(ids: [Int64]) async throws -> [Track] {
        guard !ids.isEmpty else { return [] }
        return try await database.read { db in
            try Track.filter(ids.contains(Track.Columns.id)).order(Track.Columns.id).fetchAll(db)
        }
    }

    /// In how many playlists each track is (`‹n› playlists`, V-REV.N12).
    func playlistUsage(trackIDs: [Int64]) async throws -> [Int64: Int] {
        guard !trackIDs.isEmpty else { return [:] }
        return try await database.read { db in
            let marks = trackIDs.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT track_id, COUNT(DISTINCT playlist_id) AS n FROM playlist_tracks
                WHERE track_id IN (\(marks)) GROUP BY track_id
                """, arguments: StatementArguments(trackIDs))
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["track_id"] as Int64, $0["n"] as Int) })
        }
    }

    // MARK: Deciding

    /// Decide one group in one transaction. Throws `nothingPending` when the group isn't
    /// pending any more (decided elsewhere), `invalidKeep` when a keep needs a kept member.
    @discardableResult
    func decide(_ request: ReviewDecisionRequest, now: Date = Date()) async throws -> ReviewDecisionOutcome {
        let stamp = ISO8601DateFormatter().string(from: now)
        return try await database.write { db in
            guard try Self.pendingRowCount(db, groupKey: request.groupKey) > 0 else { throw ReviewDecisionError.nothingPending }
            let members = Array(Set(request.memberIDs)).sorted()
            let keeps = request.action == .keepRecommended || request.action == .keepSelected
            if keeps {
                guard let kept = request.keptTrackID, members.contains(kept) else { throw ReviewDecisionError.invalidKeep }
            }
            var consequences = ReviewDecisionConsequences()
            consequences.tags = request.tags
            consequences.changedFields = request.changedFields

            // Flags: the exact earlier state, then the new one.
            let existing = try Track.filter(members.contains(Track.Columns.id)).fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: existing.compactMap { track in track.id.map { ($0, track) } })
            for id in members {
                guard let track = byID[id] else { continue }
                consequences.flags.append(.init(trackId: id, isDuplicate: track.isDuplicate, variantOf: track.variantOf))
            }
            var unkept: [Int64] = []
            if keeps, let kept = request.keptTrackID {
                consequences.keptFormat = byID[kept]?.format
                for id in members where byID[id] != nil {
                    if id == kept {
                        try db.execute(sql: "UPDATE tracks SET is_duplicate = 0, variant_of = NULL WHERE id = ?", arguments: [id])
                    } else {
                        unkept.append(id)
                        try db.execute(sql: "UPDATE tracks SET is_duplicate = 1, variant_of = ? WHERE id = ?", arguments: [kept, id])
                    }
                }
                consequences.hiddenCount = unkept.count
                try Self.repoint(db, unkept: unkept, to: kept, into: &consequences)
            } else {
                for id in members where byID[id] != nil {
                    try db.execute(sql: "UPDATE tracks SET is_duplicate = 0, variant_of = NULL WHERE id = ?", arguments: [id])
                }
            }

            let json = String(decoding: try JSONEncoder().encode(consequences), as: UTF8.self)
            try db.execute(sql: """
                INSERT INTO review_decisions (group_key, kind, decision, kept_track_id, unkept_mode, consequences_json, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [request.groupKey, request.kind.rawValue, request.action.rawValue,
                                 keeps ? request.keptTrackID : nil, keeps ? request.unkeptMode?.rawValue : nil, json, stamp])
            let decisionID = db.lastInsertedRowID
            for pair in ReviewPair.pairs(of: members) {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO review_decided_pairs (track_a, track_b, decision_id) VALUES (?, ?, ?)
                    """, arguments: [pair.a, pair.b, decisionID])
            }
            try Self.setQueueStatus(db, groupKey: request.groupKey, from: "pending", to: "resolved")
            return ReviewDecisionOutcome(decisionID: decisionID, unkeptTrackIDs: unkept,
                                         keptFormat: consequences.keptFormat, consequences: consequences)
        }
    }

    /// Re-point playlist entries and sync-profile rows of the unkept versions to the kept one.
    /// When the kept version is already in that playlist / profile the unkept entry is dropped
    /// instead (both count as re-pointed).
    private static func repoint(_ db: Database, unkept: [Int64], to kept: Int64,
                                into consequences: inout ReviewDecisionConsequences) throws {
        for old in unkept {
            let entries = try Row.fetchAll(db, sql: "SELECT * FROM playlist_tracks WHERE track_id = ? ORDER BY id", arguments: [old])
            for entry in entries {
                let playlistID: Int64 = entry["playlist_id"]
                let hasKept = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?)
                    """, arguments: [playlistID, kept]) ?? false
                let change: ReviewDecisionConsequences.PlaylistRow.Change = hasKept ? .deleted : .repointed
                if hasKept {
                    try db.execute(sql: "DELETE FROM playlist_tracks WHERE id = ?", arguments: [entry["id"] as Int64])
                } else {
                    try db.execute(sql: "UPDATE playlist_tracks SET track_id = ? WHERE id = ?", arguments: [kept, entry["id"] as Int64])
                }
                consequences.playlistRows.append(.init(
                    id: entry["id"], playlistId: playlistID, trackId: old, position: entry["position"],
                    addedAt: entry["added_at"], change: change))
            }
            let syncRows = try Row.fetchAll(db, sql: "SELECT profile_id FROM sync_profile_tracks WHERE track_id = ?", arguments: [old])
            for row in syncRows {
                let profileID: Int64 = row["profile_id"]
                let hasKept = try Bool.fetchOne(db, sql: """
                    SELECT EXISTS(SELECT 1 FROM sync_profile_tracks WHERE profile_id = ? AND track_id = ?)
                    """, arguments: [profileID, kept]) ?? false
                if hasKept {
                    try db.execute(sql: "DELETE FROM sync_profile_tracks WHERE profile_id = ? AND track_id = ?", arguments: [profileID, old])
                } else {
                    try db.execute(sql: "UPDATE sync_profile_tracks SET track_id = ? WHERE profile_id = ? AND track_id = ?",
                                   arguments: [kept, profileID, old])
                }
                consequences.syncRows.append(.init(profileId: profileID, trackId: old, change: hasKept ? .deleted : .repointed))
            }
        }
    }

    /// Record the files that went to the Trash (after the commit) and how many didn't.
    func recordTrashed(decisionID: Int64, trashed: [ReviewDecisionConsequences.Trashed], failures: Int) async throws {
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT consequences_json FROM review_decisions WHERE id = ?",
                                             arguments: [decisionID]) else { return }
            let json: String = row["consequences_json"]
            var consequences = (try? JSONDecoder().decode(ReviewDecisionConsequences.self, from: Data(json.utf8)))
                ?? ReviewDecisionConsequences()
            consequences.trashed = trashed
            consequences.trashFailures = failures
            try db.execute(sql: "UPDATE review_decisions SET consequences_json = ? WHERE id = ?",
                           arguments: [String(decoding: try JSONEncoder().encode(consequences), as: UTF8.self), decisionID])
        }
    }

    // MARK: Undo / Restore

    /// Put everything of the decision back: flags, re-pointed rows, the queue rows to pending,
    /// the decided pairs and the decision row gone. Returns what it was, so the caller can
    /// move files back from the Trash and put tag values back.
    @discardableResult
    func undo(decisionID: Int64) async throws -> ReviewDecisionRecord {
        try await database.write { db in
            guard let record = try Row.fetchOne(db, sql: "SELECT * FROM review_decisions WHERE id = ?", arguments: [decisionID])
                .flatMap(Self.record) else { throw ReviewDecisionError.noDecision }
            let c = record.consequences
            for flag in c.flags {
                try db.execute(sql: "UPDATE tracks SET is_duplicate = ?, variant_of = ? WHERE id = ?",
                               arguments: [flag.isDuplicate, flag.variantOf, flag.trackId])
            }
            let kept = record.keptTrackID
            for row in c.playlistRows.reversed() {
                switch row.change {
                case .repointed:
                    guard let kept else { continue }
                    try db.execute(sql: "UPDATE playlist_tracks SET track_id = ? WHERE id = ? AND playlist_id = ? AND track_id = ?",
                                   arguments: [row.trackId, row.id, row.playlistId, kept])
                case .deleted:
                    let taken = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM playlist_tracks WHERE id = ?)", arguments: [row.id]) ?? false
                    let present = try Bool.fetchOne(db, sql: """
                        SELECT EXISTS(SELECT 1 FROM playlist_tracks WHERE playlist_id = ? AND track_id = ?)
                        """, arguments: [row.playlistId, row.trackId]) ?? false
                    let playlistExists = try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM playlists WHERE id = ?)", arguments: [row.playlistId]) ?? false
                    guard playlistExists, !present else { continue }
                    try db.execute(sql: "INSERT INTO playlist_tracks (id, playlist_id, track_id, position, added_at) VALUES (?, ?, ?, ?, ?)",
                                   arguments: [taken ? nil : row.id, row.playlistId, row.trackId, row.position, row.addedAt])
                }
            }
            for row in c.syncRows.reversed() {
                switch row.change {
                case .repointed:
                    guard let kept else { continue }
                    try db.execute(sql: "UPDATE sync_profile_tracks SET track_id = ? WHERE profile_id = ? AND track_id = ?",
                                   arguments: [row.trackId, row.profileId, kept])
                case .deleted:
                    try db.execute(sql: "INSERT OR IGNORE INTO sync_profile_tracks (profile_id, track_id) VALUES (?, ?)",
                                   arguments: [row.profileId, row.trackId])
                }
            }
            try db.execute(sql: "DELETE FROM review_decided_pairs WHERE decision_id = ?", arguments: [decisionID])
            try db.execute(sql: "DELETE FROM review_decisions WHERE id = ?", arguments: [decisionID])
            try Self.setQueueStatus(db, groupKey: record.groupKey, from: "resolved", to: "pending")
            return record
        }
    }

    // MARK: Queue rows

    private static func legacyID(_ groupKey: String) -> Int64? {
        guard groupKey.hasPrefix("legacy:") else { return nil }
        return Int64(groupKey.dropFirst("legacy:".count))
    }

    private static func pendingRowCount(_ db: Database, groupKey: String) throws -> Int {
        if let id = legacyID(groupKey) {
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue WHERE id = ? AND status = 'pending'", arguments: [id]) ?? 0
        }
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM review_queue WHERE group_key = ? AND status = 'pending'",
                                arguments: [groupKey]) ?? 0
    }

    private static func setQueueStatus(_ db: Database, groupKey: String, from: String, to: String) throws {
        let resolvedAt = to == "pending" ? "NULL" : "datetime('now')"
        if let id = legacyID(groupKey) {
            try db.execute(sql: "UPDATE review_queue SET status = ?, resolved_at = \(resolvedAt) WHERE id = ? AND status = ?",
                           arguments: [to, id, from])
        } else {
            try db.execute(sql: "UPDATE review_queue SET status = ?, resolved_at = \(resolvedAt) WHERE group_key = ? AND status = ?",
                           arguments: [to, groupKey, from])
        }
    }
}
