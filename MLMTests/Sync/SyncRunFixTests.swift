import Foundation
import GRDB
import Testing
@testable import MLM

/// The named sync fixes of W3-SYNC on temporary folders and databases (no device, no /Volumes):
/// skips with reasons (PP-SYNC-01), per-profile results and Retry Failed (PP-SYNC-02), a removed
/// device that waits and resumes without copying anything twice.
@Suite("SyncRunFixTests")
@MainActor
struct SyncRunFixTests {

    // MARK: Skips are reported, never "pending"

    @Test func planListsTracksThatCantBeCopiedUnderSkipWithTheirReason() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("IPOD")
        let profile = try await env.profile("iPod", device: device)
        try env.localTrack(1, title: "Here")
        try env.remoteTrack(2, title: "Never Downloaded")
        try env.remoteTrack(3, title: "Failed", failed: true)
        let gone = try env.localTrack(4, title: "Gone")
        try FileManager.default.removeItem(at: gone)
        try await env.add([1, 2, 3, 4], to: profile)

        let plan = try await env.service.previewSync(profileId: profile.id!)
        #expect(plan.filesToAdd.map(\.trackId) == [1])
        #expect(Dictionary(uniqueKeysWithValues: plan.filesToSkip.map { ($0.trackId, $0.reason) })
                == [2: .notDownloaded, 3: .downloadFailed, 4: .fileMissing])
        #expect(plan.summary.skip == 3)
        #expect(plan.totalTracks == 4)
    }

    @Test func withTheLibraryDriveAwayNothingIsCalledMissing() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("IPOD")
        let profile = try await env.profile("iPod", device: device)
        let file = try env.localTrack(1, title: "Here")
        try FileManager.default.removeItem(at: file)  // unreadable because the drive is "away"
        try await env.add([1], to: profile)
        env.destinations.libraryReachable = false

        let plan = try await env.service.previewSync(profileId: profile.id!)
        #expect(plan.filesToSkip.map(\.reason) == [.libraryDriveAway])
        #expect(!plan.isLibraryReachable)
    }

    @Test func aSyncStoresItsSkipsAndCopiesForThisProfileOnly() async throws {
        let env = try await SyncTestEnv()
        let deviceA = try env.device("A")
        let deviceB = try env.device("B")
        let a = try await env.profile("A", device: deviceA)
        let b = try await env.profile("B", device: deviceB)
        try env.localTrack(1, title: "One")
        try env.remoteTrack(2, title: "Two")
        try await env.add([1, 2], to: a)

        let result = try await env.service.executeSync(profileId: a.id!)
        #expect(result.syncedCount == 1)
        #expect(result.skippedTracks.map(\.trackID) == [2])
        #expect(result.skippedTracks.first?.reason == .notDownloaded)

        let stored = try await env.results.fetchAll()
        #expect(stored[a.id!]?.outcome == .completed)
        #expect(stored[a.id!]?.copiedCount == 1)
        #expect(stored[a.id!]?.skipped.map(\.trackID) == [2])
        #expect(stored[a.id!]?.plan?.skip == 1)
        #expect(stored[b.id!] == nil, "B has no result of A's sync")
        #expect(env.files(in: deviceA) == ["Artist/One.mp3"])
        #expect(env.files(in: deviceB).isEmpty)
    }

    // MARK: Retry Failed — this profile, this destination (PP-SYNC-02)

    @Test func retryFailedOfProfileANeverTouchesProfileBsDestination() async throws {
        let env = try await SyncTestEnv()
        let deviceA = try env.device("A")
        let deviceB = try env.device("B")
        let a = try await env.profile("A", device: deviceA)
        let b = try await env.profile("B", device: deviceB)
        try env.localTrack(1, title: "Failed On A")
        try env.localTrack(2, title: "Only On B")
        try await env.add([1], to: a)
        try await env.add([1, 2], to: b)  // track 1 is in B too: it must still not land on B
        let failure = SyncResultFailure(trackID: 1, title: "Failed On A", artist: "Artist",
                                        reason: "Destination is full", devicePath: deviceA.path + "/Artist/Failed On A.mp3")
        let other = SyncResultFailure(trackID: 2, title: "Only On B", artist: "Artist",
                                      reason: "Destination is full", devicePath: deviceB.path + "/Artist/Only On B.mp3")
        for (profile, failures) in [(a, [failure]), (b, [other])] {
            try await env.results.begin(profileID: profile.id!, startedAt: Date(), plannedCount: 1, plan: nil, operationID: nil)
            try await env.results.finish(profileID: profile.id!, outcome: .completed, endedAt: Date(), copiedCount: 0,
                                         removedCount: 0, failures: failures, skipped: [])
        }

        let vm = env.viewModel()
        await vm.loadProfiles()
        vm.retryFailed(vm.profile(a.id!)!)
        await vm.waitForRun(a.id!)

        #expect(env.files(in: deviceA) == ["Artist/Failed On A.mp3"])
        #expect(env.files(in: deviceB).isEmpty, "Retry of A never writes into B's destination")
        #expect(try await env.syncedTrackIDs(b).isEmpty)
        let stored = try await env.results.fetchAll()
        #expect(stored[a.id!]?.failures.isEmpty == true)
        #expect(stored[a.id!]?.copiedCount == 1)
        #expect(stored[b.id!]?.failures == [other], "B keeps its own failures")
    }

    @Test func retryCopiesOnlyTheGivenTracksAndRemovesNothing() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("A")
        let profile = try await env.profile("A", device: device)
        try env.localTrack(1, title: "One")
        try env.localTrack(2, title: "Two")
        try await env.add([1, 2], to: profile)

        let result = try await env.service.executeSync(profileId: profile.id!, onlyTrackIDs: [2])
        #expect(result.syncedTrackIDs == [2])
        #expect(env.files(in: device) == ["Artist/Two.mp3"])
    }

    // MARK: Device removed mid-sync (UC-JOB-10)

    @Test func aRemovedDeviceWaitsAndResumesWithoutCopyingAnythingTwice() async throws {
        // Start guard + the first file see the device; then it is gone until the first wait.
        let destinations = ScriptedDestinations(disconnectAfter: 2)
        let env = try await SyncTestEnv(destinations: destinations)
        let device = try env.device("IPOD")
        let profile = try await env.profile("iPod", device: device)
        for (id, title) in [(1, "One"), (2, "Two"), (3, "Three")] { try env.localTrack(Int64(id), title: title) }
        try await env.add([1, 2, 3], to: profile)
        let center = ActivityCenter(scheduler: SystemActivityScheduler(), graceInterval: 0)
        env.service.activity = center
        let results = env.results
        let profileID = profile.id!
        let seenWhileWaiting = LockedBox<SyncProfileResult?>(nil)
        destinations.onWait = { _ in
            // The run recorded the interruption before it started waiting.
            seenWhileWaiting.value = try? await results.fetch(profileID: profileID)
            return true  // the device is back
        }

        let result = try await env.service.executeSync(profileId: profileID)

        #expect(result.syncedCount == 3)
        #expect(result.failedCount == 0, "nothing is marked failed because the device went away")
        #expect(result.interruptions == 1)
        #expect(env.service.attemptedTrackIds.sorted() == [1, 2, 3], "each file is copied exactly once")
        #expect(Set(env.service.attemptedTrackIds).count == env.service.attemptedTrackIds.count)
        #expect(try await env.syncedTrackIDs(profile) == [1, 2, 3])
        #expect(env.files(in: device).count == 3)
        #expect(seenWhileWaiting.value?.outcome == .interrupted)
        #expect(seenWhileWaiting.value?.copiedCount == 1)
        #expect(seenWhileWaiting.value?.plannedCount == 3)
        let stored = try await env.results.fetch(profileID: profileID)
        #expect(stored?.outcome == .completed)
        #expect(stored?.lastInterruptedAt != nil)
        // One operation, from start to end, also across the interruption.
        await Task.yield()
        #expect(center.operations.filter { $0.kind == .sync }.count == 1)
    }

    @Test func aResumedRunCopiesOnlyWhatIsNotOnTheDevice() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("IPOD")
        let profile = try await env.profile("iPod", device: device)
        for (id, title) in [(1, "One"), (2, "Two")] { try env.localTrack(Int64(id), title: title) }
        try await env.add([1], to: profile)
        _ = try await env.service.executeSync(profileId: profile.id!)
        try await env.add([2], to: profile)

        // A later run (e.g. Sync Now after a relaunch interrupted it) plans only the missing file.
        let plan = try await env.service.previewSync(profileId: profile.id!, forceRefresh: true)
        #expect(plan.filesToAdd.map(\.trackId) == [2])
        _ = try await env.service.executeSync(profileId: profile.id!)
        #expect(env.service.attemptedTrackIds == [2])
    }

    @Test func cancellingWhileWaitingForTheDeviceEndsTheRunAsCancelled() async throws {
        let destinations = ScriptedDestinations(disconnectAfter: 1)  // only the start guard sees it
        let env = try await SyncTestEnv(destinations: destinations)
        let device = try env.device("IPOD")
        let profile = try await env.profile("iPod", device: device)
        try env.localTrack(1, title: "One")
        try await env.add([1], to: profile)
        let service = env.service
        destinations.onWait = { _ in
            service.cancelSync()
            return false
        }
        let result = try await env.service.executeSync(profileId: profile.id!)
        #expect(result.wasCancelled)
        #expect(result.failedCount == 0)
        #expect(try await env.syncedTrackIDs(profile).isEmpty)
        #expect(try await env.results.fetch(profileID: profile.id!)?.outcome == .cancelled)
    }

    @Test func aSyncRefusesToStartWhenTheDestinationIsGone() async throws {
        let destinations = ScriptedDestinations(disconnectAfter: 0)
        let env = try await SyncTestEnv(destinations: destinations)
        let device = try env.device("IPOD")
        let profile = try await env.profile("iPod", device: device)
        try env.localTrack(1, title: "One")
        try await env.add([1], to: profile)
        await #expect(throws: SyncRunError.self) {
            _ = try await env.service.executeSync(profileId: profile.id!)
        }
        #expect(env.files(in: device).isEmpty)
    }

    // MARK: Space (V-SYNC-DETAIL.E23)

    @Test func removalsAreSizedSoTheirSpaceCanBeCredited() async throws {
        let env = try await SyncTestEnv()
        let device = try env.device("IPOD")
        let profile = try await env.profile("iPod", device: device)
        try env.localTrack(1, title: "One")
        try await env.add([1], to: profile)
        _ = try await env.service.executeSync(profileId: profile.id!)
        try await env.sync.removeTrack(profileId: profile.id!, trackId: 1)

        let plan = try await env.service.previewSync(profileId: profile.id!, forceRefresh: true)
        #expect(plan.filesToRemove.map(\.trackId) == [1])
        #expect(plan.totalRemoveSize == Int64("audio-1".utf8.count))
        #expect(plan.summary.removeBytes == plan.totalRemoveSize)
    }

    @Test func endMessageCountsWhatHappened() {
        var result = SyncService.SyncResult()
        result.syncedCount = 214
        result.failedCount = 3
        result.skippedCount = 9
        #expect(SyncViewModel.endMessage(result, retry: false) == "Sync finished — 214 copied · 3 failed · 9 skipped")
        result.wasCancelled = true
        #expect(SyncViewModel.endMessage(result, retry: false).hasPrefix("Sync cancelled — 214 copied"))
    }
}

/// A value shared with a closure that runs off the main actor.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
