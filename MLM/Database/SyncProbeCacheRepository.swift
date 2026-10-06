import Foundation
import GRDB

/// One cached probe of a file on a sync device (v56, IMP-104).
struct SyncProbeEntry: Equatable, Sendable {
    let devicePath: String
    let size: Int64
    let mtime: Double
    let codec: String
    let bitrate: Int?
}

/// The device codec sweep, cached per profile (v56 `sync_probe_cache`, IMP-104): a device file is
/// probed again only when its size or modification time changed; entries of files that are no
/// longer on the device are dropped after a plan; the cache of a profile is cleared when its
/// destination changes. No foreign keys (they stay disabled): `SyncRepository.delete` clears it.
final class SyncProbeCacheRepository: Sendable {
    private let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    func entries(profileId: Int64) async throws -> [String: SyncProbeEntry] {
        try await database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT device_path, size, mtime, codec, bitrate FROM sync_probe_cache WHERE profile_id = ?
                """, arguments: [profileId])
            var result: [String: SyncProbeEntry] = [:]
            for row in rows {
                let path: String = row["device_path"]
                result[path] = SyncProbeEntry(devicePath: path, size: row["size"], mtime: row["mtime"],
                                              codec: row["codec"], bitrate: row["bitrate"])
            }
            return result
        }
    }

    func store(_ entries: [SyncProbeEntry], profileId: Int64, at date: Date = Date()) async throws {
        guard !entries.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: date)
        try await database.write { db in
            for entry in entries {
                try db.execute(sql: """
                    INSERT OR REPLACE INTO sync_probe_cache
                    (profile_id, device_path, size, mtime, codec, bitrate, probed_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [profileId, entry.devicePath, entry.size, entry.mtime,
                                     entry.codec, entry.bitrate, stamp])
            }
        }
    }

    /// Drops the rows of files that are no longer on the device (everything not in `paths`).
    func prune(profileId: Int64, keeping paths: Set<String>) async throws {
        try await database.write { db in
            let stored = try String.fetchAll(db, sql: "SELECT device_path FROM sync_probe_cache WHERE profile_id = ?",
                                             arguments: [profileId])
            for path in stored where !paths.contains(path) {
                try db.execute(sql: "DELETE FROM sync_probe_cache WHERE profile_id = ? AND device_path = ?",
                               arguments: [profileId, path])
            }
        }
    }

    func clear(profileId: Int64) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM sync_probe_cache WHERE profile_id = ?", arguments: [profileId])
        }
    }
}
