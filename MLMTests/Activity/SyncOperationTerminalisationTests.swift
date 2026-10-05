import Testing
import Foundation
@testable import MLM

/// Source-scan tests locking A11.4 — the stuck-spinner root fix in SyncService.swift.
///
/// These tests assert that the three previously-unguarded throw sites between
/// `startOperation` and the finalisation block are wrapped by
/// `finalisingOperationOnThrow`, and that the wrap does not delete the real work.
///
/// Expected state: RED until the implementation worker edits SyncService.swift.
@Suite("SyncOperationTerminalisationTests")
struct SyncOperationTerminalisationTests {

    // MARK: - Helpers

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent() // Activity
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - A11.4: finalisingOperationOnThrow helper exists and calls failOperation

    @Test
    func syncService_containsFinalisingHelper() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        #expect(src.contains("finalisingOperationOnThrow"),
                "SyncService must contain the finalisingOperationOnThrow helper — A11.4 stuck-spinner root fix")
    }

    @Test
    func syncService_finalisingHelperCallsFailOperation() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        // The helper must call failOperation to terminalise the stuck row.
        // Anchor on the helper's existence first so a missing helper fails loudly,
        // not with a misleading "failOperation not found" (it exists elsewhere already).
        guard src.contains("finalisingOperationOnThrow") else {
            Issue.record("SyncService does not contain finalisingOperationOnThrow — cannot verify it fails the operation")
            return
        }
        // W3-ACT: the Activity handle's `fail(cause:)` ends the operation.
        #expect(src.contains("operationId?.fail(cause:"),
                "finalisingOperationOnThrow must fail the Activity operation on throw")
    }

    // MARK: - A11.4: Three throw sites are wrapped

    @Test
    func syncService_threeThrowSitesWrapped() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        // Count occurrences of `finalisingOperationOnThrow(operationId)` — must be >= 3.
        // Uses regex occurrence counting, not contains, so a single definition is not enough.
        let pattern = "finalisingOperationOnThrow\\(operationId"
        let regex = try NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(src.startIndex..., in: src)
        let matchCount = regex.numberOfMatches(in: src, options: [], range: range)
        #expect(matchCount >= 3,
                "SyncService must wrap at least 3 throw sites with finalisingOperationOnThrow(operationId — got \(matchCount)")
    }

    // MARK: - A11.4: The real work must survive the wrap

    @Test
    func syncService_getLibraryRootStillPresent() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        #expect(src.contains("getLibraryRoot()"),
                "SyncService must still contain getLibraryRoot() — the wrap must not delete the work")
    }

    @Test
    func syncService_generatePlaylistsStillPresent() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        #expect(src.contains("generatePlaylists("),
                "SyncService must still contain generatePlaylists( — the wrap must not delete the work")
    }

    @Test
    func syncService_generateManifestStillPresent() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        #expect(src.contains("generateManifest("),
                "SyncService must still contain generateManifest( — the wrap must not delete the work")
    }

    // MARK: - W3-ACT: one operation per sync with honest controls (PP-ACTIVITY-01)

    @Test
    func syncService_registersOneOperationWithRealControls() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        #expect(src.contains(".sync, title: \"Sync “"), "one Activity operation per sync")
        #expect(src.contains("cancel: { [weak self] in Task { @MainActor in self?.cancelSync() } }"))
        #expect(src.contains("pause: { [weak self] in Task { @MainActor in self?.pauseSync() } }"))
        #expect(src.contains("operationId.cancelled(activityResult)"),
                "a cancelled sync must end its operation (PP-ACTIVITY-01)")
    }

    // MARK: - A11.6: Guard against re-indentation / reformatting of the dirty file

    @Test
    func syncService_resultWordsAndGroupedFailures() throws {
        var result = SyncService.SyncResult()
        result.syncedCount = 86
        result.failedCount = 3
        result.failedTracks = [
            SyncService.SyncFailure(trackId: 1, title: "A", artist: "X", reason: "File missing"),
            SyncService.SyncFailure(trackId: 2, title: "B", artist: "X", reason: "File missing"),
            SyncService.SyncFailure(trackId: 3, title: "C", artist: "X", reason: "Disk full"),
        ]
        let activity = SyncService.activityResult(result)
        #expect(activity.sentence == "86 synced · 3 failed")
        #expect(activity.failureGroups.map(\.cause) == ["File missing", "Disk full"])
        #expect(activity.failureGroups.map(\.count) == [2, 1])
        #expect(activity.failedTrackIDs.isEmpty, "sync failures are not download failures")
        #expect(activity.items.count == 3)
    }
}
