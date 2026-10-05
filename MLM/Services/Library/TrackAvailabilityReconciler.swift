import Foundation

// MARK: - File probe

/// The disk questions a reconciliation asks, injectable so tests can make a library folder
/// disappear (or turn into a wrong one) in the middle of a run.
struct TrackFileProbe: Sendable {
    /// Is there a file at this absolute path?
    var fileExists: @Sendable (String) -> Bool
    /// Can the library folder be read right now? (`false` = drive away, stale mount point,
    /// folder gone — then nothing may be judged missing.)
    var isLibraryRootReachable: @Sendable (String) -> Bool
    /// Does the library folder contain anything? A reachable but empty folder that is
    /// expected to hold files is treated as suspicious, never as "everything is missing".
    var libraryRootHasEntries: @Sendable (String) -> Bool
    /// Is the volume at `/Volumes/<name>` mounted?
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
/// Safety rules (the classic failure is "drive unplugged mid-run → 12,000 files missing", and
/// its cousin "a wrong folder / another disk under the same name → everything missing"):
/// - **Nothing is written until the whole run is checked.** Results are collected; the one
///   write at the end happens only if every safety check still holds, so a stopped run
///   changes nothing.
/// - The library folder is probed **before** the run and **after every batch**; if it is not
///   reachable the run stops (`abortedRootLost`).
/// - **Share guard:** when more than `suspiciousMissingCount` files *and* more than
///   `suspiciousMissingShare` of the files checked are newly absent — in one batch or in the
///   run so far — the run stops (`abortedSuspicious`): that is a wrong folder or another disk,
///   not deleted files. Same for a fully absent batch in an empty folder.
/// - Before the write the newly missing files are stat-ed once more (a file that reappeared is
///   not flagged) and the folder and its volume are checked again.
/// - The file that decides — the stored one outside the library folder, or the original one
///   when the stored one is absent — on a volume that isn't mounted makes the row unknown,
///   never missing.
/// - Writes are guarded by the path that was checked, so concurrent downloads/path repairs win.
///
/// Off the main actor (an `actor`), batched, cancellable through task cancellation.
actor TrackAvailabilityReconciler {
    enum Outcome: Equatable, Sendable {
        case completed
        /// The library folder was not reachable at the start: nothing was read or written.
        case skippedRootUnreachable
        /// The library folder or its disk went away during the run: nothing was written.
        case abortedRootLost
        /// Too many files were absent to be true (wrong folder, another disk, empty mount
        /// point): nothing was written.
        case abortedSuspicious
        case cancelled
    }

    struct Report: Equatable, Sendable {
        var outcome: Outcome
        /// Files compared with the disk.
        var checked = 0
        /// Rows newly flagged `File missing` (written).
        var flaggedMissing = 0
        /// Rows whose file came back (written).
        var cleared = 0
        /// Rows whose deciding file is on an unmounted volume (unknown).
        var skipped = 0
        /// Newly absent files seen before a suspicious run stopped.
        var absentSeen = 0

        var changedRows: Int { flaggedMissing + cleared }
    }

    static let defaultBatchSize = 400
    /// A fully absent batch of at least this many files with an empty library folder aborts.
    static let suspiciousBatchMinimum = 20
    /// More than this many newly absent files …
    static let suspiciousMissingCount = 50
    /// … that are also more than this share of the files checked stop the run.
    static let suspiciousMissingShare = 0.2

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

    /// Whether `absent` newly missing files out of `checked` are too many to be believed.
    static func isSuspicious(absent: Int, checked: Int) -> Bool {
        guard checked > 0 else { return false }
        return absent > suspiciousMissingCount && Double(absent) / Double(checked) > suspiciousMissingShare
    }

    /// Run one reconciliation for `libraryRoot`.
    /// - Parameter progress: `(checked, total)` after each batch.
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
        var missing: [TrackFileCheckCandidate] = []
        var present: [TrackFileCheckCandidate] = []
        var start = candidates.startIndex
        while start < candidates.endIndex {
            if Task.isCancelled { return Self.stopped(report, .cancelled) }
            let end = min(start + batchSize, candidates.endIndex)
            let batch = candidates[start..<end]
            start = end

            var checkedInBatch = 0
            var absentInBatch = 0
            var newlyAbsentInBatch = 0
            for candidate in batch {
                switch check(candidate, root: root) {
                case .present:
                    checkedInBatch += 1
                    if candidate.isFlaggedMissing { present.append(candidate) }
                case .missing:
                    checkedInBatch += 1
                    absentInBatch += 1
                    if !candidate.isFlaggedMissing {
                        newlyAbsentInBatch += 1
                        missing.append(candidate)
                    }
                case .unknown:
                    report.skipped += 1
                }
            }
            report.checked += checkedInBatch

            // The batch counts only if the library folder is still there now.
            guard probe.isLibraryRootReachable(root) else {
                AppLogger.shared.info("File check stopped: the library folder went away during the check. Nothing was changed.", source: "Availability")
                return Self.stopped(report, .abortedRootLost)
            }
            let allAbsent = checkedInBatch > 0 && absentInBatch == checkedInBatch
            let emptyFolder = allAbsent && checkedInBatch >= Self.suspiciousBatchMinimum && !probe.libraryRootHasEntries(root)
            if emptyFolder
                || Self.isSuspicious(absent: newlyAbsentInBatch, checked: checkedInBatch)
                || Self.isSuspicious(absent: missing.count, checked: report.checked) {
                report.absentSeen = missing.count
                AppLogger.shared.info(
                    "File check stopped: \(missing.count) of \(report.checked) checked files weren’t found in \(root) — a wrong folder or another disk? Nothing was changed.",
                    source: "Availability"
                )
                return Self.stopped(report, .abortedSuspicious)
            }
            progress?(report.checked + report.skipped, candidates.count)
        }

        // Before writing: look once more at the files about to be flagged, and at the folder
        // and its disk.
        if Task.isCancelled { return Self.stopped(report, .cancelled) }
        let confirmedMissing = missing.filter { check($0, root: root) == .missing }
        let volumeMounted = MountObserver.extractVolumePath(from: root).map { probe.isVolumeMounted($0) } ?? true
        guard volumeMounted, probe.isLibraryRootReachable(root) else {
            return Self.stopped(report, .abortedRootLost)
        }
        do {
            let changes = try await repository.applyFileChecks(missing: confirmedMissing, present: present, checkedAt: now())
            report.flaggedMissing = changes.flagged
            report.cleared = changes.cleared
        } catch {
            AppLogger.shared.error("File check: couldn’t save the results: \(error.localizedDescription)", source: "Availability")
            return Self.stopped(report, .cancelled)
        }
        return report
    }

    private static func stopped(_ report: Report, _ outcome: Outcome) -> Report {
        var report = report
        report.outcome = outcome
        report.flaggedMissing = 0
        report.cleared = 0
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
    /// original import file still exists (playback falls back to it). Unknown when the file
    /// that decides lies on another volume that isn't mounted (S4): the stored file outside
    /// the library folder, or the original file once the stored one is absent.
    nonisolated func check(_ candidate: TrackFileCheckCandidate, root: String) -> FileState {
        let path = Self.resolve(candidate.organizedPath, root: root)
        if !Self.isInside(path, root: root), isOnUnmountedVolume(path) {
            return .unknown
        }
        if probe.fileExists(path) { return .present }
        if let original = Self.filesystemPath(candidate.originalPath) {
            if !Self.isInside(original, root: root), isOnUnmountedVolume(original) { return .unknown }
            if probe.fileExists(original) { return .present }
        }
        return .missing
    }

    private nonisolated func isOnUnmountedVolume(_ path: String) -> Bool {
        guard let volume = MountObserver.extractVolumePath(from: path) else { return false }
        return !probe.isVolumeMounted(volume)
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
