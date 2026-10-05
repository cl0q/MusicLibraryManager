import Foundation
import GRDB
import Testing
@testable import MLM

/// File checks on temporary folders (never the live library): the reconciler records
/// `File missing` only while the library folder is verifiably reachable.
@Suite("TrackAvailabilityReconcilerTests")
struct TrackAvailabilityReconcilerTests {

    // MARK: - Fixture

    private struct Fixture {
        let db: DatabaseQueue
        let repo: TrackRepository
        let root: URL

        init(createRoot: Bool = true) throws {
            db = try DatabaseManager.inMemory()
            repo = TrackRepository(database: db)
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mlm-reconcile-\(UUID().uuidString)", isDirectory: true)
            if createRoot {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            }
        }

        /// A track whose organized path is `relative`; creates the file when `onDisk`.
        @discardableResult
        func addTrack(_ relative: String, onDisk: Bool, originalPath: String? = nil) async throws -> Int64 {
            if onDisk { try write(relative) }
            var track = Track(artist: "Artist", album: "Album", title: relative, format: "m4a",
                              originalPath: originalPath ?? "soundcloud://\(UUID().uuidString)")
            track.organizedPath = relative
            return try #require(try await repo.insert(track).id)
        }

        func write(_ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }

        func delete(_ relative: String) throws {
            try FileManager.default.removeItem(at: root.appendingPathComponent(relative))
        }

        func flaggedIDs() async throws -> Set<Int64> {
            try await db.read { db in
                Set(try Int64.fetchAll(db, sql: "SELECT id FROM tracks WHERE file_missing_since IS NOT NULL"))
            }
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    /// Thread-safe counter for stateful fake probes.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    // MARK: - Detection

    @Test func detectsADeletedFile() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let kept = try await f.addTrack("A/kept.m4a", onDisk: true)
        let gone = try await f.addTrack("A/gone.m4a", onDisk: true)
        try f.delete("A/gone.m4a")

        let report = await TrackAvailabilityReconciler(repository: f.repo).reconcile(libraryRoot: f.root.path)
        #expect(report.outcome == .completed)
        #expect(report.checked == 2)
        #expect(report.flaggedMissing == 1)
        #expect(try await f.flaggedIDs() == [gone])
        #expect(try await f.repo.fetchTrack(id: gone)?.availability() == .fileMissing)
        #expect(try await f.repo.fetchTrack(id: kept)?.availability() == .local)
    }

    @Test func detectsAReturnedFile() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let id = try await f.addTrack("B/back.m4a", onDisk: false)
        let reconciler = TrackAvailabilityReconciler(repository: f.repo)
        _ = await reconciler.reconcile(libraryRoot: f.root.path)
        #expect(try await f.flaggedIDs() == [id])

        try f.write("B/back.m4a")
        let report = await reconciler.reconcile(libraryRoot: f.root.path + "/")
        #expect(report.cleared == 1)
        #expect(try await f.flaggedIDs().isEmpty)
    }

    @Test func staleOrganizedPathWithAnExistingOriginalFileIsPresent() async throws {
        // Old rows: the organized path is stale but the original import file still exists
        // (playback falls back to it), so the track is not File missing.
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.write("orig/real.m4a")
        _ = try await f.addTrack("A/stale.m4a", onDisk: false, originalPath: f.root.appendingPathComponent("orig/real.m4a").path)
        let missingBoth = try await f.addTrack("A/stale2.m4a", onDisk: false, originalPath: "/nonexistent/\(UUID().uuidString).m4a")
        _ = await TrackAvailabilityReconciler(repository: f.repo).reconcile(libraryRoot: f.root.path)
        #expect(try await f.flaggedIDs() == [missingBoth])
    }

    @Test func absolutePathsOnAnUnmountedVolumeAreSkipped() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let id = try await f.addTrack("/Volumes/NoSuchDisk-\(UUID().uuidString)/x.m4a", onDisk: false)
        let report = await TrackAvailabilityReconciler(repository: f.repo).reconcile(libraryRoot: f.root.path)
        #expect(report.skipped == 1)
        #expect(!(try await f.flaggedIDs().contains(id)))
    }

    @Test func flaggedOnlyScopeChecksOnlyFlaggedRows() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let flagged = try await f.addTrack("C/one.m4a", onDisk: false)
        let unflaggedGone = try await f.addTrack("C/two.m4a", onDisk: true)
        #expect(try await f.repo.recordFileMissing(trackId: flagged))
        try f.delete("C/two.m4a")
        let report = await TrackAvailabilityReconciler(repository: f.repo)
            .reconcile(libraryRoot: f.root.path, scope: .flaggedMissing)
        #expect(report.checked == 1)
        #expect(try await f.flaggedIDs() == [flagged])
        #expect(!(try await f.flaggedIDs().contains(unflaggedGone)))
    }

    // MARK: - Safety

    @Test func doesNothingWhenTheLibraryFolderIsUnreachable() async throws {
        let f = try Fixture(createRoot: false)  // the drive is away
        defer { f.cleanUp() }
        for index in 0..<30 { try await f.addTrack("D/\(index).m4a", onDisk: false) }
        let before = try await f.db.read { try Row.fetchAll($0, sql: "SELECT * FROM tracks ORDER BY id") }
        let report = await TrackAvailabilityReconciler(repository: f.repo).reconcile(libraryRoot: f.root.path)
        #expect(report.outcome == .skippedRootUnreachable)
        #expect(report.checked == 0)
        let after = try await f.db.read { try Row.fetchAll($0, sql: "SELECT * FROM tracks ORDER BY id") }
        #expect(before == after)
    }

    @Test func aStaleMountPointIsNotReachable() {
        // `/Volumes/<name>` that is not a mounted volume never counts as reachable.
        #expect(!LibraryRootReachability.isReachable("/Volumes/NoSuchDisk-\(UUID().uuidString)/Music"))
        #expect(!MountObserver.isVolumeMounted("/Volumes/NoSuchDisk-\(UUID().uuidString)"))
        #expect(MountObserver.isVolumeMounted("/"))
    }

    @Test func abortsSafelyWhenTheFolderDisappearsMidRun() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        // Batch 1: two present files, one of them flagged missing (comes back).
        let back = try await f.addTrack("E/1.m4a", onDisk: true)
        _ = try await f.addTrack("E/2.m4a", onDisk: true)
        #expect(try await f.repo.recordFileMissing(trackId: back))
        // Batches 2…: files "absent" because the drive was pulled.
        for index in 3...8 { try await f.addTrack("E/\(index).m4a", onDisk: true) }

        let probeCalls = Counter()
        var probe = TrackFileProbe.live
        // Reachable for the start and after batch 1, then gone.
        probe.isLibraryRootReachable = { _ in probeCalls.next() <= 2 }
        // After the first batch every file read fails, as on a yanked disk.
        probe.fileExists = { path in path.hasSuffix("/E/1.m4a") || path.hasSuffix("/E/2.m4a") }
        let report = await TrackAvailabilityReconciler(repository: f.repo, probe: probe, batchSize: 2)
            .reconcile(libraryRoot: f.root.path)
        #expect(report.outcome == .abortedRootLost)
        #expect(report.cleared == 1, "the batch checked while reachable is kept")
        #expect(try await f.flaggedIDs().isEmpty, "nothing is marked missing because the drive went away")
    }

    @Test func aFullyAbsentBatchInAnEmptyFolderIsSuspicious() async throws {
        let f = try Fixture()  // reachable but empty
        defer { f.cleanUp() }
        for index in 0..<25 { try await f.addTrack("F/\(index).m4a", onDisk: false) }
        let report = await TrackAvailabilityReconciler(repository: f.repo).reconcile(libraryRoot: f.root.path)
        #expect(report.outcome == .abortedSuspicious)
        #expect(try await f.flaggedIDs().isEmpty)
    }

    @Test func isCancellableAndWritesNothingForTheCancelledBatch() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.write("keep.txt")
        for index in 0..<5 { try await f.addTrack("G/\(index).m4a", onDisk: false) }

        final class TaskBox: @unchecked Sendable {
            let lock = NSLock()
            var task: Task<TrackAvailabilityReconciler.Report, Never>?
            func get() -> Task<TrackAvailabilityReconciler.Report, Never>? { lock.lock(); defer { lock.unlock() }; return task }
            func set(_ value: Task<TrackAvailabilityReconciler.Report, Never>) { lock.lock(); task = value; lock.unlock() }
        }
        let box = TaskBox()
        var probe = TrackFileProbe.live
        probe.fileExists = { _ in
            // Cancel the run while its first batch is being checked.
            while box.get() == nil { usleep(1_000) }
            box.get()?.cancel()
            return false
        }
        let reconciler = TrackAvailabilityReconciler(repository: f.repo, probe: probe, batchSize: 1)
        let task = Task { await reconciler.reconcile(libraryRoot: f.root.path) }
        box.set(task)
        let report = await task.value
        #expect(report.outcome == .cancelled)
        #expect(try await f.flaggedIDs().isEmpty)
    }

    // MARK: - Monitor

    @MainActor
    @Test func useTimeMissIsRecordedOnlyWhileTheFolderIsReachable() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        let id = try await f.addTrack("H/x.m4a", onDisk: false)
        let reachableRoot = f.root.path
        let monitor = LibraryAvailabilityMonitor(
            reconciler: TrackAvailabilityReconciler(repository: f.repo),
            repository: f.repo,
            libraryRoot: { "/Volumes/NoSuchDisk-\(UUID().uuidString)/Music" }
        )
        #expect(await monitor.recordMissingAtUse(trackID: id) == false)
        #expect(try await f.flaggedIDs().isEmpty)

        let reachable = LibraryAvailabilityMonitor(
            reconciler: TrackAvailabilityReconciler(repository: f.repo),
            repository: f.repo,
            libraryRoot: { reachableRoot }
        )
        #expect(await reachable.recordMissingAtUse(trackID: id))
        #expect(try await f.flaggedIDs() == [id])
    }

    @MainActor
    @Test func monitorRunsAndReportsAndMergesScopes() async throws {
        let f = try Fixture()
        defer { f.cleanUp() }
        try f.write("keep.txt")
        let gone = try await f.addTrack("I/gone.m4a", onDisk: false)
        let root = f.root.path
        let monitor = LibraryAvailabilityMonitor(
            reconciler: TrackAvailabilityReconciler(repository: f.repo),
            repository: f.repo,
            libraryRoot: { root }
        )
        await monitor.checkNow(.all)
        #expect(monitor.isChecking == false)
        #expect(monitor.lastReport?.flaggedMissing == 1)
        #expect(try await f.flaggedIDs() == [gone])

        #expect(LibraryAvailabilityMonitor.merge(nil, .flaggedMissing) == .flaggedMissing)
        #expect(LibraryAvailabilityMonitor.merge(.flaggedMissing, .all) == .all)
        #expect(LibraryAvailabilityMonitor.merge(.tracks([1]), .tracks([2])) == .tracks([1, 2]))
        #expect(LibraryAvailabilityMonitor.merge(.tracks([1]), .flaggedMissing) == .all)
    }
}
