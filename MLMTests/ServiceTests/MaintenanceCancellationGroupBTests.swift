import Foundation
import Testing
@testable import MLM

/// Cancellation-contract tests for the Group B batch services:
/// DanceabilityAnalyzer, ArtworkService, LibraryRepairService, ArtworkBackfillService.
///
/// These services shell out to ffmpeg/fpcalc/CoreML and need real media files,
/// so the tests verify the *propagation contract* — that wrapping a tracker-gated
/// loop in `withTaskCancellationHandler { … } onCancel: { tracker.cancel() }`
/// causes the loop to stop when the enclosing Task is cancelled.
///
/// FAILS-BEFORE: no — the pattern tests pass both before and after the fix because
/// they target the pattern, not the services directly. The services themselves
/// lacked this wrapper; the fix installs it.
@Suite("Maintenance Cancellation Group B Tests", .serialized)
struct MaintenanceCancellationGroupBTests {

    // MARK: - Task-group pattern (DanceabilityAnalyzer, ArtworkService)

    /// Verifies that a `withTaskGroup` wrapped in `withTaskCancellationHandler`
    /// with `onCancel: { tracker.cancel() }` stops collecting results when the
    /// enclosing Task is cancelled. This mirrors the DanceabilityAnalyzer and
    /// ArtworkService batch loops.
    @Test func taskGroupPattern_stopsOnCancellation() async throws {
        let tracker = MaintenanceProgressTracker(total: 200)
        let counter = SendableCounter()

        let task = Task {
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<200 {
                        group.addTask {
                            // Simulate work that takes longer than the pre-cancel delay
                            try? await Task.sleep(for: .milliseconds(500))
                            // Check tracker after work — mirrors how real services
                            // check isCancelled at the top of each iteration
                            if tracker.isCancelled { return }
                            counter.increment()
                        }
                    }
                    // Collection loop breaks on cancellation — mirrors DanceabilityAnalyzer:361
                    for await _ in group {
                        if tracker.isCancelled { break }
                    }
                }
            } onCancel: {
                tracker.cancel()
            }
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await withTimeout(seconds: 3) { await task.value }

        #expect(tracker.isCancelled, "Handler must set tracker.isCancelled")
        #expect(counter.value < 200, "Task group should stop early; processed \(counter.value)")
    }

    // MARK: - Plain for-loop pattern (LibraryRepairService)

    /// Verifies that a sequential `for` loop wrapped in `withTaskCancellationHandler`
    /// stops iterating when the enclosing Task is cancelled. This mirrors the
    /// LibraryRepairService.rescanMetadata loop.
    @Test func forLoopPattern_stopsOnCancellation() async throws {
        let tracker = MaintenanceProgressTracker(total: 500)
        let counter = SendableCounter()

        let task = Task {
            await withTaskCancellationHandler {
                for _ in 0..<500 {
                    guard !tracker.isCancelled else { break }
                    counter.increment()
                    try? await Task.sleep(for: .milliseconds(10))
                }
            } onCancel: {
                tracker.cancel()
            }
        }

        try? await Task.sleep(for: .milliseconds(80))
        task.cancel()

        await withTimeout(seconds: 3) { await task.value }

        #expect(tracker.isCancelled, "Handler must set tracker.isCancelled")
        #expect(counter.value < 500, "For loop should stop early; processed \(counter.value)")
    }

    // MARK: - Producer-consumer pattern (ArtworkBackfillService)

    /// Verifies that a producer-consumer `withTaskGroup` (seed N workers, then
    /// refill from a `for await` loop) wrapped in `withTaskCancellationHandler`
    /// stops enqueuing work when the enclosing Task is cancelled. This mirrors
    /// the ArtworkBackfillService.backfillMissing loop.
    @Test func producerConsumerPattern_stopsOnCancellation() async throws {
        let tracker = MaintenanceProgressTracker(total: 200)
        let counter = SendableCounter()
        let itemCount = 200
        let concurrency = 4

        let task = Task {
            await withTaskCancellationHandler {
                await withTaskGroup(of: Void.self) { group in
                    var pending = (0..<itemCount).makeIterator()
                    var running = 0

                    while running < concurrency, pending.next() != nil {
                        if tracker.isCancelled { break }
                        running += 1
                        group.addTask {
                            if tracker.isCancelled { return }
                            counter.increment()
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                    }

                    for await _ in group {
                        if tracker.isCancelled { break }
                        if pending.next() != nil {
                            group.addTask {
                                if tracker.isCancelled { return }
                                counter.increment()
                                try? await Task.sleep(for: .milliseconds(20))
                            }
                        }
                    }
                }
            } onCancel: {
                tracker.cancel()
            }
        }

        try? await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await withTimeout(seconds: 3) { await task.value }

        #expect(tracker.isCancelled, "Handler must set tracker.isCancelled")
        #expect(counter.value < itemCount, "Producer-consumer should stop early; processed \(counter.value)")
    }

    // MARK: - Bug documentation

    /// Documents the exact bug: without `withTaskCancellationHandler`, cancelling
    /// the enclosing Task does NOT set `tracker.isCancelled`, so tracker-gated
    /// loops run to completion even after the user taps Cancel.
    @Test func unwrappedLoop_doesNotStopOnTaskCancellation() async throws {
        let tracker = MaintenanceProgressTracker(total: 20)
        let counter = SendableCounter()

        let task = Task {
            for _ in 0..<20 {
                if tracker.isCancelled { break }
                counter.increment()
                try? await Task.sleep(for: .milliseconds(10))
            }
        }

        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await withTimeout(seconds: 3) { await task.value }

        #expect(!tracker.isCancelled, "Without the handler, tracker.isCancelled stays false")
        #expect(counter.value == 20, "Without the handler, the loop runs to completion")
    }

    // MARK: - Helpers

    private func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            for await result in group {
                group.cancelAll()
                if let result { return result }
            }
            Issue.record("Test timed out after \(seconds)s")
            fatalError("unreachable")
        }
    }
}

/// Thread-safe counter for asserting iteration counts across task boundaries.
private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    func increment() { lock.lock(); _value += 1; lock.unlock() }
}
