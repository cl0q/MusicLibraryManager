import Foundation
import Testing
@testable import MLM

/// Every §15.8 word and plan sentence of `SyncProfileState` (UC-SIDE-07, DEC-027).
@Suite("SyncProfileStateTests")
struct SyncProfileStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let drive = LibraryDriveState(volumeName: "Lexxar", isConnected: true)

    private func input(_ change: (inout SyncProfileStateInput) -> Void = { _ in }) -> SyncProfileStateInput {
        var input = SyncProfileStateInput(
            profileName: "iPod Classic", deviceName: "IPOD CLASSIC", destination: .connected,
            libraryDrive: drive, hasContent: true,
            plan: SyncPlanSummary(add: 214, remove: 12, skip: 9, addBytes: 3_100_000_000, removeBytes: 200_000_000,
                                  freeBytes: 12_000_000_000, cleanUp: true, totalTracks: 1_482),
            planComputedAt: now.addingTimeInterval(-120), now: now)
        change(&input)
        return input
    }

    private func state(_ change: (inout SyncProfileStateInput) -> Void = { _ in }) -> SyncProfileState {
        SyncProfileState.make(input(change))
    }

    private func rel(_ seconds: TimeInterval) -> String {
        SyncProfileState.relative(now.addingTimeInterval(-seconds), now: now)
    }

    private func bytes(_ n: Int64) -> String { SyncProfileState.bytes(n) }

    private func completed(failures: Int = 0, endedAgo: TimeInterval = 7200) -> SyncProfileResult {
        SyncProfileResult(
            profileID: 1, startedAt: now.addingTimeInterval(-endedAgo - 60), endedAt: now.addingTimeInterval(-endedAgo),
            outcome: .completed, plannedCount: 214, copiedCount: 205, removedCount: 12,
            failures: (0..<failures).map { SyncResultFailure(trackID: Int64($0), title: "T\($0)", artist: "A",
                                                              reason: "Destination is full", devicePath: "/x") },
            skipped: [SyncResultSkip(trackID: 99, title: "S", artist: "A", reason: .notDownloaded)])
    }

    // MARK: Sidebar second line (UC-SIDE-07)

    @Test func connectedWithTracksToAdd() {
        let s = state()
        #expect(s.sidebarText == "214 to add")
        #expect(s.connectionText == "Connected")
        #expect(s.headerFacts.first == "214 to add")
        #expect(s.page == .ready)
        #expect(s.canSyncNow)
        #expect(s.sidebarProgress == nil)
    }

    @Test func notConnected() {
        let seen = now.addingTimeInterval(-86_400 * 3)
        let s = state {
            $0.destination = .notConnected
            $0.result = SyncProfileResult(profileID: 1, lastConnectedAt: seen)
        }
        #expect(s.sidebarText == "Not connected")
        #expect(s.connectionText == "Not connected")
        #expect(s.headerFacts == ["last connected \(SyncProfileState.day(seen))"])
        #expect(s.syncNowDisabledReason == "Connect “IPOD CLASSIC” to sync.")
        #expect(s.page == .notConnected)
        #expect(s.planStatus == "From \(SyncProfileState.day(now.addingTimeInterval(-120))) — will be checked against the device when it is connected")
    }

    @Test func folderNotFoundOnAConnectedDevice() {
        let s = state { $0.destination = .folderNotFound }
        #expect(s.sidebarText == "Folder not found on “IPOD CLASSIC”")
        #expect(s.syncNowDisabledReason == "Folder not found on “IPOD CLASSIC”")
    }

    @Test func syncingShowsTheActivityNumbersAndAThinBar() {
        let s = state { $0.run = SyncRunSnapshot(operationID: UUID(), phase: .running, completed: 86, total: 214) }
        #expect(s.sidebarText == "Syncing 86 of 214")
        #expect(s.runText == "Syncing 86 of 214")
        #expect(s.sidebarProgress == Double(86) / 214)
        #expect(s.page == .syncing)
        #expect(!s.canSyncNow)
    }

    @Test func pausedAndQueued() {
        let paused = state { $0.run = SyncRunSnapshot(operationID: UUID(), phase: .paused, completed: 86, total: 214) }
        #expect(paused.sidebarText == "Paused · 86 of 214")
        #expect(paused.page == .paused)
        let queued = state { $0.run = SyncRunSnapshot(operationID: UUID(), phase: .queued, completed: 0, total: nil,
                                                      waitText: "Starts after “Car”") }
        #expect(queued.sidebarText == "Queued · Starts after “Car”")
        #expect(queued.page == .queued)
    }

    @Test func syncedRelativeTime() {
        let s = state {
            $0.plan = SyncPlanSummary(add: 0, remove: 0, skip: 0, addBytes: 0, freeBytes: 12_000_000_000, cleanUp: true)
            $0.result = completed(endedAgo: 7200)
        }
        #expect(s.sidebarText == "Synced \(rel(7200))")
        #expect(s.syncNowDisabledReason == "Everything in this profile is on “IPOD CLASSIC”.")
        #expect(s.headerFacts == ["last synced \(rel(7200))"])
    }

    @Test func syncedWithFailuresTakesPrecedenceOverToAdd() {
        let s = state { $0.result = completed(failures: 3) }
        #expect(s.sidebarText == "Synced \(rel(7200)) · 3 failed")
        #expect(s.failedCount == 3)
        #expect(s.page == .finishedWithFailures)
        #expect(s.lastSyncLine == "Synced \(rel(7200)) · 205 copied · 12 removed · 3 failed · 1 skipped")
    }

    @Test func connectedNeverSyncedAndNothingToAdd() {
        let s = state { $0.plan = SyncPlanSummary(add: 0, remove: 0, skip: 0, addBytes: 0, freeBytes: 1, cleanUp: true) }
        #expect(s.sidebarText == "Connected")  // IMP-007
        #expect(s.headerFacts == ["not synced yet"])
        #expect(s.lastSyncLine == "Not synced yet.")
    }

    @Test func legacyLastSyncedBeforeV47() {
        let s = state {
            $0.plan = SyncPlanSummary(add: 0, remove: 0, skip: 0, addBytes: 0, freeBytes: 1, cleanUp: true)
            $0.legacySyncedAt = now.addingTimeInterval(-3600)
        }
        #expect(s.sidebarText == "Synced \(rel(3600))")
    }

    // MARK: Device removed (interrupted)

    @Test func interruptedWhileTheOperationWaits() {
        let s = state {
            $0.destination = .notConnected
            $0.run = SyncRunSnapshot(operationID: UUID(), phase: .waitingForDevice, completed: 86, total: 214,
                                     waitText: "Waiting for “IPOD CLASSIC”")
            $0.result = SyncProfileResult(profileID: 1, startedAt: now, outcome: .interrupted, plannedCount: 214,
                                          copiedCount: 86, lastInterruptedAt: now)
        }
        #expect(s.sidebarText == "Interrupted — 86 of 214 copied")
        #expect(s.page == .interrupted)
        #expect(s.banner?.kind == .interrupted)
        #expect(s.banner?.title == "“IPOD CLASSIC” was disconnected — 86 of 214 copied · Resume when connected")
    }

    @Test func interruptedAfterARelaunchHasNoOperationButStillSaysSo() {
        let s = state {
            $0.result = SyncProfileResult(profileID: 1, startedAt: now, outcome: .running, plannedCount: 214,
                                          copiedCount: 86)
        }
        #expect(s.sidebarText == "Interrupted — 86 of 214 copied")
        #expect(s.banner?.title == "“IPOD CLASSIC” was disconnected — 86 of 214 copied")
        #expect(s.page == .interrupted)
        #expect(s.canSyncNow, "Sync Now continues with what is not on the device")
    }

    // MARK: Library drive away

    @Test func libraryDriveAway() {
        let s = state { $0.libraryDrive = LibraryDriveState(volumeName: "Lexxar", isConnected: false) }
        #expect(s.planSentence == "Can’t sync — “Lexxar” is not connected")
        #expect(s.syncNowDisabledReason == "Can’t sync — “Lexxar” is not connected")
        #expect(s.banner?.kind == .libraryDriveAway)
        #expect(s.banner?.title == "Can’t sync — “Lexxar” is not connected.")
        #expect(s.page == .libraryDriveAway)
        #expect(s.sidebarText == "214 to add", "the row keeps the profile's own words")
    }

    // MARK: Plan sentence (§15.8)

    @Test func planSentence() {
        #expect(state().planSentence == "Add 214 · Remove 12 · Skip 9 · \(bytes(3_100_000_000)) of \(bytes(12_000_000_000)) free")
        #expect(state().planStatus == "Up to date · computed \(rel(120))")
    }

    @Test func planSentenceWithCleanUpOff() {
        let s = state {
            $0.plan = SyncPlanSummary(add: 3, remove: 5, skip: 0, addBytes: 1_000, freeBytes: 2_000, cleanUp: false)
        }
        #expect(s.planSentence == "Add 3 · Remove 0 — Clean up is off · Skip 0 · \(bytes(1_000)) of \(bytes(2_000)) free")
    }

    @Test func notEnoughSpaceCreditsRemovals() {
        let s = state {
            $0.plan = SyncPlanSummary(add: 214, remove: 12, skip: 9, addBytes: 3_100_000_000, removeBytes: 400_000_000,
                                      freeBytes: 2_000_000_000, cleanUp: true)
            $0.planHasSufficientSpace = false
        }
        let sentence = "Not enough space — \(bytes(3_100_000_000)) needed, \(bytes(2_400_000_000)) free after removals"
        #expect(s.syncNowDisabledReason == sentence)
        #expect(s.planSentence == "Add 214 · Remove 12 · Skip 9 · \(sentence)")
    }

    @Test func removeOnlyWithCleanUpOffHasNothingToDo() {
        let s = state {
            $0.plan = SyncPlanSummary(add: 0, remove: 5, skip: 0, addBytes: 0, freeBytes: 1, cleanUp: false)
        }
        #expect(!s.canSyncNow, "Remove is not counted when Clean up is off")
    }

    @Test func emptyProfile() {
        let s = state { $0.hasContent = false; $0.plan = nil }
        #expect(s.page == .empty)
        #expect(s.planSentence == nil)
        #expect(s.syncNowDisabledReason == "Nothing to sync yet — add playlists or tracks below, or drag them onto “iPod Classic” in the sidebar.")
    }

    @Test func planNotComputedYet() {
        let s = state { $0.plan = nil }
        #expect(s.syncNowDisabledReason == "Updating plan…")
    }

    @Test func failedRun() {
        let s = state {
            $0.result = SyncProfileResult(profileID: 1, startedAt: now, endedAt: now, outcome: .failed,
                                          failureCause: "Couldn’t write the playlist files on “IPOD CLASSIC”")
        }
        #expect(s.page == .error)
        #expect(s.lastSyncLine == "Couldn’t finish \(rel(0)) — Couldn’t write the playlist files on “IPOD CLASSIC”")
    }

    // MARK: Run snapshot from Activity

    @Test func runSnapshotOnlyFromAnActiveSyncOperation() {
        let id = UUID()
        let running = ActivityEcho(operationID: id, kind: .sync, state: .running, verb: "Syncing",
                                   progressText: "86 of 214", fraction: 0.4, waitText: nil, failedCount: 0, resultText: nil)
        #expect(SyncRunSnapshot.from(running, progress: ActivityProgress(completed: 86, total: 214))?.phase == .running)
        let waiting = ActivityEcho(operationID: id, kind: .sync, state: .queued, verb: "Syncing", progressText: nil,
                                   fraction: nil, waitText: "Waiting for “IPOD”", failedCount: 0, resultText: nil)
        #expect(SyncRunSnapshot.from(waiting)?.phase == .waitingForDevice)
        let scan = ActivityEcho(operationID: id, kind: .deviceScan, state: .running, verb: "Reading", progressText: nil,
                                fraction: nil, waitText: nil, failedCount: 0, resultText: nil)
        #expect(SyncRunSnapshot.from(scan) == nil, "a device scan is not a sync")
        let done = ActivityEcho(operationID: id, kind: .sync, state: .completed, verb: "Synced", progressText: nil,
                                fraction: nil, waitText: nil, failedCount: 0, resultText: "214 synced")
        #expect(SyncRunSnapshot.from(done) == nil)
    }

    // MARK: Words around the state

    @Test func deviceNamesAndStatus() {
        #expect(SyncDestination.deviceName(for: "/Volumes/IPOD CLASSIC/Music") == "IPOD CLASSIC")
        #expect(SyncDestination.deviceName(for: "/Users/o/Doppi") == "Doppi")
        #expect(SyncDestination.status(for: "/Volumes/IPOD/Music", isVolumeMounted: { _ in false }, folderExists: { _ in true }) == .notConnected)
        #expect(SyncDestination.status(for: "/Volumes/IPOD/Music", isVolumeMounted: { _ in true }, folderExists: { _ in false }) == .folderNotFound)
        #expect(SyncDestination.status(for: "/Volumes/IPOD", isVolumeMounted: { _ in true }, folderExists: { _ in true }) == .connected)
        #expect(SyncDestination.status(for: "", isVolumeMounted: { _ in true }, folderExists: { _ in true }) == .none)
        #expect(!SyncDestination.isReachable("/Volumes/IPOD/Music", isVolumeMounted: { _ in false }, folderExists: { _ in true }),
                "a leftover folder on the Mac's own disk is not the device")
    }

    @Test func failureReasonsInPlainWords() {
        #expect(SyncFailureReasonText.plain("Destination is full") == "The device is full")
        #expect(SyncFailureReasonText.plain("No organized path for keepOriginals") == "File missing in the library")
        #expect(SyncFailureReasonText.plain("Track metadata not found in database") == "The track is no longer in the library")
        #expect(SyncFailureReasonText.plain("Transcode failed") == "Couldn’t convert to AAC")
    }

    @Test func presetsSayWhatTheySet() {
        #expect(SyncDevicePreset.rockbox.summary == "AAC 248 kbps · artwork 250 px · playlist files (.m3u8) · clean up on")
        #expect(SyncDevicePreset.plainFolder.options.playlistFiles == false)
        let profile = SyncProfile(name: "x", outputFolder: "/x", generateM3U8: true, transcodeMode: "aac_248",
                                  playlistFormat: "rockbox", artworkMode: "resize_250")
        #expect(SyncDevicePreset.matching(profile) == .rockbox)
    }

    @Test func deleteMessageListsTheRunningSync() {
        #expect(SyncProfileSheets.deleteMessage(isSyncing: false)
                == "The profile, its plan and its sync history are removed. Music on the device and in your library is not touched.")
        #expect(SyncProfileSheets.deleteMessage(isSyncing: true).hasSuffix(" The running sync will be cancelled."))
    }
}
