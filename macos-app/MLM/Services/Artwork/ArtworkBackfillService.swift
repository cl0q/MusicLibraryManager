import AppKit
import Foundation
import GRDB

/// Background orchestrator for embedded album-art extraction.
///
/// Observes `.libraryDidImport` and runs a TaskGroup (maxConcurrentTasks: 4) that
/// extracts embedded artwork from newly imported tracks and caches it to disk.
///
/// Direct Phase-36 twin of `PlaylistCoverService`. See PlaylistCoverService for lifecycle pattern.
///
/// Threading: `@MainActor` for state ownership; heavy work (ffmpeg subprocess) runs inside
/// `Task.detached` within `ArtworkService.extractEmbeddedArtwork` — the actor stays responsive.
///
/// Re-entry safety:
/// - `isBackfilling` flag coalesces concurrent `.libraryDidImport` triggers.
/// - `inFlight: Set<Int64>` prevents duplicate concurrent extractions per track.
///
/// Phase 37 D-01, D-02, D-03, D-04.
@MainActor
@Observable
final class ArtworkBackfillService {

    // MARK: - Public state

    /// True while the backfill TaskGroup is running.
    var isBackfilling = false

    /// Progress counter for optional toolbar UI (D-16 discretion).
    var progress: (current: Int, total: Int) = (0, 0)

    /// Concurrent ffmpeg subprocess limit (D-02). Exposed as constant for tests.
    let maxConcurrentTasks = 4

    // MARK: - Dependencies

    private let database: any DatabaseWriter
    private let trackRepository: TrackRepository
    private let analysisRepository: AnalysisRepository
    private let configRepository: ConfigRepository
    private let artworkService: ArtworkService

    // MARK: - Internal state

    /// Coalesces concurrent extractions per track id.
    private var inFlight: Set<Int64> = []

    /// NotificationCenter observer tokens (removed in deinit).
    private var libraryImportObserverToken: NSObjectProtocol?
    private var downloadCompleteObserverToken: NSObjectProtocol?

    // MARK: - Init

    init(
        database: any DatabaseWriter,
        trackRepository: TrackRepository,
        analysisRepository: AnalysisRepository,
        configRepository: ConfigRepository
    ) {
        self.database = database
        self.trackRepository = trackRepository
        self.analysisRepository = analysisRepository
        self.configRepository = configRepository

        // ArtworkService cache dir matches MaintenanceView.runArtwork path so
        // both Maintenance-Action and Auto-Trigger share the same cache (D-08).
        let cacheDir = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mlm.artwork_cache")
        self.artworkService = ArtworkService(cacheDir: cacheDir)

        startObserving()
    }

    deinit {
        // `deinit` is nonisolated; read the MainActor-isolated tokens via the
        // safe escape hatch (mirrors PlaylistCoverService deinit pattern).
        if let token = MainActor.assumeIsolated({ libraryImportObserverToken }) {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = MainActor.assumeIsolated({ downloadCompleteObserverToken }) {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Notification observer

    private func startObserving() {
        libraryImportObserverToken = NotificationCenter.default.addObserver(
            forName: .libraryDidImport,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // D-01: backfill runs AFTER import committed (triggered by notification),
            // not inline in the import pipeline — import speed unaffected.
            Task { @MainActor [weak self] in
                guard let self, !self.isBackfilling else { return }
                await self.backfillMissing()
            }
        }

        downloadCompleteObserverToken = NotificationCenter.default.addObserver(
            forName: .downloadDidComplete,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.isBackfilling else { return }
                await self.backfillMissing()
            }
        }
    }

    // MARK: - Public API

    /// Backfill embedded artwork for all tracks that have no artwork DB row.
    /// Called automatically on `.libraryDidImport`; also manually from MaintenanceView (D-16).
    public func refreshMissing(turboMode: Bool = false, progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil) async {
        guard !isBackfilling else { return }
        await backfillMissing(turboMode: turboMode, progressHandler: progressHandler)
    }

    /// Re-extract artwork for a single track (D-14 self-healing path).
    /// Called by TrackCoverView when DB says artwork exists but file is missing.
    public func refreshSingleTrack(trackId: Int64) async {
        guard !inFlight.contains(trackId) else { return }
        // TrackRepository.fetchTrack(id:) exists — using TrackRepository path (Path A)
        guard let track = try? await trackRepository.fetchTrack(id: trackId) else { return }
        await extractForTrack(track)
    }

    // MARK: - Backfill orchestration

    private func backfillMissing(turboMode: Bool = false, progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil) async {
        isBackfilling = true
        progress = (0, 0)
        defer {
            isBackfilling = false
            inFlight.removeAll()
        }

        // Fetch tracks that have no artwork row in the DB (D-15: only NULL rows, not re-extract)
        let tracks: [Track]
        do {
            tracks = try await trackRepository.fetchTracksWithoutArtwork()
        } catch {
            AppLogger.shared.warn("ArtworkBackfill: failed to fetch tracks without artwork — \(error)",
                                  source: "ArtworkBackfill")
            return
        }

        let total = tracks.count
        guard total > 0 else { return }
        progress = (0, total)
        
        let tracker = MaintenanceProgressTracker(total: total, turboMode: turboMode, progressHandler: progressHandler)
        
        AppLogger.shared.info("ArtworkBackfill: starting \(total) tracks (turbo: \(turboMode))", source: "ArtworkBackfill")

        // D-02: TaskGroup with maxConcurrentTasks: 4 (caps concurrent ffmpeg subprocesses)
        // Turbo mode increases this to 8 for M4 Macs
        let concurrentLimit = turboMode ? 8 : maxConcurrentTasks
        
        await withTaskGroup(of: Void.self) { group in
            var pending = tracks.makeIterator()
            var running = 0

            // Seed initial batch up to concurrentLimit
            while running < concurrentLimit, let track = pending.next() {
                guard let trackId = track.id else { continue }
                inFlight.insert(trackId)
                running += 1
                group.addTask { [weak self] in
                    await self?.extractForTrack(track, tracker: tracker)
                }
            }

            // As tasks complete, add next batch to maintain concurrentLimit in flight
            for await _ in group {
                progress.current += 1
                tracker.updateProgress(
                    trackId: 0,
                    trackTitle: "",
                    trackArtist: "",
                    savedToDb: false
                )
                if let track = pending.next() {
                    guard let trackId = track.id else { continue }
                    inFlight.insert(trackId)
                    group.addTask { [weak self] in
                        await self?.extractForTrack(track, tracker: tracker)
                    }
                }
            }
        }
        
        AppLogger.shared.info("ArtworkBackfill: complete", source: "ArtworkBackfill")
    }

    // MARK: - Per-track extraction

    private func extractForTrack(_ track: Track, tracker: MaintenanceProgressTracker? = nil) async {
        guard let trackId = track.id,
              let organizedPath = track.organizedPath,
              !organizedPath.isEmpty else {
            if let trackId = track.id { inFlight.remove(trackId) }
            return
        }

        // organizedPath is stored as a relative path (e.g., "Artist/Album/track.flac").
        // Resolve it against the library root, mirroring PlaylistCoverService.resolveLocalURL.
        let libraryRoot = (try? await configRepository.getLibraryRoot()) ?? nil
        var trackURL: URL
        let resolvedOrganized: URL
        if let root = libraryRoot, !root.isEmpty {
            resolvedOrganized = URL(fileURLWithPath: root).appendingPathComponent(organizedPath)
        } else {
            resolvedOrganized = URL(fileURLWithPath: organizedPath)
        }

        if FileManager.default.fileExists(atPath: resolvedOrganized.path) {
            trackURL = resolvedOrganized
        } else if FileManager.default.fileExists(atPath: track.originalPath) {
            trackURL = URL(fileURLWithPath: track.originalPath)
        } else {
            trackURL = resolvedOrganized // Fall back so the warning log below formats nicely
        }

        guard FileManager.default.fileExists(atPath: trackURL.path) else {
            AppLogger.shared.warn("ArtworkBackfill: audio file not found at \(trackURL.path) — skipping track \(trackId)",
                                  source: "ArtworkBackfill")
            inFlight.remove(trackId)
            if let tracker = tracker {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
            }
            return
        }

        // Extract embedded artwork (static async; runs ffmpeg in Task.detached internally)
        // D-07: returns nil silently if ffmpeg not found — no user-facing error
        guard let data = await ArtworkService.extractEmbeddedArtwork(from: trackURL) else {
            // No embedded art. Write a sentinel row (NULL path) so this track
            // is no longer returned by `fetchTracksWithoutArtwork()` — otherwise
            // every future download/import re-runs ffmpeg over the whole set of
            // art-less tracks, which is why backfill appeared to run constantly.
            let sentinel = Artwork(
                trackId: trackId,
                artworkPath: nil,
                source: "none",
                musicbrainzReleaseGroupId: nil,
                resolution: nil,
                fetchedAt: ISO8601DateFormatter().string(from: Date())
            )
            try? await analysisRepository.saveArtwork(sentinel)
            inFlight.remove(trackId)
            if let tracker = tracker {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
            }
            return
        }

        // D-08: Save both sizes (500px + 1200px) to disk via internal saveResized
        do {
            try artworkService.saveResized(data: data, trackId: trackId)
        } catch {
            AppLogger.shared.warn("ArtworkBackfill: saveResized failed for track \(trackId): \(error)",
                                  source: "ArtworkBackfill")
            inFlight.remove(trackId)
            if let tracker = tracker {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
            }
            return
        }

        // Persist the artwork row to the DB
        let artworkPath = artworkService.cachedPath(trackId: trackId, size: .large).path
        let artwork = Artwork(
            trackId: trackId,
            artworkPath: artworkPath,
            source: "embedded",
            musicbrainzReleaseGroupId: nil,
            resolution: "1200",
            fetchedAt: ISO8601DateFormatter().string(from: Date())
        )
do {
            try await analysisRepository.saveArtwork(artwork)
            if let tracker = tracker {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: true
                )
                AppLogger.shared.debug("ArtworkBackfill [\(tracker.currentState.current)/\(tracker.currentState.total)] \(track.artist) - \(track.title) → saved ✓", source: "ArtworkBackfill")
            }
        } catch {
            AppLogger.shared.warn("ArtworkBackfill: saveArtwork DB failed for track \(trackId): \(error)",
                                  source: "ArtworkBackfill")
            if let tracker = tracker {
                tracker.updateProgress(
                    trackId: trackId,
                    trackTitle: track.title,
                    trackArtist: track.artist,
                    savedToDb: false
                )
            }
            inFlight.remove(trackId)
            return
        }

        inFlight.remove(trackId)
        
        // D-03: Notify UI per-track so covers appear incrementally ("pop-in" effect)
        NotificationCenter.default.post(
            name: .trackArtworkDidChange,
            object: nil,
            userInfo: [
                "trackId": trackId,
                "artworkPath": artworkPath,
                "origin": "artworkBackfill"   // Re-entry guard tag (analogous to PlaylistCoverService "coverService")
            ]
        )
    }
}
