import SwiftUI

/// ViewModel for tracking active operations across the app.
///
/// Aggregates progress from downloads, syncs, imports, and analysis
/// for display in the Activity Panel.
@Observable
final class ActivityViewModel {
    // MARK: - Operation Tracking

    struct Operation: Identifiable {
        let id = UUID()
        let type: OperationType
        var title: String
        var status: OperationStatus
        var progress: Double  // 0.0–1.0
        var detail: String
        var startedAt: Date
        var completedAt: Date?

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
    }

    // MARK: - State

    private(set) var operations: [Operation] = []
    private(set) var recentOperations: [Operation] = [] // last 20 completed

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
    func startOperation(type: Operation.OperationType, title: String, detail: String = "") -> UUID {
        let op = Operation(
            type: type,
            title: title,
            status: .running,
            progress: 0,
            detail: detail,
            startedAt: Date()
        )
        operations.append(op)
        AppLogger.shared.log("Started: \(title)", source: type.rawValue)
        return op.id
    }

    /// Update progress for an operation.
    func updateProgress(id: UUID, progress: Double, detail: String? = nil) {
        guard let idx = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[idx].progress = progress
        if let detail { operations[idx].detail = detail }
    }

    /// Mark an operation as completed.
    func completeOperation(id: UUID, detail: String? = nil) {
        guard let idx = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[idx].status = .completed
        operations[idx].progress = 1.0
        operations[idx].completedAt = Date()
        if let detail { operations[idx].detail = detail }

        let op = operations[idx]
        AppLogger.shared.log("Completed: \(op.title) (\(op.formattedDuration))", source: op.type.rawValue)

        // Move to recent
        recentOperations.insert(operations.remove(at: idx), at: 0)
        if recentOperations.count > 20 {
            recentOperations = Array(recentOperations.prefix(20))
        }
    }

    /// Mark an operation as failed.
    func failOperation(id: UUID, error: String) {
        guard let idx = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[idx].status = .failed
        operations[idx].completedAt = Date()
        operations[idx].detail = error

        let op = operations[idx]
        AppLogger.shared.log("Failed: \(op.title): \(error)", level: .error, source: op.type.rawValue)

        recentOperations.insert(operations.remove(at: idx), at: 0)
        if recentOperations.count > 20 {
            recentOperations = Array(recentOperations.prefix(20))
        }
    }

    /// Mark an operation as cancelled without presenting cancellation as a
    /// failure in Activity → Recent.
    func cancelOperation(id: UUID, detail: String? = nil) {
        guard let idx = operations.firstIndex(where: { $0.id == id }) else { return }
        operations[idx].status = .cancelled
        operations[idx].completedAt = Date()
        if let detail { operations[idx].detail = detail }

        recentOperations.insert(operations.remove(at: idx), at: 0)
        if recentOperations.count > 20 {
            recentOperations = Array(recentOperations.prefix(20))
        }
    }

    /// Clear completed operations from recent list.
    func clearRecent() {
        recentOperations.removeAll()
    }
}
