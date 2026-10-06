import Foundation
import GRDB
import Testing
@testable import MLM

/// `SyncViewModel` per profile (W3-SYNC): plans for every profile, undoable content edits
/// without alerts, options, delete, the profile's own state. Temporary folders and databases.
@Suite("SyncViewModelTests")
@MainActor
struct SyncViewModelTests {

    @Test func plansAreComputedForEveryConnectedProfileButNotForOneThatIsAway() async throws {
        let env = try await SyncTestEnv()
        let deviceA = try env.device("A")
        let a = try await env.profile("A", device: deviceA)
        let b = try await env.profile("B", device: env.root.appendingPathComponent("Devices/Away"))  // not there
        try env.localTrack(1, title: "One")
        try await env.add([1], to: a)
        try await env.add([1], to: b)

        let vm = env.viewModel()
        await vm.loadProfiles()
        await vm.waitForPlans()

        #expect(vm.plans[a.id!]?.preview?.filesToAdd.map(\.trackId) == [1])
        #expect(vm.plans[b.id!]?.preview == nil, "no plan for an unreachable destination")
        #expect(vm.destinations[a.id!] == .connected)
        #expect(vm.destinations[b.id!] == .notConnected)
        #expect(vm.state(for: vm.profile(a.id!)!).sidebarText == "1 to add")
        #expect(vm.state(for: vm.profile(b.id!)!).sidebarText == "Not connected")
        #expect(vm.results[a.id!]?.lastConnectedAt != nil, "the connection date is remembered")
    }

    @Test func aContentChangeRecomputesThatProfilesPlan() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("A")
        let a = try await env.profile("A", device: device)
        try env.localTrack(1, title: "One")
        try env.localTrack(2, title: "Two")
        try await env.add([1], to: a)
        let vm = env.viewModel()
        await vm.loadProfiles()
        await vm.waitForPlans()
        #expect(vm.plans[a.id!]?.preview?.filesToAdd.count == 1)

        await vm.addTracks([2], to: vm.profile(a.id!)!)
        env.notifications.post(name: .syncProfileDidChange, object: nil, userInfo: ["profileId": a.id!])
        try await waitUntil { vm.plans[a.id!]?.preview?.filesToAdd.count == 2 }
    }

    @Test func removingContentIsUndoableAndAsksNothing() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("A")
        let a = try await env.profile("A", device: device)
        try env.localTrack(1, title: "One")
        let playlist = try await env.playlists.createNumbered(baseName: "Warm-up", trackIds: [1])
        try await env.add([1], to: a)
        try await env.sync.addPlaylist(profileId: a.id!, playlistId: playlist.id!)
        let vm = env.viewModel()
        await vm.loadProfiles()
        await vm.loadContent(a.id!)
        let profile = vm.profile(a.id!)!

        await vm.removePlaylists([playlist.id!], from: profile)
        #expect(try await env.sync.fetchProfilePlaylists(profileId: a.id!).isEmpty)
        #expect(env.status.message?.text == "Removed “Warm-up” from “A” — the files leave the device at the next sync")
        #expect(env.undoManager.undoActionName == "Remove from “A”")

        await vm.removeTracks([1], from: profile)
        #expect(try await env.sync.fetchProfileTracks(profileId: a.id!).isEmpty)
        #expect(env.status.message?.text == "Removed “One” from “A” — its file leaves the device at the next sync")

        env.undoManager.undo()
        await env.undo.waitUntilIdle()
        env.undoManager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.sync.fetchProfileTracks(profileId: a.id!).compactMap(\.id) == [1])
        #expect(try await env.sync.fetchProfilePlaylists(profileId: a.id!).compactMap(\.id) == [playlist.id!])
    }

    @Test func addToSyncProfileIsUndoableAndNamesItsProfile() async throws {
        let env = try await SyncTestEnv()
        let a = try await env.profile("A", device: try env.device("A"))
        let b = try await env.profile("B", device: try env.device("B"))
        try env.localTrack(1, title: "One")
        let vm = env.viewModel()
        await vm.loadProfiles()

        await vm.addTracks([1], to: vm.profile(b.id!)!)
        #expect(try await env.sync.fetchProfileTracks(profileId: b.id!).compactMap(\.id) == [1])
        #expect(try await env.sync.fetchProfileTracks(profileId: a.id!).isEmpty, "only the named profile changes")
        #expect(env.status.message?.text == "Added 1 track to “B”")
        env.undoManager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.sync.fetchProfileTracks(profileId: b.id!).isEmpty)
    }

    @Test func duplicateIsUndoableAndCopiesEveryOption() async throws {
        let env = try await SyncTestEnv()
        let a = try await env.profile("iPod", device: try env.device("A"))
        try await env.sync.updateSettings(profileId: a.id!, artworkMode: "resize_250")
        await env.edits.duplicateSyncProfile(a.id!, name: "iPod")
        let all = try await env.sync.fetchAll()
        let copy = try #require(all.first { $0.name == "iPod copy" })
        #expect(copy.artworkMode == "resize_250")
        #expect(env.status.message?.text == "Created “iPod copy”")
        env.undoManager.undo()
        await env.undo.waitUntilIdle()
        #expect(try await env.sync.fetchAll().map(\.name) == ["iPod"])
    }

    @Test func optionsSaveAtOnceAndKeepTheirKeys() async throws {
        let env = try await SyncTestEnv()
        let a = try await env.profile("A", device: try env.device("A"))
        let vm = env.viewModel()
        await vm.loadProfiles()
        await vm.updateOptions(a.id!, generateM3U8: true, transcodeMode: "aac_320", cleanupRemovedFiles: false,
                               playlistFormat: "doppi", normalizeLoudness: true, artworkMode: "resize_250")
        let stored = try #require(try await env.sync.fetch(id: a.id!))
        #expect(stored.generateM3U8)
        #expect(stored.transcodeMode == "aac_320")
        #expect(!stored.cleanupRemovedFiles)
        #expect(stored.playlistFormat == "doppi")
        #expect(stored.normalizeLoudness)
        #expect(stored.artworkMode == "resize_250")
        #expect(vm.profile(a.id!)?.transcodeMode == "aac_320")
    }

    @Test func changeDestinationDeletesNothingAndPlansAgain() async throws {
        let env = try await SyncTestEnv()
        let old = try env.device("Old")
        let new = try env.device("New")
        let a = try await env.profile("A", device: old)
        try env.localTrack(1, title: "One")
        try await env.add([1], to: a)
        _ = try await env.service.executeSync(profileId: a.id!)
        let vm = env.viewModel()
        await vm.loadProfiles()
        await vm.changeDestination(a.id!, to: new.path)
        await vm.waitForPlans()
        #expect(env.files(in: old) == ["Artist/One.mp3"], "nothing is deleted on the old destination")
        #expect(vm.profile(a.id!)?.outputFolder == new.path)
        #expect(vm.plans[a.id!]?.preview?.filesToAdd.map(\.trackId) == [1], "the next sync copies to the new one")
    }

    @Test func deletingAProfileRemovesItsResultAndLeavesTheDeviceAlone() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("A")
        let a = try await env.profile("A", device: device)
        try env.localTrack(1, title: "One")
        try await env.add([1], to: a)
        _ = try await env.service.executeSync(profileId: a.id!)
        let vm = env.viewModel()
        await vm.loadProfiles()
        await vm.deleteProfile(vm.profile(a.id!)!)
        #expect(vm.profiles.isEmpty)
        #expect(try await env.results.fetch(profileID: a.id!) == nil)
        #expect(env.files(in: device) == ["Artist/One.mp3"], "music on the device is not touched")
    }

    @Test func createProfileRefusesADuplicateNameInTheSheet() async throws {
        let env = try await SyncTestEnv()
        let vm = env.viewModel()
        let first = await vm.createProfile(name: "iPod", outputFolder: try env.device("A").path, preset: .rockbox)
        #expect(first?.generateM3U8 == true)
        #expect(first?.artworkMode == "resize_250")
        let second = await vm.createProfile(name: "ipod", outputFolder: try env.device("B").path, preset: .plainFolder)
        #expect(second == nil)
        #expect(vm.errorMessage == "A sync profile with this name already exists.")
    }

    @Test func createFromASelectionAddsTheTracks() async throws {
        let env = try await SyncTestEnv()
        try env.localTrack(1, title: "One")
        try env.localTrack(2, title: "Two")
        let vm = env.viewModel()
        let created = await vm.createProfile(name: "Car", outputFolder: try env.device("Car").path, preset: .plainFolder,
                                             trackIDs: [2, 1])
        let id = try #require(created?.id)
        #expect(Set(try await env.sync.fetchProfileTracks(profileId: id).compactMap(\.id)) == [1, 2])
    }

    @Test func syncNowStoresTheResultAndSaysSoInTheStatusBar() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("A")
        let a = try await env.profile("A", device: device)
        try env.localTrack(1, title: "One")
        try env.remoteTrack(2, title: "Two")
        try await env.add([1, 2], to: a)
        let vm = env.viewModel()
        await vm.loadProfiles()
        vm.syncNow(vm.profile(a.id!)!)
        await vm.waitForRun(a.id!)
        #expect(vm.results[a.id!]?.outcome == .completed)
        #expect(env.status.message?.text == "Sync finished — 1 copied · 1 skipped")
        #expect(env.status.message?.actions.isEmpty == true, "a plain folder can't be ejected")
    }

    private func waitUntil(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for the condition")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
