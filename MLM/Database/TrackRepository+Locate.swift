import Foundation
import GRDB

/// The playback package's own reads and writes on `tracks` (W2-C): the analysed drop for the
/// preview hot spot, and Locate File… (re-point a `File missing` track at a file inside the
/// library folder, undoable).
///
/// A separate small store on the same database writer — `TrackRepository` keeps its writer
/// private, and this package does not edit `TrackRepository.swift`.
struct TrackLocateRepository: Sendable {
    let database: any DatabaseWriter

    init(database: any DatabaseWriter) {
        self.database = database
    }

    /// The live store of the open library, if one is open.
    static func live(_ container: DependencyContainer = .shared) -> TrackLocateRepository? {
        container.databaseManager.map { TrackLocateRepository(database: $0.pool) }
    }

    // MARK: Hot spot

    /// The analysed drop of a track in seconds (`track_embeddings.drop_offset`), `nil` when the
    /// track wasn't analysed or no drop was found (0).
    func dropOffset(trackID: Int64) async throws -> Double? {
        try await database.read { db in
            let value = try Double.fetchOne(db, sql: "SELECT drop_offset FROM track_embeddings WHERE track_id = ? LIMIT 1",
                                            arguments: [trackID])
            guard let value, value > 0 else { return nil }
            return value
        }
    }

    // MARK: Locate File…

    /// The two columns Locate File… changes, as they were or as they become.
    struct FileLocation: Equatable, Sendable {
        let trackID: Int64
        let organizedPath: String?
        let fileMissingSince: String?
    }

    enum LocateError: Error, Equatable {
        case trackNotFound
    }

    /// Point `trackID` at `relativePath` (inside the library folder) and clear its
    /// `File missing` flag, in one transaction. Returns the columns as they were (for Undo).
    func relocate(trackID: Int64, toRelativePath relativePath: String) async throws -> FileLocation {
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT organized_path, file_missing_since FROM tracks WHERE id = ?",
                                             arguments: [trackID]) else {
                throw LocateError.trackNotFound
            }
            let previous = FileLocation(trackID: trackID, organizedPath: row["organized_path"], fileMissingSince: row["file_missing_since"])
            try db.execute(sql: "UPDATE tracks SET organized_path = ?, file_missing_since = NULL WHERE id = ?",
                           arguments: [relativePath, trackID])
            return previous
        }
    }

    /// Write back both columns exactly (Undo / Redo of Locate File…). Returns the columns as
    /// they were before this write.
    @discardableResult
    func restore(_ location: FileLocation) async throws -> FileLocation {
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT organized_path, file_missing_since FROM tracks WHERE id = ?",
                                             arguments: [location.trackID]) else {
                throw LocateError.trackNotFound
            }
            let before = FileLocation(trackID: location.trackID, organizedPath: row["organized_path"], fileMissingSince: row["file_missing_since"])
            try db.execute(sql: "UPDATE tracks SET organized_path = ?, file_missing_since = ? WHERE id = ?",
                           arguments: [location.organizedPath, location.fileMissingSince, location.trackID])
            return before
        }
    }
}

// MARK: - Locate rules (pure)

/// Locate File… accepts only a file inside the library folder (this package doesn't copy or
/// move files); the stored path is relative to it.
enum LocateFileRule {
    enum Verdict: Equatable, Sendable {
        case inside(relativePath: String)
        case outsideLibraryFolder
        case noLibraryFolder
    }

    static func verdict(for fileURL: URL, libraryRoot: String?) -> Verdict {
        guard let libraryRoot, !libraryRoot.isEmpty else { return .noLibraryFolder }
        let root = URL(fileURLWithPath: libraryRoot).standardizedFileURL.resolvingSymlinksInPath().path
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        guard file.hasPrefix(prefix), file.count > prefix.count else { return .outsideLibraryFolder }
        return .inside(relativePath: String(file.dropFirst(prefix.count)))
    }

    /// The panel's message line (UC-SHEET-24/25 shape).
    static func panelMessage(title: String) -> String {
        "Choose the file of “\(title)”. It must be inside the library folder."
    }

    /// `Locate File…` refused a file outside the library folder (UC-SHEET-19 shape: what · why).
    static func outsideMessage(fileName: String) -> String {
        "Couldn’t use “\(fileName)” — the file must be inside the library folder"
    }

    static let noLibraryFolderMessage = "Couldn’t locate the file — this library has no library folder"

    /// `Edit ▸ Undo Locate “‹title›”` (UC-UNDO-07).
    static func actionName(title: String) -> String { "Locate “\(title)”" }

    /// The confirmation, with Undo (UC-STATUS-05 shape).
    static func doneMessage(title: String) -> String { "Located the file of “\(title)”" }
}
