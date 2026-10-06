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
    private let notificationCenter: NotificationCenter

    // MARK: - Internal state

    /// Coalesces concurrent extractions per track id.
    private var inFlight: Set<Int64> = []

    /// Track ids that have already been attempted for self-heal this session.
    /// Prevents a scrolling table from re-triggering ffmpeg on the same failing
    /// track on every render pass. Cleared at the end of
    /// `reconcileDanglingArtworkFiles()` so a bulk repair can retry.
    private var selfHealAttempted: Set<Int64> = []

    /// Caps concurrent self-heal extractions at 2 (separate from the backfill
    /// TaskGroup which uses `maxConcurrentTasks`).
    private let selfHealLimiter = ConcurrencyLimiter(maxConcurrency: 2)

    /// NotificationCenter observer tokens (removed in deinit).
    private var libraryImportObserverToken: NSObjectProtocol?
    private var downloadCompleteObserverToken: NSObjectProtocol?

    // MARK: - Init

    init(
        database: any DatabaseWriter,
        trackRepository: TrackRepository,
        analysisRepository: AnalysisRepository,
        configRepository: ConfigRepository,
        notificationCenter: NotificationCenter = .default
    ) {
        self.database = database
        self.trackRepository = trackRepository
        self.analysisRepository = analysisRepository
        self.configRepository = configRepository
        self.notificationCenter = notificationCenter

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
        let center = notificationCenter
        if let token = MainActor.assumeIsolated({ libraryImportObserverToken }) {
            center.removeObserver(token)
        }
        if let token = MainActor.assumeIsolated({ downloadCompleteObserverToken }) {
            center.removeObserver(token)
        }
    }

    // MARK: - Notification observer

    private func startObserving() {
        libraryImportObserverToken = notificationCenter.addObserver(
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

        downloadCompleteObserverToken = notificationCenter.addObserver(
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
    ///
    /// Deduplication:
    /// - `inFlight` prevents concurrent extractions of the same track.
    /// - `selfHealAttempted` prevents a scrolling table from retrying the same
    ///   failing track on every render pass (session-scoped, one attempt only).
    /// - `selfHealLimiter` caps concurrent self-heals at 2.
    public func refreshSingleTrack(trackId: Int64) async {
        guard !inFlight.contains(trackId) else { return }
        guard !selfHealAttempted.contains(trackId) else { return }
        selfHealAttempted.insert(trackId)
        inFlight.insert(trackId)
        defer { inFlight.remove(trackId) }

        await selfHealLimiter.run { [weak self] in
            guard let self else { return }
            // TrackRepository.fetchTrack(id:) exists — using TrackRepository path (Path A)
            guard let track = try? await trackRepository.fetchTrack(id: trackId) else { return }
            await extractForTrack(track)
        }
    }

    // MARK: - Dangling artwork reconcile

    /// Pure function: given all artwork rows with a non-empty path, return the
    /// track ids whose path is non-absolute OR whose file does not exist on disk.
    ///
    /// Extracted for testability — the production path calls this inside a
    /// detached task so the ~8.7k `FileManager.fileExists` calls stay off the
    /// main actor.
    nonisolated static func danglingTrackIds(from entries: [(trackId: Int64, artworkPath: String)]) -> [Int64] {
        entries.compactMap { entry in
            let path = entry.artworkPath
            // Relative paths (e.g. "artwork_cache/4_500.jpg") are always dangling —
            // they were never resolved to an absolute filesystem location.
            if !path.hasPrefix("/") { return entry.trackId }
            return FileManager.default.fileExists(atPath: path) ? nil : entry.trackId
        }
    }

    /// Scan every artwork row that records a file path, detect rows whose cached
    /// file no longer exists (or was stored as a relative path that never resolved),
    /// mark them `source = 'missing'`, and clear the negative cache so the next
    /// render pass can re-resolve them.
    ///
    /// Called at the start of `backfillMissing()` on every `.libraryDidImport`
    /// trigger. Cheap enough to run every time: one DB read, one batch of
    /// `fileExists` checks on a detached task, one batched UPDATE.
    /// Converges: after one pass nothing dangles until the OS evicts cache files again.
    @discardableResult
    public func reconcileDanglingArtworkFiles() async -> Int {
        let entries: [(trackId: Int64, artworkPath: String)]
        do {
            entries = try await analysisRepository.fetchAllArtworkPaths()
        } catch {
            AppLogger.shared.warn("ArtworkBackfill: reconcile fetch failed — \(error)",
                                  source: "ArtworkBackfill")
            return 0
        }
        guard !entries.isEmpty else { return 0 }

        // fileExists checks run off the main actor (~8.7k calls).
        let danglingIds: [Int64] = await Task.detached(priority: .utility) {
            Self.danglingTrackIds(from: entries)
        }.value

        guard !danglingIds.isEmpty else { return 0 }

        do {
            try await analysisRepository.markArtworkFilesMissing(trackIds: danglingIds)
        } catch {
            AppLogger.shared.warn("ArtworkBackfill: reconcile update failed — \(error)",
                                  source: "ArtworkBackfill")
            return 0
        }

        // Clear the negative cache so previously-poisoned ids get a fresh chance.
        TrackArtworkCache.shared.clearNegativeEntries()

        // Allow self-heal to retry these tracks after the bulk repair.
        for id in danglingIds {
            selfHealAttempted.remove(id)
        }

        AppLogger.shared.info("ArtworkBackfill: reconciled \(danglingIds.count) dangling artwork rows",
                              source: "ArtworkBackfill")
        return danglingIds.count
    }

    // MARK: - Backfill orchestration

    private func backfillMissing(turboMode: Bool = false, progressHandler: ((MaintenanceProgressTracker.ProgressState) -> Void)? = nil) async {
        isBackfilling = true
        progress = (0, 0)
        defer {
            isBackfilling = false
            inFlight.removeAll()
        }

        // Reconcile dangling artwork files first — rows whose cached file is gone
        // get `source = 'missing'` so `fetchTracksWithoutArtwork()` picks them up.
        await reconcileDanglingArtworkFiles()

        // Fetch tracks that have no artwork row or whose artwork file is missing.
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
        // Activity (W3-ACT): the automatic run is `Artwork for ‹n› tracks` (Automatic; no Cancel —
        // nothing can stop it). The manual run registers in Settings ▸ Maintenance.
        let job: ActivityOperationHandle? = progressHandler == nil
            ? ActivityCenter.shared.begin(.artwork, title: "Artwork for \(ActivityNoun.track.counted(total))",
                                          subject: .allTracks, progress: ActivityProgress(total: total),
                                          itemNoun: .track, automatic: true)
            : nil
        defer { job?.finish(ActivityResult(counts: [ActivityCount(.done, tracker.currentState.current, "checked")])) }
        
        AppLogger.shared.info("ArtworkBackfill: starting \(total) tracks (turbo: \(turboMode))", source: "ArtworkBackfill")

        // D-02: TaskGroup with maxConcurrentTasks: 4 (caps concurrent ffmpeg subprocesses)
        // Turbo mode increases this to 8 for M4 Macs
        let concurrentLimit = turboMode ? 8 : maxConcurrentTasks
        
        // Bridge Swift task cancellation to the tracker so the loop's
        // isCancelled gates actually fire when the user taps Cancel.
        await withTaskCancellationHandler {
            await withTaskGroup(of: Void.self) { group in
                var pending = tracks.makeIterator()
                var running = 0

                // Seed initial batch up to concurrentLimit
                while running < concurrentLimit, let track = pending.next() {
                    if tracker.isCancelled {
                        AppLogger.shared.info("ArtworkBackfill cancelled", source: "ArtworkBackfill")
                        group.cancelAll()
                        break
                    }
                    guard let trackId = track.id else { continue }
                    inFlight.insert(trackId)
                    running += 1
                    group.addTask { [weak self] in
                        await self?.extractForTrack(track, tracker: tracker)
                    }
                }

                // As tasks complete, add next batch to maintain concurrentLimit in flight
                //
                // SCDL-08: do NOT call tracker.updateProgress here — extractForTrack
                // already calls it exactly once per completed track (on every return
                // path: file-not-found, sentinel-write, save-failure, and success).
                // Calling it again here double-counted every track, producing the
                // 84/44 / 100/53 overshoot where `current` outran `total`. Mirror the
                // tracker's single source of truth instead of maintaining a second counter.
                for await _ in group {
                    if tracker.isCancelled || Task.isCancelled {
                        AppLogger.shared.info("ArtworkBackfill cancelled", source: "ArtworkBackfill")
                        group.cancelAll()
                        break
                    }
                    progress.current = tracker.currentState.current
                    job?.update(completed: progress.current, total: total)
                    if let track = pending.next() {
                        guard let trackId = track.id else { continue }
                        inFlight.insert(trackId)
                        group.addTask { [weak self] in
                            await self?.extractForTrack(track, tracker: tracker)
                        }
                    }
                }
            }
        } onCancel: {
            tracker.cancel()
        }
        
        AppLogger.shared.info("ArtworkBackfill: complete", source: "ArtworkBackfill")
    }

    // MARK: - Per-track extraction

    private func extractForTrack(_ track: Track, tracker: MaintenanceProgressTracker? = nil) async {
        guard let trackId = track.id else { return }
        var savedToDatabase = false
        defer {
            inFlight.remove(trackId)
            tracker?.updateProgress(
                trackId: trackId,
                trackTitle: track.title,
                trackArtist: track.artist,
                savedToDb: savedToDatabase
            )
        }
        guard !Task.isCancelled, tracker?.isCancelled != true else { return }

        // organizedPath is stored as a relative path (e.g., "Artist/Album/track.flac").
        // Resolve it against the library root, mirroring PlaylistCoverService.resolveLocalURL.
        let libraryRoot = (try? await configRepository.getLibraryRoot()) ?? nil
        let organizedURL: URL? = track.organizedPath.flatMap { organizedPath in
            guard !organizedPath.isEmpty else { return nil }
            // An absolute stored path is used as it is (the root + absolute join bug, W2-C).
            if (organizedPath as NSString).isAbsolutePath { return URL(fileURLWithPath: organizedPath) }
            if let libraryRoot, !libraryRoot.isEmpty {
                return URL(fileURLWithPath: libraryRoot).appendingPathComponent(organizedPath)
            }
            return URL(fileURLWithPath: organizedPath)
        }
        let originalURL = track.originalPath.isEmpty ? nil : URL(fileURLWithPath: track.originalPath)
        guard let trackURL = [organizedURL, originalURL]
            .compactMap({ $0 })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            let attemptedPath = organizedURL?.path ?? originalURL?.path ?? "(no path)"
            AppLogger.shared.warn("ArtworkBackfill: audio file not found at \(attemptedPath) — skipping track \(trackId)",
                                  source: "ArtworkBackfill")
            return
        }

        // Extract embedded artwork through ProcessRunner so task cancellation
        // terminates ffmpeg before any persistence work can continue.
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
            guard !Task.isCancelled, tracker?.isCancelled != true else { return }
            try? await analysisRepository.saveArtwork(sentinel)
            return
        }

        // D-08: Save both sizes (500px + 1200px) to disk via internal saveResized
        do {
            try artworkService.saveResized(data: data, trackId: trackId)
        } catch {
            AppLogger.shared.warn("ArtworkBackfill: saveResized failed for track \(trackId): \(error)",
                                  source: "ArtworkBackfill")
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
        guard !Task.isCancelled, tracker?.isCancelled != true else { return }
        do {
            try await analysisRepository.saveArtwork(artwork)
            savedToDatabase = true
            AppLogger.shared.debug("ArtworkBackfill [\(tracker?.currentState.current ?? 0)/\(tracker?.currentState.total ?? 0)] \(track.artist) - \(track.title) → saved", source: "ArtworkBackfill")
        } catch {
            AppLogger.shared.warn("ArtworkBackfill: saveArtwork DB failed for track \(trackId): \(error)",
                                  source: "ArtworkBackfill")
            return
        }

        // Artwork changed for this track — allow future self-heal attempts if needed.
        selfHealAttempted.remove(trackId)

        // D-03: Notify UI per-track so covers appear incrementally ("pop-in" effect)
        notificationCenter.post(
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
