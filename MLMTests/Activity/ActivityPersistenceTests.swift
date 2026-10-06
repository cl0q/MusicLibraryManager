import Foundation
import GRDB
import Testing
@testable import MLM

/// `v46_activity_operations` + `ActivityOperationRepository` + `ActivityAppLevelStore` (W3-ACT):
/// migration, round trip, interrupted operations, pruning, per-library isolation, subject
/// cleanup and the `‹n› failed` agreement. Temporary databases and directories only.
@MainActor
@Suite("ActivityPersistenceTests")
struct ActivityPersistenceTests {
    private static let v46 = "v46_activity_operations"
    private static let previous = "v53_tag_write_originals"

    private static var configuration: Configuration {
        var config = Configuration()
        config.foreignKeysEnabled = false
        return config
    }

    private func record(_ state: ActivityState = .completed, ended: Date?, attention: Bool = false,
                        subject: ActivitySubject = .none, title: String = "Op") -> ActivityOperationRecord {
        ActivityOperationRecord(
            id: UUID(), kind: .download, title: title, subject: subject, state: state, isAutomatic: false,
            startedAt: (ended ?? Date()).addingTimeInterval(-60), endedAt: ended,
            result: ActivityResult(counts: [.init(.done, 3, "downloaded")]), needsAttention: attention, dismissedAt: nil)
    }

    // MARK: Migration

    @Test func freshDatabaseHasTheTable() async throws {
        let db = try DatabaseManager.inMemory()
        let columns = try await db.read { try $0.columns(in: "activity_operations").map(\.name) }
        #expect(columns.contains("result"))
        #expect(columns.contains("subject_missing"))
        #expect(columns.contains("needs_attention"))
        let fk = try await db.read { try Bool.fetchOne($0, sql: "PRAGMA foreign_keys") }
        #expect(fk == false)
    }

    @Test func registeredOnceAfterTheLatestExistingMigration() throws {
        let migrations = DatabaseManager.buildMigrator().migrations
        #expect(migrations.filter { $0 == Self.v46 }.count == 1)
        #expect(try #require(migrations.firstIndex(of: Self.previous)) < #require(migrations.firstIndex(of: Self.v46)))
    }

    @Test func upgradeKeepsEveryRowAndIsPending() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            for index in 0..<20 {
                try db.execute(sql: """
                    INSERT INTO tracks (artist, album_artist, album, title, format, original_path, is_duplicate)
                    VALUES ('A', 'A', 'B', ?, 'm4a', ?, 0)
                    """, arguments: ["T\(index)", "/o/\(index)"])
            }
        }
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied))
        try migrator.migrate(queue)
        let (tracks, ops) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activity_operations"))
        }
        #expect(tracks == 20)
        #expect(ops == 0)
    }

    @Test func idempotentWhenTheTableAlreadyExists() throws {
        let queue = try DatabaseQueue(configuration: Self.configuration)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: Self.previous)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE activity_operations (id TEXT PRIMARY KEY NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, subject_kind TEXT NOT NULL DEFAULT 'none', subject_id INTEGER, subject_name TEXT, subject_detail TEXT, subject_track_ids TEXT, subject_missing INTEGER NOT NULL DEFAULT 0, state TEXT NOT NULL, is_automatic INTEGER NOT NULL DEFAULT 0, started_at TEXT NOT NULL, ended_at TEXT, result TEXT, needs_attention INTEGER NOT NULL DEFAULT 0, dismissed_at TEXT)")
        }
        try migrator.migrate(queue)
        try migrator.migrate(queue)
        let count = try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'activity_operations'")
        }
        #expect(count == 1)
    }

    // MARK: Repository

    @Test func roundTrip() async throws {
        let repo = ActivityOperationRepository(database: try DatabaseManager.inMemory())
        var original = record(ended: Date(), attention: true, subject: .playlist(4, name: "Warm-up"))
        original.result = ActivityResult(
            counts: [.init(.done, 35, "downloaded"), .init(.failed, 9, "failed")],
            failureGroups: [ActivityFailureGroup(cause: "Sign-in expired (SoundCloud)", count: 9,
                                                 fix: .reconnect(source: nil), trackIDs: Array(1...9))],
            items: [ActivityItemOutcome(word: "Download failed", title: "Barker — Paradise Engineering", trackID: 1,
                                        reason: "Sign-in expired (SoundCloud)", isFailure: true)])
        try await repo.save(original)
        let loaded = try await repo.load(now: Date())
        #expect(loaded.count == 1)
        let back = try #require(loaded.first)
        #expect(back.id == original.id)
        // Items stay in the row and are read on demand (N12).
        #expect(back.result == original.withoutItems.result)
        #expect(try await repo.items(for: original.id) == original.result?.items)
        #expect(back.subject == original.subject)
        #expect(back.needsAttention)
        #expect(abs(back.startedAt.timeIntervalSince(original.startedAt)) < 0.01)
    }

    @Test func interruptedOperationsAreClosedHonestly() async throws {
        let repo = ActivityOperationRepository(database: try DatabaseManager.inMemory())
        let running = record(.running, ended: nil)
        try await repo.save(running)
        try await repo.save(record(ended: Date()))
        #expect(try await repo.closeInterrupted(at: Date()) == 1)
        let closed = try #require(try await repo.load(now: Date()).first { $0.id == running.id })
        #expect(closed.state == .cancelled)
        #expect(closed.endedAt != nil)
        #expect(closed.result?.summary == ActivityInterruption.summary)
        #expect(try await repo.closeInterrupted(at: Date()) == 0)
    }

    @Test func pruningKeeps200Or30DaysAndEveryUndismissedFailure() async throws {
        let repo = ActivityOperationRepository(database: try DatabaseManager.inMemory())
        let now = Date()
        for index in 0..<230 {
            try await repo.save(record(ended: now.addingTimeInterval(-Double(index) * 60)))
        }
        let old = record(ended: now.addingTimeInterval(-31 * 24 * 3600))
        try await repo.save(old)
        let oldFailure = record(ended: now.addingTimeInterval(-40 * 24 * 3600), attention: true)
        try await repo.save(oldFailure)
        try await repo.prune(now: now)
        let kept = try await repo.load(now: now)
        #expect(kept.count == ActivityRetention.maxCount + 1)
        #expect(!kept.contains { $0.id == old.id })
        #expect(kept.contains { $0.id == oldFailure.id })
        // Dismissed failures follow the normal limits.
        try await repo.markDismissed(ids: [oldFailure.id], at: now)
        try await repo.prune(now: now)
        #expect(try await repo.load(now: now).count == ActivityRetention.maxCount)
    }

    @Test func missingSubjectsBecomePlainText() async throws {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let kept = try await playlists.create(name: "Kept")
        let repo = ActivityOperationRepository(database: db)
        let live = record(ended: Date(), subject: .playlist(try #require(kept.id), name: "Kept"))
        let gone = record(ended: Date(), subject: .playlist(99_999, name: "Gone"))
        let profile = record(ended: Date(), subject: .syncProfile(77, name: "iPod"))
        for item in [live, gone, profile] { try await repo.save(item) }
        #expect(try await repo.markMissingSubjects() == 2)
        let loaded = Dictionary(uniqueKeysWithValues: try await repo.load(now: Date()).map { ($0.id, $0) })
        #expect(loaded[live.id]?.subject.isMissing == false)
        #expect(loaded[gone.id]?.subject.isMissing == true)
        #expect(loaded[gone.id]?.subject.isLinkable == false)
        #expect(loaded[gone.id]?.subject.name == "Gone")
        #expect(loaded[profile.id]?.subject.isMissing == true)
    }

    @Test func deletingAPlaylistTurnsItsLinksIntoPlainText() async throws {
        let db = try DatabaseManager.inMemory()
        let playlists = PlaylistRepository(database: db)
        let playlist = try await playlists.create(name: "Warm-up")
        let id = try #require(playlist.id)
        let repo = ActivityOperationRepository(database: db)
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await center.attachLibrary(id: "lib", store: repo, failureSource: repo)
        let notifications = NotificationCenter()
        center.observeLibraryChanges(center: notifications)
        let job = center.begin(.download, title: "Import “Warm-up”", subject: .playlist(id, name: "Warm-up"))
        job.finish()
        await center.flushPersistence()
        #expect(center.operation(id: job.id)?.subject.isLinkable == true)

        try await playlists.delete(id: id)
        await center.refreshSubjects()
        let op = try #require(center.operation(id: job.id))
        #expect(op.subject.isMissing)
        #expect(op.subject.showLabel == nil, "no Show Playlist for a deleted playlist")
        #expect(op.subject.linkLabel == "“Warm-up”", "the name stays as plain text")
    }

    // MARK: Center + stores

    @Test func centerPersistsAndRestoresAcrossRelaunch() async throws {
        let db = try DatabaseManager.inMemory()
        let repo = ActivityOperationRepository(database: db)
        let first = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await first.attachLibrary(id: "lib-a", store: repo, failureSource: repo)
        let done = first.begin(.folderScan, title: "Scan “Music”", subject: .folder(URL(fileURLWithPath: "/tmp/Music")))
        done.finish(ActivityResult(counts: [.init(.done, 14, "imported"), .init(.skipped, 2, "skipped")]))
        let quitMidJob = first.begin(.sync, title: "Sync “iPod”")
        _ = quitMidJob
        await first.flushPersistence()

        // Next launch.
        let second = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await second.attachLibrary(id: "lib-a", store: repo, failureSource: repo)
        let restored = try #require(second.operation(id: done.id))
        #expect(restored.isFromHistory)
        #expect(restored.result?.sentence == "14 imported · 2 skipped")
        let interrupted = try #require(second.operation(id: quitMidJob.id))
        #expect(interrupted.state == .cancelled)
        #expect(ActivityPresentation.resultText(interrupted) == ActivityInterruption.summary)
        #expect(second.activeOperations.isEmpty)
    }

    @Test func historyIsPerLibrary() async throws {
        let repoA = ActivityOperationRepository(database: try DatabaseManager.inMemory())
        let repoB = ActivityOperationRepository(database: try DatabaseManager.inMemory())
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await center.attachLibrary(id: "A", store: repoA, failureSource: nil)
        center.begin(.backup, title: "Back Up Now").finish()
        await center.flushPersistence()
        #expect(try await repoA.load(now: Date()).count == 1)
        #expect(try await repoB.load(now: Date()).isEmpty)

        let other = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await other.attachLibrary(id: "B", store: repoB, failureSource: nil)
        #expect(other.finishedOperations.isEmpty)
    }

    @Test func appLevelOperationsGoToTheJSONFile() async throws {
        let directory = try makeActivityTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ActivityAppLevelStore(fileURL: directory.appendingPathComponent("activity.json"))
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await center.attachAppLevel(store: store)
        let adoption = center.begin(.libraryAdoption, title: "Create library file “Main Library”", subject: .libraryFile)
        adoption.finish(ActivityResult(summary: "Old install adopted"))
        await center.flushPersistence()
        let records = try await store.load(now: Date())
        #expect(records.map(\.id) == [adoption.id])
        #expect(records.first?.result?.summary == "Old install adopted")

        let next = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await next.attachAppLevel(store: store)
        #expect(next.operation(id: adoption.id)?.libraryID == nil)
    }

    @Test func dismissAndRemovePersist() async throws {
        let repo = ActivityOperationRepository(database: try DatabaseManager.inMemory())
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await center.attachLibrary(id: "lib", store: repo, failureSource: nil)
        let failed = center.begin(.backup, title: "Back Up Now")
        failed.fail(cause: "the folder isn’t writable")
        let other = center.begin(.backup, title: "Back Up Now")
        other.finish()
        center.dismiss([failed.id])
        center.removeFromHistory(other.id)
        await center.flushPersistence()
        let records = try await repo.load(now: Date())
        #expect(records.map(\.id) == [failed.id])
        #expect(records.first?.dismissedAt != nil)
    }

    // MARK: `‹n› failed` agreement (item = playlist = Download failed scope)

    @Test func failedCountAgreesWithTheScopeAndThePlaylist() async throws {
        let db = try DatabaseManager.inMemory()
        let tracks = TrackRepository(database: db)
        let playlists = PlaylistRepository(database: db)
        let playlist = try await playlists.create(name: "Dekmantel 2024")
        let playlistID = try #require(playlist.id)
        var ids: [Int64] = []
        for index in 0..<12 {
            let track = try await tracks.insert(Track(artist: "A", album: "", title: "T\(index)", format: "m4a",
                                                      originalPath: "https://soundcloud.com/a/t\(index)"))
            ids.append(try #require(track.id))
        }
        try await playlists.addTracks(playlistId: playlistID, trackIds: ids, startPosition: "a0")
        // 9 of 12 fail in the import.
        let failedIDs = Array(ids.prefix(9))
        for id in failedIDs {
            _ = try await tracks.persistDownloadFailure(trackId: id, reason: "Authentication expired — re-authorize and retry")
        }
        let repo = ActivityOperationRepository(database: db)
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        await center.attachLibrary(id: "lib", store: repo, failureSource: repo)
        let job = center.begin(.download, title: "Import “Dekmantel 2024”", subject: .playlist(playlistID, name: "Dekmantel 2024"))
        job.finish(ActivityResult(
            counts: [.init(.done, 3, "downloaded"), .init(.failed, 9, "failed")],
            failureGroups: ActivityFailureGrouping.groupDownloads(failedIDs.map {
                .init(trackID: $0, reason: "Authentication expired — re-authorize and retry", sourceHint: "SoundCloud")
            })))
        await center.refreshFailing()

        func counts() async throws -> (item: Int, scope: Int, playlist: Int) {
            let scope = try await TrackScopeQueries(database: db).scopeSummary().counts.count(for: .downloadFailed)
            let playlistFailing = try await repo.failingTrackIDs(in: ids).count
            return (ActivityPresentation.failedCount(center), scope, playlistFailing)
        }
        var now = try await counts()
        #expect(now.item == 9)
        #expect(now.scope == 9)
        #expect(now.playlist == 9)
        #expect(ActivityPresentation.toolbarSummary(center).failedText == "9 failed")
        #expect(center.echo(for: .playlist(playlistID, name: "Dekmantel 2024"))?.failedCount == 9)

        // Two are fixed (downloaded later): all three drop together.
        for id in failedIDs.prefix(2) {
            try await tracks.markAsDownloaded(trackId: id, organizedPath: "A/\(id).m4a", format: "m4a", bitrate: 248, downloadStatus: nil)
        }
        await center.refreshFailing()
        now = try await counts()
        #expect(now.item == 7)
        #expect(now.scope == 7)
        #expect(now.playlist == 7)
    }
}
