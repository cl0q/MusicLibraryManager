import Foundation

// MARK: - File probe

/// The two disk questions a reconciliation asks, injectable so tests can make a library
/// folder disappear in the middle of a run.
struct TrackFileProbe: Sendable {
    /// Is there a file at this absolute path?
    var fileExists: @Sendable (String) -> Bool
    /// Can the library folder be read right now? (`false` = drive away, stale mount point,
    /// folder gone — then nothing may be judged missing.)
    var isLibraryRootReachable: @Sendable (String) -> Bool
    /// Does the library folder contain anything? A reachable but empty folder that is
    /// expected to hold files is treated as suspicious, never as "everything is missing".
    var libraryRootHasEntries: @Sendable (String) -> Bool
    /// Is the volume at `/Volumes/<name>` mounted? (absolute paths outside the library folder)
    var isVolumeMounted: @Sendable (String) -> Bool

    static let live = TrackFileProbe(
        fileExists: { FileManager.default.fileExists(atPath: $0) },
        isLibraryRootReachable: { LibraryRootReachability.isReachable($0) },
        libraryRootHasEntries: { path in
            guard let enumerator = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
            return enumerator.contains { !$0.hasPrefix(".") }
        },
        isVolumeMounted: { MountObserver.isVolumeMounted($0) }
    )
}

/// Whether the library folder can be read now. A folder under `/Volumes/<name>` counts only
/// while that volume is really mounted — an empty leftover mount-point directory on the boot
/// disk is "not reachable", never a folder whose files are all gone.
enum LibraryRootReachability {
    static func isReachable(_ root: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        if let volume = MountObserver.extractVolumePath(from: root), !MountObserver.isVolumeMounted(volume) {
            return false
        }
        return FileManager.default.isReadableFile(atPath: root)
    }
}

// MARK: - Reconciler

/// Compares the stored files of local tracks with the disk and records the persisted
/// `file_missing_since` fact (v42) — the only place besides a use-time miss that decides
/// `File missing` (UC-TABLE-20, DEC-014).
///
/// Safety rules (the classic failure is "drive unplugged mid-run → 12,000 files missing"):
/// - The library folder is probed **before** the run and **after every batch**; if it is not
///   reachable the run stops and that batch's results are thrown away. Earlier batches were
///   checked while the folder was verifiably reachable, so they stay.
/// - A batch in which every file is absent while the library folder is empty aborts the run
///   (`abortedSuspicious`) — an empty folder is a mount problem, not 500 deleted files.
/// - Absolute paths outside the library folder on an unmounted volume are skipped (unknown).
/// - Writes are guarded by the path that was checked, so concurrent downloads/path repairs win.
///
/// Off the main actor (an `actor`), batched, cancellable through task cancellation.
actor TrackAvailabilityReconciler {
    enum Outcome: Equatable, Sendable {
        case completed
        /// The library folder was not reachable at the start: nothing was read or written.
        case skippedRootUnreachable
        /// The library folder went away during the run; the running batch was discarded.
        case abortedRootLost
        /// A whole batch was missing while the library folder was empty.
        case abortedSuspicious
        case cancelled
    }

    struct Report: Equatable, Sendable {
        var outcome: Outcome
        /// Files compared with the disk in batches that were kept.
        var checked = 0
        /// Rows newly flagged `File missing`.
        var flaggedMissing = 0
        /// Rows whose file came back.
        var cleared = 0
        /// Absolute paths on an unmounted volume outside the library folder.
        var skipped = 0

        var changedRows: Int { flaggedMissing + cleared }
    }

    static let defaultBatchSize = 400
    /// A fully absent batch of at least this many files with an empty library folder aborts.
    static let suspiciousBatchMinimum = 20

    private let repository: TrackRepository
    private let probe: TrackFileProbe
    private let batchSize: Int
    private let now: @Sendable () -> Date

    init(
        repository: TrackRepository,
        probe: TrackFileProbe = .live,
        batchSize: Int = TrackAvailabilityReconciler.defaultBatchSize,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.repository = repository
        self.probe = probe
        self.batchSize = max(1, batchSize)
        self.now = now
    }

    /// Run one reconciliation for `libraryRoot`.
    /// - Parameter progress: `(checked, total)` after each kept batch.
    func reconcile(
        libraryRoot: String,
        scope: TrackFileCheckScope = .all,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> Report {
        let root = Self.normalizedRoot(libraryRoot)
        guard !root.isEmpty, probe.isLibraryRootReachable(root) else {
            return Report(outcome: .skippedRootUnreachable)
        }
        let candidates: [TrackFileCheckCandidate]
        do {
            candidates = try await repository.fetchFileCheckCandidates(scope)
        } catch {
            AppLogger.shared.error("File check: couldn’t read the tracks: \(error.localizedDescription)", source: "Availability")
            return Report(outcome: .cancelled)
        }
        var report = Report(outcome: .completed)
        var start = candidates.startIndex
        while start < candidates.endIndex {
            if Task.isCancelled {
                report.outcome = .cancelled
                return report
            }
            let end = min(start + batchSize, candidates.endIndex)
            let batch = candidates[start..<end]
            start = end

            var missing: [TrackFileCheckCandidate] = []
            var present: [TrackFileCheckCandidate] = []
            var checkedInBatch = 0
            var absentInBatch = 0
            var skippedInBatch = 0
            for candidate in batch {
                switch check(candidate, root: root) {
                case .present:
                    checkedInBatch += 1
                    if candidate.isFlaggedMissing { present.append(candidate) }
                case .missing:
                    checkedInBatch += 1
                    absentInBatch += 1
                    if !candidate.isFlaggedMissing { missing.append(candidate) }
                case .unknown:
                    skippedInBatch += 1
                }
            }

            // The batch counts only if the library folder is still there now.
            guard probe.isLibraryRootReachable(root) else {
                AppLogger.shared.info("File check stopped: the library folder went away during the check.", source: "Availability")
                report.outcome = .abortedRootLost
                return report
            }
            let allAbsent = checkedInBatch > 0 && absentInBatch == checkedInBatch
            if allAbsent, checkedInBatch >= Self.suspiciousBatchMinimum, !probe.libraryRootHasEntries(root) {
                AppLogger.shared.info("File check stopped: every file of a batch was absent and the library folder is empty.", source: "Availability")
                report.outcome = .abortedSuspicious
                return report
            }
            if Task.isCancelled {
                report.outcome = .cancelled
                return report
            }
            do {
                let changes = try await repository.applyFileChecks(missing: missing, present: present, checkedAt: now())
                report.flaggedMissing += changes.flagged
                report.cleared += changes.cleared
            } catch {
                AppLogger.shared.error("File check: couldn’t save the results: \(error.localizedDescription)", source: "Availability")
                report.outcome = .cancelled
                return report
            }
            report.checked += checkedInBatch
            report.skipped += skippedInBatch
            progress?(report.checked + report.skipped, candidates.count)
        }
        return report
    }

    /// Whether the library folder can be read now (for a use-time miss).
    func isLibraryRootReachable(_ libraryRoot: String) -> Bool {
        let root = Self.normalizedRoot(libraryRoot)
        return !root.isEmpty && probe.isLibraryRootReachable(root)
    }

    // MARK: - One file

    enum FileState: Equatable, Sendable { case present, missing, unknown }

    /// Present if the stored file exists — or, for old rows with a stale organized path, the
    /// original import file still exists (playback falls back to it). Unknown for absolute
    /// paths on another volume that isn't mounted.
    nonisolated func check(_ candidate: TrackFileCheckCandidate, root: String) -> FileState {
        let path = Self.resolve(candidate.organizedPath, root: root)
        if !Self.isInside(path, root: root),
           let volume = MountObserver.extractVolumePath(from: path),
           !probe.isVolumeMounted(volume) {
            return .unknown
        }
        if probe.fileExists(path) { return .present }
        if let original = Self.filesystemPath(candidate.originalPath), probe.fileExists(original) {
            return .present
        }
        return .missing
    }

    static func resolve(_ organizedPath: String, root: String) -> String {
        if (organizedPath as NSString).isAbsolutePath { return organizedPath }
        return (root as NSString).appendingPathComponent(organizedPath)
    }

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// The original path when it is a real filesystem path (not a URL / source id).
    static func filesystemPath(_ originalPath: String) -> String? {
        guard originalPath.hasPrefix("/") || originalPath.hasPrefix("~") else { return nil }
        return (originalPath as NSString).expandingTildeInPath
    }

    static func normalizedRoot(_ root: String) -> String {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 1, trimmed.hasSuffix("/") else { return trimmed }
        return String(trimmed.dropLast())
    }
}
