import Foundation
import GRDB

/// Parses an m3u8 file (`.ios` dialect or legacy plain), resolves entries against the library
/// and reads/writes the per-(profile, playlist) snapshot of what a sync wrote. The merge into
/// MLM playlists is `DevicePlaylistChangeService` (Read Playlist Changes from Device).
///
/// Spec: IOS_SIDECAR_PLAN.md §4.
final class PlaylistIngestService: Sendable {
    private let trackRepository: TrackRepository
    private let playlistRepository: PlaylistRepository
    private let database: any DatabaseWriter

    init(
        trackRepository: TrackRepository,
        playlistRepository: PlaylistRepository,
        database: any DatabaseWriter
    ) {
        self.trackRepository = trackRepository
        self.playlistRepository = playlistRepository
        self.database = database
    }

    // MARK: - Parsing

    /// A single parsed entry from an m3u8 file.
    struct ParsedEntry {
        let uuid: String?      // from #EXTMLM line
        let path: String       // the path/URL line
        let title: String?     // from #EXTINF
        let artist: String?    // from #EXTINF
    }

    /// Parsed header metadata from an m3u8 file.
    struct ParsedHeader {
        let playlistUuid: String?  // from #EXTMLM-PLAYLIST
    }

    /// Parse an m3u8 file at the given URL.
    /// Supports both `.ios` dialect (EXTMLM headers) and legacy plain m3u8.
    func parse(url: URL) throws -> (header: ParsedHeader, entries: [ParsedEntry]) {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(content: content)
    }

    /// Parse m3u8 content from a string.
    func parse(content: String) -> (header: ParsedHeader, entries: [ParsedEntry]) {
        let lines = content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#EXTM3U") }

        var playlistUuid: String? = nil
        var entries: [ParsedEntry] = []

        var pendingUuid: String? = nil
        var pendingTitle: String? = nil
        var pendingArtist: String? = nil

        for line in lines {
            if line.hasPrefix("#EXTMLM-PLAYLIST:") {
                playlistUuid = String(line.dropFirst("#EXTMLM-PLAYLIST:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXTMLM:") {
                pendingUuid = String(line.dropFirst("#EXTMLM:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("#EXTINF:") {
                // #EXTINF:<duration>,<Artist> - <Title>
                let infoPart = String(line.dropFirst("#EXTINF:".count))
                if let commaIdx = infoPart.firstIndex(of: ",") {
                    let meta = String(infoPart[infoPart.index(after: commaIdx)...])
                    // Split on " - " to get artist and title
                    if let dashRange = meta.range(of: " - ") {
                        pendingArtist = String(meta[meta.startIndex..<dashRange.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                        pendingTitle = String(meta[dashRange.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                    } else {
                        pendingTitle = meta.trimmingCharacters(in: .whitespaces)
                    }
                }
            } else if line.hasPrefix("#") {
                // Unknown comment — skip (preserved on re-write by iOS clients per spec)
                continue
            } else {
                // This is a path line — finalize the entry
                let entry = ParsedEntry(
                    uuid: pendingUuid,
                    path: line,
                    title: pendingTitle,
                    artist: pendingArtist
                )
                entries.append(entry)
                pendingUuid = nil
                pendingTitle = nil
                pendingArtist = nil
            }
        }

        return (header: ParsedHeader(playlistUuid: playlistUuid), entries: entries)
    }

    // MARK: - Resolution

    /// Resolve parsed entries to library tracks.
    /// Returns resolved entries and unresolved entries separately.
    func resolveEntries(
        _ entries: [ParsedEntry]
    ) async throws -> (resolved: [(entry: ParsedEntry, track: Track)], unresolved: [(entry: ParsedEntry, reason: String)]) {
        var resolved: [(entry: ParsedEntry, track: Track)] = []
        var unresolved: [(entry: ParsedEntry, reason: String)] = []

        for entry in entries {
            // 1. Try UUID match first
            if let uuid = entry.uuid, let track = try await trackRepository.fetchByMlmUuid(uuid) {
                resolved.append((entry, track))
                continue
            }

            // 2. Fallback: filename-suffix matching
            if let track = try await trackRepository.findTrackByFilename(path: entry.path) {
                resolved.append((entry, track))
                continue
            }

            // 3. Unresolved
            let reason: String
            if let uuid = entry.uuid {
                reason = "No track with mlm_uuid=\(uuid) and filename fallback failed"
            } else {
                reason = "No track matched filename: \(entry.path)"
            }
            unresolved.append((entry, reason))
        }

        return (resolved, unresolved)
    }

    // MARK: - Snapshot I/O

    /// Read the latest snapshot for (profile, playlist).
    func readSnapshot(profileId: Int64, playlistId: Int64) async throws -> [SnapshotEntry]? {
        try await database.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT snapshot_json FROM playlist_sync_snapshots
                WHERE profile_id = ? AND playlist_id = ?
                ORDER BY written_at DESC LIMIT 1
                """, arguments: [profileId, playlistId])
            guard let row, let json = row["snapshot_json"] as String? else { return nil }
            guard let data = json.data(using: .utf8) else { return nil }
            return try JSONDecoder().decode([SnapshotEntry].self, from: data)
        }
    }

    /// A single entry in the snapshot JSON.
    struct SnapshotEntry: Codable, Equatable {
        let uuid: String?
        let path: String
        /// The library track written at this path (absent in snapshots of older versions).
        var trackId: Int64? = nil

        enum CodingKeys: String, CodingKey {
            case uuid, path
            case trackId = "track_id"
        }
    }
}
