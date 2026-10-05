import Foundation
import GRDB

/// The playback package's own reads and writes on `tracks` (W2-C): the analysed drop for the
/// preview hot spot, and Locate File… (re-point a `File missing` / `Download failed` track at a
/// file inside the library folder, undoable).
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

    /// Every column Locate File… changes, as they were or as they become — Undo writes them back
    /// exactly.
    struct FileLocation: Equatable, Sendable {
        let trackID: Int64
        let organizedPath: String?
        let fileMissingSince: String?
        let format: String?
        let bitrate: Int?
        let duration: Int?
        let downloadStatus: String?
        let downloadFailure: String?

        fileprivate init(trackID: Int64, row: Row) {
            self.trackID = trackID
            organizedPath = row["organized_path"]
            fileMissingSince = row["file_missing_since"]
            format = row["format"]
            bitrate = row["bitrate"]
            duration = row["duration"]
            downloadStatus = row["download_status"]
            downloadFailure = row["download_failure"]
        }

        init(trackID: Int64, organizedPath: String?, fileMissingSince: String?, format: String?, bitrate: Int?,
             duration: Int?, downloadStatus: String?, downloadFailure: String?) {
            self.trackID = trackID
            self.organizedPath = organizedPath
            self.fileMissingSince = fileMissingSince
            self.format = format
            self.bitrate = bitrate
            self.duration = duration
            self.downloadStatus = downloadStatus
            self.downloadFailure = downloadFailure
        }
    }

    /// What the chosen file is (read from the file before anything is written).
    struct FileFacts: Equatable, Sendable {
        /// Lowercased extension (`m4a`), as `tracks.format` stores it.
        var format: String
        var bitrate: Int?
        var duration: Int?
    }

    enum LocateError: Error, Equatable {
        case trackNotFound
        /// Another track already uses that file (removing one from the library would trash the
        /// other's file).
        case alreadyUsed(byTitle: String)
    }

    private static let columns = "organized_path, file_missing_since, format, bitrate, duration, download_status, download_failure"

    /// In one transaction: refuse when another track already uses the file (relative or
    /// absolute form, any letter case); point `trackID` at `relativePath`, clear its
    /// `File missing` flag and download failure/status (a later retry can't overwrite the
    /// located path), and take format, bitrate and duration from the file. Returns the columns
    /// as they were (for Undo).
    func relocate(trackID: Int64, toRelativePath relativePath: String, absolutePath: String,
                  facts: FileFacts) async throws -> FileLocation {
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM tracks WHERE id = ?", arguments: [trackID]) else {
                throw LocateError.trackNotFound
            }
            if let other = try Row.fetchOne(db, sql: """
                SELECT title FROM tracks
                WHERE id != ? AND (LOWER(organized_path) = LOWER(?) OR LOWER(organized_path) = LOWER(?))
                LIMIT 1
                """, arguments: [trackID, relativePath, absolutePath]) {
                throw LocateError.alreadyUsed(byTitle: other["title"] ?? "")
            }
            let previous = FileLocation(trackID: trackID, row: row)
            try db.execute(sql: """
                UPDATE tracks SET organized_path = ?, file_missing_since = NULL, download_failure = NULL,
                    download_status = NULL, format = ?, bitrate = COALESCE(?, bitrate), duration = COALESCE(?, duration)
                WHERE id = ?
                """, arguments: [relativePath, facts.format, facts.bitrate, facts.duration, trackID])
            return previous
        }
    }

    /// Write back every column exactly (Undo / Redo of Locate File…). Returns the columns as they
    /// were before this write.
    @discardableResult
    func restore(_ location: FileLocation) async throws -> FileLocation {
        try await database.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT \(Self.columns) FROM tracks WHERE id = ?",
                                             arguments: [location.trackID]) else {
                throw LocateError.trackNotFound
            }
            let before = FileLocation(trackID: location.trackID, row: row)
            try db.execute(sql: """
                UPDATE tracks SET organized_path = ?, file_missing_since = ?, format = COALESCE(?, format), bitrate = ?,
                    duration = ?, download_status = ?, download_failure = ?
                WHERE id = ?
                """, arguments: [location.organizedPath, location.fileMissingSince, location.format, location.bitrate,
                                 location.duration, location.downloadStatus, location.downloadFailure, location.trackID])
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

    /// A folder's file-system identity: two URLs that name the same folder have the same one,
    /// whatever their spelling (letter case on a case-insensitive volume, symlinks).
    typealias Identity = @Sendable (URL) -> AnyHashable?

    /// The file system's own identity (`fileResourceIdentifier`); `nil` when it can't be read.
    static let fileSystemIdentity: Identity = { url in
        guard let identifier = try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
              let object = identifier as? NSObject else { return nil }
        return AnyHashable(object)
    }

    /// Inside = one of the file's ancestor folders *is* the library folder (by identity, not by
    /// comparing strings); the relative path is the file's own spelling below it.
    static func verdict(for fileURL: URL, libraryRoot: String?, identity: Identity = fileSystemIdentity) -> Verdict {
        guard let libraryRoot, !libraryRoot.isEmpty else { return .noLibraryFolder }
        let root = URL(fileURLWithPath: libraryRoot).standardizedFileURL.resolvingSymlinksInPath()
        let file = fileURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootID = identity(root) ?? AnyHashable(root.path)
        var components: [String] = [file.lastPathComponent]
        var folder = file.deletingLastPathComponent()
        while folder.path != "/" && !folder.path.isEmpty {
            let folderID = identity(folder) ?? AnyHashable(folder.path)
            if folderID == rootID {
                return .inside(relativePath: components.reversed().joined(separator: "/"))
            }
            components.append(folder.lastPathComponent)
            folder = folder.deletingLastPathComponent()
        }
        return .outsideLibraryFolder
    }

    /// The panel's message line (UC-SHEET-24/25 shape).
    static func panelMessage(title: String) -> String {
        "Choose the file of “\(title)”. It must be inside the library folder."
    }

    /// `Locate File…` refused a file outside the library folder (UC-SHEET-19 shape: what · why).
    static func outsideMessage(fileName: String) -> String {
        "Couldn’t use “\(fileName)” — the file must be inside the library folder"
    }

    /// Refused: another track uses that file.
    static func alreadyUsedMessage(fileName: String, otherTitle: String) -> String {
        "Couldn’t use “\(fileName)” — it is the file of “\(otherTitle)”"
    }

    static let noLibraryFolderMessage = "Couldn’t locate the file — this library has no library folder"

    /// `Couldn’t use “‹file›” — macOS can’t read it` (the file can't be opened as audio).
    static func unreadableMessage(fileName: String) -> String {
        "Couldn’t use “\(fileName)” — the file can’t be read"
    }

    /// Length (± 2 s) or format differ: ask first (§12.3 — the question as title, the
    /// consequence as message; `Use This File` / `Cancel`, Cancel is the default).
    struct Mismatch: Equatable, Sendable {
        let title: String
        let message: String
    }

    static let durationTolerance = 2

    static func mismatch(trackTitle: String, trackFormat: String, trackDuration: Int?, fileName: String,
                         facts: TrackLocateRepository.FileFacts) -> Mismatch? {
        var differences: [String] = []
        if let trackDuration, trackDuration > 0, let fileDuration = facts.duration,
           abs(trackDuration - fileDuration) > durationTolerance {
            differences.append("The file is \(PlaybackWords.time(TimeInterval(fileDuration))) long, the track \(PlaybackWords.time(TimeInterval(trackDuration))).")
        }
        let trackFormat = trackFormat.trimmingCharacters(in: .whitespaces).lowercased()
        if !trackFormat.isEmpty, trackFormat != facts.format {
            differences.append("The file is \(facts.format.uppercased()), the track was \(trackFormat.uppercased()).")
        }
        guard !differences.isEmpty else { return nil }
        return Mismatch(
            title: "Use “\(fileName)” for “\(trackTitle)”?",
            message: differences.joined(separator: " ")
                + " MLM will play this file for the track and take its length and format. You can undo this."
        )
    }

    /// `Edit ▸ Undo Locate “‹title›”` (UC-UNDO-07).
    static func actionName(title: String) -> String { "Locate “\(title)”" }

    /// The confirmation, with Undo (UC-STATUS-05 shape).
    static func doneMessage(title: String) -> String { "Located the file of “\(title)”" }
}
