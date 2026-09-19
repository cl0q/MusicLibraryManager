import Testing
import Foundation
@testable import MLM

/// Tests for Module 1 — ActivityViewModel hardening.
///
/// Covers the ten behaviors enumerated in `/tmp/swarm/CONTRACTS.md` §Module 1.
/// All time-dependent tests use the injected `init(now:)` clock and the
/// injectable `stallTimeout` — no real waiting, no `Thread.sleep`.
@Suite("ActivityViewModelTests")
@MainActor
struct ActivityViewModelTests {

    // MARK: - Helpers

    /// Mutable-date clock so tests can advance time deterministically.
    private final class Clock {
        var now: Date
        init(_ date: Date) { self.now = date }
    }

    private func makeVM(clock: Clock) -> ActivityViewModel {
        let vm = ActivityViewModel(now: { clock.now })
        return vm
    }

    private func advance(_ clock: Clock, by seconds: TimeInterval) {
        clock.now.addTimeInterval(seconds)
    }

    /// Poll `AppLogger.shared.entries` until a matching entry appears or the
    /// budget expires. The logger dispatches to main asynchronously, so a
    /// synchronous read right after the call may miss it.
    private func waitForLogEntry(
        matching predicate: (AppLogger.LogEntry) -> Bool,
        timeout: TimeInterval = 2.0,
        pollInterval: TimeInterval = 0.02
    ) async -> AppLogger.LogEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let hit = AppLogger.shared.entries.last(where: predicate) {
                return hit
            }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return nil
    }

    // MARK: - Behavior 1: Idempotent terminal transitions

    @Test func completeOperation_calledTwice_producesOneRecentEntry() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .download, title: "Download")

        vm.completeOperation(id: id)
        let recentCountAfterFirst = vm.recentOperations.count
        vm.completeOperation(id: id)

        #expect(vm.recentOperations.count == recentCountAfterFirst,
                "Second completeOperation must be a no-op on recentOperations")
        #expect(vm.recentOperations.count == 1,
                "Exactly one recent entry after idempotent completion")
    }

    @Test func failOperation_calledTwice_producesOneRecentEntry() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .sync, title: "Sync")

        vm.failOperation(id: id, error: "boom")
        let recentCountAfterFirst = vm.recentOperations.count
        vm.failOperation(id: id, error: "boom again")

        #expect(vm.recentOperations.count == recentCountAfterFirst,
                "Second failOperation must be a no-op on recentOperations")
        #expect(vm.recentOperations.count == 1,
                "Exactly one recent entry after idempotent failure")
    }

    @Test func completeThenFail_producesOneRecentEntry() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .import, title: "Import")

        vm.completeOperation(id: id)
        let recentCountAfterComplete = vm.recentOperations.count
        vm.failOperation(id: id, error: "late failure")

        #expect(vm.recentOperations.count == recentCountAfterComplete,
                "failOperation after completeOperation must not add a second entry")
        #expect(vm.recentOperations.first?.status == .completed,
                "First terminal transition wins — status must remain .completed")
    }

    // MARK: - Behavior 2: Late updates are not dropped

    @Test func updateProgress_afterCompletion_updatesArchivedRecord() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .analysis, title: "Analysis")

        vm.completeOperation(id: id)
        vm.updateProgress(id: id, progress: 0.99, detail: "late detail")

        let archived = vm.operation(withID: id)
        #expect(archived != nil,
                "Late update must find the archived record via operation(withID:)")
        #expect(archived?.progress == 0.99,
                "Archived record must reflect the late progress value")
        #expect(archived?.detail == "late detail",
                "Archived record must reflect the late detail string")
    }

    @Test func updateProgress_afterFailure_updatesArchivedRecord() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .artwork, title: "Artwork")

        vm.failOperation(id: id, error: "network")
        vm.updateProgress(id: id, progress: 0.5)

        let archived = vm.operation(withID: id)
        #expect(archived != nil,
                "Late update after failure must still find the record")
        #expect(archived?.progress == 0.5,
                "Archived failed record must reflect the late progress value")
    }

    // MARK: - Behavior 3: Progress clamping

    @Test func updateProgress_clampsNegativeToZero() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .download, title: "Download")

        vm.updateProgress(id: id, progress: -0.5)

        #expect(vm.operation(withID: id)?.progress == 0.0,
                "Negative progress must be clamped to 0.0")
    }

    @Test func updateProgress_clampsAboveOneToOne() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .download, title: "Download")

        vm.updateProgress(id: id, progress: 1.7)

        #expect(vm.operation(withID: id)?.progress == 1.0,
                "Progress above 1.0 must be clamped to 1.0")
    }

    @Test func updateProgress_validValueIsUnchanged() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .download, title: "Download")

        vm.updateProgress(id: id, progress: 0.42)

        #expect(vm.operation(withID: id)?.progress == 0.42,
                "In-range progress must pass through without modification")
    }

    // MARK: - Behavior 4: Cancellation invokes the token

    @Test func cancelOperation_invokesTokenExactlyOnce() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        var tokenInvocations = 0
        let token: @Sendable () -> Void = { tokenInvocations += 1 }

        let id = vm.startOperation(type: .sync, title: "Sync", cancellation: token)
        vm.cancelOperation(id: id)

        #expect(tokenInvocations == 1,
                "Cancellation token must be invoked exactly once on cancel")
    }

    @Test func cancelOperation_calledTwice_invokesTokenOnlyOnce() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        var tokenInvocations = 0
        let token: @Sendable () -> Void = { tokenInvocations += 1 }

        let id = vm.startOperation(type: .sync, title: "Sync", cancellation: token)
        vm.cancelOperation(id: id)
        vm.cancelOperation(id: id)

        #expect(tokenInvocations == 1,
                "Second cancelOperation must not re-invoke the token")
    }

    @Test func cancelOperation_withoutToken_succeedsAndIsNotCancellable() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .analysis, title: "Analysis")

        let opBeforeCancel = vm.operation(withID: id)
        #expect(opBeforeCancel?.isCancellable == false,
                "Operation without a registered token must report isCancellable == false")

        vm.cancelOperation(id: id)

        let op = vm.operation(withID: id)
        #expect(op?.status == .cancelled,
                "Cancel must succeed even without a registered token")
    }

    @Test func registerCancellationToken_setsIsCancellableTrue() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .fingerprint, title: "Fingerprint")

        #expect(vm.operation(withID: id)?.isCancellable == false,
                "Before registration, isCancellable must be false")

        vm.registerCancellationToken(id: id, token: {})

        #expect(vm.operation(withID: id)?.isCancellable == true,
                "After registration, isCancellable must be true")
    }

    // MARK: - Behavior 5: Cancellation logs

    @Test func cancelOperation_writesAppLoggerEntry() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .download, title: "Download Song")

        let entriesBefore = AppLogger.shared.entries.count
        vm.cancelOperation(id: id)

        // AppLogger dispatches to main asynchronously — poll for the entry.
        let entry = await waitForLogEntry { entry in
            entry.message.contains("Download Song")
                && entry.message.lowercased().contains("cancel")
        }

        #expect(entry != nil,
                "cancelOperation MUST write an AppLogger entry (behavior 5)")
        #expect(AppLogger.shared.entries.count > entriesBefore,
                "Logger entry count must increase after cancelOperation")
    }

    // MARK: - Behavior 6: Stall watchdog

    @Test func stallWatchdog_notStalledBeforeTimeout() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        vm.stallTimeout = 10

        let id = vm.startOperation(type: .sync, title: "Sync")
        advance(clock, by: 5)

        #expect(!vm.stalledOperationIDs.contains(id),
                "Operation must NOT be stalled before stallTimeout elapses")
    }

    @Test func stallWatchdog_stalledAfterTimeout() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        vm.stallTimeout = 10

        let id = vm.startOperation(type: .sync, title: "Sync")
        advance(clock, by: 15)

        #expect(vm.stalledOperationIDs.contains(id),
                "Operation must be stalled once lastProgressAt is older than stallTimeout")
    }

    @Test func stallWatchdog_updateProgress_resetsStallClock() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        vm.stallTimeout = 10

        let id = vm.startOperation(type: .download, title: "Download")
        advance(clock, by: 8)
        vm.updateProgress(id: id, progress: 0.5)
        advance(clock, by: 8)

        #expect(!vm.stalledOperationIDs.contains(id),
                "updateProgress must reset the stall clock — 8s after reset < 10s timeout")

        advance(clock, by: 5)

        #expect(vm.stalledOperationIDs.contains(id),
                "Operation must stall again 10s after the last progress update")
    }

    @Test func stallWatchdog_terminalOperationsNeverStalled() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        vm.stallTimeout = 10

        let id = vm.startOperation(type: .analysis, title: "Analysis")
        vm.completeOperation(id: id)
        advance(clock, by: 60)

        #expect(!vm.stalledOperationIDs.contains(id),
                "Terminal (completed) operations must never appear in stalledOperationIDs")
    }

    // MARK: - Behavior 7: Cap + truncation flag

    @Test func recentCap_at25Operations_truncatesTo20AndSetsFlag() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        for i in 0..<25 {
            let id = vm.startOperation(type: .download, title: "Op \(i)")
            vm.completeOperation(id: id)
        }

        #expect(vm.recentOperations.count == 20,
                "recentOperations must be capped at recentCapacity (20)")
        #expect(vm.isRecentTruncated == true,
                "isRecentTruncated must be true after exceeding the cap")
    }

    @Test func recentCap_at20Operations_doesNotSetTruncationFlag() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        for i in 0..<20 {
            let id = vm.startOperation(type: .download, title: "Op \(i)")
            vm.completeOperation(id: id)
        }

        #expect(vm.recentOperations.count == 20,
                "20 operations must all fit within the cap")
        #expect(vm.isRecentTruncated == false,
                "isRecentTruncated must be false when count <= recentCapacity")
    }

    @Test func recentCap_mostRecentFirst() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        for i in 0..<25 {
            let id = vm.startOperation(type: .download, title: "Op \(i)")
            vm.completeOperation(id: id)
        }

        #expect(vm.recentOperations.first?.title == "Op 24",
                "Most recently completed operation must be first in recentOperations")
        #expect(vm.recentOperations.last?.title == "Op 5",
                "Oldest surviving operation (Op 5) must be last after 25 completions")
    }

    @Test func recentCapacity_isTwenty() {
        #expect(ActivityViewModel.recentCapacity == 20,
                "recentCapacity must equal 20 per the contract")
    }

    // MARK: - Behavior 8: clearRecent resets truncation flag

    @Test func clearRecent_resetsTruncationFlag() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        for i in 0..<25 {
            let id = vm.startOperation(type: .download, title: "Op \(i)")
            vm.completeOperation(id: id)
        }
        #expect(vm.isRecentTruncated == true,
                "Precondition: truncation flag must be set before clearRecent")

        vm.clearRecent()

        #expect(vm.isRecentTruncated == false,
                "clearRecent must reset isRecentTruncated to false")
        #expect(vm.recentOperations.isEmpty,
                "clearRecent must empty the recent list")
    }

    // MARK: - Behavior 9: Thread marshalling

    @Test func mutations_fromBackgroundThread_visibleOnMain_withCorrectOrdering() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                let id = vm.startOperation(type: .sync, title: "Background Sync")
                vm.updateProgress(id: id, progress: 0.5, detail: "halfway")
                vm.completeOperation(id: id)
                continuation.resume()
            }
        }

        // After the background work finishes, main-thread reads must see the
        // final state with correct ordering.
        let op = vm.operation(withID: vm.recentOperations.first?.id ?? UUID())
        #expect(op != nil,
                "Operation started from background must be visible on main")
        #expect(op?.status == .completed,
                "Final state must be .completed after background start→update→complete")
        #expect(op?.progress == 0.5 || op?.progress == 1.0,
                "Progress must reflect the update (0.5) or completion (1.0)")
    }

    // MARK: - Behavior 10: Source-scan

    @Test func sourceFile_doesNotAnnotateClassWithMainActor() throws {
        let url = URL(fileURLWithPath: #filePath)
        let repoRoot = url
            .deletingLastPathComponent() // Activity
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
        let sourceURL = repoRoot
            .appendingPathComponent("MLM/ViewModels/ActivityViewModel.swift")
        let src = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(!src.contains("@MainActor\nfinal class ActivityViewModel"),
                "ActivityViewModel must NOT be annotated @MainActor (breaks Task.detached call sites)")
        #expect(!src.contains("@MainActor @Observable final class ActivityViewModel"),
                "ActivityViewModel must NOT be annotated @MainActor in any form")
        #expect(!src.contains("@MainActor\r\nfinal class ActivityViewModel"),
                "ActivityViewModel must NOT be annotated @MainActor (CRLF variant)")
    }

    @Test func sourceFile_containsInjectedClockInit() throws {
        let url = URL(fileURLWithPath: #filePath)
        let repoRoot = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot
            .appendingPathComponent("MLM/ViewModels/ActivityViewModel.swift")
        let src = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(src.contains("init(now:"),
                "ActivityViewModel must expose init(now:) for deterministic time injection")
    }

    @Test func sourceFile_containsStallTimeout() throws {
        let url = URL(fileURLWithPath: #filePath)
        let repoRoot = url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = repoRoot
            .appendingPathComponent("MLM/ViewModels/ActivityViewModel.swift")
        let src = try String(contentsOf: sourceURL, encoding: .utf8)

        #expect(src.contains("stallTimeout"),
                "ActivityViewModel must expose stallTimeout for testable stall detection")
    }

    // MARK: - Supplementary: operation(withID:) lookup

    @Test func operation_withID_findsActiveOperation() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .download, title: "Download")

        let found = vm.operation(withID: id)
        #expect(found != nil,
                "operation(withID:) must find an active (running) operation")
        #expect(found?.title == "Download",
                "Returned operation must carry the correct title")
    }

    @Test func operation_withID_returnsNilForUnknownID() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let found = vm.operation(withID: UUID())
        #expect(found == nil,
                "operation(withID:) must return nil for an unknown UUID")
    }

    @Test func operation_withID_findsRecentAfterCompletion() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let id = vm.startOperation(type: .sync, title: "Sync")
        vm.completeOperation(id: id)

        let found = vm.operation(withID: id)
        #expect(found != nil,
                "operation(withID:) must find a completed operation in recentOperations")
        #expect(found?.status == .completed,
                "Archived operation must report .completed status")
    }

    // MARK: - Supplementary: startOperation returns usable ID

    @Test func startOperation_returnsID_thatIsFindable() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(type: .createMLExport, title: "Export")

        #expect(vm.operation(withID: id) != nil,
                "startOperation must return an ID that operation(withID:) can resolve")
        #expect(vm.operations.contains(where: { $0.id == id }),
                "Returned ID must correspond to an entry in the active operations array")
    }

    // MARK: - Supplementary: retryTrackIds round-trip

    @Test func startOperation_retryTrackIds_areStoredOnOperation() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(
            type: .download,
            title: "Download",
            retryTrackIds: [101, 202, 303]
        )

        let op = vm.operation(withID: id)
        #expect(op?.retryTrackIds == [101, 202, 303],
                "retryTrackIds passed to startOperation must be stored on the Operation")
    }

    @Test func startOperation_defaultRetryTrackIds_isEmpty() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(type: .download, title: "Download")

        let op = vm.operation(withID: id)
        #expect(op?.retryTrackIds == [],
                "Default retryTrackIds must be an empty array")
    }

    // MARK: - Behavior 11: Retry mechanism (A11.1)

    /// Thread-safe counter for async handler invocations.
    /// Using an actor avoids Sendable warnings when the handler
    /// is `@Sendable () async -> Void`.
    private actor InvocationCounter {
        private(set) var count = 0
        func increment() { count += 1 }
        func value() -> Int { count }
    }

    @Test func startOperation_withRetry_storesHandler_makesOperationRetryable() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(
            type: .download,
            title: "Download",
            retry: { }
        )

        let op = vm.operation(withID: id)
        #expect(op?.isRetryable == true,
                "Operation started with retry: must have isRetryable == true")
    }

    @Test func registerRetryHandler_makesExistingOperationRetryable() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(type: .sync, title: "Sync")
        #expect(vm.operation(withID: id)?.isRetryable == false,
                "Operation without handler or retryTrackIds must not be retryable")

        vm.registerRetryHandler(id: id, handler: { })

        #expect(vm.operation(withID: id)?.isRetryable == true,
                "After registerRetryHandler, operation must become retryable")
    }

    @Test func registerRetryHandler_onFailedOperation_makesItRetryable() async {
        // The real user path: a failure row in recentOperations carries the Retry button.
        // registerRetryHandler must work on already-terminal (archived) operations.
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let counter = InvocationCounter()

        let id = vm.startOperation(type: .download, title: "Download")
        vm.failOperation(id: id, error: "network")

        let archivedOp = vm.operation(withID: id)
        #expect(archivedOp != nil,
                "Precondition: failed operation is archived in recentOperations")
        #expect(archivedOp?.isRetryable == false,
                "Precondition: failed operation without handler is not retryable")

        vm.registerRetryHandler(id: id, handler: { await counter.increment() })

        let updatedOp = vm.operation(withID: id)
        #expect(updatedOp?.isRetryable == true,
                "registerRetryHandler must make an already-failed operation retryable")

        // Verify the handler is actually invoked on retry
        let result = await vm.retryOperation(id: id)
        #expect(result == true,
                "retryOperation on a failed operation with late-registered handler must succeed")
        #expect(await counter.value() == 1,
                "The late-registered handler must be invoked")
    }

    @Test func isRetryable_trueWhenRetryTrackIdsNonEmpty_evenWithoutHandler() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(
            type: .download,
            title: "Download",
            retryTrackIds: [101, 202]
        )

        let op = vm.operation(withID: id)
        #expect(op?.isRetryable == true,
                "isRetryable must be true when retryTrackIds is non-empty, even with no handler")
    }

    @Test func isRetryable_falseWhenNoHandlerAndEmptyRetryTrackIds() {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(type: .analysis, title: "Analysis")

        let op = vm.operation(withID: id)
        #expect(op?.isRetryable == false,
                "isRetryable must be false when no handler registered AND retryTrackIds is empty")
    }

    @Test func retryOperation_onFailedOperation_removesRowAndInvokesHandler() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let counter = InvocationCounter()

        let id = vm.startOperation(
            type: .download,
            title: "Download",
            retry: { await counter.increment() }
        )
        vm.failOperation(id: id, error: "network error")

        let recentCountBefore = vm.recentOperations.count
        #expect(recentCountBefore == 1,
                "Precondition: failed operation must be in recentOperations")

        let result = await vm.retryOperation(id: id)

        #expect(result == true,
                "retryOperation on a failed operation with handler must return true")
        #expect(vm.recentOperations.count == recentCountBefore - 1,
                "retryOperation must remove the failed row from recentOperations")
        #expect(vm.operation(withID: id) == nil,
                "After retry, the operation must no longer be findable (row removed)")
        #expect(await counter.value() == 1,
                "retryOperation must invoke the handler exactly once")
    }

    @Test func retryOperation_returnsTrue_onSuccessfulRetry() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        let id = vm.startOperation(
            type: .sync,
            title: "Sync",
            retry: { }
        )
        vm.failOperation(id: id, error: "timeout")

        let result = await vm.retryOperation(id: id)

        #expect(result == true,
                "retryOperation must return true when the operation has a handler")
    }

    @Test func retryOperation_onUnknownID_returnsFalse_removesNothing() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        // Start and complete one operation to have something in recent
        let existingId = vm.startOperation(type: .download, title: "Download")
        vm.completeOperation(id: existingId)
        let recentCountBefore = vm.recentOperations.count

        let unknownId = UUID()
        let result = await vm.retryOperation(id: unknownId)

        #expect(result == false,
                "retryOperation on unknown id must return false")
        #expect(vm.recentOperations.count == recentCountBefore,
                "retryOperation on unknown id must not remove any rows")
        #expect(vm.operation(withID: existingId) != nil,
                "Existing operations must remain untouched")
    }

    @Test func retryOperation_onNoHandlerAndEmptyRetryTrackIds_returnsFalse_invokesNothing() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let counter = InvocationCounter()

        let id = vm.startOperation(type: .analysis, title: "Analysis")
        vm.failOperation(id: id, error: "failed")
        let recentCountBefore = vm.recentOperations.count

        let result = await vm.retryOperation(id: id)

        #expect(result == false,
                "retryOperation must return false when no handler AND empty retryTrackIds")
        #expect(vm.recentOperations.count == recentCountBefore,
                "retryOperation must not remove the row when returning false")
        #expect(await counter.value() == 0,
                "No handler means nothing to invoke")
    }

    @Test func retryOperation_invokesHandlerExactlyOnce() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let counter = InvocationCounter()

        let id = vm.startOperation(
            type: .import,
            title: "Import",
            retry: { await counter.increment() }
        )
        vm.failOperation(id: id, error: "error")

        await vm.retryOperation(id: id)

        #expect(await counter.value() == 1,
                "Handler must be invoked exactly once per retryOperation call")

        // Retry again — but the operation was removed, so this is now unknown
        let secondResult = await vm.retryOperation(id: id)
        #expect(secondResult == false,
                "Second retry must return false (operation was removed)")
        #expect(await counter.value() == 1,
                "Handler must still be at 1 — not invoked again")
    }

    @Test func retryOperation_doesNotCorruptRecentCap() async {
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)

        // Fill recent to capacity
        for i in 0..<20 {
            let id = vm.startOperation(type: .download, title: "Op \(i)", retry: {})
            vm.completeOperation(id: id)
        }
        #expect(vm.recentOperations.count == 20,
                "Precondition: recentOperations at capacity")
        #expect(vm.isRecentTruncated == false,
                "Precondition: isRecentTruncated false at exactly capacity")

        // Add one more to trigger truncation
        let overflowId = vm.startOperation(type: .download, title: "Overflow", retry: {})
        vm.completeOperation(id: overflowId)
        #expect(vm.recentOperations.count == 20,
                "After overflow, count stays at capacity")
        #expect(vm.isRecentTruncated == true,
                "After overflow, isRecentTruncated must be true")

        // Now retry the oldest operation (last in the array)
        let oldestId = vm.recentOperations.last?.id ?? UUID()
        let countBeforeRetry = vm.recentOperations.count
        let truncatedBeforeRetry = vm.isRecentTruncated

        _ = await vm.retryOperation(id: oldestId)

        #expect(vm.recentOperations.count == countBeforeRetry - 1,
                "retryOperation must drop the count by one")
        #expect(vm.isRecentTruncated == truncatedBeforeRetry,
                "retryOperation must not change isRecentTruncated flag")
    }

    @Test func retryOperation_afterCompleteOperation_stillInvokesHandler() async {
        // Regression guard: terminal idempotence is unaffected by retry.
        // A completed operation with a handler may legitimately be re-runnable
        // (e.g., re-running a sync). The handler is the explicit opt-in.
        let clock = Clock(Date())
        let vm = makeVM(clock: clock)
        let counter = InvocationCounter()

        let id = vm.startOperation(
            type: .sync,
            title: "Sync",
            retry: { await counter.increment() }
        )
        vm.completeOperation(id: id)

        #expect(vm.operation(withID: id)?.status == .completed,
                "Precondition: operation is completed")

        let result = await vm.retryOperation(id: id)

        #expect(result == true,
                "retryOperation on completed operation with handler must return true")
        #expect(await counter.value() == 1,
                "Handler must be invoked even for completed operations")
        #expect(vm.operation(withID: id) == nil,
                "Completed operation must be removed after retry")
    }
}
