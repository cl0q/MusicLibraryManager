import Foundation
import GRDB
@testable import MLM

/// A destination whose "device" can be removed and connected again by script — no real device,
/// no `/Volumes` (W3-SYNC tests).
final class ScriptedDestinations: SyncDestinationChecking, @unchecked Sendable {
    private let lock = NSLock()
    /// `true` answers left before the device "disconnects" (`nil` = never).
    private var allowance: Int?
    private var connected = true
    private(set) var waits = 0
    var libraryReachable = true
    /// Called (off the main actor) while the sync waits for the device; returns whether the
    /// device is connected again afterwards.
    var onWait: (@Sendable (Int) async -> Bool)?

    init(disconnectAfter allowance: Int? = nil) {
        self.allowance = allowance
    }

    func isDestinationReachable(_ path: String) -> Bool {
        lock.withLock {
            guard connected else { return false }
            if let left = allowance {
                if left <= 0 {
                    connected = false
                    allowance = nil
                    return false
                }
                allowance = left - 1
            }
            return true
        }
    }

    func isLibraryReachable(_ libraryRoot: String) -> Bool { lock.withLock { libraryReachable } }

    func waitBeforeRecheck() async throws {
        let count = lock.withLock { waits += 1; return waits }
        let back = await onWait?(count) ?? true
        lock.withLock { if back { connected = true } }
    }

    func disconnect() { lock.withLock { connected = false } }
}

/// A temporary library folder, device folders and database with one sync service.
@MainActor
final class SyncTestEnv {
    let db: DatabaseQueue
    let root: URL
    let library: URL
    let sync: SyncRepository
    let tracks: TrackRepository
    let playlists: PlaylistRepository
    let results: SyncProfileResultRepository
    let service: SyncService
    let destinations: ScriptedDestinations
    let notifications = NotificationCenter()
    let undoManager = UndoManager()
    let status: StatusBarCenter
    let undo: UndoCenter
    let edits: ShellEdits

    init(destinations: ScriptedDestinations = ScriptedDestinations()) async throws {
        db = try DatabaseManager.inMemory()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("w3sync_\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        sync = SyncRepository(database: db)
        tracks = TrackRepository(database: db)
        playlists = PlaylistRepository(database: db)
        results = SyncProfileResultRepository(database: db)
        let config = ConfigRepository(database: db)
        try await config.setLibraryRoot(library.path)
        service = SyncService(trackRepository: tracks, syncRepository: sync, configRepository: config,
                              transcodeCache: TranscodeCache(cacheDir: root.appendingPathComponent("cache")))
        service.results = results
        self.destinations = destinations
        service.destinations = destinations
        undoManager.groupsByEvent = false
        // Messages stay until replaced (a sleep that never ends; the test never waits on it).
        status = StatusBarCenter(sleep: { _ in try await Task.sleep(for: .seconds(3600)) }, announce: { _ in })
        undo = UndoCenter(undoManager: undoManager, statusBar: status, log: { _ in })
        let sync = self.sync
        let playlists = self.playlists
        edits = ShellEdits(dependencies: .init(playlists: { playlists }, syncProfiles: { sync },
                                               syncProfileDidChange: { _ in }),
                           undo: undo, window: ShellWindowModels(statusBar: status))
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    /// A device folder (a plain temporary folder).
    func device(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("Devices").appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func profile(_ name: String, device: URL, generateM3U8: Bool = false) async throws -> SyncProfile {
        let profile = try await sync.create(name: name, outputFolder: device.path)
        try await sync.updateSettings(profileId: profile.id!, generateM3U8: generateM3U8,
                                      transcodeMode: TranscodeMode.keepOriginals.rawValue)
        return try await sync.fetch(id: profile.id!)!
    }

    /// A downloaded track with a real file in the library folder.
    @discardableResult
    func localTrack(_ id: Int64, title: String, artist: String = "Artist") throws -> URL {
        let relative = "\(artist)/\(title).mp3"
        let file = library.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio-\(id)".utf8).write(to: file)
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, organized_path, date_added, duration)
                VALUES (?, ?, ?, '', ?, 'mp3', ?, ?, '2026-01-01T00:00:00Z', 180)
            """, arguments: [id, artist, artist, title, file.path, relative])
        }
        return file
    }

    /// A track that was never downloaded (no file).
    func remoteTrack(_ id: Int64, title: String, artist: String = "Artist", failed: Bool = false) throws {
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, date_added, download_failure)
                VALUES (?, ?, ?, '', ?, 'mp3', 'remote:' || ?, '2026-01-01T00:00:00Z', ?)
            """, arguments: [id, artist, artist, title, id, failed ? "{}" : nil])
        }
    }

    func add(_ trackIDs: [Int64], to profile: SyncProfile) async throws {
        for id in trackIDs { try await sync.addTrack(profileId: profile.id!, trackId: id) }
    }

    func syncedTrackIDs(_ profile: SyncProfile) async throws -> Set<Int64> {
        Set(try await sync.fetchSyncState(profileId: profile.id!).map(\.trackId))
    }

    func files(in device: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: device.path) else { return [] }
        return (enumerator.allObjects as? [String] ?? []).filter { $0.hasSuffix(".mp3") }.sorted()
    }

    /// A view model on this environment (its own notification center; nothing reads `.default`).
    func viewModel() -> SyncViewModel {
        let vm = SyncViewModel(syncRepository: sync, syncService: service, resultRepository: results,
                               notificationCenter: notifications, workspaceCenter: NotificationCenter())
        let edits = self.edits
        let status = self.status
        vm.edits = { edits }
        vm.statusBar = { status }
        vm.libraryDrive = { LibraryDriveState(volumeName: nil, isConnected: true) }
        vm.playlistRepository = { [playlists] in playlists }
        vm.destinationStatus = { FileManager.default.fileExists(atPath: $0) ? .connected : .notConnected }
        vm.editDebounce = .zero
        vm.backgroundDebounce = .zero
        return vm
    }
}
