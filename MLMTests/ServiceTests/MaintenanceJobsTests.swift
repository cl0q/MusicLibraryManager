import Foundation
import GRDB
import Testing
@testable import MLM

/// W3-SET (ST-MAINT, F-22, UC-JOB-07): Maintenance jobs queue instead of being refused, each row
/// echoes its operation in Activity's words, the last run comes from Activity's history, coverage
/// is counted in SQL, and Cancel is offered only where it really cancels (PP-SETTINGS-23).
@Suite("Maintenance jobs (W3-SET)", .serialized)
@MainActor
struct MaintenanceJobsTests {

    @Test func aSecondJobQueuesAndStartsByItself() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = MaintenanceJobRunner(center: center)
        let gate = AsyncGate()
        var order: [String] = []
        runner.run(MaintenanceJob.replayGain) {
            order.append("replaygain")
            await gate.wait()
            runner.resultMessage = "ReplayGain: 3 analyzed, 0 failed"
        }
        runner.run(MaintenanceJob.danceability) {
            order.append("danceability")
            runner.resultMessage = "Danceability: 2 analyzed, 0 failed"
        }
        for _ in 0..<1_000 where runner.running != MaintenanceJob.replayGain { await Task.yield() }
        #expect(runner.running == MaintenanceJob.replayGain)
        #expect(runner.isActive(MaintenanceJob.danceability))
        let queued = try! #require(runner.echo(for: MaintenanceJob.danceability))
        #expect(queued.isQueued)
        #expect(queued.text == "Queued · Starts after ReplayGain analysis")
        #expect(order == ["replaygain"])
        await gate.open()
        await runner.waitUntilIdle()
        #expect(order == ["replaygain", "danceability"])
        #expect(center.finishedOperations.count == 2)
        #expect(!runner.isActive(MaintenanceJob.danceability))
    }

    @Test func theSameJobIsNotStartedTwice() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = MaintenanceJobRunner(center: center)
        let gate = AsyncGate()
        var runs = 0
        for _ in 0..<2 {
            runner.run(MaintenanceJob.fingerprint) {
                runs += 1
                await gate.wait()
            }
        }
        await gate.open()
        await runner.waitUntilIdle()
        #expect(runs == 1)
    }

    @Test func aQueuedJobCanAlwaysBeCancelled() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = MaintenanceJobRunner(center: center)
        let gate = AsyncGate()
        var ranRescan = false
        runner.run(MaintenanceJob.pathApply) { await gate.wait() }
        runner.run(MaintenanceJob.rereadTags) { ranRescan = true }
        for _ in 0..<1_000 where runner.running != MaintenanceJob.pathApply { await Task.yield() }
        #expect(!runner.canCancel(MaintenanceJob.pathApply), "a running path migration can’t stop half-way")
        #expect(runner.canCancel(MaintenanceJob.rereadTags), "queued: Cancel is real")
        runner.cancel(MaintenanceJob.rereadTags)
        await gate.open()
        await runner.waitUntilIdle()
        #expect(!ranRescan)
        #expect(center.finishedOperations.contains { $0.title == "Reread tags from files" && $0.state == .cancelled })
    }

    @Test func runningEchoUsesActivityNumbers() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = MaintenanceJobRunner(center: center)
        let gate = AsyncGate()
        runner.run(MaintenanceJob.replayGain) {
            runner.progress = MaintenanceProgressTracker.ProgressState(current: 1_204, total: 3_523)
            await gate.wait()
        }
        for _ in 0..<1_000 where runner.echo(for: MaintenanceJob.replayGain)?.text.hasPrefix("Running — ") != true {
            await Task.yield()
        }
        let echo = try! #require(runner.echo(for: MaintenanceJob.replayGain))
        #expect(echo.text.hasPrefix("Running — "))
        #expect(echo.text.hasSuffix(" of \(3_523.formatted())"))
        await gate.open()
        await runner.waitUntilIdle()
    }

    @Test func lastRunComesFromActivityHistory() async {
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = MaintenanceJobRunner(center: center)
        #expect(runner.lastRun(of: MaintenanceJob.replayGain) == nil)
        runner.run(MaintenanceJob.replayGain) { runner.resultMessage = "ReplayGain: 3,204 analyzed, 12 failed" }
        await runner.waitUntilIdle()
        let text = try! #require(runner.lastRun(of: MaintenanceJob.replayGain))
        #expect(text.hasPrefix("last run "))
        #expect(text.hasSuffix("— \(3_204.formatted()) analysed · 12 failed"))
    }

    @Test func automaticBackfillEchoesAsRunning() {
        let op = ActivityOperation(
            id: UUID(), kind: .artwork, title: "Artwork for 2,010 tracks", subject: .allTracks, state: .running,
            wait: nil, progress: ActivityProgress(completed: 10, total: 100), result: nil, startedAt: Date(),
            endedAt: nil, isAutomatic: true, libraryID: nil, needsAttention: false, dismissedAt: nil,
            itemNoun: .track, messageName: "Artwork", controls: .none, isFromHistory: false)
        #expect(MaintenanceJobRunner.echo(op)?.text.hasPrefix("Running — ") == true)
    }

    @Test func titlesAreTheRowWords() {
        #expect(MaintenanceJob(action: MaintenanceJob.similarity).title == "Similarity analysis")
        #expect(MaintenanceJob(action: MaintenanceJob.rereadTags).title == "Reread tags from files")
        #expect(MaintenanceJob(action: MaintenanceJob.artworkMusicBrainz).title == "Fetch artwork from MusicBrainz")
        #expect(MaintenanceJob(action: MaintenanceJob.pathApply).title == "Update organized paths")
    }

    @Test func coverageIsCountedInSQL() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MaintenanceJobsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = try DatabaseManager(path: root.appendingPathComponent("music_library.db"))
        try await manager.pool.write { db in
            for id in 1...4 {
                try db.execute(sql: """
                    INSERT INTO tracks (id, artist, album_artist, album, title, format, original_path, organized_path)
                    VALUES (?, 'A', 'A', 'B', 'T', 'mp3', ?, ?)
                    """, arguments: [id, "/x/\(id).mp3", id == 4 ? nil : "A/\(id).mp3"])
            }
            try db.execute(sql: "INSERT INTO replaygain (track_id, track_gain, track_peak) VALUES (1, -6, 0.9), (2, -5, 0.8), (4, -1, 0.1)")
            try db.execute(sql: "INSERT INTO fingerprints (track_id, fingerprint, duration_seconds) VALUES (1, x'00', 10)")
            try db.execute(sql: "INSERT INTO artwork (track_id, artwork_path, source) VALUES (1, '/c/1.jpg', 'embedded'), (2, '/c/2.jpg', 'missing'), (3, NULL, 'embedded')")
            try db.execute(sql: "UPDATE tracks SET danceability = 0.5, bpm = 120 WHERE id = 2")
        }
        let coverage = try await manager.pool.read { db in try MaintenanceCoverage.load(db) }
        #expect(coverage.tracksWithFile == 3, "a track without a file isn’t counted")
        #expect(coverage.replayGain == 2)
        #expect(coverage.fingerprinted == 1)
        #expect(coverage.danceability == 1)
        #expect(coverage.withArtwork == 1, "a missing cached file doesn’t count")
        #expect(coverage.withoutArtwork == 1)
        #expect(coverage.text(for: MaintenanceJob.replayGain) == "2 of 3 analysed")
        #expect(coverage.text(for: MaintenanceJob.artworkEmbedded) == "1 of 3 tracks have artwork")
        #expect(coverage.text(for: MaintenanceJob.artworkMusicBrainz) == "1 track without artwork")
        #expect(coverage.text(for: MaintenanceJob.rereadTags) == nil)
    }

    @Test func clearingTheCacheKeepsTheFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MaintenanceCache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("1.m4a"))
        try Data("b".utf8).write(to: root.appendingPathComponent("sub/2.m4a"))
        #expect(MaintenanceJobs.cacheSummary(root)?.files == 1, "not recursive")
        #expect(MaintenanceJobs.removeCachedFiles(in: root) == 1)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("sub/2.m4a").path))
        #expect(MaintenanceJobs.cacheSummary(root)?.files == 0)
    }

    // MARK: Review B1 — Clear Cache can never reach the music

    @Test func onlyTheCachesOwnFileNamesMatch() {
        for name in ["12.m4a", "12_248.m4a", "12_248_norm.m4a", "12_320_art600.m4a", "12_248_norm_art300.m4a"] {
            #expect(TranscodeCacheSafety.isCacheFileName(name), "\(name)")
        }
        for name in ["01 Song.m4a", "12_248.mp3", ".12_248.m4a", "12_248.m4a.part", "track.flac", "12-248.m4a", "song_248.m4a"] {
            #expect(!TranscodeCacheSafety.isCacheFileName(name), "\(name)")
        }
    }

    @Test func aCachePathSetToTheLibraryRootDeletesNothing() async throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("B1Library-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: library.appendingPathComponent("Artist"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        try Data("music".utf8).write(to: library.appendingPathComponent("Artist/01 Song.m4a"))
        try Data("music".utf8).write(to: library.appendingPathComponent("7.m4a"))   // looks like a cache file
        let refusal = await TranscodeCacheSafety.refusal(for: library, libraryRoot: library) { _, _ in false }
        #expect(refusal?.contains("is the library folder") == true)
        let parent = await TranscodeCacheSafety.refusal(for: library.deletingLastPathComponent(), libraryRoot: library) { _, _ in false }
        #expect(parent?.contains("contains the library folder") == true)
        #expect(FileManager.default.fileExists(atPath: library.appendingPathComponent("7.m4a").path))
    }

    @Test func aDedicatedHiddenSubfolderDeletesOnlyMatchingFiles() async throws {
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("B1Library-\(UUID().uuidString)")
        let cache = library.appendingPathComponent(".mlm_transcode_cache")
        try FileManager.default.createDirectory(at: cache.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: library) }
        for name in ["5_248.m4a", "6_248_norm.m4a", "9.m4a"] {
            try Data("c".utf8).write(to: cache.appendingPathComponent(name))
        }
        for name in ["Keep Me.m4a", ".DS_Store", "notes.txt", "nested/7_248.m4a"] {
            try Data("k".utf8).write(to: cache.appendingPathComponent(name))
        }
        let refusal = await TranscodeCacheSafety.refusal(for: cache, libraryRoot: library) { _, _ in
            Issue.record("a `.mlm…` folder needs no track check")
            return true
        }
        #expect(refusal == nil)
        #expect(MaintenanceJobs.cacheSummary(cache)?.files == 3)
        #expect(MaintenanceJobs.removeCachedFiles(in: cache) == 3)
        for name in ["Keep Me.m4a", ".DS_Store", "notes.txt", "nested/7_248.m4a"] {
            #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent(name).path), "\(name) survives")
        }
    }

    @Test func aSubfolderHoldingTracksIsRefused() async throws {
        let library = URL(fileURLWithPath: "/tmp/B1Lib")
        var asked: (String, String)?
        let refusal = await TranscodeCacheSafety.refusal(for: library.appendingPathComponent("Artist"), libraryRoot: library) { rel, abs in
            asked = (rel, abs)
            return true
        }
        #expect(refusal?.contains("holds tracks of the library") == true)
        #expect(asked?.0 == "Artist/")
        let empty = await TranscodeCacheSafety.refusal(for: library.appendingPathComponent("Cache"), libraryRoot: library) { _, _ in false }
        #expect(empty == nil)
    }

    @Test func diskAndSystemFoldersAreRefused() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in ["/", "/Volumes", "/Volumes/Lexxar", "/Users", home.path,
                       FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].path] {
            #expect(TranscodeCacheSafety.structuralRefusal(for: URL(fileURLWithPath: folder)) != nil, "\(folder)")
        }
        #expect(TranscodeCacheSafety.structuralRefusal(for: URL(fileURLWithPath: "/Volumes/Lexxar/MLM Transcode Cache")) == nil)
    }

    @Test func likePatternsAreEscaped() {
        #expect(TranscodeCacheSafety.likePrefix("a_b%/") == "a\\_b\\%/%")
    }

    @Test func migrationErrorsInPlainWords() {
        #expect(MaintenanceJobs.pathProblemText(OrganizedPathMigrationService.MigrationError.libraryRootMissing)
                == "the library folder can’t be reached")
        #expect(MaintenanceJobs.pathProblemText(OrganizedPathMigrationService.MigrationError.noAppliedManifest)
                == "there is no migration to roll back")
    }
}
