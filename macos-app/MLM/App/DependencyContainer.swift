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

    // MARK: - Repositories

    private(set) var trackRepository: TrackRepository?
    private(set) var playlistRepository: PlaylistRepository?
    private(set) var syncRepository: SyncRepository?
    private(set) var albumRepository: AlbumRepository?
    private(set) var sourceRepository: SourceRepository?
    private(set) var analysisRepository: AnalysisRepository?
    private(set) var configRepository: ConfigRepository?

    // MARK: - Services

    private(set) var importService: ImportService?
    private(set) var audioPlayer: AudioPlayer?
    private(set) var tokenStorage: TokenStorage?
    private(set) var oauthManager: OAuthManager?
    private(set) var tokenRefreshService: TokenRefreshService?
    private(set) var mountObserver: MountObserver?
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
    private(set) var transcodeCache: TranscodeCache?
    private(set) var unifiedSearchService: UnifiedSearchService?

    // MARK: - ViewModels (shared singletons)

    private(set) var playbackViewModel: PlaybackViewModel?
    private(set) var activityViewModel: ActivityViewModel?
    private(set) var downloadViewModel: DownloadViewModel?
    private(set) var syncViewModel: SyncViewModel?

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

    deinit {
        if let token = libraryRootObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Initialize the database and all repositories.
    ///
    /// Call once during app launch (from AppDelegate).
    /// Uses the shared database path so both Tauri and native app
    /// operate on the same SQLite file.
    func initialize() async throws {
        let dbManager = try DatabaseManager()
        self.databaseManager = dbManager

        let dbPool = dbManager.pool

        self.trackRepository = TrackRepository(database: dbPool)
        self.playlistRepository = PlaylistRepository(database: dbPool)
        self.syncRepository = SyncRepository(database: dbPool)
        self.albumRepository = AlbumRepository(database: dbPool)
        self.sourceRepository = SourceRepository(database: dbPool)
        self.analysisRepository = AnalysisRepository(database: dbPool)
        self.configRepository = ConfigRepository(database: dbPool)

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

        // Auth services (shared by all source integrations)
        let tokens = TokenStorage()
        self.tokenStorage = tokens
        let oauth = OAuthManager()
        self.oauthManager = oauth
        let tokenRefresh = TokenRefreshService(tokenStorage: tokens, oauthManager: oauth)
        self.tokenRefreshService = tokenRefresh

        // Unified Search Service
        let scClient = SoundCloudClient(
            tokenStorage: tokens,
            oauthManager: oauth,
            trackRepository: self.trackRepository!,
            sourceRepository: self.sourceRepository!,
            playlistRepository: self.playlistRepository
        )
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
            configRepository: self.configRepository
        )

        self.activityViewModel = ActivityViewModel()

        self.downloadViewModel = DownloadViewModel(
            trackRepository: self.trackRepository,
            sourceRepository: self.sourceRepository
        )

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
                    configRepository: cfRepo
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
                cacheDir = FileManager.default
                    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.mlm.transcode_cache")
            }
            let cache = TranscodeCache(cacheDir: cacheDir)
            self.transcodeCache = cache
            let syncSvc = SyncService(
                trackRepository: trackRepo,
                syncRepository: syncRepo,
                configRepository: configRepo,
                transcodeCache: cache
            )
            // Bridge sync progress into the global Operations panel.
            syncSvc.activityViewModel = self.activityViewModel
            self.syncViewModel = SyncViewModel(syncRepository: syncRepo, syncService: syncSvc)
            // Pre-load profiles to ensure context menus have access from launch
            Task {
                await self.syncViewModel?.loadProfiles()
            }
        }

        // Check if library root is configured
        if let root = try await configRepository?.getLibraryRoot(), !root.isEmpty {
            hasLibraryRoot = true

            // Start mount observer for external drives
            let mount = MountObserver(libraryRoot: root)
            self.mountObserver = mount
            mount.start()
            isLibraryDriveMounted = mount.isLibraryMounted

            // Configure download orchestrator
            downloadViewModel?.configure(libraryRoot: root, tokenStorage: tokens)
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

    /// Relocates the transcode cache folder to a new path in the background.
    ///
    /// Copies all existing cached .m4a files to the new folder, validates them,
    /// deletes the originals to save space, and updates the dynamic path in TranscodeCache & Database.
    func relocateTranscodeCache(to newPath: String) {
        guard let transcodeCache = self.transcodeCache, let configRepo = self.configRepository else { return }
        
        let oldDir = transcodeCache.cacheDir.standardizedFileURL
        let newDir = URL(fileURLWithPath: newPath).standardizedFileURL
        
        if oldDir == newDir {
            AppLogger.shared.info("Cache-Migration: Neuer Pfad entspricht dem aktuellen Pfad. Keine Aktion erforderlich.", source: "Sync")
            return
        }
        
        let activityVM = self.activityViewModel
        
        Task.detached {
            let opId = activityVM?.startOperation(
                type: .sync,
                title: "Cache-Migration: \(newDir.lastPathComponent)",
                detail: "Scanne alten Cache..."
            )
            AppLogger.shared.info("Cache-Migration: Starte Umzug des Transcode-Caches von \(oldDir.path) nach \(newDir.path)", source: "Sync")
            
            do {
                // Ensure new directory exists
                try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true)
                
                // Get all cache files
                let files = try FileManager.default.contentsOfDirectory(at: oldDir, includingPropertiesForKeys: nil)
                let m4aFiles = files.filter { $0.pathExtension.lowercased() == "m4a" }
                let total = m4aFiles.count
                
                AppLogger.shared.info("Cache-Migration: \(total) Dateien zum Verschieben gefunden.", source: "Sync")
                
                var completed = 0
                for fileURL in m4aFiles {
                    let targetURL = newDir.appendingPathComponent(fileURL.lastPathComponent)
                    
                    // Copy item
                    try? FileManager.default.removeItem(at: targetURL)
                    try FileManager.default.copyItem(at: fileURL, to: targetURL)
                    
                    // Delete original
                    try FileManager.default.removeItem(at: fileURL)
                    
                    completed += 1
                    let progress = Double(completed) / Double(max(total, 1))
                    
                    // Update progress in Operations tab
                    if let opId = opId {
                        activityVM?.updateProgress(
                            id: opId,
                            progress: progress,
                            detail: "[\(completed)/\(total)] verschoben..."
                        )
                    }
                    
                    // Periodically print progress in logs
                    if completed % 20 == 0 || completed == total {
                        AppLogger.shared.info("Cache-Migration: [\(completed)/\(total)] Dateien verschoben.", source: "Sync")
                    }
                }
                
                // Update active cache directory thread-safely
                transcodeCache.updateCacheDir(to: newDir)
                
                // Persist new cache path in the GRDB database
                try await configRepo.setTranscodeCachePath(newPath)
                
                // Complete background operation
                if let opId = opId {
                    activityVM?.completeOperation(id: opId, detail: "Erfolgreich! \(total) Cache-Dateien umgezogen.")
                }
                AppLogger.shared.info("Cache-Migration: Erfolgreich abgeschlossen. \(total) Dateien umgezogen, alter Cache gelöscht.", source: "Sync")
                
            } catch {
                AppLogger.shared.error("Cache-Migration: Fehler beim Umzug: \(error.localizedDescription)", source: "Sync")
                if let opId = opId {
                    activityVM?.failOperation(id: opId, error: error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var container: DependencyContainer = .shared
}
