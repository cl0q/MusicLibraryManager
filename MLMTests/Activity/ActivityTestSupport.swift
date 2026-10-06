import Foundation
@testable import MLM

/// A hand-driven clock + timer for `ActivityCenter` (no wall-clock assertions, no sleeps).
final class ManualActivityScheduler: ActivityScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var jobs: [(deadline: Date, order: Int, work: @MainActor @Sendable () -> Void)] = []
    private var counter = 0

    init(start: Date = Date()) {
        current = start
    }

    func now() -> Date {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func schedule(after delay: TimeInterval, _ work: @escaping @MainActor @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        jobs.append((current.addingTimeInterval(max(delay, 0)), counter, work))
    }

    var pendingCount: Int {
        lock.lock(); defer { lock.unlock() }
        return jobs.count
    }

    /// Moves the clock and runs every timer that became due, in deadline order.
    @MainActor
    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        let now = current
        let due = jobs.filter { $0.deadline <= now }.sorted { ($0.deadline, $0.order) < ($1.deadline, $1.order) }
        jobs.removeAll { $0.deadline <= now }
        lock.unlock()
        for job in due { job.work() }
    }
}

/// Failure source with a fixed answer.
struct FixedFailureSource: ActivityFailureSource {
    var failing: Set<Int64>
    func failingTrackIDs(in trackIDs: [Int64]) async throws -> Set<Int64> {
        failing.intersection(trackIDs)
    }
    func allFailingTrackIDs() async throws -> Set<Int64> { failing }
}

/// A unique temporary directory, removed by the caller.
func makeActivityTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlm-activity-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
