import SwiftUI
import Foundation

/// ViewModel for tracking active operations across the app.
///
/// Aggregates progress from downloads, syncs, imports, and analysis
/// for display in the Activity Panel.
///
/// Deliberately NOT annotated `@MainActor`: `DependencyContainer` calls
/// into this from `Task.detached`. Thread safety is handled internally
/// via `onMain(_:)` marshalling.
@Observable
final class ActivityViewModel {
    // MARK: - Operation Tracking

    struct Operation: Identifiable {
        let id: UUID
        let type: OperationType
        var title: String
        var status: OperationStatus
        var progress: Double  // 0.0–1.0
        var detail: String
        var startedAt: Date
        var completedAt: Date?
        var lastProgressAt: Date = Date()
        var retryTrackIds: [Int64] = []
        var isCancellable: Bool = false
        var retryHandler: (@Sendable () async -> Void)?

        init(
            id: UUID = UUID(),
            type: OperationType,
            title: String,
            status: OperationStatus,
            progress: Double,
            detail: String,
            startedAt: Date,
            completedAt: Date? = nil,
            lastProgressAt: Date = Date(),
            retryTrackIds: [Int64] = [],
            isCancellable: Bool = false,
            retryHandler: (@Sendable () async -> Void)? = nil
        ) {
            self.id = id
            self.type = type
            self.title = title
            self.status = status
            self.progress = progress
            self.detail = detail
            self.startedAt = startedAt
            self.completedAt = completedAt
            self.lastProgressAt = lastProgressAt
            self.retryTrackIds = retryTrackIds
            self.isCancellable = isCancellable
            self.retryHandler = retryHandler
        }

        enum OperationType: String {
            case download = "Download"
            case sync = "Sync"
            case `import` = "Import"
            case analysis = "Analysis"
            case fingerprint = "Fingerprint"
            case artwork = "Artwork"
            case createMLExport = "CreateML Export"
        }

        enum OperationStatus: String {
            case running = "Running"
            case completed = "Completed"
            case failed = "Failed"
            case cancelled = "Cancelled"
        }

        var isActive: Bool {
            status == .running
        }

        var duration: TimeInterval {
            let end = completedAt ?? Date()
            return end.timeIntervalSince(startedAt)
        }

        var formattedDuration: String {
            let d = Int(duration)
            if d >= 3600 {
                return String(format: "%d:%02d:%02d", d / 3600, (d % 3600) / 60, d % 60)
            }
            return String(format: "%d:%02d", d / 60, d % 60)
        }

        var isRetryable: Bool {
            retryHandler != nil || !retryTrackIds.isEmpty
        }
    }

    // MARK: - State

    private(set) var operations: [Operation] = []
    private(set) var recentOperations: [Operation] = [] // last N completed
    private(set) var isRecentTruncated: Bool = false

    static let recentCapacity: Int = 20

    /// Seconds before a running operation with no progress is considered stalled.
    var stallTimeout: TimeInterval = 120

    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var cancellationTokens: [UUID: @Sendable () -> Void] = [:]
    // Retry handlers outlive terminal transitions (fail/complete/cancel) because
    // retryOperation targets terminal rows. Cleaned up only when the row is removed.
    @ObservationIgnored private var retryHandlers: [UUID: @Sendable () async -> Void] = [:]

    // MARK: - Init

    init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - Thread marshalling

    private func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread { MainActor.assumeIsolated(work) }
        else { DispatchQueue.main.async { MainActor.assumeIsolated(work) } }
    }

    // MARK: - Summary

    /// Summary text for the collapsed header.
    var summaryText: String {
        let active = operations.filter(\.isActive)
        if active.isEmpty {
            return "No active operations"
        }
        if active.count == 1 {
            return active[0].title
        }
        return "\(active.count) operations running"
    }

    var hasActiveOperations: Bool {
        operations.contains(where: \.isActive)
    }

    // MARK: - Operations CRUD

    /// Start a new operation and return its ID.
    @discardableResult
    func startOperation(
        type: Operation.OperationType,
        title: String,
        detail: String = "",
        retryTrackIds: [Int64] = [],
        cancellation: (@Sendable () -> Void)? = nil,
        retry: (@Sendable () async -> Void)? = nil
    ) -> UUID {
        let id = UUID()
        let startDate = now()
        onMain {
            let op = Operation(
                id: id,
                type: type,
                title: title,
                status: .running,
                progress: 0,
                detail: detail,
                startedAt: startDate,
                completedAt: nil,
                lastProgressAt: startDate,
                retryTrackIds: retryTrackIds,
                isCancellable: cancellation != nil,
                retryHandler: retry
            )
            self.operations.append(op)
            if let cancellation {
                self.cancellationTokens[id] = cancellation
            }
            if let retry {
                self.retryHandlers[id] = retry
            }
            AppLogger.shared.log("Started: \(title)", source: type.rawValue)
        }
        return id
    }

    /// Register a cancellation token for an existing operation.
    func registerCancellationToken(id: UUID, token: @escaping @Sendable () -> Void) {
        onMain {
            self.cancellationTokens[id] = token
            if let idx = self.operations.firstIndex(where: { $0.id == id }) {
                self.operations[idx].isCancellable = true
            }
        }
    }

    /// Register a retry handler for an existing operation.
    func registerRetryHandler(id: UUID, handler: @escaping @Sendable () async -> Void) {
        onMain {
            self.retryHandlers[id] = handler
            if let idx = self.operations.firstIndex(where: { $0.id == id }) {
                self.operations[idx].retryHandler = handler
            }
            if let idx = self.recentOperations.firstIndex(where: { $0.id == id }) {
                self.recentOperations[idx].retryHandler = handler
            }
        }
    }

    /// Update progress for an operation. Clamps to 0.0...1.0.
    /// Searches active operations first, then recent (for late updates).
    func updateProgress(id: UUID, progress: Double, detail: String? = nil) {
        let clamped = min(max(progress, 0.0), 1.0)
        let timestamp = now()
        onMain {
            if let idx = self.operations.firstIndex(where: { $0.id == id }) {
                self.operations[idx].progress = clamped
                if let detail { self.operations[idx].detail = detail }
                self.operations[idx].lastProgressAt = timestamp
            } else if let idx = self.recentOperations.firstIndex(where: { $0.id == id }) {
                self.recentOperations[idx].progress = clamped
                if let detail { self.recentOperations[idx].detail = detail }
            }
        }
    }

    /// Mark an operation as completed. Idempotent — no-op if already terminal.
    func completeOperation(id: UUID, detail: String? = nil) {
        let timestamp = now()
        onMain {
            guard let idx = self.operations.firstIndex(where: { $0.id == id }) else { return }
            self.operations[idx].status = .completed
            self.operations[idx].progress = 1.0
            self.operations[idx].completedAt = timestamp
            if let detail { self.operations[idx].detail = detail }

            let op = self.operations[idx]
            AppLogger.shared.log("Completed: \(op.title) (\(op.formattedDuration))", source: op.type.rawValue)

            self.recentOperations.insert(self.operations.remove(at: idx), at: 0)
            self.trimRecent()
        }
    }

    /// Mark an operation as failed. Idempotent — no-op if already terminal.
    func failOperation(id: UUID, error: String) {
        let timestamp = now()
        onMain {
            guard let idx = self.operations.firstIndex(where: { $0.id == id }) else { return }
            self.operations[idx].status = .failed
            self.operations[idx].completedAt = timestamp
            self.operations[idx].detail = error

            let op = self.operations[idx]
            AppLogger.shared.log("Failed: \(op.title): \(error)", level: .error, source: op.type.rawValue)

            self.recentOperations.insert(self.operations.remove(at: idx), at: 0)
            self.trimRecent()
        }
    }

    /// Mark an operation as cancelled. Invokes the registered cancellation
    /// token exactly once. Writes an AppLogger entry.
    func cancelOperation(id: UUID, detail: String? = nil) {
        let timestamp = now()
        onMain {
            guard let idx = self.operations.firstIndex(where: { $0.id == id }) else { return }
            self.operations[idx].status = .cancelled
            self.operations[idx].completedAt = timestamp
            if let detail { self.operations[idx].detail = detail }

            let op = self.operations[idx]

            if let token = self.cancellationTokens.removeValue(forKey: id) {
                token()
            }

            AppLogger.shared.log("Cancelled: \(op.title)", source: op.type.rawValue)

            self.recentOperations.insert(self.operations.remove(at: idx), at: 0)
            self.trimRecent()
        }
    }

    /// Retry an operation. Removes the row first (so the stale failure does not
    /// sit next to the fresh attempt), then invokes the handler exactly once.
    /// Returns false when the id is unknown or the operation is not retryable.
    @MainActor
    @discardableResult
    func retryOperation(id: UUID) async -> Bool {
        // Look up: active first, then recent.
        let located: (op: Operation, index: Int, inRecent: Bool)?
        if let idx = operations.firstIndex(where: { $0.id == id }) {
            located = (operations[idx], idx, false)
        } else if let idx = recentOperations.firstIndex(where: { $0.id == id }) {
            located = (recentOperations[idx], idx, true)
        } else {
            return false
        }

        guard let (op, idx, inRecent) = located else { return false }

        guard op.isRetryable else { return false }

        // Remove the row FIRST — retry replaces the stale entry.
        if inRecent {
            recentOperations.remove(at: idx)
        } else {
            operations.remove(at: idx)
        }

        // Pull the handler from the dictionary; the Operation's own copy may
        // have been lost during the terminal transition (it was moved between
        // arrays), but the dictionary survives.
        let handler = retryHandlers.removeValue(forKey: id)

        if let handler {
            await handler()
        }

        return true
    }

    /// Clear completed operations from recent list. Resets truncation flag.
    func clearRecent() {
        onMain {
            self.recentOperations.removeAll()
            self.isRecentTruncated = false
        }
    }

    // MARK: - Lookups

    /// Searches active operations first, then recent. Returns nil if unknown.
    func operation(withID id: UUID) -> Operation? {
        if let op = operations.first(where: { $0.id == id }) { return op }
        return recentOperations.first(where: { $0.id == id })
    }

    /// Running operations whose `lastProgressAt` is older than `stallTimeout`.
    var stalledOperationIDs: Set<UUID> {
        let currentDate = now()
        return Set(operations.filter { op in
            op.isActive && currentDate.timeIntervalSince(op.lastProgressAt) > stallTimeout
        }.map(\.id))
    }

    // MARK: - Private

    private func trimRecent() {
        if recentOperations.count > Self.recentCapacity {
            recentOperations = Array(recentOperations.prefix(Self.recentCapacity))
            isRecentTruncated = true
        }
    }
}
