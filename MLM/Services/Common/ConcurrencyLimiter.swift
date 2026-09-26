import Foundation

/// A concurrency limiter that enforces a hard cap on the number of
/// simultaneously executing async tasks.
///
/// Swift's cooperative thread pool does NOT guarantee N tasks run in
/// parallel just because you add N tasks to a TaskGroup. The pool
/// prioritizes responsiveness and may serialize `.utility` tasks.
///
/// This limiter uses a classic counting semaphore pattern to guarantee
/// exactly `maxConcurrency` tasks run at any time — crucial for turbo
/// mode where we want to saturate 80% of CPU cores with fpcalc/ffmpeg
/// subprocesses.
///
/// Usage:
/// ```swift
/// let limiter = ConcurrencyLimiter(maxConcurrency: 8)
/// await withTaskGroup(of: Void.self) { group in
///     for item in items {
///         group.addTask {
///             await limiter.run {
///                 await processItem(item)
///             }
///         }
///     }
/// }
/// ```
final class ConcurrencyLimiter: Sendable {
    private let semaphore: AsyncSemaphore

    /// Create a limiter that allows at most `maxConcurrency` tasks to
    /// execute their bodies simultaneously.
    init(maxConcurrency: Int) {
        self.semaphore = AsyncSemaphore(count: maxConcurrency)
    }

    /// Execute `operation` while holding one of the concurrency slots.
    /// Blocks (suspends) until a slot is available.
    func run<T: Sendable>(operation: @Sendable () async throws -> T) async rethrows -> T {
        await semaphore.wait()
        do {
            let result = try await operation()
            await semaphore.signal()
            return result
        } catch {
            await semaphore.signal()
            throw error
        }
    }

    /// Execute `operation` while holding a slot, abandoning a queued waiter
    /// promptly when its task is cancelled.
    func runCancellable<T: Sendable>(
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await semaphore.waitCancellable()
        do {
            let result = try await operation()
            await semaphore.signal()
            return result
        } catch {
            await semaphore.signal()
            throw error
        }
    }
}

/// A simple async-aware counting semaphore.
///
/// Backed by an actor to ensure thread-safe state management.
/// Waiters are queued FIFO and resumed when a slot becomes available.
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var cancellableWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    init(count: Int) {
        self.count = count
    }

    /// Acquire a permit. Suspends if none are available.
    func wait() async {
        if count > 0 {
            count -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Release a permit, waking the next waiter if any.
    func signal() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else if let next = cancellableWaiters.first {
            cancellableWaiters.removeValue(forKey: next.key)
            next.value.resume()
        } else {
            count += 1
        }
    }

    /// Acquire a permit, removing the waiter and throwing when the surrounding
    /// task is cancelled before admission.
    func waitCancellable() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if count > 0 {
                    count -= 1
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    cancellableWaiters[id] = continuation
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: id)
            }
        }
    }

    private func cancelWaiter(id: UUID) {
        guard let continuation = cancellableWaiters.removeValue(forKey: id) else { return }
        continuation.resume(throwing: CancellationError())
    }
}
