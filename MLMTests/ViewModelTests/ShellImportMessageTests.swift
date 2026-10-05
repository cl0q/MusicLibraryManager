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

    /// W3-ACT: the import's start/end messages come from Activity; the words stay (ported
    /// from the W1-1 review round's `ShellActions.importMessage`).
    @Test func importMessagesNeverShowRawErrorsOrClaimACancelledImportFinished() {
        func message(_ result: ImportService.ImportResult, state: ActivityState) -> String {
            let op = ActivityOperation(
                id: UUID(), kind: .folderScan, title: "Scan “Sets”", subject: .folder(URL(fileURLWithPath: "/tmp/Sets")),
                state: state, wait: nil, progress: .indeterminate, result: ImportViewModel.activityResult(for: result),
                startedAt: Date(), endedAt: Date(), isAutomatic: false, libraryID: nil, needsAttention: false,
                dismissedAt: nil, itemNoun: .file, messageName: ActivityKind.folderScan.messageName, controls: .none,
                isFromHistory: false)
            return ActivityPresentation.endMessage(op)
        }
        #expect(message(result(imported: 35, failed: 2, skipped: 3), state: .completed)
                == "Import finished — 35 imported, 2 failed, 3 already in the library")
        #expect(message(result(imported: 4), state: .completed) == "Import finished — 4 imported")
        #expect(message(result(imported: 10, cancelled: true, committed: 6), state: .cancelled)
                == "Import cancelled — 6 imported")
        #expect(ImportViewModel.plainCause(CocoaError(.fileReadUnknown), folder: URL(fileURLWithPath: "/nonexistent-\(UUID())/Sets"))
                == "“Sets” isn’t reachable")
        #expect(ShellActions.importUnavailableMessage(folder: "Sets") == "Couldn’t import “Sets” — the library isn’t ready yet")
    }
}
