import Foundation
import Observation

/// The tabs of Review. `Albums` belongs to Wave 4: it exists in the scope bar as a hidden item
/// (count `nil`, `hidesWhenEmpty`), so it never shows now and needs no change of the bar later
/// (IMP-050).
enum ReviewTab: String, CaseIterable, Identifiable, Sendable {
    case duplicates, conflicts, albums, resolved

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duplicates: "Duplicates"
        case .conflicts: "Conflicts"
        case .albums: "Albums"
        case .resolved: "Resolved"
        }
    }
}

/// One line of Review ▸ Resolved.
struct ReviewResolvedRow: Identifiable, Equatable {
    let key: String
    let kind: ReviewGroupItem.Kind
    let title: String
    let artist: String
    let date: Date?
    let outcome: String
    /// Restore needs the decision's recorded consequences; earlier decisions have none.
    let decisionID: Int64?
    let memberIDs: [Int64]

    var id: String { key }
    var canRestore: Bool { decisionID != nil }
    var groupName: String { "“\(title)”" }
}

/// What deciding a group does, before anything is written.
struct ReviewGroupPlan: Sendable {
    struct TagApplication: Sendable {
        var field: TrackTagField
        var value: TrackTagValue
        var trackIDs: [Int64]
    }

    var request: ReviewDecisionRequest
    var tagApplications: [TagApplication] = []
    var title: String
    var versionCount: Int
}

/// Review's state and decisions (V-REV, DEC-021/028/041/044): the groups of every tab from the
/// repository, the session choice for unkept versions, the picked version per group, the
/// in-place filter, the scan's echo — and every decision as **one** `UndoCenter` step with its
/// exact consequences (`ReviewDecisionRepository`, `ReviewConsequences`).
@MainActor
@Observable
final class ReviewModel {
    struct Dependencies {
        var analysis: AnalysisRepository
        var decisions: ReviewDecisionRepository
        var libraryRoot: @MainActor () async -> String?
        var tagEdit: @MainActor () -> TrackTagEdit
        var consequences: ReviewConsequences
        var postChange: @MainActor (_ playlistsChanged: Bool, _ filesChanged: Bool) -> Void

        @MainActor
        static func live(_ container: DependencyContainer = .shared) -> Dependencies? {
            guard let manager = container.databaseManager, let analysis = container.analysisRepository else { return nil }
            return Dependencies(
                analysis: analysis,
                decisions: ReviewDecisionRepository(database: manager.pool),
                libraryRoot: { (try? await container.configRepository?.getLibraryRoot()) ?? nil },
                tagEdit: { TrackTagEdit.live(undo: nil) },
                consequences: ReviewConsequences(),
                postChange: { playlists, files in
                    let center = NotificationCenter.default
                    center.post(name: .reviewQueueDidChange, object: nil)
                    // The lists reload: hidden versions leave All Tracks, restored ones come back.
                    center.post(name: .libraryDidImport, object: nil)
                    if playlists { center.post(name: .playlistDidChange, object: nil) }
                    // A file check finds what moved to / came back from the Trash.
                    if files { center.post(name: .libraryFilesDidChange, object: nil) }
                }
            )
        }
    }

    // MARK: State

    private(set) var duplicates: [ReviewGroupItem] = []
    private(set) var conflicts: [ReviewGroupItem] = []
    private(set) var resolved: [ReviewResolvedRow] = []
    private(set) var isLoaded = false
    private(set) var loadError: String?
    /// The in-place filter of this view (`SearchCoordinator.filter(for: .review)`).
    var filter: SearchFilter = .empty
    /// Picked version per group key (a missing entry = the recommended one).
    private(set) var picks: [String: Int64] = [:]
    /// Conflict choices: group key → field → the version whose value is kept.
    private(set) var choices: [String: [ConflictField: Int64]] = [:]
    /// The library's disk (Trash needs it).
    var drive = LibraryDriveState(volumeName: nil, isConnected: true) {
        didSet { if unkeptMode == .trash, trashRefusal != nil { unkeptMode = .hidden } }
    }

    /// `Unkept versions:` — chosen once per session, resets at launch (a new model), never
    /// stored (V-REV.N03).
    private(set) var unkeptMode: UnkeptMode = .hidden

    let dependencies: Dependencies
    let scan: ReviewScanRunner
    @ObservationIgnored private let center: ActivityCenter

    init(dependencies: Dependencies, scan: ReviewScanRunner? = nil, center: ActivityCenter? = nil) {
        self.dependencies = dependencies
        self.scan = scan ?? .shared
        self.center = center ?? .shared
    }

    // MARK: Counts and visible lists

    var duplicateCount: Int { duplicates.count }
    var conflictCount: Int { conflicts.count }
    var resolvedCount: Int { resolved.count }
    /// What the sidebar badge adds up (UC-SIDE-05): groups waiting + conflicts.
    var waitingCount: Int { duplicates.count + conflicts.count }
    var isNothingToReview: Bool { isLoaded && duplicates.isEmpty && conflicts.isEmpty }

    func count(for tab: ReviewTab) -> Int? {
        guard isLoaded else { return nil }
        switch tab {
        case .duplicates: return duplicateCount
        case .conflicts: return conflictCount
        case .resolved: return resolvedCount
        case .albums: return nil
        }
    }

    var visibleDuplicates: [ReviewGroupItem] { duplicates.filter(matches) }
    var visibleConflicts: [ReviewGroupItem] { conflicts.filter(matches) }
    var visibleResolved: [ReviewResolvedRow] {
        resolved.filter { filter.matchesName("\($0.title) \($0.artist)") }
    }

    private func matches(_ group: ReviewGroupItem) -> Bool {
        filter.matchesName("\(group.title) \(group.artist)")
    }

    /// Something is typed or chosen in the filter.
    var isFiltering: Bool { !filter.isEmpty }

    func group(withKey key: String) -> ReviewGroupItem? {
        (duplicates + conflicts).first { $0.key == key }
    }

    /// The pending group a track belongs to (`Show in Review` from Info).
    func group(containing trackID: Int64) -> ReviewGroupItem? {
        (duplicates + conflicts).first { $0.memberIDs.contains(trackID) }
    }

    // MARK: Header

    /// The running scan's words and numbers — Activity's (`Comparing 48,210 of 131,400`).
    var scanEcho: ActivityEcho? {
        guard let echo = center.echo(for: .review), echo.state.isActive else { return nil }
        return echo
    }

    var lastScan: ReviewLastScan? { scan.lastScan }
    var scanFailure: ReviewScanFailure? { scan.failure }

    // MARK: Unkept versions (V-REV.N03)

    /// Why `Move to Trash` can't be chosen now: `“Lexxar” is not connected`.
    var trashRefusal: String? {
        guard drive.isOffline, let name = drive.volumeName else { return nil }
        return "“\(name)” is not connected"
    }

    /// Choose what happens to unkept versions. Trash is refused while the drive is away and
    /// the mode stays (or falls back to) `Stay in library, hidden from lists`.
    func setUnkeptMode(_ mode: UnkeptMode) {
        if mode == .trash, trashRefusal != nil {
            unkeptMode = .hidden
            return
        }
        unkeptMode = mode
    }

    // MARK: Picks and choices

    func pick(for group: ReviewGroupItem) -> Int64 {
        if let picked = picks[group.key], group.memberIDs.contains(picked) { return picked }
        return group.recommendedID
    }

    func setPick(_ trackID: Int64, in group: ReviewGroupItem) {
        guard group.memberIDs.contains(trackID) else { return }
        picks[group.key] = trackID
    }

    /// `Keep Selected` is only for a pick that differs from the recommendation.
    func canKeepSelected(_ group: ReviewGroupItem) -> Bool {
        pick(for: group) != group.recommendedID
    }

    func choice(for field: ConflictField, in group: ReviewGroupItem) -> Int64 {
        if let chosen = choices[group.key]?[field], group.memberIDs.contains(chosen) { return chosen }
        return group.recommendedID
    }

    func setChoice(_ trackID: Int64, for field: ConflictField, in group: ReviewGroupItem) {
        choices[group.key, default: [:]][field] = trackID
    }

    /// `Use All from A`.
    func useAll(from trackID: Int64, in group: ReviewGroupItem) {
        var all: [ConflictField: Int64] = [:]
        for field in ConflictField.differing(in: group.members) { all[field] = trackID }
        choices[group.key] = all
    }

    /// The fields that differ between the versions.
    func differingFields(_ group: ReviewGroupItem) -> [ConflictField] {
        ConflictField.differing(in: group.members)
    }

    /// `After merge`: field and the value the choice gives.
    func mergedValues(_ group: ReviewGroupItem) -> [(field: ConflictField, text: String)] {
        differingFields(group).map { field in
            let source = group.members.first { $0.id == choice(for: field, in: group) } ?? group.members[0]
            return (field, field.text(of: source))
        }
    }

    // MARK: Loading

    func reload() async {
        do {
            let pending = ReviewGroup.groups(from: try await dependencies.analysis.fetchPendingReviews())
            let resolvedGroups = ReviewGroup.groups(from: try await dependencies.analysis.fetchResolvedReviews())
            let decisions = try await dependencies.decisions.decisions()
            let ids = Array(Set(pending.flatMap(\.memberTrackIDs)))
            let tracks = try await dependencies.decisions.tracks(ids: ids)
            let byID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in track.id.map { ($0, track) } })
            let usage = try await dependencies.decisions.playlistUsage(trackIDs: ids)
            var newDuplicates: [ReviewGroupItem] = []
            var newConflicts: [ReviewGroupItem] = []
            for group in pending {
                // A group whose versions left the library has nothing left to compare.
                let members = group.memberTrackIDs.compactMap { byID[$0] }
                guard members.count > 1, let item = Self.item(for: group, members: members, usage: usage) else { continue }
                if item.kind == .conflict { newConflicts.append(item) } else { newDuplicates.append(item) }
            }
            duplicates = newDuplicates
            conflicts = newConflicts
            resolved = resolvedGroups.map { Self.resolvedRow($0, decision: decisions[$0.key]) }
            let liveKeys = Set((duplicates + conflicts).map(\.key))
            picks = picks.filter { liveKeys.contains($0.key) }
            choices = choices.filter { liveKeys.contains($0.key) }
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoaded = true
    }

    static func item(for group: ReviewGroup, members: [Track], usage: [Int64: Int]) -> ReviewGroupItem? {
        let recommendation = group.details?.recommendation
        let best = DuplicateReviewRecommendation.recommendedTrack(in: members)
        let recommendedTrack = recommendation?.trackId.flatMap { id in members.first { $0.id == id } } ?? best
        guard let recommendedID = recommendedTrack?.id ?? members.first?.id else { return nil }
        let others = members.filter { $0.id != recommendedID }
        let similarity = group.details?.evidence?.fingerprintSimilarity ?? group.details?.similarityScore
        return ReviewGroupItem(
            key: group.key,
            kind: group.isMetadataConflict ? .conflict : .duplicate,
            members: members,
            recommendedID: recommendedID,
            recommendsKeepAll: recommendation?.action == .keepBoth,
            why: ReviewPresentation.why(reasons: recommendation?.reasons ?? [], recommended: recommendedTrack, others: others),
            matchPercent: similarity.map { Int(($0 * 100).rounded()) },
            usedIn: usage)
    }

    static func resolvedRow(_ group: ReviewGroup, decision: ReviewDecisionRecord?) -> ReviewResolvedRow {
        let snapshot = group.details?.tracks.first ?? group.details?.trackA
        let item = group.primaryItem
        return ReviewResolvedRow(
            key: group.key,
            kind: group.isMetadataConflict ? .conflict : .duplicate,
            title: snapshot?.title ?? "Unknown title",
            artist: snapshot?.artist ?? "",
            date: decision.flatMap { Self.parse($0.decidedAt) } ?? item.resolvedAt.flatMap(Self.parse),
            outcome: ReviewPresentation.outcome(decision),
            decisionID: decision?.id,
            memberIDs: group.memberTrackIDs)
    }

    /// `2026-10-03T17:02:00Z` or SQLite's `2026-10-03 17:02:00` (UTC).
    static func parse(_ stamp: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: stamp) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: stamp)
    }

    // MARK: Plans

    /// `Keep Recommended`: the recommended version, or — when the scan says the versions are
    /// probably different — all of them.
    func plan(keepRecommendedIn group: ReviewGroupItem) -> ReviewGroupPlan {
        if group.recommendsKeepAll { return plan(keepAllIn: group) }
        return plan(keep: group.recommendedID, in: group, action: .keepRecommended)
    }

    func plan(keepSelectedIn group: ReviewGroupItem) -> ReviewGroupPlan {
        plan(keep: pick(for: group), in: group, action: .keepSelected)
    }

    func plan(keep trackID: Int64, in group: ReviewGroupItem, action: ReviewDecisionAction) -> ReviewGroupPlan {
        ReviewGroupPlan(
            request: ReviewDecisionRequest(groupKey: group.key, kind: .duplicate, action: action,
                                           memberIDs: group.memberIDs, keptTrackID: trackID, unkeptMode: effectiveMode),
            title: group.title, versionCount: group.members.count)
    }

    func plan(keepAllIn group: ReviewGroupItem) -> ReviewGroupPlan {
        ReviewGroupPlan(
            request: ReviewDecisionRequest(groupKey: group.key, kind: group.kind == .conflict ? .conflict : .duplicate,
                                           action: group.kind == .conflict ? .keepBoth : .keepAll,
                                           memberIDs: group.memberIDs),
            title: group.title, versionCount: group.members.count)
    }

    /// `Apply Merge`: every differing field gets the chosen value on every version.
    func plan(mergeIn group: ReviewGroupItem) -> ReviewGroupPlan {
        var applications: [ReviewGroupPlan.TagApplication] = []
        var oldValues: [ReviewDecisionConsequences.TagChange] = []
        var changed: [String] = []
        for (field, text) in mergedValues(group) {
            let value = field.value(from: text)
            let needing = group.members.filter { field.text(of: $0) != text }
            guard !needing.isEmpty else { continue }
            changed.append(field.label)
            applications.append(.init(field: field.tagField, value: value, trackIDs: needing.compactMap(\.id)))
            for track in needing {
                guard let id = track.id else { continue }
                oldValues.append(.init(trackId: id, field: field.tagField.rawValue, old: TrackTagValue.stored(field.tagField, of: track)))
            }
        }
        var request = ReviewDecisionRequest(groupKey: group.key, kind: .conflict, action: .merge,
                                            memberIDs: group.memberIDs)
        request.tags = oldValues
        request.changedFields = changed
        return ReviewGroupPlan(request: request, tagApplications: applications, title: group.title,
                               versionCount: group.members.count)
    }

    /// The mode a decision uses: Trash only while the drive is connected.
    var effectiveMode: UnkeptMode { unkeptMode == .trash && trashRefusal != nil ? .hidden : unkeptMode }

    // MARK: Applying

    struct Applied: Sendable {
        var outcomes: [ReviewDecisionOutcome]
        var trashFailures: Int { outcomes.reduce(0) { $0 + $1.consequences.trashFailures } }
        var hidden: Int { outcomes.reduce(0) { $0 + $1.hiddenCount } }
        var playlistEntries: Int { outcomes.reduce(0) { $0 + $1.consequences.repointedPlaylistEntries } }
    }

    /// Decide `plans` as one undo step. Returns whether anything was decided.
    @discardableResult
    func apply(_ plans: [ReviewGroupPlan], actionName: String, undo: UndoCenter?, statusBar: StatusBarCenter? = nil) async -> Bool {
        guard !plans.isEmpty else { return false }
        let mode = plans.first?.request.unkeptMode ?? .hidden
        let message: @MainActor (Applied) -> String = { applied in
            Self.message(for: plans, applied: applied, mode: mode)
        }
        guard let undo else {
            let applied = Applied(outcomes: (try? await execute(plans)) ?? [])
            if let bar = statusBar, !applied.outcomes.isEmpty { bar.post(message(applied)) }
            await reload()
            return !applied.outcomes.isEmpty
        }
        let done: Applied?
        do {
            done = try await undo.perform(
                actionName, failure: "Couldn’t save the decision",
                do: { [self] in
                    let outcomes = try await execute(plans)
                    return outcomes.isEmpty ? nil : Applied(outcomes: outcomes)
                },
                undo: { [self] applied in try await revert(applied.outcomes, statusBar: undo.statusBar) },
                redo: { [self] _ in Applied(outcomes: try await execute(plans)) },
                message: message)
        } catch {
            await reload()
            return false
        }
        if let done, done.trashFailures > 0, let current = undo.statusBar.message {
            // `Couldn’t move ‹n› files to the Trash` is in the message; the log has the reasons.
            undo.statusBar.replaceActions(of: current.id, with: current.actions + [StatusAction("Show Logs") {
                ActivityRouter.shared.showLogs(for: nil)
            }])
        }
        await reload()
        return done != nil
    }

    static func message(for plans: [ReviewGroupPlan], applied: Applied, mode: UnkeptMode) -> String {
        if plans.count > 1 {
            return ReviewPresentation.bulkMessage(groups: applied.outcomes.count, hidden: applied.hidden, mode: mode,
                                                  playlistEntries: applied.playlistEntries, trashFailures: applied.trashFailures)
        }
        guard let plan = plans.first, let outcome = applied.outcomes.first else { return "" }
        switch plan.request.action {
        case .keepRecommended, .keepSelected:
            return ReviewPresentation.keptMessage(
                format: outcome.keptFormat, title: plan.title, hidden: outcome.hiddenCount, mode: mode,
                playlistEntries: outcome.consequences.repointedPlaylistEntries, trashFailures: outcome.consequences.trashFailures)
        case .keepAll:
            return ReviewPresentation.keptAllMessage(count: plan.versionCount, title: plan.title)
        case .merge:
            return ReviewPresentation.mergedMessage(title: plan.title, files: Set(plan.tagApplications.flatMap(\.trackIDs)).count)
        case .keepBoth:
            return ReviewPresentation.differentVersionsMessage(title: plan.title)
        }
    }

    /// The writes of a step: tags, then the decision (one transaction), then — after the commit —
    /// the files.
    private func execute(_ plans: [ReviewGroupPlan]) async throws -> [ReviewDecisionOutcome] {
        var outcomes: [ReviewDecisionOutcome] = []
        for plan in plans {
            for application in plan.tagApplications {
                try await dependencies.tagEdit().perform(application.value, field: application.field, trackIDs: application.trackIDs)
            }
            do {
                outcomes.append(try await dependencies.decisions.decide(plan.request))
            } catch ReviewDecisionError.nothingPending {
                continue  // decided meanwhile (another window, Restore): nothing to do for this group
            }
        }
        if plans.contains(where: { $0.request.unkeptMode == .trash }) {
            outcomes = try await moveToTrash(outcomes)
        }
        let playlists = outcomes.contains { !$0.consequences.playlistRows.isEmpty || !$0.consequences.syncRows.isEmpty }
        let files = outcomes.contains { !$0.consequences.trashed.isEmpty }
        dependencies.postChange(playlists, files)
        return outcomes
    }

    /// Trash mode, after the commit: per file, failures counted (the database stays decided).
    private func moveToTrash(_ outcomes: [ReviewDecisionOutcome]) async throws -> [ReviewDecisionOutcome] {
        let root = await dependencies.libraryRoot()
        let ids = outcomes.flatMap(\.unkeptTrackIDs)
        let tracks = try await dependencies.decisions.tracks(ids: ids)
        let byID = Dictionary(uniqueKeysWithValues: tracks.compactMap { track in track.id.map { ($0, track) } })
        var result = outcomes
        for index in result.indices {
            let targets = result[index].unkeptTrackIDs.map { id in
                (id: id, url: ReviewConsequences.fileURL(organizedPath: byID[id]?.organizedPath, libraryRoot: root))
            }
            let report = dependencies.consequences.trash(targets)
            try await dependencies.decisions.recordTrashed(decisionID: result[index].decisionID, trashed: report.trashed,
                                                           failures: report.failures)
            result[index].consequences.trashed = report.trashed
            result[index].consequences.trashFailures = report.failures
        }
        return result
    }

    /// Undo: everything back — rows and flags, tag values, files still in the Trash.
    private func revert(_ outcomes: [ReviewDecisionOutcome], statusBar: StatusBarCenter) async throws -> Applied {
        var gone = 0
        var undone = 0
        for outcome in outcomes.reversed() {
            let record: ReviewDecisionRecord
            do {
                record = try await dependencies.decisions.undo(decisionID: outcome.decisionID)
            } catch ReviewDecisionError.noDecision {
                continue  // restored from Resolved meanwhile
            }
            undone += 1
            try await restoreTags(record.consequences.tags)
            gone += dependencies.consequences.putBack(record.consequences.trashed).gone
        }
        guard undone > 0 else { throw UndoNothingLeft(note: "Nothing to undo — the decision was already restored") }
        let playlists = outcomes.contains { !$0.consequences.playlistRows.isEmpty || !$0.consequences.syncRows.isEmpty }
        dependencies.postChange(playlists, outcomes.contains { !$0.consequences.trashed.isEmpty })
        if gone > 0 { statusBar.post(ReviewPresentation.cantUndoTrash(gone)) }
        await reload()
        return Applied(outcomes: outcomes)
    }

    /// Put earlier tag values back through the same edit (the tag-writing setting decides about
    /// files).
    private func restoreTags(_ changes: [ReviewDecisionConsequences.TagChange]) async throws {
        var grouped: [String: (field: TrackTagField, value: TrackTagValue, ids: [Int64])] = [:]
        for change in changes {
            guard let field = TrackTagField(rawValue: change.field) else { continue }
            let key = "\(change.field)|\(change.old)"
            grouped[key, default: (field, change.old, [])].ids.append(change.trackId)
        }
        for entry in grouped.values {
            try await dependencies.tagEdit().perform(entry.value, field: entry.field, trackIDs: entry.ids)
        }
    }

    // MARK: Restore (Resolved)

    /// `Restore`: the same inverse as Undo for one group, outside the undo stack.
    @discardableResult
    func restore(_ row: ReviewResolvedRow, statusBar: StatusBarCenter?) async -> Bool {
        guard let decisionID = row.decisionID else { return false }
        do {
            let record = try await dependencies.decisions.undo(decisionID: decisionID)
            try await restoreTags(record.consequences.tags)
            let report = dependencies.consequences.putBack(record.consequences.trashed)
            let playlists = !record.consequences.playlistRows.isEmpty || !record.consequences.syncRows.isEmpty
            dependencies.postChange(playlists, !record.consequences.trashed.isEmpty)
            statusBar?.post(report.gone > 0
                ? ReviewPresentation.restoredMessage(title: row.title) + " · " + ReviewPresentation.cantUndoTrash(report.gone)
                : ReviewPresentation.restoredMessage(title: row.title))
            await reload()
            return true
        } catch {
            statusBar?.post("Couldn’t restore “\(row.title)”")
            await reload()
            return false
        }
    }
}
