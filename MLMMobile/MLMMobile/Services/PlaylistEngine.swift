import Foundation
import GRDB

/// Parses, writes, and incrementally syncs `.ios` m3u8 playlists per IOS_SIDECAR_PLAN.md §2.
final class PlaylistEngine {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Parsing

    /// Parse a `.ios` m3u8 file into a `ParsedPlaylist`.
    func parse(url: URL) throws -> ParsedPlaylist {
        let data = try Data(contentsOf: url)
        let content = String(data: data, encoding: .utf8) ?? ""
        return parse(content: content)
    }

    /// Parse m3u8 content string into a `ParsedPlaylist`.
    func parse(content: String) -> ParsedPlaylist {
        let lines = content.components(separatedBy: .newlines)
        var playlistUUID: String?
        var headerComments: [String] = []
        var entries: [ParsedEntry] = []

        var pendingComments: [String] = []
        var currentExtinf: String?
        var currentTrackUUID: String?
        var entryComments: [String] = []
        var haveEntryStart = false
        var seenFirstEntry = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            // Skip empty lines
            if line.isEmpty { continue }

            // #EXTM3U header
            if line == "#EXTM3U" { continue }

            // #EXTMLM-PLAYLIST:<uuid>
            if line.hasPrefix("#EXTMLM-PLAYLIST:") {
                playlistUUID = String(line.dropFirst("#EXTMLM-PLAYLIST:".count))
                continue
            }

            // #EXTINF:<duration>,<text>
            if line.hasPrefix("#EXTINF:") {
                // If we were building an entry but got a new EXTINF without a path,
                // flush the pending entry with what we have (lenient parsing).
                if haveEntryStart {
                    let entry = ParsedEntry(
                        extinfLine: currentExtinf,
                        trackUUID: currentTrackUUID,
                        path: "",
                        precedingComments: entryComments
                    )
                    entries.append(entry)
                }
                // Comments before the first entry go to header, not to the entry
                if !seenFirstEntry && !pendingComments.isEmpty {
                    headerComments.append(contentsOf: pendingComments)
                    pendingComments = []
                }
                currentExtinf = line
                currentTrackUUID = nil
                entryComments = pendingComments
                pendingComments = []
                haveEntryStart = true
                seenFirstEntry = true
                continue
            }

            // #EXTMLM:<track-uuid>
            if line.hasPrefix("#EXTMLM:") {
                currentTrackUUID = String(line.dropFirst("#EXTMLM:".count))
                continue
            }

            // Other #EXT* or # comment lines — unknown comments to preserve
            if line.hasPrefix("#") {
                pendingComments.append(line)
                continue
            }

            // Non-comment, non-empty line → path
            if haveEntryStart {
                let entry = ParsedEntry(
                    extinfLine: currentExtinf,
                    trackUUID: currentTrackUUID,
                    path: line,
                    precedingComments: entryComments
                )
                entries.append(entry)
                currentExtinf = nil
                currentTrackUUID = nil
                entryComments = []
                haveEntryStart = false
                pendingComments = []
            } else {
                // Path without EXTINF (bare path line in header area)
                // Treat pending comments as header comments
                if !seenFirstEntry {
                    headerComments.append(contentsOf: pendingComments)
                } else {
                    // Between entries — attach to next entry via pendingComments
                }
                pendingComments = []
            }
        }

        // Flush any trailing entry without a path
        if haveEntryStart {
            let entry = ParsedEntry(
                extinfLine: currentExtinf,
                trackUUID: currentTrackUUID,
                path: "",
                precedingComments: entryComments
            )
            entries.append(entry)
        }

        // Remaining pending comments after all entries → header if no entries seen
        if !seenFirstEntry {
            headerComments.append(contentsOf: pendingComments)
        }

        return ParsedPlaylist(
            playlistUUID: playlistUUID,
            headerComments: headerComments,
            entries: entries
        )
    }

    // MARK: - Writing

    /// Serialize a `ParsedPlaylist` to the `.ios` m3u8 dialect string.
    func serialize(_ playlist: ParsedPlaylist) -> String {
        var lines: [String] = ["#EXTM3U"]

        if let uuid = playlist.playlistUUID {
            lines.append("#EXTMLM-PLAYLIST:\(uuid)")
        }

        for comment in playlist.headerComments {
            lines.append(comment)
        }

        for entry in playlist.entries {
            for comment in entry.precedingComments {
                lines.append(comment)
            }
            if let extinf = entry.extinfLine {
                lines.append(extinf)
            }
            if let uuid = entry.trackUUID {
                lines.append("#EXTMLM:\(uuid)")
            }
            lines.append(entry.path)
        }

        // NFC-normalized UTF-8 with trailing newline
        let result = lines.joined(separator: "\n") + "\n"
        return result.precomposedStringWithCanonicalMapping
    }

    /// Write a `ParsedPlaylist` to a file (NFC-normalized UTF-8).
    func write(_ playlist: ParsedPlaylist, to url: URL) throws {
        let content = serialize(playlist)
        let data = content.data(using: .utf8) ?? Data()
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Sync from folder

    /// Read all `.m3u8` files in the playlists directory and incrementally sync
    /// each against local state. Unchanged files are cheap no-ops.
    func syncFromFolder(playlistsDirectory: URL) throws -> PlaylistSyncResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: playlistsDirectory.path) else {
            return PlaylistSyncResult()
        }

        let files = try fm.contentsOfDirectory(
            at: playlistsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { url in
            url.pathExtension.lowercased() == "m3u8"
        }

        var result = PlaylistSyncResult()

        for fileURL in files {
            let parsed = try parse(url: fileURL)
            let fileName = fileURL.deletingPathExtension().lastPathComponent

            let playlist = try findOrCreatePlaylist(for: parsed, fileName: fileName, file: fileURL.lastPathComponent)
            let changed = try applyDiff(playlist: playlist, parsed: parsed)

            if changed {
                result.updated += 1
            } else {
                result.unchanged += 1
            }
        }

        return result
    }

    // MARK: - Local playlist queries

    /// Fetch all local playlists ordered by name.
    func fetchAllPlaylists() throws -> [LocalPlaylist] {
        try dbQueue.read { db in
            try LocalPlaylist
                .order(LocalPlaylist.Columns.name)
                .fetchAll(db)
        }
    }

    /// Fetch entries for a playlist ordered by orderIndex.
    func fetchEntries(playlistID: Int64) throws -> [PlaylistEntry] {
        try dbQueue.read { db in
            try PlaylistEntry
                .filter(PlaylistEntry.Columns.playlistID == playlistID)
                .order(PlaylistEntry.Columns.orderIndex)
                .fetchAll(db)
        }
    }

    /// Fetch a playlist by its UUID.
    func fetchPlaylist(uuid: String) throws -> LocalPlaylist? {
        try dbQueue.read { db in
            try LocalPlaylist
                .filter(LocalPlaylist.Columns.uuid == uuid)
                .fetchOne(db)
        }
    }

    // MARK: - Local edits

    /// Add a track to a playlist at the end (or at a specific index).
    func addEntry(playlistID: Int64, trackUUID: String, relativePath: String, at index: Int? = nil) throws {
        try dbQueue.write { db in
            let maxOrder = try PlaylistEntry
                .filter(PlaylistEntry.Columns.playlistID == playlistID)
                .order(PlaylistEntry.Columns.orderIndex.desc)
                .fetchOne(db)?
                .orderIndex ?? -1

            let targetIndex: Int
            if let index = index {
                // Shift existing entries at or after the target index
                let existing = try PlaylistEntry
                    .filter(PlaylistEntry.Columns.playlistID == playlistID && PlaylistEntry.Columns.orderIndex >= index)
                    .order(PlaylistEntry.Columns.orderIndex)
                    .fetchAll(db)
                for var entry in existing {
                    entry.orderIndex += 1
                    try entry.update(db)
                }
                targetIndex = index
            } else {
                targetIndex = maxOrder + 1
            }

            var entry = PlaylistEntry(
                id: nil,
                playlistID: playlistID,
                trackUUID: trackUUID,
                relativePath: relativePath,
                orderIndex: targetIndex,
                addedAt: Date()
            )
            try entry.insert(db)
        }
    }

    /// Remove an entry by its ID.
    func removeEntry(entryID: Int64) throws {
        try dbQueue.write { db in
            guard let entry = try PlaylistEntry.fetchOne(db, key: entryID) else { return }
            try db.execute(sql: "DELETE FROM playlist_entries WHERE id = ?", arguments: [entryID])
            // Re-index subsequent entries
            let remaining = try PlaylistEntry
                .filter(PlaylistEntry.Columns.playlistID == entry.playlistID && PlaylistEntry.Columns.orderIndex > entry.orderIndex)
                .order(PlaylistEntry.Columns.orderIndex)
                .fetchAll(db)
            for var e in remaining {
                e.orderIndex -= 1
                try e.update(db)
            }
        }
    }

    /// Reorder entries to match the given entry ID sequence.
    func reorderEntries(playlistID: Int64, entryIDs: [Int64]) throws {
        try dbQueue.write { db in
            for (newIndex, entryID) in entryIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE playlist_entries SET order_index = ? WHERE id = ? AND playlist_id = ?",
                    arguments: [newIndex, entryID, playlistID]
                )
            }
        }
    }

    // MARK: - Write-back

    /// Serialize a local playlist back to the `.ios` dialect and write it to the playlists directory.
    func writeBack(playlist: LocalPlaylist, to directory: URL) throws {
        let entries = try fetchEntries(playlistID: playlist.id!)
        let parsed = try buildParsedPlaylist(playlist: playlist, entries: entries)
        let fileName = playlist.file ?? "\(playlist.name).m3u8"
        let fileURL = directory.appendingPathComponent(fileName)
        try write(parsed, to: fileURL)
    }

    /// Build a `ParsedPlaylist` from local DB state, generating EXTINF lines from the indexed library.
    func buildParsedPlaylist(playlist: LocalPlaylist, entries: [PlaylistEntry], trackLookup: ((String) -> IndexedTrack?)? = nil) throws -> ParsedPlaylist {
        var parsedEntries: [ParsedEntry] = []
        for entry in entries {
            let track = trackLookup?(entry.trackUUID)
            let extinf: String?
            if let track = track {
                extinf = "#EXTINF:\(track.duration),\(track.artist) - \(track.title)"
            } else {
                extinf = nil
            }
            parsedEntries.append(ParsedEntry(
                extinfLine: extinf,
                trackUUID: entry.trackUUID,
                path: entry.relativePath,
                precedingComments: []
            ))
        }
        return ParsedPlaylist(
            playlistUUID: playlist.uuid,
            headerComments: [],
            entries: parsedEntries
        )
    }

    // MARK: - Private helpers

    /// Find an existing local playlist by UUID (or by file name), or create a new one.
    private func findOrCreatePlaylist(for parsed: ParsedPlaylist, fileName: String, file: String) throws -> LocalPlaylist {
        try dbQueue.write { db -> LocalPlaylist in
            // Try by UUID first
            if let uuid = parsed.playlistUUID {
                if let existing = try LocalPlaylist.filter(LocalPlaylist.Columns.uuid == uuid).fetchOne(db) {
                    return existing
                }
            }
            // Fallback: by file name
            if let existing = try LocalPlaylist.filter(LocalPlaylist.Columns.file == file).fetchOne(db) {
                return existing
            }
            // Create new
            let uuid = parsed.playlistUUID ?? UUID().uuidString.uppercased()
            var newPlaylist = LocalPlaylist(id: nil, uuid: uuid, name: fileName, file: file)
            try newPlaylist.insert(db)
            return newPlaylist
        }
    }

    /// Diff incoming parsed entries against current DB state and apply incrementally.
    /// Returns true if any changes were made.
    private func applyDiff(playlist: LocalPlaylist, parsed: ParsedPlaylist) throws -> Bool {
        guard let playlistID = playlist.id else { return false }

        let currentEntries = try fetchEntries(playlistID: playlistID)

        // Build identity keys for comparison
        let incomingKeys = parsed.entries.map { entryKey($0) }
        let currentKeys = currentEntries.map { entryKey($0) }

        // Cheap no-op: identical ordered key sequence
        if incomingKeys == currentKeys {
            return false
        }

        let incomingSet = Set(incomingKeys)
        let currentSet = Set(currentKeys)

        let toRemove = currentSet.subtracting(incomingSet)
        let toAdd = incomingKeys.enumerated().filter { !currentSet.contains($0.element) }

        try dbQueue.write { db in
            // Remove vanished entries
            if !toRemove.isEmpty {
                for entry in currentEntries where toRemove.contains(entryKey(entry)) {
                    try db.execute(sql: "DELETE FROM playlist_entries WHERE id = ?", arguments: [entry.id!])
                }
            }

            // Build the final ordered list: use incoming order
            // First, update order for existing entries that remain
            var existingByPath: [String: PlaylistEntry] = [:]
            var existingByUUID: [String: PlaylistEntry] = [:]
            let remaining = try PlaylistEntry
                .filter(PlaylistEntry.Columns.playlistID == playlistID)
                .order(PlaylistEntry.Columns.orderIndex)
                .fetchAll(db)
            for entry in remaining {
                existingByPath[entry.relativePath] = entry
                existingByUUID[entry.trackUUID] = entry
            }

            for (newIndex, parsedEntry) in parsed.entries.enumerated() {
                let key = entryKey(parsedEntry)
                if let existing = findExisting(key: key, byUUID: existingByUUID, byPath: existingByPath) {
                    if existing.orderIndex != newIndex {
                        try db.execute(
                            sql: "UPDATE playlist_entries SET order_index = ? WHERE id = ?",
                            arguments: [newIndex, existing.id!]
                        )
                    }
                } else {
                    // New entry
                    var newEntry = PlaylistEntry(
                        id: nil,
                        playlistID: playlistID,
                        trackUUID: parsedEntry.trackUUID ?? "",
                        relativePath: parsedEntry.path,
                        orderIndex: newIndex,
                        addedAt: Date()
                    )
                    try newEntry.insert(db)
                }
            }
        }

        return true
    }

    /// Identity key for diff comparison: prefer trackUUID, fallback to relative path.
    private func entryKey(_ entry: ParsedEntry) -> String {
        entry.trackUUID ?? entry.path
    }

    /// Identity key for DB entries.
    private func entryKey(_ entry: PlaylistEntry) -> String {
        entry.trackUUID.isEmpty ? entry.relativePath : entry.trackUUID
    }

    /// Find an existing DB entry matching the given key.
    private func findExisting(key: String, byUUID: [String: PlaylistEntry], byPath: [String: PlaylistEntry]) -> PlaylistEntry? {
        byUUID[key] ?? byPath[key]
    }
}
