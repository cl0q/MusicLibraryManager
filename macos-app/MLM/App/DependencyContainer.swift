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

        // Auth services (shared by all source integrations)
        let tokens = TokenStorage()
        self.tokenStorage = tokens
        let oauth = OAuthManager()
        self.oauthManager = oauth
        let tokenRefresh = TokenRefreshService(tokenStorage: tokens, oauthManager: oauth)
        self.tokenRefreshService = tokenRefresh

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

        // SyncViewModel — held in container so navigating away from the
        // Sync tab and back doesn't tear down + re-init the service stack.
        if let trackRepo = self.trackRepository,
           let syncRepo = self.syncRepository,
           let configRepo = self.configRepository {
            let cacheDir = FileManager.default
                .urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("com.mlm.transcode_cache")
            let cache = TranscodeCache(cacheDir: cacheDir)
            let syncSvc = SyncService(
                trackRepository: trackRepo,
                syncRepository: syncRepo,
                configRepository: configRepo,
                transcodeCache: cache
            )
            self.syncViewModel = SyncViewModel(syncRepository: syncRepo, syncService: syncSvc)
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
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var container: DependencyContainer = .shared
}
