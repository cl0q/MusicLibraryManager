import Foundation

/// Where MLM keeps its files. Optional entries are locations that may not be configured.
struct DataLocations: Sendable, Equatable {
    /// `nil` while no library is open (the per-library rows are dimmed, UC-WIN-05).
    var database: URL?
    var playlistCovers: URL?
    var credentialsFile: URL
    var transcodeCache: URL?
    var libraryFolder: URL?
    /// The open library file (A3); `nil` while the pre-A3 layout is in use.
    var libraryFile: URL? = nil
    /// `libraries.json` — the list of libraries on this Mac (ST-STORAGE.N02).
    var libraryList: URL? = nil
    /// Artwork and waveform caches (can be rebuilt); the first is the one `Show in Finder` opens.
    var caches: [URL] = []
    /// Backups and records of organised-path migrations.
    var pathMigrations: URL? = nil
    /// The log file (`Show in Finder` selects it; its folder with the rotated logs is measured).
    var logFile: URL? = nil
    /// `legacy-adopted-…` folders kept after library file setup (can be deleted).
    var previousInstalls: [URL] = []
}

/// One part of a storage bar (ST-STORAGE.N01).
struct StorageSegment: Identifiable, Equatable, Sendable {
    let name: String
    let bytes: Int64
    var id: String { name }
}

/// Whether a folder can be reached now, in the words Settings uses for every location
/// (UC §15.2, DEC-014): the library folder, the backup folder, the transcode cache.
enum LocationReach: Equatable, Sendable {
    /// On the Mac's own disk and present.
    case onThisMac
    /// On a mounted volume (`/Volumes/<name>`) and present.
    case connected(volume: String)
    /// Its volume is not mounted.
    case notConnected(volume: String)
    /// Its volume is there but the folder isn't (`Not found` — not a drive state, IMP-024).
    case notFound
    /// No folder configured.
    case notSet

    static func of(_ url: URL?, isVolumeMounted: (URL) -> Bool, exists: (URL) -> Bool) -> LocationReach {
        guard let url else { return .notSet }
        let volume = MountObserver.extractVolumePath(from: url.path).map { URL(fileURLWithPath: $0).lastPathComponent }
        if let volume, !isVolumeMounted(url) { return .notConnected(volume: volume) }
        guard exists(url) else { return .notFound }
        return volume.map { .connected(volume: $0) } ?? .onThisMac
    }

    var isReachable: Bool {
        switch self {
        case .onThisMac, .connected: true
        case .notConnected, .notFound, .notSet: false
        }
    }

    /// `Connected · on “Lexxar”` · `Not connected — on “Lexxar”` · `Not found` ·
    /// `Connected — on this Mac` · `No library folder set` (only for the library folder).
    var text: String {
        switch self {
        case .onThisMac: "Connected — on this Mac"
        case .connected(let volume): "Connected · on “\(volume)”"
        case .notConnected(let volume): "Not connected — on “\(volume)”"
        case .notFound: "Not found"
        case .notSet: "No library folder set"
        }
    }

    /// Symbol for the state (orange/red tint only for the failures, UC-COLOR-05).
    var systemImage: String {
        switch self {
        case .onThisMac, .connected: "checkmark.circle"
        case .notConnected: "externaldrive.badge.xmark"
        case .notFound: "questionmark.folder"
        case .notSet: "folder.badge.questionmark"
        }
    }
}

/// What the Backup tab knows about the backup folder.
struct BackupStatus: Sendable, Equatable {
    var destination: URL?
    var count: Int
    var lastBackupDate: Date?
}

/// A library folder size the user calculated, kept until the next calculation.
struct LibrarySizeRecord: Sendable, Equatable {
    var bytes: Int64
    var calculatedAt: Date
    /// Path of the library folder that was measured; a different folder discards the record.
    var root: String
}

/// Persistence for `LibrarySizeRecord`.
struct LibrarySizeStore: Sendable {
    var load: @Sendable () async -> LibrarySizeRecord?
    var save: @Sendable (LibrarySizeRecord) async throws -> Void

    private static let bytesKey = "library_size_bytes"
    private static let dateKey = "library_size_calculated_at"
    private static let rootKey = "library_size_root"

    /// Stores the record in `app_config`.
    static func config(_ repository: ConfigRepository) -> LibrarySizeStore {
        LibrarySizeStore(
            load: {
                guard let bytes = (try? await repository.get(key: bytesKey)).flatMap({ $0 }).flatMap(Int64.init),
                      let date = (try? await repository.get(key: dateKey)).flatMap({ $0 }).flatMap(Double.init),
                      let root = (try? await repository.get(key: rootKey)).flatMap({ $0 }) else {
                    return nil
                }
                return LibrarySizeRecord(bytes: bytes, calculatedAt: Date(timeIntervalSince1970: date), root: root)
            },
            save: { record in
                try await repository.set(key: bytesKey, value: String(record.bytes))
                try await repository.set(key: dateKey, value: String(record.calculatedAt.timeIntervalSince1970))
                try await repository.set(key: rootKey, value: record.root)
            }
        )
    }
}

/// Outcome of measuring the library folder.
enum LibrarySizeResult: Sendable, Equatable {
    case measured(Int64)
    case cancelled
    case failed
}

/// View model for Settings → Storage Location.
///
/// Lists every place MLM keeps files with existence, sizes and the backup status. Everything
/// that touches the filesystem or the container is injected, so tests run on temp dirs only.
/// The library folder is never measured by `refresh()` — only by `calculateLibrarySize()`.
@MainActor
@Observable
final class DataLocationsViewModel {

    enum Location: CaseIterable, Sendable {
        case libraryFile
        case database
        case playlistCovers
        case backups
        case credentialsFile
        case libraryFolder
        case transcodeCache
        case libraryList
        case caches
        case pathMigrations
        case logs
    }

    enum LocationState: Equatable, Sendable {
        case available
        case notFound
        case notConnected
        /// No path configured (library folder without a library root).
        case notSet
    }

    struct LocationRow: Equatable, Sendable {
        var url: URL?
        var state: LocationState
        var sizeBytes: Int64?
        var itemCount: Int?

        var canShowInFinder: Bool { url != nil && state == .available }
    }

    /// Binding UI copy (UI-GROUNDTRUTH §3.14 / §5.6, Storage Location tab).
    enum Copy {
        static let notLoaded = "Storage locations are shown once the library has loaded."
        static let notFound = "Not found"
        static let notConnected = "Not connected"
        static let noLibraryFolder = "No library folder set — choose one in the Library tab."
        static let calculating = "Calculating…"
        static let sizeNotCalculated = "Size not calculated"
        static let sizeFailed = "The size couldn't be calculated. Check that the drive is connected and try again."
        static let storedInKeychain = "Stored in the macOS Keychain"
        static let never = "Never"
        static let backupHint = "Change the backup folder in the Backup tab."
        static let transcodeHint = "Change the location in the Maintenance tab."
        static let recentChangesHelp = "Recent changes are kept in a separate file (-wal) and merged into the database automatically."
        static let footer = "Library files and the credentials file remain on your Mac if you delete the app. Audio files are never moved by this tab."
        static let refreshNote = "Sizes refresh when this tab opens and when a drive is connected."
    }

    // MARK: - State

    private(set) var rows: [Location: LocationRow] = [:]
    private(set) var databaseFileBytes: Int64?
    private(set) var walBytes: Int64?
    private(set) var shmBytes: Int64?
    private(set) var backupCount = 0
    private(set) var lastBackupDate: Date?
    private(set) var trackCount: Int?
    /// Stored size of the current library folder; `nil` when never calculated or the folder changed.
    private(set) var librarySize: LibrarySizeRecord?
    private(set) var isMeasuring = false
    private(set) var isCalculatingLibrarySize = false
    private(set) var errorMessage: String?
    /// `legacy-adopted-…` folders with their sizes.
    private(set) var previousInstalls: [LocationRow] = []
    /// Capacity of the library folder's volume, when it is reachable.
    private(set) var volumeCapacity: VolumeCapacity?

    @ObservationIgnored private var librarySizeTask: Task<LibrarySizeResult, Never>?

    // MARK: - Dependencies

    private let locations: @Sendable () async -> DataLocations
    private let backupStatus: @Sendable () async -> BackupStatus
    private let countTracks: @Sendable () async -> Int?
    private let sizeStore: LibrarySizeStore
    private let isVolumeMounted: @Sendable (URL) -> Bool
    private let measureLibrary: @Sendable (URL) -> LibrarySizeResult
    private let now: @Sendable () -> Date

    init(
        locations: @escaping @Sendable () async -> DataLocations,
        backupStatus: @escaping @Sendable () async -> BackupStatus,
        countTracks: @escaping @Sendable () async -> Int?,
        sizeStore: LibrarySizeStore,
        isVolumeMounted: @escaping @Sendable (URL) -> Bool = { DataLocationsViewModel.isVolumeMounted($0) },
        measureLibrary: @escaping @Sendable (URL) -> LibrarySizeResult = { DataLocationsViewModel.measureDirectory($0) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.locations = locations
        self.backupStatus = backupStatus
        self.countTracks = countTracks
        self.sizeStore = sizeStore
        self.isVolumeMounted = isVolumeMounted
        self.measureLibrary = measureLibrary
        self.now = now
    }

    func row(_ location: Location) -> LocationRow {
        rows[location] ?? LocationRow(url: nil, state: .notSet)
    }

    // MARK: - Actions

    /// Resolve every location and measure everything except the library folder.
    func refresh() async {
        isMeasuring = true
        defer { isMeasuring = false }

        let current = await locations()
        let backups = await backupStatus()
        let tracks = await countTracks()
        let stored = await sizeStore.load()
        let mounted = isVolumeMounted

        let measured = await Task.detached {
            Self.measure(current, backupFolder: backups.destination, isVolumeMounted: mounted)
        }.value

        rows = measured.rows
        previousInstalls = measured.previousInstalls
        volumeCapacity = measured.volumeCapacity
        databaseFileBytes = measured.databaseFileBytes
        walBytes = measured.walBytes
        shmBytes = measured.shmBytes
        backupCount = backups.count
        lastBackupDate = backups.lastBackupDate
        trackCount = tracks
        librarySize = stored.flatMap { record in
            record.root == current.libraryFolder?.path ? record : nil
        }
    }

    /// Measure the library folder on request and store the result. A cancelled or failed
    /// calculation keeps the previous value.
    func calculateLibrarySize() async {
        let library = row(.libraryFolder)
        guard !isCalculatingLibrarySize, library.state == .available, let root = library.url else { return }

        errorMessage = nil
        isCalculatingLibrarySize = true
        let measure = measureLibrary
        let task = Task.detached { measure(root) }
        librarySizeTask = task
        // Activity (W3-ACT): `Calculate storage sizes`, shown when slower than ~2 s; Cancel is real.
        let job = ActivityCenter.shared.begin(
            .storageSize, title: "Calculate storage sizes", subject: .settings(.storage),
            controls: ActivityControls(cancel: { task.cancel() }), graceful: true)
        let result = await task.value
        librarySizeTask = nil
        isCalculatingLibrarySize = false

        switch result {
        case .measured(let bytes):
            let record = LibrarySizeRecord(bytes: bytes, calculatedAt: now(), root: root.path)
            do {
                try await sizeStore.save(record)
                librarySize = record
                job.finish(ActivityResult(summary: "Library folder \(bytes.formatted(.byteCount(style: .file)))"))
            } catch {
                errorMessage = Copy.sizeFailed
                job.fail(cause: Copy.sizeFailed)
            }
        case .cancelled:
            job.cancelled()
        case .failed:
            errorMessage = Copy.sizeFailed
            job.fail(cause: Copy.sizeFailed)
        }
    }

    func cancelLibrarySizeCalculation() {
        librarySizeTask?.cancel()
    }

    // MARK: - Presentation

    /// Why a location can't be opened, or `nil` when it can.
    static func stateText(_ state: LocationState) -> String? {
        switch state {
        case .available: return nil
        case .notFound: return Copy.notFound
        case .notConnected: return Copy.notConnected
        case .notSet: return Copy.noLibraryFolder
        }
    }

    static func stateSymbol(_ state: LocationState) -> String? {
        switch state {
        case .available: return nil
        case .notFound: return "questionmark.folder"
        case .notConnected: return "externaldrive.badge.xmark"
        case .notSet: return "folder.badge.questionmark"
        }
    }

    static func formatBytes(_ bytes: Int64) -> String {
        BackupSettingsViewModel.formatBytes(bytes)
    }

    static func formatDate(_ date: Date) -> String {
        BackupSettingsViewModel.formatDate(date)
    }

    static func countText(_ count: Int, singular: String, plural: String) -> String {
        count == 1 ? "1 \(singular)" : "\(count.formatted()) \(plural)"
    }

    /// The `Library file` row only exists once the library lives in a library file.
    var showsLibraryFile: Bool { row(.libraryFile).url != nil }

    /// Total size of the library file.
    var libraryFileDetail: String? {
        let file = row(.libraryFile)
        guard file.state == .available, let size = file.sizeBytes else { return nil }
        return Self.formatBytes(size)
    }

    /// `‹total› · database file ‹size› · recent changes ‹size›`
    var databaseDetail: String? {
        guard let file = databaseFileBytes else { return nil }
        let wal = walBytes ?? 0
        let total = file + wal + (shmBytes ?? 0)
        return [
            Self.formatBytes(total),
            "database file \(Self.formatBytes(file))",
            "recent changes \(Self.formatBytes(wal))",
        ].joined(separator: " · ")
    }

    /// `‹n› files · ‹size›`
    var playlistCoversDetail: String? {
        let covers = row(.playlistCovers)
        guard covers.state == .available, let size = covers.sizeBytes else { return nil }
        return Self.countText(covers.itemCount ?? 0, singular: "file", plural: "files")
            + " · " + Self.formatBytes(size)
    }

    /// `‹n› backups · ‹size›`
    var backupsDetail: String? {
        let backups = row(.backups)
        guard backups.state == .available else { return nil }
        return Self.countText(backupCount, singular: "backup", plural: "backups")
            + " · " + Self.formatBytes(backups.sizeBytes ?? 0)
    }

    var lastBackupText: String {
        lastBackupDate.map(Self.formatDate) ?? Copy.never
    }

    var credentialsDetail: String? {
        let credentials = row(.credentialsFile)
        guard credentials.state == .available, let size = credentials.sizeBytes else { return nil }
        return Self.formatBytes(size)
    }

    var transcodeCacheDetail: String? {
        let cache = row(.transcodeCache)
        guard cache.state == .available, let size = cache.sizeBytes else { return nil }
        return Self.formatBytes(size)
    }

    /// `‹n› tracks`
    var trackCountText: String? {
        trackCount.map { Self.countText($0, singular: "track", plural: "tracks") }
    }

    /// `‹size› · calculated ‹date›` or `Size not calculated`.
    var librarySizeText: String {
        guard let librarySize else { return Copy.sizeNotCalculated }
        return "\(Self.formatBytes(librarySize.bytes)) · calculated \(Self.formatDate(librarySize.calculatedAt))"
    }

    // MARK: - Sizes chart (ST-STORAGE.N01)

    /// What MLM itself stores on this Mac, by kind (only parts with a size).
    var macSegments: [StorageSegment] {
        var parts: [StorageSegment] = []
        func add(_ name: String, _ bytes: Int64?) {
            if let bytes, bytes > 0 { parts.append(StorageSegment(name: name, bytes: bytes)) }
        }
        add("Library file", row(.libraryFile).sizeBytes ?? row(.database).sizeBytes)
        if let backups = row(.backups).url, MountObserver.extractVolumePath(from: backups.path) == nil {
            add("Backups", row(.backups).sizeBytes)
        }
        add("Caches", row(.caches).sizeBytes)
        add("Path migration backups", row(.pathMigrations).sizeBytes)
        let previous = previousInstalls.compactMap(\.sizeBytes).reduce(0, +)
        add("Previous install and logs", previous + (row(.logs).sizeBytes ?? 0))
        return parts
    }

    var macTotalBytes: Int64 { macSegments.map(\.bytes).reduce(0, +) }

    /// The library folder's volume: the library folder (when calculated), the transcode cache
    /// when it lives there, and everything else on it.
    var driveSegments: [StorageSegment] {
        guard let capacity = volumeCapacity else { return [] }
        var parts: [StorageSegment] = []
        var known: Int64 = 0
        if let size = librarySize?.bytes {
            parts.append(StorageSegment(name: "Library folder", bytes: size))
            known += size
        }
        let volume = row(.libraryFolder).url.flatMap { MountObserver.extractVolumePath(from: $0.path) }
        if let cache = row(.transcodeCache).url, let bytes = row(.transcodeCache).sizeBytes, bytes > 0,
           MountObserver.extractVolumePath(from: cache.path) == volume {
            parts.append(StorageSegment(name: "Transcode cache", bytes: bytes))
            known += bytes
        }
        parts.append(StorageSegment(name: "Other files", bytes: max(0, capacity.used - known)))
        return parts
    }

    /// `On “Lexxar”` / `On this Mac’s disk`.
    var driveTitle: String {
        guard let folder = row(.libraryFolder).url,
              let volume = LibraryDriveState.volumeName(fromVolumePath: MountObserver.extractVolumePath(from: folder.path))
        else { return "On this Mac’s disk" }
        return "On “\(volume)”"
    }

    /// `430 GB of 2 TB · 1.2 TB free`.
    var driveCapacityText: String? {
        volumeCapacity.map {
            "\(Self.formatBytes($0.used)) of \(Self.formatBytes($0.total)) · \(Self.formatBytes($0.available)) free"
        }
    }

    var canCalculateLibrarySize: Bool {
        !isCalculatingLibrarySize && row(.libraryFolder).state == .available
    }

    // MARK: - Filesystem (off the main actor)

    struct Measurement: Sendable {
        var rows: [Location: LocationRow]
        var databaseFileBytes: Int64?
        var walBytes: Int64?
        var shmBytes: Int64?
        var previousInstalls: [LocationRow] = []
        var volumeCapacity: VolumeCapacity?
    }

    /// Size and free space of a volume (`430 GB of 2 TB · 1.2 TB free`).
    struct VolumeCapacity: Equatable, Sendable {
        let total: Int64
        let available: Int64
        var used: Int64 { max(0, total - available) }
    }

    /// Existence and sizes for every location except the library folder, which only gets
    /// its state. Never reads file contents.
    nonisolated static func measure(
        _ locations: DataLocations,
        backupFolder: URL?,
        isVolumeMounted: (URL) -> Bool
    ) -> Measurement {
        func state(of url: URL?) -> LocationState {
            guard let url else { return .notSet }
            guard isVolumeMounted(url) else { return .notConnected }
            return FileManager.default.fileExists(atPath: url.path) ? .available : .notFound
        }

        func directoryRow(_ url: URL?, countItems: Bool = false) -> LocationRow {
            var row = LocationRow(url: url, state: state(of: url))
            if let url, row.state == .available {
                row.sizeBytes = measureBundles([url])[url]
                if countItems {
                    row.itemCount = (try? FileManager.default.contentsOfDirectory(
                        at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
                    ))?.count
                }
            }
            return row
        }

        var rows: [Location: LocationRow] = [:]

        if let libraryFile = locations.libraryFile {
            rows[.libraryFile] = directoryRow(libraryFile)
        }

        let database = locations.database
        var databaseRow = LocationRow(url: database, state: state(of: database))
        var databaseFileBytes: Int64?
        var walBytes: Int64?
        var shmBytes: Int64?
        if let database, databaseRow.state == .available {
            // Sidecars are suffixes of the full path, not path extensions.
            databaseFileBytes = fileSize(database)
            walBytes = fileSize(URL(fileURLWithPath: database.path + "-wal"))
            shmBytes = fileSize(URL(fileURLWithPath: database.path + "-shm"))
            databaseRow.sizeBytes = (databaseFileBytes ?? 0) + (walBytes ?? 0) + (shmBytes ?? 0)
        }
        rows[.database] = databaseRow

        rows[.playlistCovers] = directoryRow(locations.playlistCovers, countItems: true)
        var backupsRow = directoryRow(backupFolder)
        if backupFolder == nil { backupsRow.state = .notFound }
        rows[.backups] = backupsRow

        let credentials = locations.credentialsFile
        var credentialsRow = LocationRow(url: credentials, state: state(of: credentials))
        if credentialsRow.state == .available {
            credentialsRow.sizeBytes = fileSize(credentials)
        }
        rows[.credentialsFile] = credentialsRow

        var cacheRow = directoryRow(locations.transcodeCache)
        if locations.transcodeCache == nil { cacheRow.state = .notFound }
        rows[.transcodeCache] = cacheRow

        rows[.libraryFolder] = LocationRow(url: locations.libraryFolder, state: state(of: locations.libraryFolder))

        // This Mac (W3-SET, ST-STORAGE.N02/N03): the list of libraries, caches, migration
        // backups, logs and a kept previous install.
        if let list = locations.libraryList {
            var row = LocationRow(url: list, state: state(of: list))
            if row.state == .available { row.sizeBytes = fileSize(list) }
            rows[.libraryList] = row
        }
        let caches = locations.caches.filter { FileManager.default.fileExists(atPath: $0.path) }
        rows[.caches] = LocationRow(
            url: caches.first ?? locations.caches.first,
            state: caches.isEmpty ? .notFound : .available,
            sizeBytes: caches.isEmpty ? nil : measureBundles(caches).values.reduce(0, +))
        if let migrations = locations.pathMigrations {
            rows[.pathMigrations] = directoryRow(migrations)
        }
        if let log = locations.logFile {
            var row = LocationRow(url: log, state: state(of: log))
            if row.state == .available {
                let folder = log.deletingLastPathComponent()
                row.sizeBytes = measureBundles([folder])[folder]
            }
            rows[.logs] = row
        }
        let previous = locations.previousInstalls.map { directoryRow($0) }.filter { $0.state == .available }

        var capacity: VolumeCapacity?
        if let folder = locations.libraryFolder, rows[.libraryFolder]?.state == .available,
           let values = try? folder.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
           let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity {
            capacity = VolumeCapacity(total: Int64(total), available: Int64(available))
        }

        return Measurement(rows: rows, databaseFileBytes: databaseFileBytes, walBytes: walBytes, shmBytes: shmBytes,
                           previousInstalls: previous, volumeCapacity: capacity)
    }

    /// Logical size of a single file, or `nil` when it doesn't exist.
    nonisolated static func fileSize(_ url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    nonisolated static func measureBundles(_ urls: [URL]) -> [URL: Int64] {
        BackupSettingsViewModel.measureBundles(urls)
    }

    /// Allocated size of everything below `url`; stops early when the task is cancelled.
    /// Unreadable subfolders are skipped; the drive going away mid-way is a failure.
    nonisolated static func measureDirectory(_ url: URL) -> LibrarySizeResult {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else {
            return .failed
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if Task.isCancelled { return .cancelled }
            let values = try? file.resourceValues(forKeys: Set(keys))
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        if Task.isCancelled { return .cancelled }
        guard FileManager.default.fileExists(atPath: url.path) else { return .failed }
        return .measured(total)
    }

    /// A path below `/Volumes/<name>` is reachable only while that volume is mounted;
    /// anything else is on the startup disk.
    nonisolated static func isVolumeMounted(_ url: URL) -> Bool {
        guard let volume = MountObserver.extractVolumePath(from: url.path) else { return true }
        return FileManager.default.fileExists(atPath: volume)
    }
}

/// Dates in Settings (UC-COPY-10): `today, 09:14` · `yesterday, 18:02` · `4 Oct 2026, 08:57`.
enum SettingsDate {
    static func text(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "yesterday, \(time)"
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Sentence start: `Today, 09:14`.
    static func capitalized(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let text = self.text(date, now: now, calendar: calendar)
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}
