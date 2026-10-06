import Foundation

// MARK: - File access (injectable: tests use a temporary folder and never touch /Volumes)

/// The few file operations Review's Trash mode needs.
protocol ReviewFileManaging: Sendable {
    func fileExists(atPath path: String) -> Bool
    /// Move to the Trash; returns where it went (`nil` when the system doesn't say).
    func trash(_ url: URL) throws -> URL?
    /// Move a file back from `source` to `destination` (creating the folder when needed).
    func moveBack(from source: URL, to destination: URL) throws
    /// An identity of the file itself (`fileResourceIdentifier`), equal for hard links and
    /// the same file reached by two paths; `nil` when the system doesn't give one.
    func fileIdentity(atPath path: String) -> String?
    func isSymbolicLink(atPath path: String) -> Bool
}

extension ReviewFileManaging {
    func fileIdentity(atPath path: String) -> String? { nil }
    func isSymbolicLink(atPath path: String) -> Bool { false }
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

    func fileIdentity(atPath path: String) -> String? {
        guard let identifier = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        else { return nil }
        return (identifier as? NSObject)?.description
    }

    func isSymbolicLink(atPath path: String) -> Bool {
        (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) ?? false
    }
}

// MARK: - Trash mode (V-REV.N03, IMP-052)

/// The file side of a Review decision in `Move to Trash` mode. It runs **after** the database
/// transaction committed — the database stays decided whatever happens to a file — off the main
/// actor, and each file is its own try: failures are counted, never thrown. A file is moved only
/// when it is safe: not the kept version's file, not a file another listed track uses, inside
/// the library folder and not a symbolic link.
struct ReviewConsequences: Sendable {
    var files: any ReviewFileManaging = SystemReviewFileManager()
    /// The library file lock: a file is locked while it moves to the Trash and while it comes back.
    var lock: LibraryFileLock = .shared

    /// One unkept version.
    struct TrashCandidate: Equatable, Sendable {
        var id: Int64
        /// The resolved file (`nil` = the track has no file path).
        var url: URL?
    }

    /// What a file must not be shared with, and where it must live.
    struct TrashGuards: Sendable {
        var keptURL: URL?
        var libraryRoot: URL?
        /// Files of other **listed** tracks (not hidden by Review).
        var otherListed: [URL] = []
    }

    enum SkipReason: String, Equatable, Sendable {
        case sharesFileWithKept
        case sharedWithListedTrack
        case outsideLibrary
        case symbolicLink

        /// `shares its file with the kept version`.
        var sentence: String {
            switch self {
            case .sharesFileWithKept: "shares its file with the kept version"
            case .sharedWithListedTrack: "shares its file with another track in the library"
            case .outsideLibrary: "is outside the library folder"
            case .symbolicLink: "is a symbolic link"
            }
        }
    }

    struct TrashReport: Equatable, Sendable {
        struct Skip: Equatable, Sendable {
            var id: Int64
            var reason: SkipReason
        }

        var trashed: [ReviewDecisionConsequences.Trashed] = []
        var failures = 0
        var skipped: [Skip] = []
        /// The file is already gone.
        var notFound = 0
        /// The version has no file path.
        var noFile = 0
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

    /// The `organized_path` spellings a file can be stored under (raw, absolute, relative to the
    /// library folder) — to find the listed tracks that use it.
    static func pathSpellings(of url: URL, rawPath: String?, libraryRoot: String?) -> Set<String> {
        var result = Set<String>()
        if let rawPath, !rawPath.isEmpty { result.insert(rawPath) }
        let absolute = url.standardizedFileURL.path
        result.insert(absolute)
        if let libraryRoot, !libraryRoot.isEmpty {
            let root = URL(fileURLWithPath: libraryRoot).standardizedFileURL.path
            if absolute.hasPrefix(root + "/") { result.insert(String(absolute.dropFirst(root.count + 1))) }
        }
        return result
    }

    /// Move the files of `candidates` to the Trash, safely. `record` runs right after each
    /// move, so a crash between two files never loses the Trash URL of the first.
    func trash(_ candidates: [TrashCandidate], guards: TrashGuards,
               record: @escaping @Sendable (ReviewDecisionConsequences.Trashed) async -> Void = { _ in }) async -> TrashReport {
        let work = self
        return await Task.detached(priority: .userInitiated) {
            await work.performTrash(candidates, guards: guards, record: record)
        }.value
    }

    private func performTrash(_ candidates: [TrashCandidate], guards: TrashGuards,
                              record: @Sendable (ReviewDecisionConsequences.Trashed) async -> Void) async -> TrashReport {
        var report = TrashReport()
        let rootPrefix = guards.libraryRoot.map { $0.standardizedFileURL.path + "/" }
        for candidate in candidates {
            guard let url = candidate.url else {
                report.noFile += 1
                continue
            }
            let path = url.standardizedFileURL.path
            guard files.fileExists(atPath: path) else {
                report.notFound += 1
                continue
            }
            if let keptURL = guards.keptURL, sameFile(path, keptURL.standardizedFileURL.path) {
                report.skipped.append(.init(id: candidate.id, reason: .sharesFileWithKept))
                continue
            }
            if guards.otherListed.contains(where: { sameFile(path, $0.standardizedFileURL.path) }) {
                report.skipped.append(.init(id: candidate.id, reason: .sharedWithListedTrack))
                continue
            }
            guard let rootPrefix, path.hasPrefix(rootPrefix) else {
                report.skipped.append(.init(id: candidate.id, reason: .outsideLibrary))
                continue
            }
            if files.isSymbolicLink(atPath: path) {
                report.skipped.append(.init(id: candidate.id, reason: .symbolicLink))
                continue
            }
            do {
                let resulting = try await LibraryFileLock.holding(url, in: lock) { try files.trash(url) }
                let item = ReviewDecisionConsequences.Trashed(trackId: candidate.id, from: path, trashURL: resulting?.path ?? "")
                report.trashed.append(item)
                await record(item)
            } catch {
                report.failures += 1
                AppLogger.shared.error("Review: couldn’t move “\(url.lastPathComponent)” to the Trash: \(error.localizedDescription)",
                                       source: "Review")
            }
        }
        return report
    }

    /// The same file: equal case-folded, NFC-normalised paths, or equal file identity.
    private func sameFile(_ a: String, _ b: String) -> Bool {
        if Self.normalised(a) == Self.normalised(b) { return true }
        if let idA = files.fileIdentity(atPath: a), let idB = files.fileIdentity(atPath: b) { return idA == idB }
        return false
    }

    private static func normalised(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Move each trashed file back from its resulting Trash URL while it is still there.
    func putBack(_ trashed: [ReviewDecisionConsequences.Trashed]) async -> PutBackReport {
        var report = PutBackReport()
        for item in trashed {
            guard !item.trashURL.isEmpty, files.fileExists(atPath: item.trashURL),
                  !files.fileExists(atPath: item.from) else {
                report.gone += 1
                continue
            }
            do {
                let original = URL(fileURLWithPath: item.from)
                try await LibraryFileLock.holding(original, in: lock) {
                    try files.moveBack(from: URL(fileURLWithPath: item.trashURL), to: original)
                }
                report.restored += 1
            } catch {
                report.gone += 1
                AppLogger.shared.error("Review: couldn’t put “\(item.from)” back: \(error.localizedDescription)", source: "Review")
            }
        }
        return report
    }
}
