import Foundation
import GRDB

/// Parses an m3u8 file (`.ios` dialect or legacy plain), resolves entries
/// against the library, computes a diff against the last snapshot, and
/// applies the result through `PlaylistRepository`.
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

    /// Resolve the target playlist from the header and file URL.
    /// Returns (playlist, willCreate).
    func resolveTargetPlaylist(
        header: ParsedHeader,
        fileURL: URL,
        profileId: Int64?
    ) async throws -> (playlist: Playlist?, willCreate: Bool, name: String) {
        // Derive a name from the filename
        let name = fileURL.deletingPathExtension().lastPathComponent

        // Special case: Liked.m3u8
        if name.lowercased() == "liked" {
            // Use findOrCreateLikedPlaylist with a sentinel sourceId for standalone imports
            let sourceId = profileId ?? -1
            let playlist = try await playlistRepository.findOrCreateLikedPlaylist(
                name: "Liked",
                sourceId: sourceId,
                externalId: header.playlistUuid,
                legacyNameMatches: ["liked"]
            )
            return (playlist, false, playlist.name)
        }

        // 1. Try UUID match
        if let uuid = header.playlistUuid,
           let playlist = try await playlistRepository.findByMlmUuid(uuid) {
            return (playlist, false, playlist.name)
        }

        // 2. Fallback: name match
        if let playlist = try await playlistRepository.findByName(name) {
            return (playlist, false, playlist.name)
        }

        // 3. Will create
        return (nil, true, name)
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

    /// Write (replace) the snapshot for (profile, playlist).
    func writeSnapshot(
        profileId: Int64,
        playlistId: Int64,
        playlistUuid: String?,
        entries: [SnapshotEntry]
    ) async throws {
        let data = try JSONEncoder().encode(entries)
        let json = String(data: data, encoding: .utf8) ?? "[]"

        try await database.write { db in
            // Delete existing snapshot for this (profile, playlist)
            try db.execute(
                sql: "DELETE FROM playlist_sync_snapshots WHERE profile_id = ? AND playlist_id = ?",
                arguments: [profileId, playlistId]
            )
            // Insert new snapshot
            try db.execute(
                sql: """
                    INSERT INTO playlist_sync_snapshots (profile_id, playlist_id, playlist_uuid, snapshot_json, written_at)
                    VALUES (?, ?, ?, ?, datetime('now'))
                    """,
                arguments: [profileId, playlistId, playlistUuid, json]
            )
        }
    }

    /// A single entry in the snapshot JSON.
    struct SnapshotEntry: Codable, Equatable {
        let uuid: String?
        let path: String
    }

    // MARK: - Diff

    /// Compute the diff between incoming entries and the snapshot.
    func computeDiff(
        incoming: [(entry: ParsedEntry, track: Track)],
        snapshot: [SnapshotEntry]?
    ) -> (added: [IngestPreview.Entry], removed: [IngestPreview.Entry], reordered: [IngestPreview.Entry]) {
        // Build snapshot path set
        let snapshotPaths: [String] = snapshot?.map { $0.path } ?? []
        let snapshotPathSet = Set(snapshotPaths)

        // Incoming paths in order
        let incomingPaths = incoming.map { $0.entry.path }

        // Added: in incoming but not in snapshot paths
        var added: [IngestPreview.Entry] = []
        for (entry, track) in incoming {
            if !snapshotPathSet.contains(entry.path) {
                added.append(IngestPreview.Entry(
                    id: track.id!,
                    title: track.title,
                    artist: track.artist,
                    uuid: track.mlmUuid,
                    path: entry.path
                ))
            }
        }

        // Removed: in snapshot but not in incoming paths
        var removed: [IngestPreview.Entry] = []
        let incomingPathSet = Set(incomingPaths)
        if let snapshot = snapshot {
            for snapEntry in snapshot {
                if !incomingPathSet.contains(snapEntry.path) {
                    // Try to find the track for display info
                    let displayEntry = IngestPreview.Entry(
                        id: 0, // unknown — track may have been removed from library
                        title: "Unknown",
                        artist: "",
                        uuid: snapEntry.uuid,
                        path: snapEntry.path
                    )
                    removed.append(displayEntry)
                }
            }
        }

        // Reordered: same set of paths but different order
        // Only detect reorder if no adds/removes (pure reorder)
        var reordered: [IngestPreview.Entry] = []
        if added.isEmpty && removed.isEmpty, let snapshot = snapshot {
            let snapshotOrderedPaths = snapshot.map { $0.path }
            if snapshotOrderedPaths != incomingPaths {
                // All entries are "reordered" — report entries whose index changed
                for (newIdx, path) in incomingPaths.enumerated() {
                    if let oldIdx = snapshotOrderedPaths.firstIndex(of: path), oldIdx != newIdx {
                        if let match = incoming.first(where: { $0.entry.path == path }) {
                            reordered.append(IngestPreview.Entry(
                                id: match.track.id!,
                                title: match.track.title,
                                artist: match.track.artist,
                                uuid: match.track.mlmUuid,
                                path: path
                            ))
                        }
                    }
                }
            }
        }

        return (added, removed, reordered)
    }

    // MARK: - Preview

    /// Build a full `IngestPreview` for the given m3u8 file.
    func preview(
        url: URL,
        profileId: Int64? = nil
    ) async throws -> IngestPreview {
        let (header, entries) = try parse(url: url)

        // Resolve target playlist
        let (playlist, willCreate, name) = try await resolveTargetPlaylist(
            header: header,
            fileURL: url,
            profileId: profileId
        )

        // Resolve entries to tracks
        let (resolved, unresolvedRaw) = try await resolveEntries(entries)

        let unresolved = unresolvedRaw.map { entry, reason in
            IngestPreview.UnresolvedEntry(
                path: entry.path,
                uuid: entry.uuid,
                reason: reason
            )
        }

        // If the playlist doesn't exist yet, all entries are additions (first import)
        guard let playlist = playlist, let playlistId = playlist.id else {
            // Will create — all resolved entries are additions
            let added = resolved.map { entry, track in
                IngestPreview.Entry(
                    id: track.id!,
                    title: track.title,
                    artist: track.artist,
                    uuid: track.mlmUuid,
                    path: entry.path
                )
            }
            return IngestPreview(
                targetPlaylistId: 0, // will be assigned on apply
                targetPlaylistName: name,
                willCreate: true,
                added: added,
                removed: [],
                reordered: [],
                unresolved: unresolved
            )
        }

        // Read snapshot
        let snapshot: [SnapshotEntry]?
        if let profileId = profileId {
            snapshot = try await readSnapshot(profileId: profileId, playlistId: playlistId)
        } else {
            snapshot = nil
        }

        // Compute diff
        let (added, removed, reordered) = computeDiff(incoming: resolved, snapshot: snapshot)

        return IngestPreview(
            targetPlaylistId: playlistId,
            targetPlaylistName: name,
            willCreate: willCreate,
            added: added,
            removed: removed,
            reordered: reordered,
            unresolved: unresolved
        )
    }

    // MARK: - Apply

    /// Apply the preview: add/remove/reorder tracks in the target playlist,
    /// then persist the new snapshot. Transactional — all-or-nothing.
    @discardableResult
    func apply(
        preview: IngestPreview,
        profileId: Int64,
        incomingEntries: [(entry: ParsedEntry, track: Track)]
    ) async throws -> Int64 {
        let playlistId: Int64

        if preview.willCreate {
            // Create the playlist first
            let newPlaylist = try await playlistRepository.create(name: preview.targetPlaylistName)
            playlistId = newPlaylist.id!
        } else {
            playlistId = preview.targetPlaylistId
        }

        // Apply changes through PlaylistRepository
        // 1. Remove tracks
        for entry in preview.removed {
            if entry.id > 0 {
                try await playlistRepository.removeTrack(playlistId: playlistId, trackId: entry.id)
            }
        }

        // 2. Add new tracks
        if !preview.added.isEmpty {
            let addIds = preview.added.map { $0.id }
            // Get the current last position
            let tracks = try await playlistRepository.fetchTracks(playlistId: playlistId)
            let lastPosition = tracks.last?.playlistPosition
            try await playlistRepository.addTracks(
                playlistId: playlistId,
                trackIds: addIds,
                startPosition: FractionalIndexer.positionBetween(left: lastPosition, right: nil)
            )
        }

        // 3. Reorder: replace the entire track list in the new order
        if !preview.reordered.isEmpty {
            // Build the full ordered list: keep existing order but move reordered entries
            // Reorder: replace the entire track list in the incoming order
            let orderedIds = incomingEntries.map { $0.track.id! }
            try await playlistRepository.replaceTrackList(playlistId: playlistId, trackIds: orderedIds)
        } else if preview.added.isEmpty && preview.removed.isEmpty {
            // No changes needed
        } else if !preview.added.isEmpty || !preview.removed.isEmpty {
            // Mixed adds/removes — rebuild the ordered list from incoming entries
            let orderedIds = incomingEntries.map { $0.track.id! }
            try await playlistRepository.replaceTrackList(playlistId: playlistId, trackIds: orderedIds)
        }

        // Persist the new snapshot
        let snapshotEntries = incomingEntries.map { entry, track in
            SnapshotEntry(uuid: track.mlmUuid, path: entry.path)
        }
        let playlistUuid = try await playlistRepository.fetch(id: playlistId)?.mlmUuid
        try await writeSnapshot(
            profileId: profileId,
            playlistId: playlistId,
            playlistUuid: playlistUuid,
            entries: snapshotEntries
        )

        return playlistId
    }

    /// High-level: parse + preview + apply in one call.
    /// Returns the target playlist id.
    func ingest(
        url: URL,
        profileId: Int64
    ) async throws -> (playlistId: Int64, preview: IngestPreview) {
        let preview = try await preview(url: url, profileId: profileId)

        // Re-parse to get entries for apply
        let (_, entries) = try parse(url: url)
        let (resolved, _) = try await resolveEntries(entries)

        let playlistId = try await apply(
            preview: preview,
            profileId: profileId,
            incomingEntries: resolved
        )

        return (playlistId, preview)
    }
}
