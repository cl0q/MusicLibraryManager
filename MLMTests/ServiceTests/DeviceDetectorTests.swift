import Testing
import Foundation
import GRDB
@testable import MLM

/// Wave-0 unit tests for DeviceDetector (Phase 38 Plan 04 Task 2).
///
/// Tests cover:
/// 1. detectRockboxDevices() returns an array without crashing
/// 2. RockboxDevice struct has mountPoint, deviceName, availableSpace fields
/// 3. Smart-default logic: createProfile with device flags persists correctly
/// 4. SyncViewModel.profiles empty initially, then populated after createProfile
@Suite("DeviceDetectorTests")
@MainActor
struct DeviceDetectorTests {

    // MARK: - Setup

    private func makeViewModel() throws -> (DatabaseQueue, SyncViewModel) {
        let db = try DatabaseManager.inMemory()
        let syncRepo = SyncRepository(database: db)
        let trackRepo = TrackRepository(database: db)
        let configRepo = ConfigRepository(database: db)
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ddtest_\(UUID().uuidString)")
        let cache = TranscodeCache(cacheDir: cacheDir)
        let syncSvc = SyncService(
            trackRepository: trackRepo,
            syncRepository: syncRepo,
            configRepository: configRepo,
            transcodeCache: cache
        )
        let vm = SyncViewModel(syncRepository: syncRepo, syncService: syncSvc)
        return (db, vm)
    }

    // MARK: - Tests

    /// Test 1: detectRockboxDevices() completes without crashing.
    /// In CI/test, there may be no Rockbox devices — that is acceptable.
    @Test func detectRockboxDevicesReturnsSafeArray() {
        let devices = DeviceDetector.detectRockboxDevices()
        #expect(devices.count >= 0) // No crash = success
    }

    /// Test 2: RockboxDevice struct exposes mountPoint, deviceName, and availableSpace.
    @Test func rockboxDeviceStructHasRequiredFields() {
        let device = DeviceDetector.RockboxDevice(
            mountPoint: "/Volumes/TestPod",
            deviceName: "TestPod",
            availableSpace: 8_000_000_000
        )
        #expect(device.mountPoint == "/Volumes/TestPod")
        #expect(device.deviceName == "TestPod")
        #expect(device.availableSpace == 8_000_000_000)
    }

    /// Test 3: D-03 smart-defaults — createProfile with device flags persists
    /// generateM3U8=true and transcodeMode="aac_248" to the database.
    @Test func smartDefaultsCreateProfileWithDeviceSettings() async throws {
        let (db, vm) = try makeViewModel()

        // W3-SYNC: the device preset sets the options (S-SYNC-NEWPROFILE.N01).
        _ = await vm.createProfile(name: "TestPod", outputFolder: "/tmp", preset: .rockbox)

        let profiles = try await db.read { db in try SyncProfile.fetchAll(db) }
        let created = profiles.first { $0.name == "TestPod" }
        #expect(created != nil)
        #expect(created?.generateM3U8 == true)
        #expect(created?.transcodeMode == "aac_248")
        #expect(created?.fat32SafePaths == true)
        #expect(created?.cleanupRemovedFiles == true)
    }

    /// Test 4: profiles starts empty, then has 1 entry after createProfile.
    @Test func profilesEmptyThenPopulatedAfterCreate() async throws {
        let (_, vm) = try makeViewModel()

        await vm.loadProfiles()
        #expect(vm.profiles.isEmpty)

        _ = await vm.createProfile(name: "iPod", outputFolder: "/tmp", preset: .plainFolder)
        #expect(vm.profiles.count == 1)
        #expect(vm.profiles.first?.name == "iPod")
    }
}
