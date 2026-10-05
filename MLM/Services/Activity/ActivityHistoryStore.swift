import Foundation

// MARK: - Retention (B3-PLAN §5 question 4, IMP proposed by W3-ACT)

/// How much finished history is kept: **the last 200 finished operations or 30 days, whichever
/// is smaller** (both limits apply). Operations that still need attention (failures not
/// dismissed and not fixed) are never pruned. One constant, no setting.
enum ActivityRetention {
    static let maxCount = 200
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    static func cutoff(now: Date) -> Date { now.addingTimeInterval(-maxAge) }
}

// MARK: - Persisted record

/// One row of `activity_operations` (per library, in the library file) or one entry of the
/// app-level JSON file (operations without a library). Running operations are written when
/// they start so that a quit mid-job can be closed honestly at the next launch.
struct ActivityOperationRecord: Codable, Equatable, Sendable {
    var id: UUID
    var kind: ActivityKind
    var title: String
    var subject: ActivitySubject
    var state: ActivityState
    var isAutomatic: Bool
    var startedAt: Date
    var endedAt: Date?
    var result: ActivityResult?
    var needsAttention: Bool
    var dismissedAt: Date?

    init(_ operation: ActivityOperation) {
        id = operation.id
        kind = operation.kind
        title = operation.title
        subject = operation.subject
        state = operation.state
        isAutomatic = operation.isAutomatic
        startedAt = operation.startedAt
        endedAt = operation.endedAt
        result = operation.result
        needsAttention = operation.needsAttention
        dismissedAt = operation.dismissedAt
    }

    init(id: UUID, kind: ActivityKind, title: String, subject: ActivitySubject, state: ActivityState,
         isAutomatic: Bool, startedAt: Date, endedAt: Date?, result: ActivityResult?,
         needsAttention: Bool, dismissedAt: Date?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subject = subject
        self.state = state
        self.isAutomatic = isAutomatic
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.result = result
        self.needsAttention = needsAttention
        self.dismissedAt = dismissedAt
    }

    /// The operation as restored from history: no controls, no job behind it.
    func operation(libraryID: String?) -> ActivityOperation {
        ActivityOperation(
            id: id, kind: kind, title: title, subject: subject, state: state, wait: nil,
            progress: .indeterminate, result: result, startedAt: startedAt, endedAt: endedAt,
            isAutomatic: isAutomatic, libraryID: libraryID, needsAttention: needsAttention,
            dismissedAt: dismissedAt, itemNoun: .item, messageName: kind.messageName,
            controls: .none, isFromHistory: true
        )
    }
}

/// The sentence of an operation that was still running when MLM quit (closed at the next
/// launch, never left "Running" forever).
enum ActivityInterruption {
    static let summary = "Stopped when MLM quit — finished work is kept"
}

// MARK: - Store

/// Where finished operations are kept. Two implementations: `ActivityOperationRepository`
/// (table `activity_operations` in the open library, migration `v46_activity_operations`)
/// and `ActivityAppLevelStore` (a small JSON file next to the library registry, for work
/// without a library). Tests inject temporary databases / directories.
protocol ActivityHistoryStore: Sendable {
    /// Insert or replace one record.
    func save(_ record: ActivityOperationRecord) async throws
    /// Newest first: finished operations within the retention limits, plus every record that
    /// still needs attention.
    func load(now: Date) async throws -> [ActivityOperationRecord]
    /// Close every record still marked queued/running/paused (MLM quit mid-job) as Cancelled
    /// with `ActivityInterruption.summary`. Returns the number closed.
    @discardableResult
    func closeInterrupted(at date: Date) async throws -> Int
    /// Apply `ActivityRetention`.
    func prune(now: Date) async throws
    func delete(id: UUID) async throws
    func markDismissed(ids: [UUID], at date: Date) async throws
    func clearAttention(id: UUID) async throws
    /// Mark subjects that no longer exist (deleted playlist, sync profile) so their links become
    /// plain text. Returns the number of records changed.
    @discardableResult
    func markMissingSubjects() async throws -> Int
}

/// Pure retention rule shared by both stores (and tested once).
enum ActivityRetentionRule {
    /// The records to keep, newest first.
    static func apply(_ records: [ActivityOperationRecord], now: Date) -> [ActivityOperationRecord] {
        let cutoff = ActivityRetention.cutoff(now: now)
        let sorted = records.sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
        var keptFinished = 0
        var kept: [ActivityOperationRecord] = []
        for record in sorted {
            if record.state.isActive || isProtected(record) {
                kept.append(record)
                continue
            }
            let end = record.endedAt ?? record.startedAt
            guard end >= cutoff, keptFinished < ActivityRetention.maxCount else { continue }
            keptFinished += 1
            kept.append(record)
        }
        return kept
    }

    /// Needs attention and not dismissed: kept until dismissed or fixed.
    static func isProtected(_ record: ActivityOperationRecord) -> Bool {
        record.needsAttention && record.dismissedAt == nil
    }
}

// MARK: - App-level JSON store

/// Operations without a library (library adoption, open / restore, backups before a library
/// is open). A JSON file next to the library registry (`LibraryRegistryStore`'s folder) in
/// the app, a temporary directory in tests. Never created by tests that don't inject it.
actor ActivityAppLevelStore: ActivityHistoryStore {
    let fileURL: URL

    /// `activity.json` beside `libraries.json`.
    static var defaultFileURL: URL {
        LibraryRegistryStore.defaultFileURL.deletingLastPathComponent().appendingPathComponent("activity.json")
    }

    init(fileURL: URL = ActivityAppLevelStore.defaultFileURL) {
        self.fileURL = fileURL
    }

    private func read() -> [ActivityOperationRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([ActivityOperationRecord].self, from: data)) ?? []
    }

    private func write(_ records: [ActivityOperationRecord]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let data = try Self.encoder.encode(records)
        try data.write(to: fileURL, options: .atomic)
    }

    func save(_ record: ActivityOperationRecord) async throws {
        var records = read().filter { $0.id != record.id }
        records.append(record)
        try write(ActivityRetentionRule.apply(records, now: Date()))
    }

    func load(now: Date) async throws -> [ActivityOperationRecord] {
        ActivityRetentionRule.apply(read(), now: now)
    }

    func closeInterrupted(at date: Date) async throws -> Int {
        var records = read()
        var closed = 0
        for index in records.indices where records[index].state.isActive {
            records[index].state = .cancelled
            records[index].endedAt = date
            var result = records[index].result ?? .empty
            result.summary = ActivityInterruption.summary
            records[index].result = result
            closed += 1
        }
        if closed > 0 { try write(records) }
        return closed
    }

    func prune(now: Date) async throws {
        let records = read()
        let kept = ActivityRetentionRule.apply(records, now: now)
        if kept.count != records.count { try write(kept) }
    }

    func delete(id: UUID) async throws {
        try write(read().filter { $0.id != id })
    }

    func markDismissed(ids: [UUID], at date: Date) async throws {
        let set = Set(ids)
        var records = read()
        for index in records.indices where set.contains(records[index].id) {
            records[index].dismissedAt = date
        }
        try write(records)
    }

    func clearAttention(id: UUID) async throws {
        var records = read()
        for index in records.indices where records[index].id == id {
            records[index].needsAttention = false
        }
        try write(records)
    }

    /// App-level operations have no library subjects to check.
    func markMissingSubjects() async throws -> Int { 0 }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
