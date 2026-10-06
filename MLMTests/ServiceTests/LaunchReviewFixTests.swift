import Testing
import AppKit
import GRDB
@testable import MLM

/// W3-LAUNCH review round: the library-file icon without `Bundle.module` (S6) and the rule
/// that brings back the setup (S8). Temporary databases only.
@Suite("Launch review fixes (W3-LAUNCH)")
@MainActor
struct LaunchReviewFixTests {

    @Test func theIconFallsBackToTheSystemIconWithoutAnyBundle() {
        let image = LibraryFileIcon.load(from: [])
        #expect(image.size.width > 0 && image.size.height > 0)
    }

    @Test func theIconIsFoundWhereTheResourceBundleIs() {
        let image = LibraryFileIcon.load(from: LibraryFileIcon.candidateBundles())
        #expect(image.size.width > 0)
        // The candidates exist or are skipped; looking never crashes.
        #expect(LibraryFileIcon.candidateBundles().first == Bundle.main)
    }

    /// S8: setup shows for an empty library without a folder — unless it was left with
    /// `Set Up Later`; a folder or a track ends it.
    @Test func setupReturnsOnlyUntilSetUpLater() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LaunchReviewFixTests-\(UUID().uuidString)/music_library.db")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let manager = try DatabaseManager(path: url)
        defer { try? manager.pool.close() }
        let pool = manager.pool

        #expect(await LibrarySetupModel.needsSetup(pool))
        try await pool.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO app_config (key, value) VALUES (?, '1')",
                           arguments: [LibrarySetupModel.dismissedKey])
        }
        #expect(!(await LibrarySetupModel.needsSetup(pool)), "Set Up Later is remembered")
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM app_config WHERE key = ?", arguments: [LibrarySetupModel.dismissedKey])
            try db.execute(sql: "INSERT OR REPLACE INTO app_config (key, value) VALUES ('library_root', '/Volumes/Lexxar/Music')")
        }
        #expect(!(await LibrarySetupModel.needsSetup(pool)), "a library folder ends it")
    }
}
