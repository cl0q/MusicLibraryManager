import Testing
import Foundation
@testable import MLM

/// Tests for the Settings → Storage Location view model.
///
/// Temp-dir fixtures only: every location is a fake layout under a fresh temp dir and all
/// container lookups are stubs. The live install, the credentials file and the music drive
/// are never resolved, read or measured.
@Suite("DataLocationsViewModel (A1)", .serialized)
@MainActor
struct DataLocationsViewModelTests {

    // MARK: - Fixture

    private final class Box<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: Value
        init(_ value: Value) { _value = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    private struct Fixture {
        let root: URL
        let locations: DataLocations
        let backupsDir: URL
        let stored = Box<LibrarySizeRecord?>(nil)
        let measureCalls = Box(0)

        init() throws {
            let fm = FileManager.default
            root = fm.temporaryDirectory.appendingPathComponent("DataLocationsViewModelTests-\(UUID().uuidString)")
            try fm.createDirectory(at: root, withIntermediateDirectories: true)

            let support = root.appendingPathComponent("support")
            try fm.createDirectory(at: support, withIntermediateDirectories: true)
            let database = support.appendingPathComponent("music_library.db")
            try Data(count: 1000).write(to: database)
            try Data(count: 300).write(to: URL(fileURLWithPath: database.path + "-wal"))
            try Data(count: 32).write(to: URL(fileURLWithPath: database.path + "-shm"))

            let covers = support.appendingPathComponent("playlist-covers")
            try fm.createDirectory(at: covers, withIntermediateDirectories: true)
            try Data(count: 10).write(to: covers.appendingPathComponent("1.png"))
            try Data(count: 20).write(to: covers.appendingPathComponent("2.png"))

            backupsDir = root.appendingPathComponent("backups")
            try fm.createDirectory(at: backupsDir, withIntermediateDirectories: true)
            try Data(count: 50).write(to: backupsDir.appendingPathComponent("bundle.db"))

            let credentials = root.appendingPathComponent("MLM/.env")
            try fm.createDirectory(at: credentials.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(count: 42).write(to: credentials)

            let cache = root.appendingPathComponent("transcode")
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(count: 64).write(to: cache.appendingPathComponent("1.m4a"))

            let library = root.appendingPathComponent("Music")
            try fm.createDirectory(at: library, withIntermediateDirectories: true)
            try Data(count: 4096).write(to: library.appendingPathComponent("song.flac"))

            // W3-SET: the locations this Mac keeps (ST-STORAGE.N02/N03).
            let list = root.appendingPathComponent("libraries.json")
            try Data(count: 12).write(to: list)
            let artwork = root.appendingPathComponent("artwork_cache")
            try fm.createDirectory(at: artwork, withIntermediateDirectories: true)
            try Data(count: 100).write(to: artwork.appendingPathComponent("a.jpg"))
            let migrations = root.appendingPathComponent("PathMigrations")
            try fm.createDirectory(at: migrations, withIntermediateDirectories: true)
            try Data(count: 30).write(to: migrations.appendingPathComponent("m.json"))
            let logs = root.appendingPathComponent("Logs")
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            try Data(count: 50).write(to: logs.appendingPathComponent("mlm.log"))

            locations = DataLocations(
                database: database,
                playlistCovers: covers,
                credentialsFile: credentials,
                transcodeCache: cache,
                libraryFolder: library,
                libraryList: list,
                caches: [artwork, root.appendingPathComponent("waveforms-missing")],
                pathMigrations: migrations,
                logFile: logs.appendingPathComponent("mlm.log")
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }

        @MainActor
        func makeViewModel(
            locations: DataLocations? = nil,
            locationsBox: Box<DataLocations>? = nil,
            lastBackup: Date? = nil,
            backupDestination: URL?? = .none,
            isVolumeMounted: @escaping @Sendable (URL) -> Bool = { _ in true },
            measureLibrary: (@Sendable (URL) -> LibrarySizeResult)? = nil,
            saveFails: Bool = false,
            now: Date = Date(timeIntervalSince1970: 1_700_000_000)
        ) -> DataLocationsViewModel {
            let box = locationsBox ?? Box(locations ?? self.locations)
            let destination = backupDestination ?? backupsDir
            let stored = self.stored
            let calls = self.measureCalls
            let measure = measureLibrary ?? { url in DataLocationsViewModel.measureDirectory(url) }
            return DataLocationsViewModel(
                locations: { box.value },
                backupStatus: { BackupStatus(destination: destination, count: 3, lastBackupDate: lastBackup) },
                countTracks: { 12_935 },
                sizeStore: LibrarySizeStore(
                    load: { stored.value },
                    save: { record in
                        if saveFails { throw CocoaError(.fileWriteNoPermission) }
                        stored.value = record
                    }
                ),
                isVolumeMounted: isVolumeMounted,
                measureLibrary: { url in
                    calls.value += 1
                    return measure(url)
                },
                now: { now }
            )
        }
    }

    // MARK: - Refresh

    @Test func refreshFillsEveryRow() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = fx.makeViewModel()

        await vm.refresh()

        #expect(vm.row(.database).url == fx.locations.database)
        #expect(vm.row(.playlistCovers).url == fx.locations.playlistCovers)
        #expect(vm.row(.backups).url == fx.backupsDir)
        #expect(vm.row(.credentialsFile).url == fx.locations.credentialsFile)
        #expect(vm.row(.transcodeCache).url == fx.locations.transcodeCache)
        #expect(vm.row(.libraryFolder).url == fx.locations.libraryFolder)
        // Legacy-layout fixture: the library file row is covered by its own tests.
        for location in DataLocationsViewModel.Location.allCases where location != .libraryFile {
            #expect(vm.row(location).state == .available, "\(location)")
            #expect(vm.row(location).canShowInFinder, "\(location)")
        }

        #expect(vm.row(.credentialsFile).sizeBytes == 42)
        #expect(vm.row(.playlistCovers).itemCount == 2)
        #expect((vm.row(.playlistCovers).sizeBytes ?? 0) > 0)
        #expect((vm.row(.backups).sizeBytes ?? 0) > 0)
        #expect((vm.row(.transcodeCache).sizeBytes ?? 0) > 0)
        #expect(vm.trackCount == 12_935)
        #expect(vm.trackCountText == "12,935 tracks" || vm.trackCountText == "12.935 tracks")
        #expect(vm.backupCount == 3)
        #expect(vm.isMeasuring == false)
    }

    @Test func libraryFileRowIsMeasuredAsAWhole() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        var locations = f.locations
        let package = f.root.appendingPathComponent("Main Library.mlibm")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(count: 700).write(to: package.appendingPathComponent("music_library.db"))
        try Data(count: 100).write(to: package.appendingPathComponent("library.json"))
        locations.libraryFile = package

        let vm = f.makeViewModel(locations: locations)
        await vm.refresh()
        let row = vm.row(.libraryFile)
        #expect(row.state == .available)
        #expect(row.url == package)
        #expect((row.sizeBytes ?? 0) >= 800)
        #expect(vm.libraryFileDetail == DataLocationsViewModel.formatBytes(row.sizeBytes ?? 0))
        #expect(vm.showsLibraryFile)
    }

    @Test func legacyLayoutHasNoLibraryFileRow() async throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let vm = f.makeViewModel()
        await vm.refresh()
        #expect(!vm.showsLibraryFile)
        #expect(vm.libraryFileDetail == nil)
    }

    @Test func databaseSidecarsAreReportedSeparately() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = fx.makeViewModel()

        await vm.refresh()

        #expect(vm.databaseFileBytes == 1000)
        #expect(vm.walBytes == 300)
        #expect(vm.shmBytes == 32)
        #expect(vm.row(.database).sizeBytes == 1332)

        let detail = try #require(vm.databaseDetail)
        #expect(detail.contains("database file \(DataLocationsViewModel.formatBytes(1000))"))
        #expect(detail.contains("recent changes \(DataLocationsViewModel.formatBytes(300))"))
        #expect(detail.hasPrefix(DataLocationsViewModel.formatBytes(1332)))
    }

    @Test func missingLocationShowsNotFoundAndDisablesFinder() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        try FileManager.default.removeItem(at: fx.locations.credentialsFile)
        try FileManager.default.removeItem(at: fx.locations.playlistCovers!)
        let vm = fx.makeViewModel()

        await vm.refresh()

        for location in [DataLocationsViewModel.Location.credentialsFile, .playlistCovers] {
            let row = vm.row(location)
            #expect(row.state == .notFound)
            #expect(row.canShowInFinder == false)
            #expect(row.sizeBytes == nil)
            #expect(DataLocationsViewModel.stateText(row.state) == "Not found")
        }
        #expect(vm.credentialsDetail == nil)
        #expect(vm.playlistCoversDetail == nil)
    }

    @Test func unmountedLibraryShowsNotConnectedAndIsNotMeasured() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let library = try #require(fx.locations.libraryFolder)
        let vm = fx.makeViewModel(isVolumeMounted: { $0 != library })

        await vm.refresh()
        let row = vm.row(.libraryFolder)
        #expect(row.state == .notConnected)
        #expect(row.canShowInFinder == false)
        #expect(DataLocationsViewModel.stateText(row.state) == "Not connected")
        #expect(vm.canCalculateLibrarySize == false)

        await vm.calculateLibrarySize()
        #expect(fx.measureCalls.value == 0)
        #expect(vm.librarySize == nil)
    }

    @Test func missingLibraryRootShowsNotSet() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        var locations = fx.locations
        locations.libraryFolder = nil
        let vm = fx.makeViewModel(locations: locations)

        await vm.refresh()

        #expect(vm.row(.libraryFolder).state == .notSet)
        #expect(DataLocationsViewModel.stateText(.notSet) == "No library folder set — choose one in the Library tab.")
        #expect(vm.canCalculateLibrarySize == false)
    }

    @Test func refreshNeverMeasuresTheLibrary() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = fx.makeViewModel()

        await vm.refresh()
        await vm.refresh()

        #expect(fx.measureCalls.value == 0)
        #expect(vm.row(.libraryFolder).sizeBytes == nil)
        #expect(vm.librarySize == nil)
        #expect(vm.librarySizeText == "Size not calculated")
    }

    // MARK: - Backups

    @Test func lastBackupComesFromInjectedStatus() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let date = Date(timeIntervalSince1970: 1_750_000_000)

        let withBackup = fx.makeViewModel(lastBackup: date)
        await withBackup.refresh()
        #expect(withBackup.lastBackupDate == date)
        #expect(withBackup.lastBackupText == DataLocationsViewModel.formatDate(date))

        let never = fx.makeViewModel(lastBackup: nil)
        await never.refresh()
        #expect(never.lastBackupText == "Never")
        #expect(never.backupsDetail?.hasPrefix("3 backups · ") == true)
    }

    // MARK: - Library size

    @Test func calculateLibrarySizeStoresAndShowsResult() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let vm = fx.makeViewModel(measureLibrary: { _ in .measured(5_000_000) }, now: now)
        await vm.refresh()

        await vm.calculateLibrarySize()

        let library = try #require(fx.locations.libraryFolder)
        let expected = LibrarySizeRecord(bytes: 5_000_000, calculatedAt: now, root: library.path)
        #expect(fx.measureCalls.value == 1)
        #expect(fx.stored.value == expected)
        #expect(vm.librarySize == expected)
        #expect(vm.isCalculatingLibrarySize == false)
        #expect(vm.librarySizeText
            == "\(DataLocationsViewModel.formatBytes(5_000_000)) · calculated \(DataLocationsViewModel.formatDate(now))")

        // Shown again after a refresh / relaunch, without measuring.
        let reopened = fx.makeViewModel()
        await reopened.refresh()
        #expect(reopened.librarySize == expected)
        #expect(fx.measureCalls.value == 1)
    }

    @Test func realMeasurementCountsLibraryFiles() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = fx.makeViewModel()
        await vm.refresh()

        await vm.calculateLibrarySize()

        let bytes = try #require(vm.librarySize?.bytes)
        #expect(bytes >= 4096)
    }

    @Test func storedSizeIsDiscardedWhenLibraryFolderChanges() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        fx.stored.value = LibrarySizeRecord(
            bytes: 1, calculatedAt: Date(timeIntervalSince1970: 0), root: "/Volumes/Old/Music"
        )
        let vm = fx.makeViewModel()

        await vm.refresh()

        #expect(vm.librarySize == nil)
        #expect(vm.librarySizeText == "Size not calculated")
    }

    @Test func failedCalculationKeepsPreviousValue() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let library = try #require(fx.locations.libraryFolder)
        let previous = LibrarySizeRecord(bytes: 7, calculatedAt: Date(timeIntervalSince1970: 0), root: library.path)
        fx.stored.value = previous
        let vm = fx.makeViewModel(measureLibrary: { _ in .failed })
        await vm.refresh()

        await vm.calculateLibrarySize()

        #expect(vm.librarySize == previous)
        #expect(fx.stored.value == previous)
        #expect(vm.errorMessage == "The size couldn't be calculated. Check that the drive is connected and try again.")
    }

    @Test func cancelledCalculationKeepsPreviousValue() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let library = try #require(fx.locations.libraryFolder)
        let previous = LibrarySizeRecord(bytes: 7, calculatedAt: Date(timeIntervalSince1970: 0), root: library.path)
        fx.stored.value = previous
        let vm = fx.makeViewModel(measureLibrary: { _ in
            while !Task.isCancelled { Thread.sleep(forTimeInterval: 0.005) }
            return .cancelled
        })
        await vm.refresh()

        let calculation = Task { await vm.calculateLibrarySize() }
        while !vm.isCalculatingLibrarySize { await Task.yield() }
        vm.cancelLibrarySizeCalculation()
        await calculation.value

        #expect(vm.isCalculatingLibrarySize == false)
        #expect(vm.librarySize == previous)
        #expect(vm.errorMessage == nil)
    }

    @Test func measureDirectoryHonorsCancellation() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let library = try #require(fx.locations.libraryFolder)
        let task = Task.detached { () -> LibrarySizeResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return DataLocationsViewModel.measureDirectory(library)
        }
        #expect(await task.value == .cancelled)
        #expect(DataLocationsViewModel.measureDirectory(fx.root.appendingPathComponent("gone")) == .failed)
    }

    // MARK: - Volumes & copy

    @Test func volumeMountCheckOnlyAppliesToVolumesPaths() {
        #expect(DataLocationsViewModel.isVolumeMounted(FileManager.default.temporaryDirectory))
        #expect(DataLocationsViewModel.isVolumeMounted(
            URL(fileURLWithPath: "/Volumes/MLMTestsNoSuchVolume-\(UUID().uuidString)/Music")
        ) == false)
    }

    @Test func copyMatchesApprovedStrings() {
        typealias Copy = DataLocationsViewModel.Copy
        #expect(Copy.notLoaded == "Storage locations are shown once the library has loaded.")
        #expect(Copy.notFound == "Not found")
        #expect(Copy.notConnected == "Not connected")
        #expect(Copy.noLibraryFolder == "No library folder set — choose one in the Library tab.")
        #expect(Copy.calculating == "Calculating…")
        #expect(Copy.sizeNotCalculated == "Size not calculated")
        #expect(Copy.sizeFailed == "The size couldn't be calculated. Check that the drive is connected and try again.")
        #expect(Copy.storedInKeychain == "Stored in the macOS Keychain")
        #expect(Copy.never == "Never")
        #expect(Copy.backupHint == "Change the backup folder in the Backup tab.")
        #expect(Copy.transcodeHint == "Change the location in the Maintenance tab.")
        #expect(Copy.recentChangesHelp
            == "Recent changes are kept in a separate file (-wal) and merged into the database automatically.")
        #expect(Copy.footer
            == "Library files and the credentials file remain on your Mac if you delete the app. Audio files are never moved by this tab.")
    }

    // MARK: - W3-SET: regrouped locations and the sizes chart

    @Test func macLocationsAreMeasured() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = fx.makeViewModel()
        await vm.refresh()
        #expect(vm.row(.libraryList).sizeBytes == 12)
        #expect(vm.row(.caches).state == .available, "one existing cache folder is enough")
        #expect((vm.row(.caches).sizeBytes ?? 0) > 0)
        #expect((vm.row(.pathMigrations).sizeBytes ?? 0) > 0)
        #expect(vm.row(.logs).url?.lastPathComponent == "mlm.log")
        #expect((vm.row(.logs).sizeBytes ?? 0) > 0)
        let names = vm.macSegments.map(\.name)
        #expect(names.contains("Backups") && names.contains("Caches") && names.contains("Path migration backups"))
        #expect(vm.macTotalBytes == vm.macSegments.map(\.bytes).reduce(0, +))
    }

    @Test func noLibraryKeepsTheMacRows() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        var locations = fx.locations
        locations.database = nil
        locations.playlistCovers = nil
        locations.libraryFolder = nil
        let vm = fx.makeViewModel(locations: locations)
        await vm.refresh()
        #expect(vm.row(.database).state == .notSet)
        #expect(vm.row(.credentialsFile).state == .available)
        #expect(vm.row(.libraryList).state == .available)
    }

    @Test func driveBarAddsOtherFiles() async throws {
        let fx = try Fixture()
        defer { fx.cleanup() }
        let vm = fx.makeViewModel()
        await vm.refresh()
        // The temporary folder's volume is the Mac's own disk.
        #expect(vm.driveTitle == "On this Mac’s disk")
        #expect(vm.driveSegments.last?.name == "Other files")
        #expect(vm.driveCapacityText?.contains(" free") == true)
    }
}
