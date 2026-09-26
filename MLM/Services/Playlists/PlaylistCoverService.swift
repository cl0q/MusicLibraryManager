import AppKit
import AVFoundation
import Foundation
import GRDB

private actor PlaylistCoverOperationGate {
    private var active: Set<Int64> = []
    private var waiters: [Int64: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ playlistId: Int64) async {
        if !active.contains(playlistId) {
            active.insert(playlistId)
            return
        }
        await withCheckedContinuation { continuation in
            waiters[playlistId, default: []].append(continuation)
        }
    }

    func release(_ playlistId: Int64) {
        guard var playlistWaiters = waiters[playlistId], !playlistWaiters.isEmpty else {
            active.remove(playlistId)
            return
        }
        let next = playlistWaiters.removeFirst()
        waiters[playlistId] = playlistWaiters.isEmpty ? nil : playlistWaiters
        next.resume()
    }
}

/// Orchestrates auto-generation of playlist cover images.
///
/// Lifecycle: long-lived (held by `DependencyContainer`). Observes `.playlistDidChange`
/// and regenerates covers for playlists that don't have a user-set custom cover.
///
/// Threading: `@MainActor` for state ownership; heavy work (artwork extraction,
/// PNG composition) happens inside `async` methods that suspend on AVFoundation
/// loads — the actor stays responsive between hops.
///
/// Re-entry safety:
/// - Notifications posted by this service tag `userInfo["origin"] = "coverService"`
///   so the observer ignores its own emissions (prevents an infinite regenerate loop).
/// - A per-playlist gate serializes auto, custom, and reset mutations.
///
/// Database type: `any DatabaseWriter` (mirrors `TrackRepository.init(database:)`).
/// Accepts `DatabasePool` (production) AND `DatabaseQueue` (in-memory tests) — both
/// conform to GRDB's `DatabaseWriter` protocol. This lets tests construct the
/// service directly without back-editing the init signature.
///
/// Phase 36 Plan 02 — implements decisions D-01..D-06.
@MainActor
@Observable
final class PlaylistCoverService {

    // MARK: - Dependencies

    private let database: any DatabaseWriter
    private let playlistRepository: PlaylistRepository
    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository

    /// Serializes auto, custom, and reset mutations sharing one playlist PNG.
    private let operationGate = PlaylistCoverOperationGate()

    /// NotificationCenter observer token for `.playlistDidChange` (removed in deinit).
    private var playlistObserverToken: NSObjectProtocol?

    /// NotificationCenter observer token for `.trackArtworkDidChange` (removed in deinit).
    private var trackArtworkObserverToken: NSObjectProtocol?

    // MARK: - Init

    init(
        database: any DatabaseWriter,
        playlistRepository: PlaylistRepository,
        trackRepository: TrackRepository,
        configRepository: ConfigRepository
    ) {
        self.database = database
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
        self.configRepository = configRepository
        startObserving()
    }

    deinit {
        // `deinit` is nonisolated; read the MainActor-isolated token via the
        // safe escape hatch. The observer token is a stable opaque value once
        // assigned in `init`, so concurrent mutation isn't a real concern.
        let tokens = MainActor.assumeIsolated({ [playlistObserverToken, trackArtworkObserverToken] })
        tokens.compactMap { $0 }.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func startObserving() {
        playlistObserverToken = NotificationCenter.default.addObserver(
            forName: .playlistDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Ignore notifications this service emitted (re-entry guard, D-04 safety).
            if (note.userInfo?["origin"] as? String) == "coverService" { return }

            // Optionally targeted regen via userInfo["playlistId"].
            let userInfo = note.userInfo
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let pid = userInfo?["playlistId"] as? Int64 {
                    await self.regenerateCover(playlistId: pid)
                }
                // No-target notifications (rare; createPlaylist/delete) currently NOOP.
                // Cards reload covers when their playlist re-renders via @Observable.
            }
        }

        trackArtworkObserverToken = NotificationCenter.default.addObserver(
            forName: .trackArtworkDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // origin guard: ArtworkBackfillService posts "artworkBackfill" — not "coverService".
            // PlaylistCoverService's own posts tag "coverService" on .playlistDidChange (not
            // .trackArtworkDidChange), so there is no cross-notification re-entry risk.

            guard let trackId = note.userInfo?["trackId"] as? Int64 else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.regenerateCoversContainingTrack(trackId: trackId)
            }
        }
    }

    // MARK: - Public API

    /// Regenerate the auto-cover for `playlistId`.
    /// No-op if `playlists.cover_is_custom == 1` (D-05).
    func regenerateCover(playlistId: Int64) async {
        await withPlaylistOperation(playlistId) {
            await regenerateCoverLocked(playlistId: playlistId)
        }
    }

    private func regenerateCoverLocked(playlistId: Int64) async {
        do {
            // 1. Load playlist; bail if user-locked.
            guard let playlist = try await playlistRepository.fetch(id: playlistId) else { return }
            if playlist.coverIsCustom == 1 { return }   // D-05

            // 2. Fetch first 4 tracks (position ASC, added_at ASC tie-break from Plan 01).
            let tracks = Array((try await playlistRepository.fetchTracks(playlistId: playlistId))
                .prefix(4))

            // 3. Resolve URLs + extract artwork for each.
            let libraryRoot = (try? await configRepository.getLibraryRoot()) ?? nil
            var artworks: [NSImage?] = []
            for track in tracks {
                if let url = resolveLocalURL(for: track, libraryRoot: libraryRoot),
                   let data = await ArtworkExtractor.extract(audioURL: url),
                   let image = NSImage(data: data) {
                    artworks.append(image)
                } else {
                    artworks.append(nil)
                }
            }

            // 4. Decide branch (D-01) and compose.
            // Hop the pixel work (bitmap allocation, image drawing, PNG encoding)
            // off the main actor so cover revalidation on appearance never blocks
            // the UI. MosaicCompositor is a plain enum — safe to call from any context.
            let coversDir = try ensureCoversDir()
            let pngURL = coversDir.appendingPathComponent("\(playlistId).png")
            let nonNilCount = artworks.compactMap { $0 }.count
            let playlistName = playlist.name

            try await Task.detached(priority: .userInitiated) {
                if nonNilCount == 0 {
                    // D-03: fallback gradient + initials
                    try MosaicCompositor.composeFallbackPNG(
                        playlistId: playlistId,
                        name: playlistName,
                        outputURL: pngURL
                    )
                } else if tracks.count < 4 || nonNilCount == 1 {
                    // D-01 auto1: single cover from the first available image
                    if let single = artworks.compactMap({ $0 }).first {
                        try MosaicCompositor.composeSingleCoverPNG(image: single, outputURL: pngURL)
                    } else {
                        // Defensive: nonNilCount > 0 but compact returned empty — shouldn't happen
                        try MosaicCompositor.composeFallbackPNG(
                            playlistId: playlistId, name: playlistName, outputURL: pngURL
                        )
                    }
                } else {
                    // D-01 + D-02: 2×2 mosaic with gradient-tile gaps
                    // Pad to exactly 4 tiles
                    var tiles: [NSImage?] = Array(artworks)
                    while tiles.count < 4 { tiles.append(nil) }
                    let palette = GradientPalette.colors(forPlaylistId: playlistId)
                    let gradients = Array(repeating: palette, count: 4)
                    try MosaicCompositor.composeMosaicPNG(
                        tiles: tiles, gradients: gradients, outputURL: pngURL
                    )
                }
            }.value

            // 5. Re-check the custom lock immediately before committing. The
            // artwork extraction and PNG compose above are slow and run across
            // suspension points, so a custom cover set meanwhile (D-05, LOGIC-018)
            // must not be clobbered by this now-stale auto regeneration.
            if let current = try? await playlistRepository.fetch(id: playlistId),
               current.coverIsCustom == 1 {
                return
            }

            // 6. Persist the path with isCustom=false (auto).
            try await playlistRepository.setCoverPath(
                id: playlistId,
                path: "playlist-covers/\(playlistId).png",
                isCustom: false
            )

            // 7. Tagged completion notification (origin guard prevents self-trigger).
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["origin": "coverService", "playlistId": playlistId]
            )
        } catch {
            // Silent-fail per UI-SPEC line 173 — log and let the card fall back to its
            // gradient placeholder. No toast.
            AppLogger.shared.error(
                "Cover regeneration failed for playlist \(playlistId): \(error)",
                source: "PlaylistCover"
            )
        }
    }

    /// User dropped/picked an image. Compose + persist + flip lock to 1 (D-05).
    func setCustomCover(playlistId: Int64, sourceURL: URL) async {
        await withPlaylistOperation(playlistId) {
            await setCustomCoverLocked(playlistId: playlistId, sourceURL: sourceURL)
        }
    }

    private func setCustomCoverLocked(playlistId: Int64, sourceURL: URL) async {
        do {
            guard let image = NSImage(contentsOf: sourceURL) else {
                AppLogger.shared.error(
                    "Custom cover unreadable: \(sourceURL.path)",
                    source: "PlaylistCover"
                )
                return
            }
            let coversDir = try ensureCoversDir()
            let pngURL = coversDir.appendingPathComponent("\(playlistId).png")
            // Hop pixel work off-main (same rationale as regenerateCover).
            try await Task.detached(priority: .userInitiated) {
                try MosaicCompositor.composeSingleCoverPNG(image: image, outputURL: pngURL)
            }.value

            try await playlistRepository.setCoverPath(
                id: playlistId,
                path: "playlist-covers/\(playlistId).png",
                isCustom: true   // D-05 sticky-lock
            )
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["origin": "coverService", "playlistId": playlistId]
            )
        } catch {
            AppLogger.shared.error(
                "setCustomCover failed for playlist \(playlistId): \(error)",
                source: "PlaylistCover"
            )
        }
    }

    /// D-06: clear the user lock and regenerate from track artwork.
    func resetToAuto(playlistId: Int64) async {
        await withPlaylistOperation(playlistId) {
            await resetToAutoLocked(playlistId: playlistId)
        }
    }

    private func resetToAutoLocked(playlistId: Int64) async {
        do {
            try await playlistRepository.setCoverPath(
                id: playlistId, path: nil, isCustom: false
            )
            // Delete the old cached PNG so a half-failed regen falls back to gradient.
            let coversDir = try ensureCoversDir()
            let pngURL = coversDir.appendingPathComponent("\(playlistId).png")
            try? FileManager.default.removeItem(at: pngURL)
            await regenerateCoverLocked(playlistId: playlistId)
        } catch {
            AppLogger.shared.error(
                "resetToAuto failed for playlist \(playlistId): \(error)",
                source: "PlaylistCover"
            )
        }
    }

    // MARK: - Private helpers

    private func withPlaylistOperation(
        _ playlistId: Int64,
        operation: () async -> Void
    ) async {
        await operationGate.acquire(playlistId)
        await operation()
        await operationGate.release(playlistId)
    }

    /// Find all playlists that (a) contain `trackId` and (b) have cover_is_custom = 0,
    /// then schedule a serialized cover regeneration for each.
    ///
    /// Uses a direct DB read rather than a PlaylistRepository method because no such
    /// method exists; adding a dedicated repo method for this one-off query is not
    /// worth the repository surface growth.
    private func regenerateCoversContainingTrack(trackId: Int64) async {
        let playlistIds: [Int64]
        do {
            playlistIds = try await database.read { db in
                try Int64.fetchAll(db, sql: """
                    SELECT p.id
                    FROM playlists p
                    INNER JOIN playlist_tracks pt ON pt.playlist_id = p.id
                    WHERE pt.track_id = ?
                      AND p.cover_is_custom = 0
                """, arguments: [trackId])
            }
        } catch {
            AppLogger.shared.error(
                "PlaylistCoverService: failed to query playlists for track \(trackId): \(error)",
                source: "PlaylistCover"
            )
            return
        }

        for pid in playlistIds {
            await regenerateCover(playlistId: pid)
        }
    }

    private func ensureCoversDir() throws -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.musiclibrary.app")
            .appendingPathComponent("playlist-covers")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func resolveLocalURL(for track: Track, libraryRoot: String?) -> URL? {
        if let root = libraryRoot,
           let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }
}
