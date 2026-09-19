import Testing
import Foundation
@testable import MLM

@MainActor
@Suite("Maintenance Cancellation Tests")
struct MaintenanceCancellationTests {

    /// Tests that withTaskCancellationHandler correctly propagates Swift task
    /// cancellation to MaintenanceProgressTracker. This is the pattern installed
    /// in ReplayGainAnalyzer, FingerprintService, and GrooveBatchAnalyzer.
    @Test func cancellationHandlerPropagatesToTracker() async throws {
        let tracker = MaintenanceProgressTracker(total: 100)
        var iterations = 0

        let task = Task {
            await withTaskCancellationHandler {
                for i in 0..<100 {
                    guard !tracker.isCancelled else { break }
                    iterations = i + 1
                    try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            } onCancel: {
                tracker.cancel()
            }
        }

        // Give the loop a chance to start
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        task.cancel()

        // Wait for the task to complete with a timeout
        let completed = await withTimeout(seconds: 2) {
            await task.value
            return true
        }

        #expect(completed, "Task should complete within timeout")
        #expect(tracker.isCancelled, "Tracker should be cancelled after task cancellation")
        #expect(iterations < 100, "Loop should stop early when cancelled, but ran \(iterations) iterations")
    }

    /// Documents the bug: without withTaskCancellationHandler, cancelling the
    /// Swift task does NOT set tracker.isCancelled, so the loop runs to completion.
    /// This test passes both before and after the fix because it targets the
    /// unwrapped pattern that the fix addresses.
    @Test func unwrappedLoopDoesNotStopOnTaskCancellation() async throws {
        let tracker = MaintenanceProgressTracker(total: 100)
        var iterations = 0

        let task = Task {
            // No withTaskCancellationHandler - this is the bug pattern
            for i in 0..<10 {
                guard !tracker.isCancelled else { break }
                iterations = i + 1
                try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }

        // Give the loop a chance to start
        try? await Task.sleep(nanoseconds: 20_000_000) // 20ms
        task.cancel()

        // Wait for the task to complete with a timeout
        let completed = await withTimeout(seconds: 2) {
            await task.value
            return true
        }

        #expect(completed, "Task should complete within timeout")
        // Without the handler, tracker.isCancelled remains false even after task cancellation
        #expect(!tracker.isCancelled, "Tracker should NOT be cancelled without the handler")
        // The loop runs to completion because it only checks tracker.isCancelled
        #expect(iterations == 10, "Loop runs to completion without the handler")
    }

    /// Helper to await a task with a timeout, preventing hung tests.
    private func withTimeout<T>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            for await result in group {
                group.cancelAll()
                if let result = result {
                    return result
                }
            }
            fatalError("Timeout reached")
        }
    }
}
