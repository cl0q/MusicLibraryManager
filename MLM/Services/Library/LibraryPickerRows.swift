import Foundation
import GRDB

/// One row of the library picker (V-PICKER, DEC-031): a library MLM knows, with its state in
/// the words of UC-STATE §15.1. Built purely from the registry, the old install and what this
/// session found out by trying to open libraries; nothing here reads or writes a database.
struct LibraryPickerRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// A registry entry (A0 D5).
        case registered(libraryId: String)
        /// The install from before library files, until it is set up (A0 D7, G-LIB-LEGACY).
        case legacy
        /// A library file that isn't on the list and couldn't be opened this session.
        case unlisted
        /// A library file setup whose journal is still there (interrupted, or its rollback
        /// failed) — W3-LAUNCH review S3.
        case interruptedSetup
    }

    enum State: Equatable, Sendable {
        case available
        case notFound
        case notConnected(volume: String)
        /// The library file and its database don't belong together (G-LIB-MISMATCH).
        case mismatch(details: String)
        /// The old install: openable as it is, `Set Up…` makes it a library file.
        case needsSetup
        /// The setup of the library file didn't finish; `Try Again` finishes or undoes it.
        case setupInterrupted(details: String)
    }

    let id: String
    let kind: Kind
    let name: String
    /// The library file, or the old install's database.
    let url: URL
    let lastOpenedAt: Date?
    let state: State

    /// Name as listed: `Main Library (needs setup)` for the old install,
    /// `Main Library (setup interrupted)` for an unfinished setup.
    var listedName: String {
        switch state {
        case .needsSetup: return "\(name) (needs setup)"
        case .setupInterrupted: return "\(name) (setup interrupted)"
        default: return name
        }
    }

    /// Location with the home folder as `~`.
    var location: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    var canOpen: Bool {
        switch state {
        case .available, .needsSetup: return true
        case .notFound, .notConnected, .mismatch, .setupInterrupted: return false
        }
    }

    /// The row's state in words; nothing when all is well (UC-STATE §15.1).
    var stateText: String? {
        switch state {
        case .available, .needsSetup, .setupInterrupted: return nil
        case .notFound: return "Not found"
        case .notConnected(let volume): return "Not connected — on “\(volume)”"
        case .mismatch: return "Can’t be opened — the file and its database don’t match"
        }
    }

    /// The explanation under a selected problem row (`launch.html` V-PICKER `.lx` texts).
    var explanation: String? {
        switch state {
        case .available: return nil
        case .notConnected(let volume):
            return "The library file is on “\(volume)”, which isn’t connected. Connect the disk, then try again — this row becomes available as soon as the disk appears."
        case .notFound:
            return "The library file isn’t where MLM last found it. If you moved it, locate it. If you deleted it, remove it from this list — nothing else is removed."
        case .mismatch:
            return "The library file and its database don’t belong together. This can happen when files inside a library file were replaced. MLM didn’t change anything."
        case .needsSetup:
            return "This is your library from before MLM used library files. Setting it up takes about a minute: MLM backs up first, then copies it into one library file. Audio files are not moved. You can also open it as it is."
        case .setupInterrupted:
            return "Setting up the library file didn’t finish. Try Again completes it, or undoes it and asks again. Your previous library is not changed until the new file is verified."
        }
    }

    /// Beside a disabled `Open` (UC-COPY-13).
    var openRefusal: String? {
        switch state {
        case .available, .needsSetup: return nil
        case .notFound: return "Can’t open — not found"
        case .notConnected: return "Can’t open — not connected"
        case .mismatch: return "Can’t open — doesn’t match its database"
        case .setupInterrupted: return "Can’t open — setup interrupted"
        }
    }

    var isRegistered: Bool {
        if case .registered = kind { return true }
        return false
    }
}

/// A library file that couldn't be opened and isn't on the list (shown for this session).
struct UnlistedLibraryProblem: Equatable, Sendable {
    let url: URL
    let name: String
    let state: LibraryPickerRow.State
}

/// An adoption journal that is still there (S3).
struct InterruptedSetup: Equatable, Sendable {
    let name: String
    let journal: URL
    let details: String
}

enum LibraryPickerRows {
    /// The old install's name in the picker (`Main Library (needs setup)`).
    static let legacyName = "Main Library"

    /// Rows in picker order: libraries that just failed and aren't listed, then the registry
    /// most recently opened first, then the old install (or its interrupted setup).
    ///
    /// - Parameters:
    ///   - interruptedSetup: an adoption journal left behind; shown instead of the old install.
    ///   - mismatches: library-file paths found not to match their database this session,
    ///     with the details for the `Details` disclosure.
    static func build(
        registry: LibraryRegistry,
        legacyDatabase: URL?,
        interruptedSetup: InterruptedSetup? = nil,
        mismatches: [String: String] = [:],
        unlisted: [UnlistedLibraryProblem] = [],
        availability: (URL) -> LibraryAvailability = { LibraryRegistry.availability(of: $0) }
    ) -> [LibraryPickerRow] {
        var rows: [LibraryPickerRow] = []
        for problem in unlisted where registry.entry(at: problem.url) == nil {
            rows.append(LibraryPickerRow(
                id: "unlisted:" + problem.url.standardizedFileURL.path, kind: .unlisted, name: problem.name,
                url: problem.url, lastOpenedAt: nil, state: problem.state))
        }
        for entry in registry.recentEntries {
            let url = entry.url
            let path = url.standardizedFileURL.path
            let state: LibraryPickerRow.State
            switch availability(url) {
            case .available:
                state = mismatches[path].map { .mismatch(details: $0) } ?? .available
            case .notFound:
                state = .notFound
            case .notConnected:
                state = .notConnected(volume: volumeName(of: url) ?? "")
            }
            rows.append(LibraryPickerRow(
                id: entry.libraryId, kind: .registered(libraryId: entry.libraryId), name: entry.displayName,
                url: url, lastOpenedAt: entry.lastOpenedAt, state: state))
        }
        if let interruptedSetup {
            rows.append(LibraryPickerRow(
                id: "setup-interrupted", kind: .interruptedSetup, name: interruptedSetup.name,
                url: interruptedSetup.journal, lastOpenedAt: nil,
                state: .setupInterrupted(details: interruptedSetup.details)))
        } else if let legacyDatabase {
            rows.append(LibraryPickerRow(
                id: "legacy", kind: .legacy, name: legacyName, url: legacyDatabase,
                lastOpenedAt: nil, state: .needsSetup))
        }
        return rows
    }

    /// `Lexxar` for `/Volumes/Lexxar/…`, nil on the Mac's own disk.
    static func volumeName(of url: URL) -> String? {
        MountObserver.extractVolumePath(from: url.standardizedFileURL.path)
            .map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// The row to select first: the one a problem is about, else the most recent openable one.
    static func initialSelection(in rows: [LibraryPickerRow], focus: URL?) -> String? {
        if let focus {
            let path = focus.standardizedFileURL.path
            if let row = rows.first(where: { $0.url.standardizedFileURL.path == path }) { return row.id }
        }
        return (rows.first(where: \.canOpen) ?? rows.first)?.id
    }
}

/// The second line of an available row: `12,935 tracks · library folder on “Lexxar”`.
/// Read with a read-only connection, best effort: a library that can't be read just has no
/// second line. Never creates, migrates or repairs anything.
struct LibraryPickerFacts: Equatable, Sendable {
    var trackCount: Int?
    var libraryRoot: String?

    static func read(databaseAt url: URL) -> LibraryPickerFacts? {
        // Reachable first, like the file check's `LibraryRootReachability` (N6): never touch a
        // library on a volume that isn't mounted, or one that can't be read.
        if let volume = MountObserver.extractVolumePath(from: url.standardizedFileURL.path),
           !MountObserver.isVolumeMounted(volume) {
            return nil
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        var config = Configuration()
        config.readonly = true
        config.foreignKeysEnabled = false
        guard let queue = try? DatabaseQueue(path: url.path, configuration: config) else { return nil }
        defer { try? queue.close() }
        return try? queue.read { db in
            let count = try db.tableExists("tracks") ? try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tracks") : nil
            let root = try db.tableExists("app_config")
                ? try String.fetchOne(db, sql: "SELECT value FROM app_config WHERE key = 'library_root'")
                : nil
            return LibraryPickerFacts(trackCount: count, libraryRoot: root?.isEmpty == false ? root : nil)
        }
    }

    /// `12,935 tracks · library folder on “Lexxar”` / `… · not yet a library file` (old install).
    func caption(isLegacy: Bool) -> String? {
        var parts: [String] = []
        if let trackCount {
            parts.append("\(trackCount.formatted(.number)) \(trackCount == 1 ? "track" : "tracks")")
        }
        if isLegacy {
            parts.append("not yet a library file")
        } else if let libraryRoot {
            if let volume = LibraryPickerRows.volumeName(of: URL(fileURLWithPath: libraryRoot)) {
                parts.append("library folder on “\(volume)”")
            } else {
                parts.append("library folder on this Mac")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
