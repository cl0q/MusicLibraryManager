import Foundation
import GRDB
import Observation

// MARK: - Coverage (UC-JOB-07: `9,412 of 12,935 analysed`)

/// How much of the library each Maintenance job has covered, counted in SQL with the same
/// conditions the jobs use to pick their tracks (tracks with a file: `organized_path` set).
struct MaintenanceCoverage: Equatable, Sendable {
    var tracksWithFile = 0
    var fingerprinted = 0
    var replayGain = 0
    var danceability = 0
    var embeddings = 0
    /// Tracks whose cover was read or fetched and is on disk.
    var withArtwork = 0
    /// Tracks a MusicBrainz fetch would look for (`fetchTracksEligibleForProviderArtwork`).
    var withoutArtwork = 0
    /// Album tracks with a file and no track number yet (`Read Track Numbers`, W4-1).
    var unnumberedAlbumTracks = 0

    static func load(_ db: Database) throws -> MaintenanceCoverage {
        func count(_ sql: String) throws -> Int { try Int.fetchOne(db, sql: sql) ?? 0 }
        let withFile = "t.organized_path IS NOT NULL"
        return MaintenanceCoverage(
            tracksWithFile: try count("SELECT COUNT(*) FROM tracks t WHERE \(withFile)"),
            fingerprinted: try count("""
                SELECT COUNT(*) FROM tracks t WHERE \(withFile)
                AND EXISTS (SELECT 1 FROM fingerprints f WHERE f.track_id = t.id)
                """),
            replayGain: try count("""
                SELECT COUNT(*) FROM tracks t WHERE \(withFile)
                AND EXISTS (SELECT 1 FROM replaygain r WHERE r.track_id = t.id)
                """),
            danceability: try count("""
                SELECT COUNT(*) FROM tracks t WHERE \(withFile) AND t.danceability IS NOT NULL AND t.bpm IS NOT NULL
                """),
            embeddings: try count("""
                SELECT COUNT(*) FROM tracks t WHERE \(withFile)
                AND EXISTS (SELECT 1 FROM track_embeddings e WHERE e.track_id = t.id)
                """),
            withArtwork: try count("""
                SELECT COUNT(*) FROM tracks t WHERE \(withFile)
                AND EXISTS (SELECT 1 FROM artwork a WHERE a.track_id = t.id AND a.artwork_path IS NOT NULL
                            AND (a.source IS NULL OR a.source <> 'missing'))
                """),
            withoutArtwork: try count("""
                SELECT COUNT(*) FROM tracks t WHERE \(withFile)
                AND NOT EXISTS (SELECT 1 FROM artwork a WHERE a.track_id = t.id AND a.artwork_path IS NOT NULL)
                """),
            unnumberedAlbumTracks: try TrackNumberReader.unreadCount(db)
        )
    }

    /// `7,880 of 8,902 analysed`.
    static func analysed(_ done: Int, of total: Int) -> String {
        "\(done.formatted()) of \(total.formatted()) analysed"
    }

    /// The coverage words of a job row; `nil` for jobs without coverage.
    func text(for action: String) -> String? {
        switch action {
        case MaintenanceJob.fingerprint: Self.analysed(fingerprinted, of: tracksWithFile)
        case MaintenanceJob.replayGain: Self.analysed(replayGain, of: tracksWithFile)
        case MaintenanceJob.danceability: Self.analysed(danceability, of: tracksWithFile)
        case MaintenanceJob.similarity: Self.analysed(embeddings, of: tracksWithFile)
        case MaintenanceJob.artworkEmbedded: "\(withArtwork.formatted()) of \(tracksWithFile.formatted()) tracks have artwork"
        case MaintenanceJob.artworkMusicBrainz:
            withoutArtwork == 1 ? "1 track without artwork" : "\(withoutArtwork.formatted()) tracks without artwork"
        default: nil
        }
    }
}

extension MaintenanceJob {
    static let fingerprint = "fingerprint"
    static let replayGain = "replaygain"
    static let danceability = "danceability"
    static let similarity = "groove"
    static let artworkEmbedded = "artwork-embedded"
    static let artworkMusicBrainz = "artwork-musicbrainz"
    static let rereadTags = "rescan"
    static let readTrackNumbers = "read-track-numbers"
    static let recreateLikedPlaylist = "create-liked-playlist"
    static let pathAudit = "path-audit"
    static let pathApply = "path-apply"
    static let pathRollback = "path-rollback"

    /// Jobs that read the audio files: they wait for the library drive (ST-MAINT.N01).
    var readsAudioFiles: Bool {
        [Self.fingerprint, Self.replayGain, Self.danceability, Self.similarity, Self.artworkEmbedded,
         Self.rereadTags, Self.readTrackNumbers, Self.pathAudit, Self.pathApply].contains(action)
    }
}

// MARK: - The jobs

/// The Maintenance jobs (F-22), started from Settings ▸ Maintenance and from Library ▸
/// Maintenance ▸ — the same function, one Activity operation each (`MaintenanceJobRunner`).
/// The work moved here from the old pane so the menu can start it too; the work on files and the
/// database is unchanged. Also holds the organised-path preview and the coverage numbers.
@MainActor
@Observable
final class MaintenanceJobs {
    static let shared = MaintenanceJobs()

    private(set) var coverage: MaintenanceCoverage?
    /// The read-only preview of the organised-path repair (A-SET-PATHAPPLY reads its counts).
    private(set) var pathReport: OrganizedPathMigrationService.AuditReport?
    /// The last preview failed: the cause in words.
    private(set) var pathProblem: String?
    /// The migration `Roll Back Last Migration…` would undo.
    private(set) var lastMigration: OrganizedPathMigrationService.MigrationSummary?
    /// The last apply / rollback, for the block's own result line.
    private(set) var pathResult: String?
    /// `Reread tags from files` asks first (review S2); set by the row and by Library ▸
    /// Maintenance ▸, answered by Settings ▸ Maintenance.
    var rereadConfirmationRequested = false

    /// A-SET-REREAD (W3-SET review S2): the question with the count.
    static func rereadTitle(tracks: Int) -> String {
        "Reread tags of \(tracks == 1 ? "1 track" : "\(tracks.formatted()) tracks") from their files?"
    }

    static let rereadMessage = "Edits made in MLM that were not written to files are replaced. Tracks with tag edits that are still waiting to be written are left as they are."

    @ObservationIgnored let runner: MaintenanceJobRunner
    @ObservationIgnored private let container: () -> DependencyContainer

    init(runner: MaintenanceJobRunner? = nil, container: @escaping () -> DependencyContainer = { .shared }) {
        self.runner = runner ?? .shared
        self.container = container
    }

    // MARK: Start

    /// Starts (or queues) `action`; does nothing without a library or when it's already active.
    func start(_ action: String) {
        guard container().isInitialized, !runner.isActive(action) else { return }
        switch action {
        case MaintenanceJob.fingerprint: runner.run(action) { await self.runFingerprint() }
        case MaintenanceJob.replayGain: runner.run(action) { await self.runReplayGain() }
        case MaintenanceJob.danceability: runner.run(action) { await self.runDanceability() }
        case MaintenanceJob.similarity: runner.run(action) { await self.runSimilarity() }
        case MaintenanceJob.artworkEmbedded: runner.run(action) { await self.runArtworkEmbedded() }
        case MaintenanceJob.artworkMusicBrainz: runner.run(action) { await self.runArtworkMusicBrainz() }
        case MaintenanceJob.rereadTags: runner.run(action) { await self.runRereadTags() }
        case MaintenanceJob.readTrackNumbers: runner.run(action) { await self.runReadTrackNumbers() }
        case MaintenanceJob.recreateLikedPlaylist: runner.run(action) { await self.runRecreateLikedPlaylist() }
        case MaintenanceJob.pathAudit: runner.run(action) { await self.runPathAudit() }
        case MaintenanceJob.pathApply: runner.run(action) { await self.applyPathMigration() }
        case MaintenanceJob.pathRollback: runner.run(action) { await self.rollbackPathMigration() }
        default: break
        }
    }

    /// Why `action` can't start now, or `nil` (the reason goes beside the disabled `Run` and into
    /// the menu item's help).
    func blockedReason(_ action: String, drive: LibraryDriveState, toolMissing: Bool = false) -> String? {
        guard container().isInitialized else { return "No library is open." }
        if MaintenanceJob(action: action).readsAudioFiles, drive.isOffline, let name = drive.volumeName {
            return "“\(name)” is not connected."
        }
        if action == MaintenanceJob.readTrackNumbers, coverage?.unnumberedAlbumTracks == 0 { return TrackNumberReader.nothingToRead }
        if toolMissing, action == MaintenanceJob.fingerprint { return "fpcalc not found." }
        if action == MaintenanceJob.artworkEmbedded, automaticArtworkOperation != nil {
            return "Artwork is being read for new tracks."
        }
        if action == MaintenanceJob.pathApply, let reason = pathApplyBlockedReason() { return reason }
        return nil
    }

    /// The automatic artwork backfill, while it runs: `Refresh embedded artwork` shows its echo
    /// instead of claiming a refresh (W3-ACT report: "refresh complete while a backfill runs").
    var automaticArtworkOperation: ActivityOperation? {
        runner.center.activeOperations.first { $0.kind == .artwork && $0.isAutomatic }
            ?? (container().artworkBackfillService?.isBackfilling == true && !runner.isActive(MaintenanceJob.artworkEmbedded)
                ? ActivityOperation.placeholderArtwork : nil)
    }

    // MARK: Coverage

    func refreshCoverage() async {
        guard let pool = container().databaseManager?.pool else { coverage = nil; return }
        coverage = try? await pool.read { db in try MaintenanceCoverage.load(db) }
        lastMigration = try? await makePathMigrationService().lastAppliedMigration()
    }

    // MARK: Helpers

    private var usesAcceleratedProcessing: Bool {
        let level = container().syncViewModel?.syncService.syncTurboLevel
            ?? UserDefaults.standard.string(forKey: "sync_turbo_level").flatMap(SyncTurboLevel.init(rawValue:))
            ?? .standard
        return level != .conservative
    }

    private func progressHandler() -> (MaintenanceProgressTracker.ProgressState) -> Void {
        { [runner] state in Task { @MainActor in runner.progress = state } }
    }

    private func didChangeLibrary() async {
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
        await refreshCoverage()
    }

    // MARK: Analyses

    private func runFingerprint() async {
        let c = container()
        guard let trackRepo = c.trackRepository, let analysisRepo = c.analysisRepository else { return }
        let service = FingerprintService()
        guard service.isAvailable else {
            runner.resultMessage = "fpcalc not found. Install via: brew install chromaprint"
            return
        }
        let tracks = (try? await trackRepo.fetchUnfingerprintedTracks()) ?? []
        let libraryRoot = try? await c.configRepository?.getLibraryRoot()
        let (processed, failed, _) = await service.batchFingerprint(
            tracks: tracks, repository: analysisRepo, libraryRoot: libraryRoot,
            turboMode: usesAcceleratedProcessing, progressHandler: progressHandler())
        runner.resultMessage = "Fingerprint: \(processed) processed, \(failed) failed"
        await didChangeLibrary()
    }

    private func runReplayGain() async {
        let c = container()
        guard let trackRepo = c.trackRepository, let analysisRepo = c.analysisRepository else { return }
        let analyzer = ReplayGainAnalyzer()
        guard analyzer.isAvailable else {
            runner.resultMessage = "ffmpeg not found. Install via: brew install ffmpeg"
            return
        }
        let tracks = (try? await trackRepo.fetchUnanalyzedTracks()) ?? []
        let libraryRoot = try? await c.configRepository?.getLibraryRoot()
        let (analyzed, failed, _) = await analyzer.batchAnalyze(
            tracks: tracks, repository: analysisRepo, trackRepository: trackRepo, libraryRoot: libraryRoot,
            turboMode: usesAcceleratedProcessing, progressHandler: progressHandler())
        runner.resultMessage = "ReplayGain: \(analyzed) analyzed, \(failed) failed"
        await didChangeLibrary()
    }

    private func runDanceability() async {
        let c = container()
        guard let trackRepo = c.trackRepository else { return }
        let analyzer = DanceabilityAnalyzer()
        guard analyzer.isAvailable else {
            runner.resultMessage = "ffmpeg not found. Install via: brew install ffmpeg"
            return
        }
        let tracks = (try? await trackRepo.fetchTracksWithoutDanceability()) ?? []
        let libraryRoot = try? await c.configRepository?.getLibraryRoot()
        let (analyzed, failed, _) = await analyzer.batchAnalyze(
            tracks: tracks, trackRepository: trackRepo, libraryRoot: libraryRoot,
            turboMode: usesAcceleratedProcessing, progressHandler: progressHandler())
        runner.resultMessage = "Danceability: \(analyzed) analyzed, \(failed) failed"
        await didChangeLibrary()
    }

    private func runSimilarity() async {
        let c = container()
        guard let trackRepo = c.trackRepository, let analyzer = c.grooveBatchAnalyzer else { return }
        guard analyzer.isAvailable else {
            runner.resultMessage = "Similarity analysis is not available: the on-device model or ffmpeg is missing."
            return
        }
        let tracks = (try? await trackRepo.fetchTracksWithoutGrooveEmbedding()) ?? []
        let libraryRoot = try? await c.configRepository?.getLibraryRoot()
        let (analyzed, failed, _) = await analyzer.batchAnalyze(
            tracks: tracks, trackRepository: trackRepo, libraryRoot: libraryRoot,
            turboMode: usesAcceleratedProcessing, progressHandler: progressHandler())
        runner.resultMessage = "Similarity analysis: \(analyzed) analyzed, \(failed) failed"
        await didChangeLibrary()
    }

    // MARK: Artwork

    /// Embedded artwork via `ArtworkBackfillService` (ffmpeg, no network). Never claims a refresh
    /// that didn't happen: while the automatic backfill runs, nothing starts (and no result line).
    private func runArtworkEmbedded() async {
        guard let service = container().artworkBackfillService, !service.isBackfilling else { return }
        var processed = 0
        await service.refreshMissing(turboMode: usesAcceleratedProcessing) { [runner] state in
            processed = state.current
            Task { @MainActor in runner.progress = state }
        }
        runner.resultMessage = "Embedded artwork: \(processed) processed"
        await didChangeLibrary()
    }

    /// MusicBrainz Cover Art Archive for tracks without art (network, rate-limited).
    private func runArtworkMusicBrainz() async {
        let c = container()
        guard let trackRepo = c.trackRepository, let analysisRepo = c.analysisRepository else { return }
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mlm.artwork_cache")
        let service = ArtworkService(cacheDir: cacheDir)
        // SCDL-08: the provider-eligibility query keeps NULL-path sentinel rows eligible.
        let tracks = (try? await trackRepo.fetchTracksEligibleForProviderArtwork()) ?? []
        let libraryRoot = try? await c.configRepository?.getLibraryRoot()
        let result = await service.batchFetchArtwork(
            tracks: tracks, repository: analysisRepo, libraryRoot: libraryRoot,
            turboMode: usesAcceleratedProcessing, progressHandler: progressHandler())
        runner.resultMessage = "Artwork: \(result.fetched) fetched, \(result.notFound) not found"
        await didChangeLibrary()
    }

    // MARK: Tags and the liked playlist

    private func runRereadTags() async {
        let c = container()
        guard let trackRepo = c.trackRepository, let configRepo = c.configRepository else { return }
        let service = LibraryRepairService(trackRepository: trackRepo, configRepository: configRepo)
        do {
            let (succeeded, failed) = try await service.rescanMetadata(
                turboMode: usesAcceleratedProcessing, progressHandler: progressHandler())
            runner.resultMessage = "Tags: \(succeeded) updated · \(failed) failed"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
        } catch {
            runner.resultMessage = "Rereading tags failed: \(error.localizedDescription)"
        }
    }

    /// `Read Track Numbers` (W4-1): the `track` / `disc` tags of album tracks into `album_tracks`.
    private func runReadTrackNumbers() async {
        let c = container()
        guard let pool = c.databaseManager?.pool else { return }
        let root = (try? await c.configRepository?.getLibraryRoot()).flatMap { $0 }
        var reader = TrackNumberReader(database: pool, libraryRoot: root)
        reader.isDriveConnected = { await MainActor.run { !LibraryDriveState.current(c).isOffline } }
        let outcome = await reader.run { [runner] state in Task { @MainActor in runner.progress = state } }
        runner.resultMessage = "Track numbers: \(outcome.read) updated, \(outcome.unreadable) failed"
        if outcome.read > 0 { NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil) }
        await didChangeLibrary()
    }

    /// The liked playlist's name (SoundCloud is the only source with one today).
    static let likedPlaylistName = "Liked from SoundCloud"

    private func runRecreateLikedPlaylist() async {
        let c = container()
        guard let sourceRepo = c.sourceRepository, let playlistRepo = c.playlistRepository else { return }
        do {
            let source = try await sourceRepo.upsert(name: "soundcloud", userId: "default")
            guard let sourceId = source.id else { return }
            let playlist = try await playlistRepo.findOrCreateLikedPlaylist(
                name: Self.likedPlaylistName, sourceId: sourceId, externalId: nil,
                legacyNameMatches: ["soundcloud", "liked"])
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
            // The result is the playlist itself plus one status-bar line (ST-MAINT.E17).
            runner.center.postNote("“\(playlist.name)” is in the sidebar again")
            // No result line: a success leaves no Activity trace (a short job).
        } catch {
            runner.resultMessage = "Recreating the liked playlist failed: \(error.localizedDescription)"
        }
    }

    // MARK: Organised paths (preview → apply → roll back)

    private func makePathMigrationService() async throws -> OrganizedPathMigrationService {
        let c = container()
        guard let databaseManager = c.databaseManager, let configRepository = c.configRepository,
              let root = try await configRepository.getLibraryRoot(), !root.isEmpty else {
            throw OrganizedPathMigrationService.MigrationError.libraryRootMissing
        }
        return OrganizedPathMigrationService(
            database: databaseManager.pool, databasePath: databaseManager.databasePath,
            libraryRoot: URL(fileURLWithPath: root, isDirectory: true))
    }

    /// `Not started — 2 downloads are running` (A-SET-PATHAPPLY: the reason replaces the button).
    func pathApplyBlockedReason() -> String? {
        let downloads = runner.center.activeOperations.filter {
            [.download, .recommendationDownload, .reelsDownload].contains($0.kind)
        }.count
        let downloading = downloads > 0 || container().downloadViewModel?.isDownloading == true
            || PerformanceQueueService.shared.isDownloadActive
        guard downloading else { return nil }
        let count = max(downloads, 1)
        return "Not started — \(count == 1 ? "1 download is" : "\(count) downloads are") running"
    }

    private func runPathAudit() async {
        pathProblem = nil
        pathResult = nil
        do {
            let report = try await makePathMigrationService().audit()
            pathReport = report
            runner.resultMessage = "Path preview: \(report.eligibleCount) can be fixed, \(report.unresolvedCount) unclear"
        } catch {
            pathReport = nil
            pathProblem = Self.pathProblemText(error)
            runner.resultMessage = "Path preview failed: \(pathProblem ?? error.localizedDescription)"
        }
    }

    private func applyPathMigration() async {
        guard let report = pathReport else { return }
        if let reason = pathApplyBlockedReason() {
            pathResult = reason
            return
        }
        do {
            let result = try await makePathMigrationService().apply(report)
            pathReport = nil
            pathResult = "\(result.updatedCount.formatted()) organized paths updated · \(report.unresolvedCount.formatted()) unclear entries unchanged"
            runner.resultMessage = "Path migration: \(result.updatedCount) organized paths updated"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            // Files were re-pointed: check them (W2-A).
            NotificationCenter.default.post(name: .libraryFilesDidChange, object: nil)
        } catch {
            pathResult = "Not updated — \(Self.pathProblemText(error))"
            runner.resultMessage = "Path migration cancelled: \(Self.pathProblemText(error))"
        }
        await refreshCoverage()
    }

    private func rollbackPathMigration() async {
        do {
            let result = try await makePathMigrationService().rollbackMostRecent()
            pathReport = nil
            pathResult = "\(result.restoredCount.formatted()) organized paths restored"
            runner.resultMessage = "Rollback: \(result.restoredCount) organized paths updated"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            NotificationCenter.default.post(name: .libraryFilesDidChange, object: nil)
        } catch {
            pathResult = "Not rolled back — \(Self.pathProblemText(error))"
            runner.resultMessage = "Rollback cancelled: \(Self.pathProblemText(error))"
        }
        await refreshCoverage()
    }

    /// Plain words for the migration's errors (no internal codes).
    static func pathProblemText(_ error: Error) -> String {
        guard let error = error as? OrganizedPathMigrationService.MigrationError else { return error.localizedDescription }
        switch error {
        case .libraryRootMissing: return "the library folder can’t be reached"
        case .auditChanged: return "the library changed since the preview. Preview again"
        case .noEligibleChanges: return "nothing can be fixed"
        case .noAppliedManifest: return "there is no migration to roll back"
        default: return error.localizedDescription
        }
    }

    // MARK: Transcode cache

    /// `2,140 files · 18.2 GB` — only the cache's own files (`TranscodeCacheSafety`), read off the
    /// main actor.
    nonisolated static func cacheSummary(_ directory: URL) -> (files: Int, bytes: Int64)? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        var bytes: Int64 = 0
        let files = TranscodeCacheSafety.cacheFiles(in: directory)
        for url in files {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            bytes += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return (files.count, bytes)
    }

    /// Why the transcode cache folder `folder` can't be cleared or moved now, or `nil`
    /// (review B1): a running move or sync, or a folder that isn't a dedicated cache folder.
    func cacheRefusal(for folder: URL) async -> String? {
        let c = container()
        if let reason = c.transcodeCacheMoveBlockedReason { return reason }
        let root = (try? await c.configRepository?.getLibraryRoot()).flatMap { $0 }.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let pool = c.databaseManager?.pool
        return await TranscodeCacheSafety.refusal(for: folder, libraryRoot: root) { prefix, absolute in
            (try? await pool?.read { db in
                try Bool.fetchOne(db, sql: """
                    SELECT EXISTS (SELECT 1 FROM tracks
                                   WHERE organized_path LIKE ? ESCAPE '\' OR organized_path LIKE ? ESCAPE '\')
                    """, arguments: [TranscodeCacheSafety.likePrefix(prefix), TranscodeCacheSafety.likePrefix(absolute)])
            }) ?? true
        }
    }

    /// `Clear Cache` (A-SET-CACHECLEAR): deletes the cache's own transcoded copies — never another
    /// file. Refused (with the reason) while a sync reads the cache or a move runs, and for a
    /// folder that isn't a dedicated cache folder. Returns the refusal, or `nil` when it ran.
    @discardableResult
    func clearTranscodeCache() async -> String? {
        let c = container()
        guard let cache = c.transcodeCache else { return "There is no transcode cache." }
        let directory = cache.cacheDir
        if let refusal = await cacheRefusal(for: directory) { return refusal }
        let job = runner.center.begin(.transcodeCacheMove, title: "Clear the transcode cache",
                                      subject: .settings(.maintenance), itemNoun: .file, graceful: true)
        let removed = await Task.detached(priority: .utility) { () -> Int in
            Self.removeCachedFiles(in: directory)
        }.value
        job.finish(ActivityResult(counts: [ActivityCount(.done, removed, removed == 1 ? "copy deleted" : "copies deleted")]))
        return nil
    }

    /// `Change…` of the cache folder: both the current and the chosen folder must be dedicated
    /// cache folders; then the existing move (which moves only cache files) runs.
    func relocateTranscodeCache(to folder: URL) async -> String? {
        let c = container()
        if let current = c.transcodeCache?.cacheDir, let refusal = await cacheRefusal(for: current) { return refusal }
        if let refusal = await cacheRefusal(for: folder) { return refusal }
        c.relocateTranscodeCache(to: folder.path)
        return nil
    }

    /// Removes the cache's own files directly in `directory` (`TranscodeCacheSafety.isCacheFileName`):
    /// non-recursive, never a directory, never another file.
    nonisolated static func removeCachedFiles(in directory: URL) -> Int {
        var removed = 0
        for url in TranscodeCacheSafety.cacheFiles(in: directory) {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}

// MARK: - Transcode cache safety (review B1)

/// What MLM may treat as its transcode cache. The cache folder is user-chosen and may sit inside
/// the library folder (a hidden `.mlm_transcode_cache`), so deleting or moving "everything in it"
/// could reach the music: only the cache's own file names are touched, and folders that aren't a
/// dedicated cache folder are refused.
enum TranscodeCacheSafety {
    /// `‹track id›_‹kbps›[_norm][_art‹px›].m4a` and the legacy `‹track id›.m4a`
    /// (`TranscodeCache.cachePath`).
    static func isCacheFileName(_ name: String) -> Bool {
        name.range(of: #"^\d+(_\d+(_norm)?(_art\d+)?)?\.m4a$"#, options: .regularExpression) != nil
    }

    /// The cache's own regular files directly in `directory` (not recursive, no directories).
    static func cacheFiles(in directory: URL, fileManager: FileManager = .default) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter(isCacheFileName).map { directory.appendingPathComponent($0) }.filter { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).map {
                $0.isRegularFile == true && $0.isSymbolicLink != true
            } ?? false
        }
    }

    /// `%` and `_` escaped for `LIKE … ESCAPE '\'`, plus the trailing wildcard.
    static func likePrefix(_ prefix: String) -> String {
        prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
    }

    /// A path without a trailing slash, symlinks resolved.
    static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The root, a volume root, `/Volumes`, the home folder, Application Support or a system folder.
    static func structuralRefusal(
        for folder: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    ) -> String? {
        let lower = key(folder).lowercased()
        let components = lower.split(separator: "/")
        let isVolumeRoot = components.count == 2 && components[0] == "volumes"
        guard lower == "/" || lower == key(home).lowercased() || lower == key(appSupport).lowercased()
                || lower == "/volumes" || isVolumeRoot
                || ["/users", "/library", "/system", "/applications"].contains(lower) else { return nil }
        return "“\(folder.lastPathComponent)” is a disk or system folder, not a transcode cache."
    }

    /// Why `folder` can't be the transcode cache that MLM clears or moves, or `nil`.
    ///
    /// - Parameter holdsTracks: whether a track's `organized_path` lies inside the folder, given its
    ///   path relative to the library folder (with a trailing `/`) and its absolute path (with `/`).
    static func refusal(
        for folder: URL,
        libraryRoot: URL?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        appSupport: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        holdsTracks: (_ relativePrefix: String, _ absolutePrefix: String) async -> Bool
    ) async -> String? {
        if let structural = structuralRefusal(for: folder, home: home, appSupport: appSupport) { return structural }
        let target = key(folder)
        let name = "“\(folder.lastPathComponent)”"
        let lower = target.lowercased()
        guard let libraryRoot else { return nil }
        let root = key(libraryRoot).lowercased()
        if lower == root { return "\(name) is the library folder, not a transcode cache." }
        if root.hasPrefix(lower + "/") { return "\(name) contains the library folder, not only transcoded copies." }
        if lower.hasPrefix(root + "/") {
            // Inside the library folder: only a dedicated cache folder.
            if folder.lastPathComponent.hasPrefix(".mlm") { return nil }
            let relative = String(target.dropFirst(root.count + 1)) + "/"
            if await holdsTracks(relative, target + "/") {
                return "\(name) holds tracks of the library, so it can’t be the transcode cache."
            }
        }
        return nil
    }
}

private extension ActivityOperation {
    /// Stands for the automatic backfill when it runs without an operation yet (its operation is
    /// registered only once it has counted its tracks).
    static let placeholderArtwork = ActivityOperation(
        id: UUID(), kind: .artwork, title: "Artwork", subject: .allTracks, state: .running, wait: nil,
        progress: .indeterminate, result: nil, startedAt: Date(), endedAt: nil, isAutomatic: true,
        libraryID: nil, needsAttention: false, dismissedAt: nil, itemNoun: .track, messageName: "Artwork",
        controls: .none, isFromHistory: false)
}
