import Foundation
import GRDB
import Testing
@testable import MLM

/// Read Playlist Changes from Device (F-11): a merge that never drops MLM-only tracks
/// (PP-SYNC-04), one undo step, an error stays on its card.
@Suite("DevicePlaylistChangesTests")
@MainActor
struct DevicePlaylistChangesTests {

    // MARK: Pure diff and merge

    @Test func diffSeparatesDeviceChangesFromMLMOnlyTracks() {
        // MLM: 1 2 3 4 5 · MLM wrote 1 2 3 to the device · the device now lists 3 1 9.
        let diff = DevicePlaylistDiff.make(device: [3, 1, 9], mlm: [1, 2, 3, 4, 5], expected: [1, 2, 3])
        #expect(diff.added == [9])
        #expect(diff.removed == [2], "only a track MLM put on the device can be removed on it")
        #expect(diff.keptOnlyInMLM == [4, 5], "tracks that never reached the device are kept")
        #expect(diff.orderDiffers)
    }

    @Test func mergeNeverDropsMLMOnlyTracks() {
        let merged = DevicePlaylistDiff.mergedOrder(mlm: [1, 2, 3, 4, 5], device: [3, 1, 9], add: [9], remove: [2],
                                                    useDeviceOrder: false)
        #expect(merged == [1, 3, 4, 5, 9])
        let unchecked = DevicePlaylistDiff.mergedOrder(mlm: [1, 2, 3, 4, 5], device: [3, 1, 9], add: [], remove: [],
                                                       useDeviceOrder: false)
        #expect(unchecked == [1, 2, 3, 4, 5], "nothing checked, nothing changes")
    }

    @Test func deviceOrderPermutesOnlyTheTracksOnTheDevice() {
        let merged = DevicePlaylistDiff.mergedOrder(mlm: [1, 2, 3, 4, 5], device: [3, 1, 9], add: [9], remove: [2],
                                                    useDeviceOrder: true)
        // Slots of the device tracks (1, 3) take the device order 3, 1; MLM-only 4, 5 stay put; 9 joins at the end.
        #expect(merged == [3, 1, 4, 5, 9])
        #expect(Set(merged).isSuperset(of: [4, 5]))
    }

    @Test func cardWordsSayWhatChanged() {
        let card = DevicePlaylistCard(
            id: "Road.m3u8", fileURL: URL(fileURLWithPath: "/tmp/Road.m3u8"), target: .existing(id: 1, name: "Road"),
            device: [3, 1, 9], mlm: [1, 2, 3, 4], diff: DevicePlaylistDiff.make(device: [3, 1, 9], mlm: [1, 2, 3, 4], expected: [1, 2, 3]),
            unmatched: [], labels: [4: .init(title: "T", artist: "A", availability: .notDownloaded)])
        #expect(card.summary == "+1 −1 on device · order changed")
        #expect(card.keptSentence == "1 track that is not on the device (1 Not downloaded) stays in the playlist.")
        let new = DevicePlaylistCard(id: "Gym.m3u8", fileURL: URL(fileURLWithPath: "/tmp/Gym.m3u8"), target: .new(name: "Gym"),
                                     device: [1, 2], mlm: [], diff: DevicePlaylistDiff.make(device: [1, 2], mlm: [], expected: []),
                                     unmatched: [], labels: [:])
        #expect(new.summary == "New on device · 2 tracks")
    }

    // MARK: Scan + apply on a temporary database and device folder

    private func seed(_ env: SyncTestEnv) async throws -> (profile: SyncProfile, playlistID: Int64, device: URL) {
        let device = try env.device("IPOD")
        for id in Int64(1)...5 { try env.localTrack(id, title: "Song \(id)") }
        let playlist = try await env.playlists.createNumbered(baseName: "Road", trackIds: [1, 2, 3, 4])
        let profile = try await env.profile("iPod", device: device, generateM3U8: true)
        try await env.sync.addPlaylist(profileId: profile.id!, playlistId: playlist.id!)
        // Tracks 1–3 were synced (and were in the playlist then); 4 never reached the device.
        try await env.db.write { db in
            try db.execute(sql: "UPDATE playlist_tracks SET added_at = '2026-01-01 00:00:00'")
            for id in [1, 2, 3] {
                try db.execute(sql: """
                    INSERT INTO sync_state (profile_id, track_id, synced_checksum, synced_size, synced_timestamp)
                    VALUES (?, ?, 'x', 1, '2026-02-01 00:00:00')
                """, arguments: [profile.id!, id])
            }
        }
        // On the device the user removed Song 2, added Song 5 and reordered.
        let m3u = "#EXTM3U\nArtist/Song 3.mp3\nArtist/Song 1.mp3\nArtist/Song 5.mp3\nUnknown/track 07.m4a\n"
        try m3u.write(to: device.appendingPathComponent("Road.m3u8"), atomically: true, encoding: .utf8)
        // A hidden folder (Rockbox's own) is never read.
        let hidden = device.appendingPathComponent(".rockbox")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try "#EXTM3U\nArtist/Song 1.mp3\n".write(to: hidden.appendingPathComponent("Internal.m3u8"), atomically: true, encoding: .utf8)
        return (profile, playlist.id!, device)
    }

    private func service(_ env: SyncTestEnv) -> DevicePlaylistChangeService {
        let ingest = PlaylistIngestService(trackRepository: env.tracks, playlistRepository: env.playlists, database: env.db)
        return DevicePlaylistChangeService(ingest: ingest, tracks: env.tracks, playlists: env.playlists, database: env.db)
    }

    private func members(_ env: SyncTestEnv, _ playlistID: Int64) async throws -> [Int64] {
        try await env.db.read { db in
            try Int64.fetchAll(db, sql: "SELECT track_id FROM playlist_tracks WHERE playlist_id = ? ORDER BY position, added_at, id",
                               arguments: [playlistID])
        }
    }

    @Test func scanFindsTheChangeAndApplyMergesKeepingMLMOnlyTracks() async throws {
        let env = try await SyncTestEnv()
        let (profile, playlistID, _) = try await seed(env)
        let service = service(env)

        let scan = try await service.scan(profile: profile)
        #expect(scan.cards.count == 1, "the hidden .rockbox folder is not read")
        let card = try #require(scan.cards.first)
        #expect(card.diff.added == [5])
        #expect(card.diff.removed == [2])
        #expect(card.diff.keptOnlyInMLM == [4])
        #expect(card.unmatched.map(\.path) == ["Unknown/track 07.m4a"])

        let model = DevicePlaylistChangesModel(profile: profile, service: service, isReachable: { _ in true })
        model.load(cards: scan.cards)
        #expect(model.applyTitle == "Apply 2 Changes")
        let closed = await model.apply(edits: env.edits)
        #expect(closed)
        #expect(try await members(env, playlistID) == [1, 3, 4, 5], "Song 4 (never on the device) stays")
    }

    @Test func applyIsOneUndoStepThatRestoresTheExactRows() async throws {
        let env = try await SyncTestEnv()
        let (profile, playlistID, _) = try await seed(env)
        let service = service(env)
        let before = try await env.db.read { db in
            try PlaylistTrack.fetchAll(db, sql: "SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY id", arguments: [playlistID])
        }
        let scan = try await service.scan(profile: profile)
        var selection = DevicePlaylistSelection(card: scan.cards[0])
        selection.useDeviceOrder = true
        await env.edits.applyDeviceChanges([(scan.cards[0], selection)], service: service, profileName: profile.name)
        #expect(try await members(env, playlistID) == [3, 1, 4, 5])
        #expect(env.undoManager.canUndo)

        env.undoManager.undo()
        await env.undo.waitUntilIdle()
        let after = try await env.db.read { db in
            try PlaylistTrack.fetchAll(db, sql: "SELECT * FROM playlist_tracks WHERE playlist_id = ? ORDER BY id", arguments: [playlistID])
        }
        #expect(after.map(\.id) == before.map(\.id))
        #expect(after.map(\.position) == before.map(\.position))
        #expect(after.map(\.addedAt) == before.map(\.addedAt))
        #expect(!env.undoManager.canUndo, "one gesture, one step")
    }

    @Test func uncheckedRemovalsStayAndANewDevicePlaylistIsCreatedUndoably() async throws {
        let env = try await SyncTestEnv()
        let (profile, playlistID, device) = try await seed(env)
        try "#EXTM3U\nArtist/Song 4.mp3\nArtist/Song 5.mp3\n".write(to: device.appendingPathComponent("Gym.m3u8"),
                                                                     atomically: true, encoding: .utf8)
        let service = service(env)
        let model = DevicePlaylistChangesModel(profile: profile, service: service, isReachable: { _ in true })
        model.load(cards: try await service.scan(profile: profile).cards)
        #expect(model.cards.count == 2)
        let road = try #require(model.cards.first { $0.id == "Road.m3u8" })
        model.toggle(road.id, removed: 2)  // keep Song 2
        #expect(model.applyTitle == "Apply 1 Change and Create 1 Playlist")
        _ = await model.apply(edits: env.edits)
        #expect(try await members(env, playlistID) == [1, 2, 3, 4, 5])
        let gym = try #require(try await env.playlists.findByName("Gym"))
        #expect(try await members(env, gym.id!) == [4, 5])

        env.undoManager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.playlists.findByName("Gym") == nil)
        #expect(try await members(env, playlistID) == [1, 2, 3, 4])
    }

    @Test func anErrorStaysOnItsCardAndTheOthersGoAhead() async throws {
        let env = try await SyncTestEnv()
        let (profile, playlistID, device) = try await seed(env)
        let doomed = try await env.playlists.createNumbered(baseName: "Doomed", trackIds: [1])
        try "#EXTM3U\nArtist/Song 5.mp3\n".write(to: device.appendingPathComponent("Doomed.m3u8"), atomically: true, encoding: .utf8)
        let service = service(env)
        let model = DevicePlaylistChangesModel(profile: profile, service: service, isReachable: { _ in true })
        model.load(cards: try await service.scan(profile: profile).cards)
        #expect(model.cards.count == 2)
        try await env.playlists.deleteReturningSnapshot(id: doomed.id!)  // gone before Apply

        let closed = await model.apply(edits: env.edits)
        #expect(!closed, "the sheet stays with the card that failed")
        #expect(model.cards.map(\.id) == ["Doomed.m3u8"])
        #expect(model.errors["Doomed.m3u8"]?.hasPrefix("Couldn’t apply the changes to “Doomed”") == true)
        #expect(try await members(env, playlistID) == [1, 3, 4, 5], "the other card was applied")
    }

    @Test func notConnectedSaysSoInTheSheet() {
        let model = DevicePlaylistChangesModel(profile: SyncProfile(id: 1, name: "iPod", outputFolder: "/Volumes/IPOD"),
                                               service: nil, isReachable: { _ in false })
        model.scan()
        #expect(model.phase == .notConnected)
    }

    @Test func doppiFilesAreFoundAndRockboxReadsOnlyM3U8() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ingestfiles_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: root.appendingPathComponent("A.m3u"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("B.m3u8"), atomically: true, encoding: .utf8)
        let doppi = SyncProfile(id: 1, name: "Phone", outputFolder: root.path, playlistFormat: "doppi")
        #expect(DevicePlaylistChangeService.playlistFiles(for: doppi).map(\.name) == ["A.m3u", "B.m3u8"])
        let rockbox = SyncProfile(id: 2, name: "iPod", outputFolder: root.path, playlistFormat: "rockbox")
        #expect(DevicePlaylistChangeService.playlistFiles(for: rockbox).map(\.name) == ["B.m3u8"])
    }
}
