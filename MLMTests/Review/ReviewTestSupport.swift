import Foundation
import GRDB
import Testing
@testable import MLM

/// An in-memory stand-in for the file system and the Trash: never touches a real disk.
final class FakeReviewFiles: ReviewFileManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var existing: Set<String>
    /// Paths whose move to the Trash fails.
    var failing: Set<String> = []
    /// Paths that are symbolic links.
    var symlinks: Set<String> = []
    /// Path → file identity (two paths with the same value are the same file).
    var identities: [String: String] = [:]
    private(set) var trashed: [String] = []

    init(existing: [String]) { self.existing = Set(existing) }

    func fileExists(atPath path: String) -> Bool { lock.withLock { existing.contains(path) } }

    func fileIdentity(atPath path: String) -> String? { lock.withLock { identities[path] } }

    func isSymbolicLink(atPath path: String) -> Bool { lock.withLock { symlinks.contains(path) } }

    func trash(_ url: URL) throws -> URL? {
        try lock.withLock {
            if failing.contains(url.path) { throw CocoaError(.fileWriteNoPermission) }
            existing.remove(url.path)
            let target = "/Trash/" + url.lastPathComponent
            existing.insert(target)
            trashed.append(url.path)
            return URL(fileURLWithPath: target)
        }
    }

    func moveBack(from source: URL, to destination: URL) throws {
        lock.withLock {
            existing.remove(source.path)
            existing.insert(destination.path)
        }
    }

    /// The user emptied the Trash.
    func removeFromTrash(_ name: String) { lock.withLock { _ = existing.remove("/Trash/" + name) } }
}

struct NullTagWriter: TagWriting {
    func write(_ request: TagWriteRequest, captureOriginals: @escaping TagOriginalsCapture) async -> TagWriteOutcome { .written }
}

/// A Review model over a temporary database, an undo center on its own manager and a fake Trash.
@MainActor
struct ReviewEnv {
    let db: DatabaseQueue
    let model: ReviewModel
    let decisions: ReviewDecisionRepository
    let undo: UndoCenter
    let manager: UndoManager
    let status: StatusBarCenter
    let files: FakeReviewFiles
    let center: ActivityCenter
    let runner: ReviewScanRunner
    let config: ConfigRepository
    let changes: Changes

    final class Changes: @unchecked Sendable {
        var playlists = 0
        var files = 0
    }

    static let root = "/lib"

    static func make(existingFiles: [String] = []) throws -> ReviewEnv {
        let db = try DatabaseManager.inMemory()
        let decisions = ReviewDecisionRepository(database: db)
        let repository = TrackTagRepository(database: db)
        let config = ConfigRepository(database: db)
        let files = FakeReviewFiles(existing: existingFiles)
        let changes = Changes()
        let queue = TagWriteQueue(dependencies: .init(
            repository: { repository }, libraryRoot: { root }, isEnabled: { false },
            writer: NullTagWriter(), statusBar: { nil }))
        let edit = TrackTagEdit(dependencies: .init(
            repository: { repository }, writesEnabled: { false }, isLibraryFolderReachable: { true },
            volumeName: { nil }, queue: queue, tracksDidChange: { _ in }), undo: nil)
        let manager = UndoManager()
        manager.groupsByEvent = false
        let sleeper = ManualSleeper()
        let status = StatusBarCenter(sleep: { await sleeper.sleep($0) }, announce: { _ in })
        let undo = UndoCenter(undoManager: manager, statusBar: status, log: { _ in })
        let center = ActivityCenter(scheduler: ManualActivityScheduler(), progressInterval: 0)
        let runner = ReviewScanRunner(center: center, config: { config }, scan: { nil }, didChange: {})
        let dependencies = ReviewModel.Dependencies(
            analysis: AnalysisRepository(database: db), decisions: decisions,
            libraryRoot: { root }, tagEdit: { edit }, consequences: ReviewConsequences(files: files),
            postChange: { playlists, files in
                if playlists { changes.playlists += 1 }
                if files { changes.files += 1 }
            })
        let model = ReviewModel(dependencies: dependencies, scan: runner, center: center)
        return ReviewEnv(db: db, model: model, decisions: decisions, undo: undo, manager: manager, status: status,
                         files: files, center: center, runner: runner, config: config, changes: changes)
    }

    /// Insert `count` versions of one recording and a pending group for them.
    @discardableResult
    func addGroup(title: String, artist: String = "Overmono", versions: [(format: String, bitrate: Int)],
                  conflict: Bool = false, albums: [String]? = nil, status: String = "pending") async throws -> (ids: [Int64], key: String) {
        let ids: [Int64] = try await db.write { db in
            var ids: [Int64] = []
            for (index, version) in versions.enumerated() {
                var track = Track(artist: artist, album: albums?[index] ?? "Good Lies", title: title,
                                  format: version.format, originalPath: "/orig/\(title)-\(index).\(version.format)")
                track.bitrate = version.bitrate
                track.organizedPath = "\(artist)/\(title)-\(index).\(version.format)"
                track.duration = 200
                try track.insert(db)
                ids.append(track.id!)
            }
            return ids
        }
        let key = DuplicateReviewGrouping.groupKey(for: ids)
        let details = ReviewDetails(
            groupKey: key, evidence: ReviewEvidence(fingerprintSimilarity: 0.97),
            recommendation: ReviewRecommendation(action: .keepTrack, trackId: ids[0], reasons: ["lossless format"]),
            tracks: ids.map { ReviewTrackSnapshot(id: $0, title: title, artist: artist) })
        let json = try details.encodedJSON()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO review_queue (action_type, group_key, track_id, related_track_id, details, status)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [conflict ? "metadata_conflict" : "fingerprint_dedup", key, ids[0], ids[1], json, status])
        }
        return (ids, key)
    }

    func fileURL(for id: Int64) async throws -> String? {
        let path = try await decisions.tracks(ids: [id]).first?.organizedPath
        return path.map { Self.root + "/" + $0 }
    }
}
