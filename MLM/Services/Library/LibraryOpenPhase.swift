import Foundation
import GRDB

/// What opening a library is doing right now: the phase line under `Opening “‹name›”…`
/// (V-LAUNCH-LOADING, UC-STATE §15.1, UC-JOB-01: the pre-update backup is a phase line here,
/// because the Activity registry doesn't exist before a library is open).
///
/// Reported by the open path through a `LibraryOpenProgress` callback. Reporting never changes
/// what the open path does to files or databases.
enum LibraryOpenPhase: Equatable, Sendable {
    /// Validating the library file (identity of file, database and registry).
    case checking
    /// Opening the database and starting the library's services.
    case reading
    /// The pre-update backup (`Before update`); `bytes` = size of the database being copied.
    case backingUp(bytes: Int64?)
    /// Schema updates, `step` of `total` (1-based). `step == nil` when they run as one block.
    case updating(step: Int?, total: Int)
    /// Finishing a library file setup (adoption) that was interrupted last time.
    case finishingSetup

    /// The phase line, verbatim UC-STATE §15.1 where it has the words.
    var line: String {
        switch self {
        case .checking: return "Checking the library file…"
        case .reading: return "Reading the library…"
        case .backingUp: return "Backing up before update…"
        case .updating: return "Updating the library…"
        case .finishingSetup: return "Finishing library file setup…"
        }
    }

    /// The count after the phase line (`3 of 5`), when there is one.
    var count: String? {
        guard case .updating(let step?, let total) = self else { return nil }
        return "\(step.formatted(.number)) of \(total.formatted(.number))"
    }

    /// `step / total` for a determinate bar, `nil` when indeterminate.
    var fraction: Double? {
        guard case .updating(let step?, let total) = self, total > 0 else { return nil }
        return Double(step - 1) / Double(total)
    }

    /// One explanatory line under the phase.
    var caption: String? {
        switch self {
        case .backingUp(let bytes?):
            return "This version of MLM updates the library database. A backup of \(bytes.formatted(.byteCount(style: .file))) is made first."
        case .backingUp(nil):
            return "This version of MLM updates the library database. A backup is made first."
        case .updating:
            return "A backup was made before the update."
        case .finishingSetup:
            return "The setup was interrupted last time. MLM is completing it; your library is not changed until it is verified."
        case .checking, .reading:
            return nil
        }
    }

    /// The library file is being written: there is no way out while this runs (V-LAUNCH-LOADING.N01).
    var isWriting: Bool {
        switch self {
        case .backingUp, .updating, .finishingSetup: return true
        case .checking, .reading: return false
        }
    }
}

/// Receives the phases of one open, from whatever thread the open runs on.
typealias LibraryOpenProgress = @Sendable (LibraryOpenPhase) -> Void

/// An error of `DatabaseManager(databaseURL:…)` with the step it came from, so the failure
/// screen says what is true (W3-LAUNCH review S7): before the pre-update backup nothing was
/// written; a failed backup means nothing was updated; a failed update had a backup first.
/// Any other error while opening a library is not one of these.
struct LibraryOpenError: Error, CustomStringConvertible {
    enum Stage: Equatable, Sendable {
        /// Opening the database and reading its migrations.
        case opening
        /// The pre-update backup (`Before update`).
        case backingUp
        /// Running the migrations.
        case updating
    }

    let stage: Stage
    let underlying: Error

    var description: String { String(describing: underlying) }
}

/// Runs the pending migrations one by one so the loading screen can say `3 of 5`.
///
/// The result is the same as `migrator.migrate(writer)`: the same migrations, in registration
/// order, each in its own transaction (GRDB runs every migration in its own transaction either
/// way). `migrate(_:upTo:)` refuses a target that lies before an applied migration, so stepping
/// is used only when every pending migration comes after the last applied one; otherwise the
/// migrations run as one block (`updating(step: nil, …)`). A final `migrate(writer)` always
/// runs, so nothing registered is ever left out.
enum DatabaseMigrationSteps {
    static func migrate(
        _ migrator: DatabaseMigrator,
        _ writer: some DatabaseWriter,
        progress: LibraryOpenProgress?
    ) throws {
        guard let progress else {
            try migrator.migrate(writer)
            return
        }
        let (applied, appliedKnown) = try writer.read { db in
            (try migrator.appliedIdentifiers(db), try migrator.appliedMigrations(db))
        }
        let registered = migrator.migrations
        let pending = registered.filter { !applied.contains($0) }
        // A new database is created, not updated: nothing to count.
        guard !applied.isEmpty, !pending.isEmpty else {
            try migrator.migrate(writer)
            return
        }
        let lastApplied = appliedKnown.last.flatMap { registered.firstIndex(of: $0) } ?? -1
        let steppable = pending.allSatisfy { (registered.firstIndex(of: $0) ?? -1) > lastApplied }
        if steppable {
            for (index, identifier) in pending.enumerated() {
                progress(.updating(step: index + 1, total: pending.count))
                try migrator.migrate(writer, upTo: identifier)
            }
        } else {
            progress(.updating(step: nil, total: pending.count))
        }
        try migrator.migrate(writer)
    }
}
