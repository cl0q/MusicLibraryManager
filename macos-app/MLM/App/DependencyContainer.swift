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

    // MARK: - State

    private(set) var isInitialized = false
    private(set) var initializationError: Error?

    // MARK: - Initialization

    private init() {}

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

        isInitialized = true
    }
}

// MARK: - Environment Key

extension EnvironmentValues {
    @Entry var container: DependencyContainer = .shared
}
