import SwiftUI
import GRDB

/// Central dependency container for the application.
///
/// Owns the database connection and all repositories/services.
/// Injected into the SwiftUI environment via `@Environment`.
@Observable
final class DependencyContainer {
    // MARK: - Singleton

    static let shared = DependencyContainer()

    // MARK: - Database

    private(set) var databaseManager: DatabaseManager?
    /// The open library (A3). `nil` until `initialize(location:)` has opened one.
    private(set) var activeLibrary: ActiveLibrary?

    // MARK: - Repositories

    private(set) var trackRepository: TrackRepository?
    private(set) var playlistRepository: PlaylistRepository?
    private(set) var syncRepository: SyncRepository?
    private(set) var albumRepository: AlbumRepository?
    private(set) var sourceRepository: SourceRepository?
    private(set) var analysisRepository: AnalysisRepository?
    private(set) var configRepository: ConfigRepository?
    private(set) var reelRepository: ReelRepository?

    // MARK: - Services

    private(set) var importService: ImportService?
    private(set) var audioPlayer: AudioPlayer?
    private(set) var tokenStorage: TokenStorage?
    private(set) var oauthManager: OAuthManager?
    private(set) var tokenRefreshService: TokenRefreshService?
    /// Observable per-service keychain access state — drives the amber
    /// "token inaccessible" notice in the Sources view.
    private(set) var tokenAccessStatus: TokenAccessStatus?
    private(set) var mountObserver: MountObserver?
    /// Keeps persisted track availability fresh (W2-A, UC-TABLE-20).
    private(set) var availabilityMonitor: LibraryAvailabilityMonitor?
    /// Cover-image orchestrator (Phase 36 Plan 02). Observes `.playlistDidChange`
    /// and regenerates auto covers (skips rows with `cover_is_custom = 1`).
    private(set) var playlistCoverService: PlaylistCoverService?
    /// Embedded artwork extraction orchestrator (Phase 37 Plan 02).
    /// Observes `.libraryDidImport`; runs background TaskGroup(maxConcurrentTasks: 4)
    /// to extract embedded artwork for all tracks without an artwork DB row.
    private(set) var artworkBackfillService: ArtworkBackfillService?
    private(set) var audioEmbeddingService: AudioEmbeddingService?
    private(set) var grooveBatchAnalyzer: GrooveBatchAnalyzer?
    private(set) var swarmRecommendationService: SwarmRecommendationService?
    private(set) var discoveryReviewService: DiscoveryReviewService?
    private(set) var transcodeCache: TranscodeCache?
    private(set) var unifiedSearchService: UnifiedSearchService?
    private(set) var playlistIngestService: PlaylistIngestService?
    /// macOS media-key + Now Playing bridge (play/pause/next/prev).
    private(set) var remoteCommandService: RemoteCommandService?
    /// Auto-pause/resume when the default audio output device changes.
    private(set) var outputDeviceMonitor: OutputDeviceMonitor?
    /// Backup service (A2). Creates, lists, prunes, and restores backup bundles.
    private(set) var backupService: BackupService?

    // MARK: - Search

    private(set) var searchCoordinator = SearchCoordinator()

    /// SoundCloud API client — exposed for universal search metadata resolution.
    private(set) var soundCloudClient: SoundCloudClient?

    // MARK: - ViewModels (shared singletons)

    private(set) var playbackViewModel: PlaybackViewModel?
    private(set) var downloadViewModel: DownloadViewModel?
    private(set) var syncViewModel: SyncViewModel?
    /// Library VM owned by the container so navigating away from the Library
    /// section and back doesn't tear it down and refetch 11k rows.
    private(set) var libraryViewModel: LibraryViewModel?
    /// LRU cache for playlist detail tables (Settings-adjustable cap).
    private(set) var playlistTableCache: PlaylistTableCache?

    // MARK: - State

    private(set) var isInitialized = false
    private(set) var initializationError: Error?
    var hasLibraryRoot = false

    /// Whether the library's external drive is currently mounted.
    var isLibraryDriveMounted = true

    /// Observer for `libraryRootDidChange` — re-wires the download pipeline.
    private var libraryRootObserver: NSObjectProtocol?

    // MARK: - Initialization

    private init() {}

    /// Publishes a terminal bootstrap failure for the root loading view.
    @MainActor
    func reportInitializationFailure(_ error: Error) {
        isInitialized = false
        initializationError = error
        AppLogger.shared.error(
            "Application initialization failed: \(error.localizedDescription)",
            source: "App"
        )
    }

    /// Test-only composition root for UI fixtures. It deliberately wires only
    /// database repositories: no playback, keychain, network, process, mount,
    /// or background service is started by this initializer.
    init(snapshotDatabase: any DatabaseWriter) {
        self.trackRepository = TrackRepository(database: snapshotDatabase)
        self.playlistRepository = PlaylistRepository(database: snapshotDatabase)
        self.syncRepository = SyncRepository(database: snapshotDatabase)
        self.albumRepository = AlbumRepository(database: snapshotDatabase)
        self.sourceRepository = SourceRepository(database: snapshotDatabase)
        self.analysisRepository = AnalysisRepository(database: snapshotDatabase)
        self.configRepository = ConfigRepository(database: snapshotDatabase)
        self.reelRepository = ReelRepository(database: snapshotDatabase)
    }

    static func configureSoundCloudTokenRefresh(
        _ tokenRefresh: any TokenRefreshConfiguring,
        clientId: String,
        clientSecret: String?
    ) async {
        await tokenRefresh.register(
            service: .soundcloud,
            tokenURL: SoundCloudClient.tokenURL,
            clientId: clientId,
            clientSecret: clientSecret
        )
        await tokenRefresh.start()
    }

    deinit {
        if let token = libraryRootObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Open the library at `location` and build all repositories and services around it.
    ///
    /// Called once per launch by `LibraryLaunchCoordinator` (A0 D4: one library per process;
    /// switching relaunches).
    func initialize(location: LibraryLocation) async throws {
        let dbManager = try DatabaseManager(databaseURL: location.databaseURL)
        self.databaseManager = dbManager

        let dbPool = dbManager.pool
        let libraryId = (try? await dbPool.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_id'")
        }) ?? nil
        let library = ActiveLibrary(
            databaseURL: dbManager.databasePath,
            libraryId: libraryId ?? "",
            packageURL: location.packageURL
        )
        self.activeLibrary = library

        self.trackRepository = TrackRepository(database: dbPool)
        self.playlistRepository = PlaylistRepository(database: dbPool)
        self.syncRepository = SyncRepository(database: dbPool)
        self.albumRepository = AlbumRepository(database: dbPool)
        self.sourceRepository = SourceRepository(database: dbPool)
        self.analysisRepository = AnalysisRepository(database: dbPool)
        self.configRepository = ConfigRepository(database: dbPool)
        self.reelRepository = ReelRepository(database: dbPool)

        // LRU cache for playlist detail tables — no repo dependencies.
        await MainActor.run {
            self.playlistTableCache = PlaylistTableCache()
        }

        // Services
        self.importService = ImportService(
            database: dbPool,
            trackRepository: self.trackRepository!
        )

        let player = AudioPlayer()
        self.audioPlayer = player
        self.audioEmbeddingService = AudioEmbeddingService()
        self.grooveBatchAnalyzer = GrooveBatchAnalyzer(embeddingService: self.audioEmbeddingService!)
        self.swarmRecommendationService = SwarmRecommendationService()
        self.discoveryReviewService = DiscoveryReviewService(
            trackRepository: self.trackRepository!,
            configRepository: self.configRepository!
        )

        // Auth services (shared by all source integrations)
        let tokens = TokenStorage()
        self.tokenStorage = tokens
        let oauth = OAuthManager()
        self.oauthManager = oauth
        let accessStatus = await MainActor.run { TokenAccessStatus() }
        self.tokenAccessStatus = accessStatus
        let tokenRefresh = TokenRefreshService(
            tokenStorage: tokens,
            oauthManager: oauth,
            accessStatus: accessStatus
        )
        self.tokenRefreshService = tokenRefresh

        // Register + start proactive token refresh for SoundCloud (SCDL-05).
        // Without this, tokens are never refreshed in the background and
        // users are forced to reconnect after every restart.
        await Self.configureSoundCloudTokenRefresh(
            tokenRefresh,
            clientId: CredentialsLoader.credential(key: "SOUNDCLOUD_CLIENT_ID") ?? "",
            clientSecret: CredentialsLoader.credential(key: "SOUNDCLOUD_CLIENT_SECRET")
        )

        // Unified Search Service
        let scClient = SoundCloudClient(
            tokenStorage: tokens,
            oauthManager: oauth,
            trackRepository: self.trackRepository!,
            sourceRepository: self.sourceRepository!,
            playlistRepository: self.playlistRepository
        )
        self.soundCloudClient = scClient
        let dab = DABClient(tokenStorage: tokens)
        let squid = SquidWtfClient()
        let ytDownloader = YouTubeDownloader()
        let searchService = UnifiedSearchService(
            dabClient: dab,
            squidClient: squid,
            soundCloudClient: scClient,
            youtubeDownloader: ytDownloader
        )
        self.unifiedSearchService = searchService
        UnifiedSearchService.shared = searchService

        // Shared ViewModels
        self.playbackViewModel = PlaybackViewModel(
            audioPlayer: player,
            configRepository: self.configRepository,
            waveformCacheDirectory: library.namespacedCacheDirectory(in: ActiveLibrary.defaultWaveformCacheRoot)
        )

        // Library VM — owned by the container so it survives view teardown.
        if let trackRepo = self.trackRepository, let cfRepo = self.configRepository {
            await MainActor.run {
                self.libraryViewModel = LibraryViewModel(
                    trackRepository: trackRepo,
                    configRepository: cfRepo
                )
            }
        }

        // Media-key + Now Playing bridge, and headphone auto-pause/resume.
        // Both services need the PlaybackViewModel and must run on the
        // main actor (MPRemoteCommandCenter registration and CoreAudio
        // listener installation both touch UI-adjacent state).
        if let playbackVM = self.playbackViewModel {
            await MainActor.run {
                let remote = RemoteCommandService()
                remote.start(viewModel: playbackVM)
                self.remoteCommandService = remote

                let monitor = OutputDeviceMonitor()
                monitor.start(viewModel: playbackVM)
                self.outputDeviceMonitor = monitor
            }
        }

        // Activity (W3-ACT): this library's history of operations (v46), and which failed
        // downloads still fail (the `Download failed` scope's own predicate).
        let activityRepository = ActivityOperationRepository(database: dbPool)
        await ActivityCenter.shared.attachLibrary(id: library.libraryId, store: activityRepository,
                                                  failureSource: activityRepository)

        self.downloadViewModel = DownloadViewModel(
            trackRepository: self.trackRepository,
            sourceRepository: self.sourceRepository,
            activity: .shared
        )
        let downloads = self.downloadViewModel
        // `Retry All` for failures restored from the history (no job of this session behind them).
        await MainActor.run {
            ActivityCenter.shared.retryHandler = { ids in Task { await downloads?.retryAllFailed(trackIds: ids) } }
        }

        // Phase 36 — Playlist cover orchestrator. Observes `.playlistDidChange`
        // and regenerates auto covers. Mirrors the existing service-init pattern.
        // PlaylistCoverService is `@MainActor`, so construction must hop to the
        // main actor (matches the libraryRootObserver-init pattern below).
        if let plRepo = self.playlistRepository,
           let trRepo = self.trackRepository,
           let cfRepo = self.configRepository {
            self.playlistCoverService = await MainActor.run {
                PlaylistCoverService(
                    database: dbPool,
                    playlistRepository: plRepo,
                    trackRepository: trRepo,
                    configRepository: cfRepo,
                    coversDirectory: dbManager.playlistCoversDirectory
                )
            }
        }

        // Phase 37 — Artwork backfill orchestrator. Observes `.libraryDidImport`
        // and extracts embedded artwork for imported tracks in a background TaskGroup.
        // configRepository is required to resolve organizedPath (relative) to an absolute URL.
        if let trRepo = self.trackRepository,
           let aRepo = self.analysisRepository,
           let cfRepo = self.configRepository {
            self.artworkBackfillService = await MainActor.run {
                ArtworkBackfillService(
                    database: dbPool,
                    trackRepository: trRepo,
                    analysisRepository: aRepo,
                    configRepository: cfRepo
                )
            }
        }

        // A2 — Backup service. Creates, lists, prunes, and restores backup bundles.
        if let cfRepo = self.configRepository {
            let pool = dbManager.pool
            let service = BackupService(
                database: pool,
                databasePath: dbManager.databasePath,
                coversDirectory: dbManager.playlistCoversDirectory,
                configRepository: cfRepo,
                poolCloser: { try pool.close() }
            )
            self.backupService = service
            // Launch-throttled backup (at most once per 24 h). Failure is logged, never fatal.
            // Activity: a quiet, automatic `Backup (scheduled)` — no toolbar text while it runs;
            // its result is the popover's `Last backup` line; a failure needs attention.
            Task.detached {
                await service.ensureDefaultDestinationExists()
                let job = ActivityCenter.shared.begin(
                    .backup, title: "Backup (scheduled)", subject: .settings(.backup),
                    automatic: true, graceful: true, quiet: true)
                do {
                    if let info = try await service.createBackupIfDue() {
                        AppLogger.shared.info("Launch backup created: \(info.url.lastPathComponent)", source: "Backup")
                        job.finish(.backup(info))
                    } else {
                        // Not due: nothing happened, nothing to keep.
                        job.discard()
                    }
                } catch {
                    AppLogger.shared.error("Launch backup failed: \(error.localizedDescription)", source: "Backup")
                    job.fail(cause: error.localizedDescription, fix: .openSettings(SettingsTab.backup.rawValue))
                }
            }
        }

        // SyncViewModel — held in container so navigating away from the
        // Sync tab and back doesn't tear down + re-init the service stack.
        if let trackRepo = self.trackRepository,
           let syncRepo = self.syncRepository,
           let configRepo = self.configRepository {
            let customPath = try? await configRepo.getTranscodeCachePath()
            let cacheDir: URL
            if let customPath = customPath, !customPath.isEmpty {
                cacheDir = URL(fileURLWithPath: customPath)
            } else {
                cacheDir = library.namespacedCacheDirectory(in: ActiveLibrary.defaultTranscodeCacheRoot)
            }
            let cache = TranscodeCache(cacheDir: cacheDir)
            self.transcodeCache = cache
            let syncSvc = SyncService(
                trackRepository: trackRepo,
                syncRepository: syncRepo,
                configRepository: configRepo,
                transcodeCache: cache
            )
            // One Activity operation per sync (W3-ACT).
            syncSvc.activity = .shared
            self.syncViewModel = SyncViewModel(syncRepository: syncRepo, syncService: syncSvc)
            // Pre-load profiles to ensure context menus have access from launch
            Task {
                await self.syncViewModel?.loadProfiles()
            }
        }

        // WP4 — Playlist ingest service (device → MLM m3u8 import with diff preview)
        if let trackRepo = self.trackRepository,
           let playlistRepo = self.playlistRepository {
            let ingestSvc = PlaylistIngestService(
                trackRepository: trackRepo,
                playlistRepository: playlistRepo,
                database: dbPool
            )
            self.playlistIngestService = ingestSvc
            // Wire into SyncViewModel for device scan (Trigger B)
            self.syncViewModel?.setIngestService(ingestSvc)
        }

        // Check if library root is configured
        if let root = try await configRepository?.getLibraryRoot(), !root.isEmpty {
            // Start the mount observer for the library's disk (window-level drive state).
            await MainActor.run { self.applyLibraryRoot(root) }

            // Configure download orchestrator
            downloadViewModel?.configure(libraryRoot: root, tokenStorage: tokens)
        }

        // Persisted availability (W2-A): checks files on open, after scans, mounts and
        // downloads — only while the library folder is reachable.
        if let trackRepo = self.trackRepository, let cfRepo = self.configRepository {
            let reconciler = TrackAvailabilityReconciler(repository: trackRepo)
            let previous = self.availabilityMonitor
            self.availabilityMonitor = await MainActor.run {
                // A second `initialize` (another library) must not leave the old one running.
                previous?.stop()
                let monitor = LibraryAvailabilityMonitor(
                    reconciler: reconciler,
                    repository: trackRepo,
                    libraryRoot: { (try? await cfRepo.getLibraryRoot()) ?? nil }
                )
                monitor.start()
                return monitor
            }
        }

        // Tag writes waiting for the library folder (W2-E): flush on open, mount, folder change.
        await MainActor.run {
            TagWriteQueue.shared.start(.live())
            // `3 tag changes waiting for “Lexxar”` in Activity while the drive is away (W3-ACT).
            TagWriteWaitActivity.shared.start()
        }

        // Reconfigure the download pipeline whenever the library root is
        // changed at runtime (e.g. from the First-Run Wizard or Settings).
        libraryRootObserver = NotificationCenter.default.addObserver(
            forName: .libraryRootDidChange,
            object: nil,
            queue: .main
        ) { notification in
            let newRoot = (notification.userInfo?["path"] as? String) ?? ""
            guard !newRoot.isEmpty else { return }
            Task { @MainActor in
                // The drive state follows a folder chosen after launch (fixes PP-SHELL-10/11).
                DependencyContainer.shared.applyLibraryRoot(newRoot)
                guard let tokens = DependencyContainer.shared.tokenStorage else { return }
                DependencyContainer.shared.downloadViewModel?.configure(
                    libraryRoot: newRoot,
                    tokenStorage: tokens
                )
                AppLogger.shared.info(
                    "Download pipeline reconfigured for new library root: \(newRoot)",
                    source: "Download"
                )
            }
        }

        isInitialized = true
        AppLogger.shared.info(
            "App initialized — DB at \(dbManager.databasePath.path)",
            source: "boot"
        )
    }

    /// Points the drive state at `root` — at launch and whenever the library folder is set or
    /// changed later (`.libraryRootDidChange`; before W2-A the observer was created only at
    /// launch, PP-SHELL-10/11). Replaces the mount observer, so `LibraryDriveState` (which
    /// reads `mountObserver`) follows. A folder on the Mac's own disk is always connected.
    /// No mount/unmount notification is posted: choosing another folder is not a disk event.
    ///
    /// - Parameter startMonitoring: `false` in tests (no DiskArbitration session).
    @MainActor
    func applyLibraryRoot(_ root: String?, startMonitoring: Bool = true) {
        let trimmed = root?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let current = mountObserver {
            if current.watchedLibraryRoot == trimmed {
                isLibraryDriveMounted = current.checkMountStatus()
                return
            }
            // `stop()` unregisters and drains its callbacks, so it can go at once.
            current.stop()
        }
        guard !trimmed.isEmpty else {
            mountObserver = nil
            hasLibraryRoot = false
            isLibraryDriveMounted = true
            return
        }
        let observer = MountObserver(libraryRoot: trimmed)
        mountObserver = observer
        hasLibraryRoot = true
        isLibraryDriveMounted = observer.isLibraryMounted
        if startMonitoring { observer.start() }
    }

    /// Relocates the transcode cache folder to a new path in the background.
    ///
    /// Activity (W3-ACT): `Move transcode cache to “‹folder›”` with its **own** Cancel — it stops
    /// after the current file and moves what was moved back, so the cache stays in one place
    /// (fixes PP-ACTIVITY-02: the old Cancel cancelled a sync instead). The new folder is used
    /// only when every file arrived.
    func relocateTranscodeCache(to newPath: String) {
        guard let transcodeCache = self.transcodeCache, let configRepo = self.configRepository else { return }

        let oldDir = transcodeCache.cacheDir.standardizedFileURL
        let newDir = URL(fileURLWithPath: newPath).standardizedFileURL

        if oldDir == newDir {
            AppLogger.shared.info("Cache migration: The new path is already in use. No action is required.", source: "Sync")
            return
        }

        let stop = CacheMoveCancellation()
        let job = ActivityCenter.shared.begin(
            .transcodeCacheMove, title: "Move transcode cache to “\(newDir.lastPathComponent)”",
            subject: .settings(.maintenance), itemNoun: .file,
            controls: ActivityControls(cancelStyle: .afterThisFile, cancel: { stop.cancel() },
                                       runAgain: { [weak self] in self?.relocateTranscodeCache(to: newPath) })
        )

        Task.detached {
            AppLogger.shared.info("Cache migration: Moving transcode cache from \(oldDir.path) to \(newDir.path)", source: "Sync")
            let outcome = await TranscodeCacheMove.run(from: oldDir, to: newDir, isCancelled: { stop.isCancelled },
                                                       progress: { done, total, name in
                job.update(completed: done, total: total, currentItem: name)
            })
            switch outcome {
            case .moved(let count):
                transcodeCache.updateCacheDir(to: newDir)
                do {
                    try await configRepo.setTranscodeCachePath(newPath)
                    AppLogger.shared.info("Cache migration complete. Moved \(count) files and removed the old cache.", source: "Sync")
                    job.finish(ActivityResult(counts: [ActivityCount(.done, count, "moved")]))
                } catch {
                    job.fail(cause: "The new folder couldn’t be saved — \(error.localizedDescription)", fix: .runAgain)
                }
            case .cancelled(let movedBack):
                AppLogger.shared.info("Cache migration cancelled; \(movedBack) files moved back.", source: "Sync")
                job.cancelled(ActivityResult(summary: "The cache stays in “\(oldDir.lastPathComponent)”"))
            case .failed(let message, let movedBack):
                AppLogger.shared.error("Cache migration failed: \(message) (\(movedBack) files moved back)", source: "Sync")
                job.fail(cause: message, fix: .runAgain)
            }
        }
    }
}

/// Thread-safe stop flag of a transcode-cache move.
final class CacheMoveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Moves the transcode cache's files one by one; on cancel or failure it moves the moved ones
/// back, so the cache is never split between two folders.
enum TranscodeCacheMove {
    enum Outcome: Equatable {
        case moved(Int)
        case cancelled(movedBack: Int)
        case failed(String, movedBack: Int)
    }

    static func run(from oldDir: URL, to newDir: URL, fileManager: FileManager = .default,
                    isCancelled: () -> Bool, progress: (Int, Int, String) -> Void) async -> Outcome {
        var moved: [(from: URL, to: URL)] = []
        func moveBack() -> Int {
            var count = 0
            for pair in moved.reversed() {
                try? fileManager.removeItem(at: pair.from)
                if (try? fileManager.moveItem(at: pair.to, to: pair.from)) != nil { count += 1 }
            }
            return count
        }
        do {
            try fileManager.createDirectory(at: newDir, withIntermediateDirectories: true)
            let files = try fileManager.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "m4a" }
            for (index, file) in files.enumerated() {
                if isCancelled() { return .cancelled(movedBack: moveBack()) }
                progress(index, files.count, file.lastPathComponent)
                let target = newDir.appendingPathComponent(file.lastPathComponent)
                try? fileManager.removeItem(at: target)
                try fileManager.copyItem(at: file, to: target)
                try fileManager.removeItem(at: file)
                moved.append((file, target))
            }
            return .moved(files.count)
        } catch {
            return .failed(error.localizedDescription, movedBack: moveBack())
        }
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var container: DependencyContainer = .shared
}
