import Testing
import GRDB
import AppKit
@testable import MLM

/// Tests for `PlaylistCoverService` — the cover-image orchestrator.
///
/// Covers the 5 critical behaviors:
/// - fallback PNG generation for 0-track playlists
/// - sticky-lock (cover_is_custom == 1) skip path
/// - setCustomCover flips the lock to 1
/// - resetToAuto clears the lock and regenerates
/// - re-entry guard: own .playlistDidChange emissions are skipped
///
/// Phase 36 Plan 02 Task 3.
@MainActor
@Suite("PlaylistCoverService (Phase 36)", .serialized)
struct PlaylistCoverServiceTests {

    /// Per-test covers folder in a temp dir — the live install under Application Support is
    /// never written. Stored cover paths stay relative (`playlist-covers/<id>.png`).
    private let coversDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("PlaylistCoverServiceTests-\(UUID().uuidString)")
        .appendingPathComponent("playlist-covers")

    private func cleanup() {
        try? FileManager.default.removeItem(at: coversDir.deletingLastPathComponent())
    }

    private func makeService() async throws -> (DatabaseQueue, PlaylistRepository, PlaylistCoverService, NotificationCenter) {
        // PlaylistCoverService.init accepts `any DatabaseWriter`, so DatabaseQueue
        // (returned by DatabaseManager.inMemory()) flows through without a cast.
        let db = try DatabaseManager.inMemory()
        let plRepo = PlaylistRepository(database: db)
        let trRepo = TrackRepository(database: db)
        let cfRepo = ConfigRepository(database: db)
        let center = NotificationCenter()
        let svc = PlaylistCoverService(
            database: db,
            playlistRepository: plRepo,
            trackRepository: trRepo,
            configRepository: cfRepo,
            coversDirectory: coversDir,
            notificationCenter: center
        )
        return (db, plRepo, svc, center)
    }

    @Test func fallback_with_zero_tracks_writes_PNG() async throws {
        let (_, repo, svc, _) = try await makeService()
        defer { cleanup() }
        let pl = try await repo.create(name: "Empty Test")
        let id = pl.id!

        await svc.regenerateCover(playlistId: id)

        // PNG must exist
        let pngURL = coversDir.appendingPathComponent("\(id).png")
        #expect(FileManager.default.fileExists(atPath: pngURL.path),
                "Fallback PNG was not written")

        // DB row updated
        let fetched = try await repo.fetch(id: id)
        #expect(fetched?.coverImagePath == "playlist-covers/\(id).png")
        #expect(fetched?.coverIsCustom == 0)

        // PNG dimensions = 512×512
        let img = NSImage(contentsOf: pngURL)
        #expect(img?.size.width == 512 && img?.size.height == 512)
    }

    @Test func respects_cover_is_custom_flag() async throws {
        let (_, repo, svc, _) = try await makeService()
        defer { cleanup() }
        let pl = try await repo.create(name: "Locked")
        let id = pl.id!
        try await repo.setCoverPath(id: id, path: "playlist-covers/sentinel.png", isCustom: true)

        await svc.regenerateCover(playlistId: id)

        // DB row must be untouched
        let fetched = try await repo.fetch(id: id)
        #expect(fetched?.coverImagePath == "playlist-covers/sentinel.png")
        #expect(fetched?.coverIsCustom == 1)
    }

    @Test func setCustomCover_flipsLockTo1() async throws {
        let (_, repo, svc, _) = try await makeService()
        defer { cleanup() }
        let pl = try await repo.create(name: "Custom Test")
        let id = pl.id!

        // Make a tmp PNG to feed in
        let tmpPNG = FileManager.default.temporaryDirectory
            .appendingPathComponent("custom_cover_\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 256, pixelsHigh: 256,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 32)!
        let pngData = rep.representation(using: .png, properties: [:])!
        try pngData.write(to: tmpPNG)
        defer { try? FileManager.default.removeItem(at: tmpPNG) }

        await svc.setCustomCover(playlistId: id, sourceURL: tmpPNG)

        let pngURL = coversDir.appendingPathComponent("\(id).png")

        let fetched = try await repo.fetch(id: id)
        #expect(fetched?.coverIsCustom == 1, "setCustomCover must flip lock to 1")
        #expect(fetched?.coverImagePath == "playlist-covers/\(id).png")
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
    }

    @Test func resetToAuto_clearsLockAndRegens() async throws {
        let (_, repo, svc, _) = try await makeService()
        defer { cleanup() }
        let pl = try await repo.create(name: "Reset Auto Test")
        let id = pl.id!
        // Precondition: custom
        try await repo.setCoverPath(id: id, path: "playlist-covers/old.png", isCustom: true)

        await svc.resetToAuto(playlistId: id)

        let pngURL = coversDir.appendingPathComponent("\(id).png")

        let fetched = try await repo.fetch(id: id)
        #expect(fetched?.coverIsCustom == 0, "resetToAuto must clear the lock")
        #expect(fetched?.coverImagePath == "playlist-covers/\(id).png",
                "resetToAuto must regenerate (path points at new auto cover)")
        #expect(FileManager.default.fileExists(atPath: pngURL.path))
    }

    @Test func reentry_guard_skips_self_notifications() async throws {
        let (_, repo, svc, center) = try await makeService()
        defer { cleanup() }
        // Keep `svc` alive across the await — the observer's [weak self] would
        // otherwise let the service be released before the test completes.
        _ = svc

        let pl = try await repo.create(name: "Reentry Test")
        let id = pl.id!

        // Capture initial state — no cover yet.
        let fetched1 = try await repo.fetch(id: id)
        #expect(fetched1?.coverImagePath == nil)

        // Post a notification with the service-origin tag.
        center.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["origin": "coverService", "playlistId": id]
        )
        // Yield to let any erroneous re-entry have a chance to run.
        try await Task.sleep(for: .milliseconds(200))

        // Service must NOT have written a cover (no regenerate triggered).
        let fetched2 = try await repo.fetch(id: id)
        #expect(fetched2?.coverImagePath == nil,
                "Service should ignore its own .playlistDidChange emissions (re-entry guard)")
    }
}
