import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - M3U import into a chosen playlist (S-PLD-M3U-PREVIEW, PP-PLAYLISTS-01)

/// What importing an M3U file will do — the preview sheet's rows and counts. The *destination*
/// is the caller's (the open playlist, or a new playlist named after the file): the file's
/// name and embedded playlist UUID choose nothing any more (PP-PLAYLISTS-01, fixed here).
/// Entries are matched by the ingest engine (`PlaylistIngestService.resolveEntries`: track
/// UUID, then file name).
struct M3UImportPlan: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case willAdd
        case alreadyInPlaylist
        case notFound

        /// The Result column (`playlists.html` S-PLD-M3U-PREVIEW).
        var text: String {
            switch self {
            case .willAdd: "Will be added"
            case .alreadyInPlaylist: "Already in playlist — skipped"
            case .notFound: "Not found — skipped"
            }
        }
    }

    struct Row: Equatable, Identifiable, Sendable {
        /// 1-based entry number in the file.
        let id: Int
        /// The entry as the file has it (its path or URL line).
        let entry: String
        let trackID: Int64?
        /// `Title — Artist` of the matched library track.
        let trackText: String?
        let outcome: Outcome
    }

    let fileName: String
    let rows: [Row]

    /// Tracks to append, in file order, each once.
    var toAdd: [Int64] { rows.filter { $0.outcome == .willAdd }.compactMap(\.trackID) }
    var alreadyPresent: Int { rows.filter { $0.outcome == .alreadyInPlaylist }.count }
    var notFound: [Row] { rows.filter { $0.outcome == .notFound } }

    /// The file's name without its extension — the name of a new playlist.
    var playlistName: String { (fileName as NSString).deletingPathExtension }

    /// Builds the rows. `existing` = the destination's tracks (empty for a new playlist); a
    /// track listed twice in the file counts as already in the playlist the second time.
    static func make(fileName: String, entries: [(entry: String, trackID: Int64?, trackText: String?)],
                     existing: Set<Int64>) -> M3UImportPlan {
        var present = existing
        var rows: [Row] = []
        for (index, item) in entries.enumerated() {
            let outcome: Outcome
            if let id = item.trackID {
                outcome = present.insert(id).inserted ? .willAdd : .alreadyInPlaylist
            } else {
                outcome = .notFound
            }
            rows.append(Row(id: index + 1, entry: item.entry, trackID: item.trackID, trackText: item.trackText, outcome: outcome))
        }
        return M3UImportPlan(fileName: fileName, rows: rows)
    }

    /// Sheet title (UC-SHEET-01): `Import “Old iPod.m3u8” into “Warm-up”`.
    static func title(fileName: String, destination: String?) -> String {
        destination.map { "Import “\(fileName)” into “\($0)”" } ?? "Import “\(fileName)” as a New Playlist"
    }

    /// First sentence (UC-SHEET-02): what will happen, in numbers.
    func summary(destination: String?) -> String {
        let count = toAdd.count
        if let destination {
            return "\(StatusBarText.tracks(count)) will be added to the end of “\(destination)”."
        }
        return "A new playlist “\(playlistName)” will be created with \(StatusBarText.tracks(count))."
    }

    /// Second sentence: what is skipped. `Nothing is removed or reordered. 4 entries are already
    /// in this playlist and 6 can’t be found in the library.`
    func skippedText(intoExisting: Bool) -> String {
        var parts: [String] = []
        if alreadyPresent > 0 {
            parts.append(intoExisting
                ? "\(StatusBarText.count(alreadyPresent, "entry is", "entries are")) already in this playlist"
                : "\(StatusBarText.count(alreadyPresent, "entry is", "entries are")) listed twice")
        }
        if !notFound.isEmpty {
            parts.append("\(notFound.count.formatted(.number)) can’t be found in the library")
        }
        let lead = intoExisting ? "Nothing is removed or reordered." : ""
        guard !parts.isEmpty else { return lead }
        return ([lead, parts.joined(separator: " and ") + "."].filter { !$0.isEmpty }).joined(separator: " ")
    }

    /// Primary button (UC-SHEET-03): `Add 38 Tracks` / `Create Playlist with 38 Tracks`.
    func primaryTitle(intoExisting: Bool) -> String {
        let n = toAdd.count
        let tracks = n == 1 ? "1 Track" : "\(n.formatted(.number)) Tracks"
        return intoExisting ? "Add \(tracks)" : "Create Playlist with \(tracks)"
    }

    /// `Copy Not-Found List`: one entry per line.
    var notFoundList: String { notFound.map(\.entry).joined(separator: "\n") }
}

enum PlaylistM3U {
    /// Reads and matches an M3U file against the library (no write).
    static func plan(url: URL, ingest: PlaylistIngestService, existing: Set<Int64>) async throws -> M3UImportPlan {
        let parsed = try ingest.parse(url: url)
        let resolved = try await ingest.resolveEntries(parsed.entries)
        var matched: [String: Track] = [:]
        for item in resolved.resolved { matched[item.entry.path] = item.track }
        // Resolution splits matched and unmatched; the file's order comes from the parsed entries.
        let entries: [(entry: String, trackID: Int64?, trackText: String?)] = parsed.entries.map { entry in
            let track = matched[entry.path]
            return (entry.path, track?.id, track.map { "\($0.title) — \($0.artist)" })
        }
        return .make(fileName: url.lastPathComponent, entries: entries, existing: existing)
    }

    /// The playlist as an extended M3U (UTF-8): `#EXTINF` per track, the file's absolute path
    /// under the library folder, and `#EXTMLM` (MLM's track id) so re-importing it matches
    /// exactly. Tracks without a file are left out and counted.
    static func export(tracks: [Track], libraryRoot: String?) -> (text: String, leftOut: Int) {
        var lines = ["#EXTM3U"]
        var leftOut = 0
        for track in tracks {
            guard let organized = track.organizedPath, !organized.isEmpty else {
                leftOut += 1
                continue
            }
            let path = libraryRoot.map { URL(fileURLWithPath: $0).appendingPathComponent(organized).path } ?? organized
            lines.append("#EXTINF:\(track.duration ?? -1),\(track.artist) - \(track.title)")
            if let uuid = track.mlmUuid { lines.append("#EXTMLM:\(uuid)") }
            lines.append(path)
        }
        return (lines.joined(separator: "\n") + "\n", leftOut)
    }

    static var contentTypes: [UTType] {
        [UTType(filenameExtension: "m3u8"), UTType(filenameExtension: "m3u")].compactMap { $0 }
    }
}

/// The exported file for `.fileExporter` (Export ▸ Playlist as M3U…).
struct M3UDocument: FileDocument {
    static var readableContentTypes: [UTType] { PlaylistM3U.contentTypes }
    static var writableContentTypes: [UTType] { PlaylistM3U.contentTypes }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
