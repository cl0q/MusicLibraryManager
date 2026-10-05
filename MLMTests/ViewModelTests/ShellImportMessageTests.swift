import Foundation
import Testing
@testable import MLM

// W1-1 review round: import status messages (UC-COPY-11).

@Suite("Shell import messages")
@MainActor
struct ShellImportMessageTests {
    private func result(imported: Int, failed: Int = 0, skipped: Int = 0, cancelled: Bool = false, committed: Int = 0) -> ImportService.ImportResult {
        ImportService.ImportResult(
            succeeded: imported, failed: failed, skipped: skipped, failures: [],
            totalScanned: imported + failed + skipped, cancelled: cancelled, committed: committed
        )
    }

    @Test func importMessagesNeverShowRawErrorsOrClaimACancelledImportFinished() {
        let finished = ShellActions.importMessage(folder: "Sets", result: result(imported: 35, failed: 2, skipped: 3))
        #expect(finished.text == "Import finished — 35 imported, 2 failed, 3 already in the library")
        #expect(finished.offersShow)

        let clean = ShellActions.importMessage(folder: "Sets", result: result(imported: 4))
        #expect(clean.text == "Import finished — 4 imported")
        #expect(!clean.offersShow)

        let cancelled = ShellActions.importMessage(folder: "Sets", result: result(imported: 10, cancelled: true, committed: 6))
        #expect(cancelled.text == "Import of “Sets” cancelled — 6 imported")

        let failed = ShellActions.importMessage(folder: "Sets", result: nil)
        #expect(failed.text == "Couldn’t import “Sets” — the details are in Activity")
        #expect(failed.offersShow)

        #expect(ShellActions.importUnavailableMessage(folder: "Sets") == "Couldn’t import “Sets” — the library isn’t ready yet")
    }
}
