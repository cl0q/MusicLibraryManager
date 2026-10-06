import Foundation
import GRDB
import Testing
@testable import MLM

/// Sync Now for playlist-only changes (IMP-105): the plan counts playlists whose members or
/// order changed since their file was written; such a run rewrites the playlist files only.
@Suite("SyncPlaylistOnlyTests")
@MainActor
struct SyncPlaylistOnlyTests {

    private func m3u(_ device: URL, name: String) throws -> String {
        try String(contentsOf: device.appendingPathComponent(name), encoding: .utf8)
    }

    /// Two tracks and one playlist of both, synced once with playlist files on.
    private func syncedFixture() async throws -> (env: SyncTestEnv, profile: SyncProfile, device: URL, playlist: Playlist) {
        let env = try await SyncTestEnv()
        let device = try env.device("PLAYER")
        let profile = try await env.profile("Player", device: device, generateM3U8: true)
        try env.localTrack(1, title: "First")
        try env.localTrack(2, title: "Second")
        let playlist = try await env.playlists.create(name: "Mix")
        try await env.playlists.replaceTrackList(playlistId: playlist.id!, trackIds: [1, 2])
        try await env.sync.addPlaylist(profileId: profile.id!, playlistId: playlist.id!)
        let first = try await env.service.executeSync(profileId: profile.id!)
        #expect(first.syncedCount == 2)
        return (env, profile, device, playlist)
    }

    @Test func nothingChangedMeansNothingToUpdate() async throws {
        let f = try await syncedFixture()
        let plan = try await f.env.service.previewSync(profileId: f.profile.id!)
        #expect(plan.filesToAdd.isEmpty && plan.filesToRemove.isEmpty)
        #expect(plan.playlistsToUpdate == 0)
        #expect(plan.summary.playlistsToUpdate == 0)
    }

    @Test func aReorderIsOnePlaylistToUpdateAndTheRunRewritesOnlyTheFile() async throws {
        let f = try await syncedFixture()
        let before = f.env.files(in: f.device)
        let beforeAttempts = f.env.service.attemptedTrackIds

        try await f.env.playlists.replaceTrackList(playlistId: f.playlist.id!, trackIds: [2, 1])
        let plan = try await f.env.service.previewSync(profileId: f.profile.id!)
        #expect(plan.filesToAdd.isEmpty && plan.filesToRemove.isEmpty)
        #expect(plan.playlistsToUpdate == 1)
        #expect(plan.summary.playlistsToUpdate == 1)

        let result = try await f.env.service.executeSync(profileId: f.profile.id!)
        #expect(result.syncedCount == 0)
        #expect(result.removedCount == 0)
        #expect(f.env.service.attemptedTrackIds.isEmpty && beforeAttempts.count == 2)
        #expect(f.env.files(in: f.device) == before)
        let file = try m3u(f.device, name: "Mix.m3u8")
        let second = try #require(file.range(of: "Second"))
        let first = try #require(file.range(of: "First"))
        #expect(second.lowerBound < first.lowerBound, "the new order is on the device")

        let after = try await f.env.service.previewSync(profileId: f.profile.id!)
        #expect(after.playlistsToUpdate == 0)
    }

    @Test func aTrackAddedToThePlaylistCountsOnceNotAsAnExtraPlaylist() async throws {
        let f = try await syncedFixture()
        try f.env.localTrack(3, title: "Third")
        try await f.env.playlists.replaceTrackList(playlistId: f.playlist.id!, trackIds: [1, 2, 3])
        let plan = try await f.env.service.previewSync(profileId: f.profile.id!)
        #expect(plan.filesToAdd.map(\.trackId) == [3])
        #expect(plan.playlistsToUpdate == 1)
    }

    @Test func aMemberThatCantBeCopiedDoesNotMakeThePlaylistOutOfDate() async throws {
        let f = try await syncedFixture()
        try f.env.remoteTrack(9, title: "Not Downloaded")
        try await f.env.playlists.replaceTrackList(playlistId: f.playlist.id!, trackIds: [1, 2, 9])
        let plan = try await f.env.service.previewSync(profileId: f.profile.id!)
        #expect(plan.filesToSkip.map(\.trackId) == [9])
        #expect(plan.playlistsToUpdate == 0, "a skipped track is not in the file")
    }

    @Test func withoutPlaylistFilesThereIsNothingToUpdate() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("PLAYER")
        let profile = try await env.profile("Player", device: device, generateM3U8: false)
        try env.localTrack(1, title: "First")
        let playlist = try await env.playlists.create(name: "Mix")
        try await env.playlists.replaceTrackList(playlistId: playlist.id!, trackIds: [1])
        try await env.sync.addPlaylist(profileId: profile.id!, playlistId: playlist.id!)
        _ = try await env.service.executeSync(profileId: profile.id!)
        try await env.playlists.replaceTrackList(playlistId: playlist.id!, trackIds: [1])
        #expect(try await env.service.previewSync(profileId: profile.id!).playlistsToUpdate == 0)
    }

    // MARK: Words

    private func state(playlists: Int, add: Int = 0, remove: Int = 0, cleanUp: Bool = true) -> SyncProfileState {
        SyncProfileState.make(SyncProfileStateInput(
            profileName: "Player", deviceName: "PLAYER", destination: .connected,
            libraryDrive: LibraryDriveState(volumeName: "Lexxar", isConnected: true), hasContent: true,
            plan: SyncPlanSummary(add: add, remove: remove, skip: 0, addBytes: 0, freeBytes: 10_000_000_000,
                                  cleanUp: cleanUp, totalTracks: 2, playlistsToUpdate: playlists),
            planComputedAt: Date(timeIntervalSince1970: 1_800_000_000),
            now: Date(timeIntervalSince1970: 1_800_000_060)))
    }

    @Test func syncNowIsEnabledForPlaylistOnlyChangesWithTheirOwnCount() {
        let s = state(playlists: 2)
        #expect(s.canSyncNow)
        #expect(s.planSentence?.contains("Add 0 · Remove 0 · Skip 0 · 2 playlists to update ·") == true)
        #expect(s.sidebarText == "2 playlists to update")
        #expect(s.headerFacts.contains("2 playlists to update"))
        #expect(state(playlists: 1).planSentence?.contains("1 playlist to update") == true)
    }

    @Test func withNoPlaylistChangeSyncNowStaysDisabledAsBefore() {
        let s = state(playlists: 0)
        #expect(!s.canSyncNow)
        #expect(s.syncNowDisabledReason == "Everything in this profile is on “PLAYER”.")
        #expect(s.planSentence?.contains("playlist") == false)
    }

    @Test func aPlanStoredBeforeV56DecodesWithZeroPlaylists() throws {
        let json = """
        {"add":3,"remove":1,"skip":2,"add_bytes":300,"remove_bytes":0,"free_bytes":9000,"clean_up":true,"total_tracks":5}
        """
        let plan = try JSONDecoder().decode(SyncPlanSummary.self, from: Data(json.utf8))
        #expect(plan.playlistsToUpdate == 0 && plan.add == 3)
        let again = try JSONDecoder().decode(SyncPlanSummary.self,
                                             from: JSONEncoder().encode(SyncPlanSummary(add: 1, remove: 0, skip: 0, addBytes: 0, freeBytes: 1, cleanUp: true, playlistsToUpdate: 4)))
        #expect(again.playlistsToUpdate == 4)
    }
}
