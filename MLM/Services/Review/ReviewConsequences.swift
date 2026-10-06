import Foundation

// MARK: - File access (injectable: tests use a temporary folder and never touch /Volumes)

/// The few file operations Review's Trash mode needs.
protocol ReviewFileManaging: Sendable {
    func fileExists(atPath path: String) -> Bool
    /// Move to the Trash; returns where it went (`nil` when the system doesn't say).
    func trash(_ url: URL) throws -> URL?
    /// Move a file back from `source` to `destination` (creating the folder when needed).
    func moveBack(from source: URL, to destination: URL) throws
}

/// The system Trash.
struct SystemReviewFileManager: ReviewFileManaging {
    func fileExists(atPath path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    func moveBack(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.moveItem(at: source, to: destination)
    }
}

// MARK: - Trash mode (V-REV.N03, IMP-052)

/// The file side of a Review decision in `Move to Trash` mode. It runs **after** the database
/// transaction committed — the database stays decided whatever happens to a file — and each
/// file is its own try: failures are counted, never thrown.
struct ReviewConsequences: Sendable {
    var files: any ReviewFileManaging = SystemReviewFileManager()

    struct TrashReport: Equatable, Sendable {
        var trashed: [ReviewDecisionConsequences.Trashed] = []
        var failures = 0
    }

    struct PutBackReport: Equatable, Sendable {
        var restored = 0
        /// No longer in the Trash (emptied, moved) or the original place is taken.
        var gone = 0
    }

    /// The file of a track: `organized_path` is absolute or relative to the library folder.
    static func fileURL(organizedPath: String?, libraryRoot: String?) -> URL? {
        guard let organizedPath, !organizedPath.isEmpty else { return nil }
        if (organizedPath as NSString).isAbsolutePath { return URL(fileURLWithPath: organizedPath) }
        guard let libraryRoot, !libraryRoot.isEmpty else { return nil }
        return URL(fileURLWithPath: libraryRoot).appendingPathComponent(organizedPath)
    }

    /// Move the files of `tracks` (id and resolved URL) to the Trash. A track without a file
    /// is not a failure (nothing to move); a file that is already gone isn't either.
    func trash(_ tracks: [(id: Int64, url: URL?)]) -> TrashReport {
        var report = TrashReport()
        for track in tracks {
            guard let url = track.url, files.fileExists(atPath: url.path) else { continue }
            do {
                let resulting = try files.trash(url)
                report.trashed.append(.init(trackId: track.id, from: url.path, trashURL: resulting?.path ?? ""))
            } catch {
                report.failures += 1
                AppLogger.shared.error("Review: couldn’t move “\(url.lastPathComponent)” to the Trash: \(error.localizedDescription)",
                                       source: "Review")
            }
        }
        return report
    }

    /// Move each trashed file back from its resulting Trash URL while it is still there.
    func putBack(_ trashed: [ReviewDecisionConsequences.Trashed]) -> PutBackReport {
        var report = PutBackReport()
        for item in trashed {
            guard !item.trashURL.isEmpty, files.fileExists(atPath: item.trashURL),
                  !files.fileExists(atPath: item.from) else {
                report.gone += 1
                continue
            }
            do {
                try files.moveBack(from: URL(fileURLWithPath: item.trashURL), to: URL(fileURLWithPath: item.from))
                report.restored += 1
            } catch {
                report.gone += 1
                AppLogger.shared.error("Review: couldn’t put “\(item.from)” back: \(error.localizedDescription)", source: "Review")
            }
        }
        return report
    }
}
