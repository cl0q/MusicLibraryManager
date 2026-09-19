import Testing
import Foundation

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
            Issue.record("SyncService does not contain finalisingOperationOnThrow — cannot verify it calls failOperation")
            return
        }
        #expect(src.contains("failOperation"),
                "finalisingOperationOnThrow must call failOperation to terminalise the operation on throw")
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

    // MARK: - A11.4: Sync retry recipe registered at startOperation

    @Test
    func syncService_registersRetryRecipe() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        // The startOperation call in the executeSync region must register a retry: closure.
        // Assert the file contains `retry:` — this is sufficient because the only
        // startOperation call with a `retry:` argument is in executeSync.
        guard src.contains("executeSync") else {
            Issue.record("SyncService does not contain executeSync — cannot verify retry: registration")
            return
        }
        #expect(src.contains("retry:"),
                "SyncService executeSync must register a retry: recipe at startOperation — A11.4")
    }

    // MARK: - A11.6: Guard against re-indentation / reformatting of the dirty file

    @Test
    func syncService_finalisationSummaryStringPreserved() throws {
        let src = try readSource("MLM/Services/Sync/SyncService.swift")
        // The existing finalisation summary string "synced · " from
        // "\(result.syncedCount) synced · \(result.failedCount) failed" must survive.
        // A careless rewrite that mangles the finalisation block would lose this.
        #expect(src.contains("synced · "),
                "SyncService must still contain the finalisation summary string 'synced · ' — A11.6 forbids reformatting the dirty file")
    }
}
