import Foundation
import GRDB

// MARK: - Read Playlist Changes from Device (S-SYNC-INGESTPREVIEW, F-11, PP-SYNC-04)

/// The difference between a playlist file on the device and the MLM playlist — **a merge, never a
/// replace** (PP-SYNC-04). Pure.
///
/// - `added`: tracks the device file lists that the MLM playlist doesn't (device order).
/// - `removed`: tracks MLM wrote into the device file (`expected`) that the device no longer
///   lists — the only entries Apply may remove, and only when checked.
/// - `keptOnlyInMLM`: tracks of the MLM playlist that never reached the device (not downloaded,
///   synced later, skipped). They are never treated as removed.
/// - `orderDiffers`: the tracks both have are in another order on the device.
struct DevicePlaylistDiff: Equatable, Sendable {
    let added: [Int64]
    let removed: [Int64]
    let keptOnlyInMLM: [Int64]
    let orderDiffers: Bool

    var hasChanges: Bool { !added.isEmpty || !removed.isEmpty || orderDiffers }

    static func make(device: [Int64], mlm: [Int64], expected: Set<Int64>) -> DevicePlaylistDiff {
        let deviceSet = Set(device)
        let ownSet = Set(mlm)
        let added = unique(device.filter { !ownSet.contains($0) })
        let removed = mlm.filter { expected.contains($0) && !deviceSet.contains($0) }
        let kept = mlm.filter { !deviceSet.contains($0) && !expected.contains($0) }
        let commonOnDevice = unique(device.filter { ownSet.contains($0) })
        let commonInMLM = mlm.filter { deviceSet.contains($0) }
        return DevicePlaylistDiff(added: added, removed: removed, keptOnlyInMLM: kept,
                                  orderDiffers: commonOnDevice != commonInMLM)
    }

    /// The MLM playlist after Apply: the checked removals leave, the checked additions join (at
    /// the end, or — with `useDeviceOrder` — the tracks that are on the device take the device's
    /// order in their slots while every MLM-only track keeps its place).
    static func mergedOrder(mlm: [Int64], device: [Int64], add: [Int64], remove: Set<Int64>,
                            useDeviceOrder: Bool) -> [Int64] {
        let base = mlm.filter { !remove.contains($0) }
        let baseSet = Set(base)
        let additions = unique(add.filter { !baseSet.contains($0) })
        guard useDeviceOrder else { return base + additions }
        let deviceSet = Set(device)
        let present = Set(base.filter { deviceSet.contains($0) }).union(additions)
        let sequence = unique(device.filter { present.contains($0) })
        var result = base
        var next = sequence.makeIterator()
        for index in result.indices where deviceSet.contains(result[index]) {
            if let track = next.next() { result[index] = track }
        }
        while let track = next.next() { result.append(track) }
        // Tracks in `present` the device sequence didn't carry (none in practice) stay appended.
        let placed = Set(result)
        return result + additions.filter { !placed.contains($0) }
    }

    private static func unique(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        return ids.filter { seen.insert($0).inserted }
    }
}

/// One changed playlist file on the device (a card of the sheet).
struct DevicePlaylistCard: Identifiable, Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case existing(id: Int64, name: String)
        /// A playlist created on the device (`New on device`).
        case new(name: String)

        var name: String {
            switch self {
            case .existing(_, let name), .new(let name): name
            }
        }
    }

    struct Unmatched: Equatable, Hashable, Sendable {
        let path: String
        let reason: String
    }

    struct TrackLabel: Equatable, Sendable {
        let title: String
        let artist: String
        let availability: TrackAvailability

        var text: String { artist.isEmpty ? title : "\(title) — \(artist)" }
    }

    /// Path of the file relative to the destination (stable identity).
    let id: String
    let fileURL: URL
    let target: Target
    let device: [Int64]
    let mlm: [Int64]
    let diff: DevicePlaylistDiff
    let unmatched: [Unmatched]
    let labels: [Int64: TrackLabel]

    var isNew: Bool { if case .new = target { return true } else { return false } }

    /// `+3 −1 on device`, `+1 on device · order changed`, `New on device · 14 tracks`.
    var summary: String {
        if isNew { return "New on device · \(StatusBarText.tracks(device.count))" }
        var parts: [String] = []
        if !diff.added.isEmpty { parts.append("+\(diff.added.count.formatted(.number))") }
        if !diff.removed.isEmpty { parts.append("−\(diff.removed.count.formatted(.number))") }
        var text = parts.isEmpty ? "" : parts.joined(separator: " ") + " on device"
        if diff.orderDiffers { text += text.isEmpty ? "Order changed on device" : " · order changed" }
        if !unmatched.isEmpty {
            let note = "\(unmatched.count.formatted(.number)) not matched"
            text += text.isEmpty ? note : " · \(note)"
        }
        return text
    }

    /// `7 tracks that are not on the device (6 Not downloaded, 1 Download failed) stay in the playlist.`
    var keptSentence: String? {
        guard !diff.keptOnlyInMLM.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        var order: [String] = []
        for id in diff.keptOnlyInMLM {
            let word: String = switch labels[id]?.availability {
            case .notDownloaded?, .downloading?: "Not downloaded"
            case .failed?: "Download failed"
            case .fileMissing?: "File missing"
            default: "not synced yet"
            }
            if counts[word] == nil { order.append(word) }
            counts[word, default: 0] += 1
        }
        let detail = order.map { "\(counts[$0]!.formatted(.number)) \($0)" }.joined(separator: ", ")
        let n = diff.keptOnlyInMLM.count
        return "\(StatusBarText.tracks(n)) that \(n == 1 ? "is" : "are") not on the device (\(detail)) stay\(n == 1 ? "s" : "") in the playlist."
    }
}

/// What the user chose on a card.
struct DevicePlaylistSelection: Equatable, Sendable {
    var include = true
    var added: Set<Int64>
    var removed: Set<Int64>
    var useDeviceOrder = false

    init(card: DevicePlaylistCard) {
        added = Set(card.isNew ? card.device : card.diff.added)
        // Removals are pre-checked only when every entry of the file was understood; with
        // unmatched entries MLM can't be sure what the device really dropped.
        removed = card.unmatched.isEmpty ? Set(card.diff.removed) : []
    }

    var changeCount: Int { added.count + removed.count + (useDeviceOrder ? 1 : 0) }
}

/// What one Apply did to one playlist — exactly enough to undo and redo it.
enum DevicePlaylistApplied: Sendable {
    /// Every `playlist_tracks` row of the playlist before and after (ids, positions, `added_at`).
    case updated(playlistID: Int64, name: String, before: [PlaylistTrack], after: [PlaylistTrack], changes: Int)
    case created(Playlist, trackCount: Int)
}

/// Scans a profile's destination for playlist files, matches them with the library and applies
/// the checked changes. Reads only playlist files — no music is ever copied from a device.
final class DevicePlaylistChangeService: Sendable {
    private let ingest: PlaylistIngestService
    private let tracks: TrackRepository
    private let playlists: PlaylistRepository
    private let database: any DatabaseWriter

    init(ingest: PlaylistIngestService, tracks: TrackRepository, playlists: PlaylistRepository,
         database: any DatabaseWriter) {
        self.ingest = ingest
        self.tracks = tracks
        self.playlists = playlists
        self.database = database
    }

    // MARK: Files on the device

    /// The playlist files MLM may read for the profile: for the iOS dialect `Playlists/` then the
    /// root; otherwise every `.m3u8` (Doppi: `.m3u`) below the destination, without hidden
    /// folders (`.rockbox`, `.Trashes`, `.Spotlight-V100`).
    static func playlistFiles(for profile: SyncProfile, fileManager: FileManager = .default) -> [(url: URL, name: String)] {
        let root = profile.outputFolder
        let extensions: Set<String> = profile.playlistFormatEnum == .doppi ? ["m3u", "m3u8"] : ["m3u8"]
        var files: [(URL, String)] = []
        var seen = Set<String>()
        func add(_ path: String, _ name: String) {
            guard seen.insert(path).inserted else { return }
            files.append((URL(fileURLWithPath: path), name))
        }
        if profile.playlistFormatEnum == .ios {
            let folder = SyncService.playlistsFolder(for: profile)
            for entry in ((try? fileManager.contentsOfDirectory(atPath: folder)) ?? []).sorted()
            where extensions.contains((entry as NSString).pathExtension.lowercased()) {
                add((folder as NSString).appendingPathComponent(entry), "Playlists/\(entry)")
            }
            for entry in ((try? fileManager.contentsOfDirectory(atPath: root)) ?? []).sorted()
            where extensions.contains((entry as NSString).pathExtension.lowercased()) {
                add((root as NSString).appendingPathComponent(entry), entry)
            }
        } else if let enumerator = fileManager.enumerator(atPath: root) {
            var relative: [String] = []
            while let path = enumerator.nextObject() as? String {
                if (path as NSString).pathComponents.contains(where: { $0.hasPrefix(".") }) {
                    if (path as NSString).lastPathComponent.hasPrefix(".") { enumerator.skipDescendants() }
                    continue
                }
                if extensions.contains((path as NSString).pathExtension.lowercased()) { relative.append(path) }
            }
            for path in relative.sorted() { add((root as NSString).appendingPathComponent(path), path) }
        }
        return files
    }

    // MARK: Scan

    /// Reads every playlist file and returns the changed ones. `progress(done, total)`.
    /// Files that can't be read are returned in `unreadable` (shown in the sheet, not hidden).
    func scan(profile: SyncProfile, progress: @Sendable (Int, Int) -> Void = { _, _ in })
        async throws -> (cards: [DevicePlaylistCard], unchanged: Int, unreadable: [String]) {
        guard let profileID = profile.id else { return ([], 0, []) }
        let files = Self.playlistFiles(for: profile)
        let profilePlaylists = try await SyncRepository(database: database).fetchProfilePlaylists(profileId: profileID)
        let synced = Set(try await database.read { db in
            try Int64.fetchAll(db, sql: "SELECT track_id FROM sync_state WHERE profile_id = ?", arguments: [profileID])
        })
        // The path MLM wrote for every track this profile has synced (the device's own names are
        // never guessed from the library's file names).
        let libraryRoot = try await ConfigRepository(database: database).getLibraryRoot() ?? ""
        var writtenPaths: [String: Track] = [:]
        for track in try await tracks.fetchTracks(ids: synced) {
            writtenPaths[Self.pathKey(SyncService.devicePath(for: track, profile: profile, libraryRoot: libraryRoot))] = track
        }
        var cards: [DevicePlaylistCard] = []
        var unchanged = 0
        var unreadable: [String] = []
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            progress(index, files.count)
            do {
                if let card = try await card(for: file.url, name: file.name, profile: profile, profileID: profileID,
                                             libraryRoot: libraryRoot, writtenPaths: writtenPaths,
                                             profilePlaylists: profilePlaylists) {
                    cards.append(card)
                } else {
                    unchanged += 1
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                AppLogger.shared.error("Couldn’t read \(file.name): \(error.localizedDescription)", source: "PlaylistIngest")
                unreadable.append(file.name)
            }
        }
        progress(files.count, files.count)
        return (cards, unchanged, unreadable)
    }

    private func card(for url: URL, name: String, profile: SyncProfile, profileID: Int64,
                      libraryRoot: String, writtenPaths: [String: Track],
                      profilePlaylists: [Playlist]) async throws -> DevicePlaylistCard? {
        let (header, entries) = try ingest.parse(url: url)
        let target = try await resolveTarget(header: header, url: url, profilePlaylists: profilePlaylists)

        var pathMap = writtenPaths
        var memberRows: [PlaylistTrack] = []
        if case .existing(let playlistID, _) = target {
            memberRows = try await database.read { db in
                try PlaylistTrack.fetchAll(db, sql: """
                    SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY position, added_at, id
                """, arguments: [playlistID])
            }
            for track in try await tracks.fetchTracks(ids: Set(memberRows.map(\.trackId))) {
                pathMap[Self.pathKey(SyncService.devicePath(for: track, profile: profile, libraryRoot: libraryRoot))] = track
            }
        }
        // 1. The path MLM wrote; 2. only then the UUID / file-name guesses.
        var resolvedTracks: [Track] = []
        var unmatched: [DevicePlaylistCard.Unmatched] = []
        for entry in entries {
            if let track = pathMap[Self.pathKey(entry.path)] {
                resolvedTracks.append(track)
                continue
            }
            let (resolved, unresolved) = try await ingest.resolveEntries([entry])
            if let track = resolved.first?.track {
                resolvedTracks.append(track)
            } else if let miss = unresolved.first {
                unmatched.append(.init(path: miss.entry.path, reason: "no track in the library has this file"))
            }
        }
        let device = resolvedTracks.compactMap(\.id)

        var labelTracks = resolvedTracks
        let mlm: [Int64]
        let expected: Set<Int64>
        switch target {
        case .new:
            guard !device.isEmpty || !unmatched.isEmpty else { return nil }
            mlm = []
            expected = []
        case .existing(let playlistID, _):
            let rows = memberRows
            mlm = rows.map(\.trackId)
            expected = try await expectedOnDevice(rows: rows, profileID: profileID,
                                                  playlistID: playlistID)
            labelTracks += try await tracks.fetchTracks(ids: Set(mlm))
        }
        let diff = DevicePlaylistDiff.make(device: device, mlm: mlm, expected: expected)
        if case .existing = target, !diff.hasChanges, unmatched.isEmpty { return nil }
        var labels: [Int64: DevicePlaylistCard.TrackLabel] = [:]
        for track in labelTracks {
            guard let id = track.id else { continue }
            labels[id] = .init(title: track.title, artist: track.artist, availability: track.availability())
        }
        return DevicePlaylistCard(id: name, fileURL: url, target: target, device: device, mlm: mlm,
                                  diff: diff, unmatched: unmatched, labels: labels)
    }

    /// Normalised key of a device path: precomposed Unicode, case-insensitive (FAT / HFS+).
    static func pathKey(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// The tracks MLM itself wrote into the device file — the only ones the device can have
    /// "removed": exactly the snapshot the last sync wrote for (profile, playlist). No snapshot,
    /// nothing was written, nothing can be removed.
    private func expectedOnDevice(rows: [PlaylistTrack], profileID: Int64, playlistID: Int64) async throws -> Set<Int64> {
        let memberIDs = Set(rows.map(\.trackId))
        guard let snapshot = try await ingest.readSnapshot(profileId: profileID, playlistId: playlistID) else { return [] }
        var ids = Set(snapshot.compactMap(\.trackId))
        let legacy = snapshot.filter { $0.trackId == nil }
            .map { PlaylistIngestService.ParsedEntry(uuid: $0.uuid, path: $0.path, title: nil, artist: nil) }
        if !legacy.isEmpty {
            let (resolved, _) = try await ingest.resolveEntries(legacy)
            ids.formUnion(resolved.compactMap { $0.track.id })
        }
        return ids.intersection(memberIDs)
    }

    /// The embedded playlist UUID; else this profile's playlist with the file's name (the name
    /// the sync wrote — Liked is one of them when the profile has it). Never a playlist the
    /// profile doesn't sync, never creates anything (a scan only reads).
    private func resolveTarget(header: PlaylistIngestService.ParsedHeader, url: URL,
                               profilePlaylists: [Playlist]) async throws -> DevicePlaylistCard.Target {
        let name = url.deletingPathExtension().lastPathComponent
        if let uuid = header.playlistUuid, let playlist = try await playlists.findByMlmUuid(uuid), let id = playlist.id {
            return .existing(id: id, name: playlist.name)
        }
        let key = Self.pathKey(name)
        let match = profilePlaylists.first { Self.pathKey(PathSanitizer.sanitizeComponent($0.name)) == key }
            ?? (key == "liked" ? profilePlaylists.first { $0.isLiked == 1 } : nil)
        if let match, let id = match.id {
            return .existing(id: id, name: match.name)
        }
        return .new(name: name)
    }

    // MARK: Apply (merge)

    /// Applies the checked changes of one card in one transaction, against the playlist as it is
    /// now (it may have changed since the scan). Tracks that only MLM has are never removed.
    func apply(_ card: DevicePlaylistCard, selection: DevicePlaylistSelection) async throws -> DevicePlaylistApplied? {
        switch card.target {
        case .new(let name):
            let ids = card.device.filter { selection.added.contains($0) }
            guard !ids.isEmpty else { return nil }
            let created = try await playlists.createNumbered(baseName: name, trackIds: ids)
            return .created(created, trackCount: ids.count)
        case .existing(let playlistID, let name):
            return try await database.write { db in
                guard try Playlist.fetchOne(db, id: playlistID) != nil else {
                    throw PlaylistRepositoryError.playlistNotFound
                }
                let before = try PlaylistTrack.fetchAll(db, sql: """
                    SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY position, added_at, id
                """, arguments: [playlistID])
                let current = before.map(\.trackId)
                let currentSet = Set(current)
                let add = card.device.filter { selection.added.contains($0) && !currentSet.contains($0) }
                let remove = selection.removed.intersection(currentSet)
                let final = DevicePlaylistDiff.mergedOrder(mlm: current, device: card.device, add: add,
                                                           remove: remove, useDeviceOrder: selection.useDeviceOrder)
                let reorders = selection.useDeviceOrder && final != current.filter { !remove.contains($0) } + add
                let changes = add.count + remove.count + (reorders ? 1 : 0)
                guard changes > 0 else { return nil }
                let rowsByTrack = Dictionary(before.map { ($0.trackId, $0) }, uniquingKeysWith: { first, _ in first })
                for row in before where remove.contains(row.trackId) {
                    try db.execute(sql: "DELETE FROM playlist_tracks WHERE id = ?", arguments: [row.id])
                }
                let now = Self.addedAtFormatter.string(from: Date())
                if selection.useDeviceOrder {
                    let keys = FractionalIndexer.evenlySpaced(count: final.count)
                    for (trackID, key) in zip(final, keys) {
                        if var row = rowsByTrack[trackID] {
                            row.position = key
                            try row.update(db)
                        } else {
                            var row = PlaylistTrack(id: nil, playlistId: playlistID, trackId: trackID, position: key, addedAt: now)
                            try row.insert(db)
                        }
                    }
                } else {
                    var tail = before.filter { !remove.contains($0.trackId) }.map(\.position).max()
                    for trackID in add {
                        let position = FractionalIndexer.positionBetween(left: tail, right: nil)
                        var row = PlaylistTrack(id: nil, playlistId: playlistID, trackId: trackID, position: position, addedAt: now)
                        try row.insert(db)
                        tail = position
                    }
                }
                let after = try PlaylistTrack.fetchAll(db, sql: """
                    SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY position, added_at, id
                """, arguments: [playlistID])
                return .updated(playlistID: playlistID, name: name, before: before, after: after, changes: changes)
            }
        }
    }

    /// Puts a playlist's rows back exactly as given (undo / redo of an Apply): same row ids,
    /// positions and `added_at`. Rows of tracks that left the library meanwhile are skipped.
    func replaceRows(playlistID: Int64, with rows: [PlaylistTrack]) async throws {
        try await database.write { db in
            guard try Playlist.fetchOne(db, id: playlistID) != nil else {
                throw UndoNothingLeft(note: "Nothing to undo — the playlist no longer exists")
            }
            try db.execute(sql: "DELETE FROM playlist_tracks WHERE playlist_id = ?", arguments: [playlistID])
            for var row in rows {
                guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM tracks WHERE id = ?)",
                                        arguments: [row.trackId]) ?? false else { continue }
                try row.insert(db)
            }
        }
    }

    private static let addedAtFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
