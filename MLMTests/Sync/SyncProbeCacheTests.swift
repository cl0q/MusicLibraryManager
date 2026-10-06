import Foundation
import GRDB
import Testing
@testable import MLM

/// The cached device codec sweep (v56, IMP-104): a device file is probed again only when its
/// size or mtime changed; rows of vanished files are dropped; a new destination clears the cache.
/// A fake probe stands in for ffprobe (no process, no network).
@Suite("SyncProbeCacheTests")
@MainActor
struct SyncProbeCacheTests {

    /// Counts probes and answers per file name.
    final class FakeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var probed: [String] = []
        var codec: @Sendable (URL) -> TranscodeCache.CodecProbe = { _ in .codec("aac", bitrate: 248_000) }
        var count: Int { lock.withLock { probed.count } }
        var paths: [String] { lock.withLock { probed } }
        func probe(_ url: URL) async -> TranscodeCache.CodecProbe {
            lock.withLock { probed.append(url.path) }
            return codec(url)
        }
    }

    private struct Fixture {
        let env: SyncTestEnv
        let profile: SyncProfile
        let device: URL
        let probe: FakeProbe
        let destinations: [Int64: URL]
    }

    /// An AAC profile with `ids` synced and present on the device.
    private func fixture(ids: [Int64]) async throws -> Fixture {
        let env = try await SyncTestEnv()
        let device = try env.device("PLAYER")
        var profile = try await env.profile("Player", device: device)
        try await env.sync.updateSettings(profileId: profile.id!, transcodeMode: TranscodeMode.aac248.rawValue)
        profile = try await env.sync.fetch(id: profile.id!)!
        var destinations: [Int64: URL] = [:]
        for id in ids {
            try env.localTrack(id, title: "Song \(id)")
            try await env.sync.addTrack(profileId: profile.id!, trackId: id)
            try await env.sync.updateSyncState(profileId: profile.id!, trackId: id, checksum: "x", size: 5)
            let track = try await env.tracks.fetchTracks(ids: [id])[0]
            let url = TranscodeCache.buildProfilePath(track: track, libraryRoot: env.library.path,
                                                      profileOutputFolder: SyncService.musicRootFolder(for: profile),
                                                      transcodeMode: .aac248)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("device-\(id)".utf8).write(to: url)
            destinations[id] = url
        }
        let probe = FakeProbe()
        env.service.codecProbe = { await probe.probe($0) }
        return Fixture(env: env, profile: profile, device: device, probe: probe, destinations: destinations)
    }

    @Test func aSecondPlanProbesNothingNewAndPlansTheSame() async throws {
        let f = try await fixture(ids: [1, 2, 3])
        let first = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        #expect(f.probe.count == 3)
        let second = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        #expect(f.probe.count == 3)
        #expect(first.filesToAdd.isEmpty && second.filesToAdd.isEmpty)
        #expect(try await f.env.service.probeCache.entries(profileId: f.profile.id!).count == 3)
    }

    @Test func aChangedFileIsProbedAgainAndAWrongCodecStillPlansTheCopy() async throws {
        let f = try await fixture(ids: [1, 2])
        _ = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        #expect(f.probe.count == 2)

        // Track 2 is replaced on the device by something else (size and mtime change).
        let changed = f.destinations[2]!
        try Data("a different, longer file".utf8).write(to: changed)
        f.probe.codec = { url in url == changed ? .codec("mp3", bitrate: nil) : .codec("aac", bitrate: nil) }
        let plan = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        #expect(f.probe.count == 3)
        #expect(f.probe.paths.last == changed.path)
        #expect(plan.filesToAdd.map(\.trackId) == [2])

        // The wrong codec was cached too: the next plan still wants the copy, with no new probe.
        let again = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        #expect(f.probe.count == 3)
        #expect(again.filesToAdd.map(\.trackId) == [2])
    }

    @Test func rowsOfFilesNoLongerOnTheDeviceAreDropped() async throws {
        let f = try await fixture(ids: [1, 2])
        _ = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        try FileManager.default.removeItem(at: f.destinations[1]!)
        _ = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        let entries = try await f.env.service.probeCache.entries(profileId: f.profile.id!)
        #expect(Set(entries.keys) == [f.destinations[2]!.path])
    }

    @Test func aNewDestinationClearsTheProfilesCacheAndOnlyHis() async throws {
        let f = try await fixture(ids: [1])
        _ = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        let other = try await f.env.profile("Other", device: try f.env.device("OTHER"))
        try await f.env.service.probeCache.store(
            [SyncProbeEntry(devicePath: "/x.m4a", size: 1, mtime: 1, codec: "aac", bitrate: nil)], profileId: other.id!)

        // Same destination again: nothing is cleared.
        try await f.env.sync.updateSettings(profileId: f.profile.id!, outputFolder: f.device.path)
        #expect(try await f.env.service.probeCache.entries(profileId: f.profile.id!).count == 1)

        try await f.env.sync.updateSettings(profileId: f.profile.id!, outputFolder: try f.env.device("NEW").path)
        #expect(try await f.env.service.probeCache.entries(profileId: f.profile.id!).isEmpty)
        #expect(try await f.env.service.probeCache.entries(profileId: other.id!).count == 1)
    }

    @Test func deletingTheProfileDropsItsCacheAndTheMigrationCreatedTheTable() async throws {
        let f = try await fixture(ids: [1])
        _ = try await f.env.service.previewSync(profileId: f.profile.id!, forceRefresh: true)
        try await f.env.sync.delete(id: f.profile.id!)
        #expect(try await f.env.service.probeCache.entries(profileId: f.profile.id!).isEmpty)
    }

    @Test func v56BackfillsPositionsByNameAndIsRegisteredAfterV52() throws {
        var config = Configuration()
        config.foreignKeysEnabled = false
        let queue = try DatabaseQueue(configuration: config)
        let migrator = DatabaseManager.buildMigrator()
        try migrator.migrate(queue, upTo: "v52_album_suggestions")
        try queue.write { db in
            for name in ["Zebra", "Alpha", "Mid"] {
                try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES (?, '/d', '')",
                               arguments: [name])
            }
        }
        let applied = try queue.read { try migrator.appliedIdentifiers($0) }
        #expect(BackupService.hasPendingMigrations(registered: Set(migrator.migrations), applied: applied))
        try migrator.migrate(queue)
        let rows = try queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, position FROM sync_profiles ORDER BY position")
        }
        #expect(rows.map { $0["name"] as String } == ["Alpha", "Mid", "Zebra"])
        #expect(rows.map { $0["position"] as Int } == [1, 2, 3])
        #expect(try queue.read { try $0.tableExists("sync_probe_cache") })
        let names = migrator.migrations
        #expect(try #require(names.firstIndex(of: "v56_sync_followups")) > #require(names.firstIndex(of: "v52_album_suggestions")))
    }
}
