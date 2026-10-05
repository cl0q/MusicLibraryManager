import Foundation
import Observation

/// The state behind Info (P-INSPECTOR, DEC-007, UC-TRAIL-03/04): the selected tracks, loaded
/// **by id from the database** (never a stale row copy), and the fields being edited.
///
/// **Keyed to the selection (fixes PP-INSPECTOR-04).** An edit is a `Draft` that captures the
/// track ids and the selection `generation` it was typed for. Committing uses the draft's own
/// ids — there is no "current selection" in the commit path — so a value can never be saved
/// into tracks it wasn't typed for:
/// - a change of selection first commits every open draft to *its* tracks (an invalid one is
///   dropped), then shows the new selection;
/// - text arriving from a field of an earlier selection (a late write of a text field being
///   torn down) carries the old generation and is ignored;
/// - Info never follows the playing track: nothing here reads playback.
///
/// Return or leaving a field commits (`commit`); Esc reverts (`revert`); an invalid value keeps
/// the draft with the reason (`issues`); a save failure keeps it with `Try Again` (`retry`).
@MainActor
@Observable
final class InspectorModel {
    struct Dependencies {
        /// Tracks by id, in the order asked (missing ids left out).
        var loadTracks: @MainActor ([Int64]) async throws -> [Track]
        /// The undoable edit (`TrackTagEdit.perform`).
        var commit: @MainActor (_ value: TrackTagValue, _ field: TrackTagField, _ trackIDs: [Int64], _ singleTitle: String?) async throws -> Void
        /// A draft committed after the selection moved on failed: say so in the status bar.
        var reportFailure: @MainActor (String) -> Void

        @MainActor
        static func live(undo: UndoCenter?, statusBar: StatusBarCenter?, container: DependencyContainer = .shared) -> Dependencies {
            let edit = TrackTagEdit.live(undo: undo)
            return Dependencies(
                loadTracks: { ids in
                    guard let pool = container.databaseManager?.pool else { return [] }
                    return try await TrackTagRepository(database: pool).fetchTracks(ids: ids)
                },
                commit: { value, field, ids, title in
                    try await edit.perform(value, field: field, trackIDs: ids, singleTitle: title)
                },
                reportFailure: { statusBar?.post($0) }
            )
        }
    }

    /// An open edit of one field, bound to the tracks it was typed for.
    struct Draft: Equatable, Sendable {
        let field: TrackTagField
        let trackIDs: [Int64]
        let generation: Int
        /// The value the field showed when typing started (`""` for `Mixed`).
        let original: String
        var text: String
        /// The track's title for a one-track confirmation.
        let subjectTitle: String?
    }

    /// Said under a field (UC-SHEET-17).
    struct FieldIssue: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            /// The typed value isn't valid: the field stays open with the reason.
            case invalid
            /// The database refused: the field stays open, `Try Again`.
            case saveFailed
        }

        let kind: Kind
        let message: String
    }

    enum CommitResult: Equatable, Sendable {
        case nothingToCommit
        case unchanged
        case saved
        case invalid
        case failed
    }

    private(set) var trackIDs: [Int64] = []
    /// The loaded tracks of `trackIDs`, in selection order.
    private(set) var tracks: [Track] = []
    /// Bumped by every change of selection.
    private(set) var generation = 0
    /// A new selection is loading: fields are disabled, the previous content stays (no
    /// full-pane spinner, UC-EMPTY-04).
    private(set) var isLoadingSelection = false
    /// The selection couldn't be read: shown instead of the form, editing is off (S4).
    private(set) var loadError: String?
    /// The generation `tracks` were loaded for; drafts only capture tracks of the current one.
    private(set) var loadedGeneration = -1
    private(set) var drafts: [TrackTagField: Draft] = [:]
    private(set) var issues: [TrackTagField: FieldIssue] = [:]
    private(set) var saving: Set<TrackTagField> = []

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var work: [Task<Void, Never>] = []

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    // MARK: Selection

    /// Nothing selected (or every selected track is gone).
    var isEmpty: Bool { trackIDs.isEmpty || (!isLoadingSelection && tracks.isEmpty && loadError == nil) }

    /// Fields accept typing: the loaded tracks belong to the current selection.
    var canEdit: Bool { !isLoadingSelection && loadError == nil && loadedGeneration == generation && !tracks.isEmpty }
    var isMultiple: Bool { trackIDs.count > 1 }

    /// Fields the form offers: Title only for one track (P-INSPECTOR.N01: left out for many).
    var editableFields: [TrackTagField] {
        isMultiple ? TrackTagField.allCases.filter { $0 != .title } : TrackTagField.allCases
    }

    /// Show `ids` (display order). Open drafts are committed to the tracks they were typed
    /// for first — never across the change (UC-TRAIL-04).
    func select(_ ids: [Int64]) {
        let ids = TrackTagRepository.uniqued(ids)
        guard ids != trackIDs else { return }
        let open = Array(drafts.values)
        drafts = [:]
        issues = [:]
        for draft in open {
            enqueue { _ = await self.save(draft, current: false) }
        }
        trackIDs = ids
        generation += 1
        isLoadingSelection = !ids.isEmpty
        loadError = nil
        if ids.isEmpty { tracks = [] }
        load()
    }

    /// Another library opened: forget everything (the ids belong to the old library).
    func reset() {
        loadTask?.cancel()
        drafts = [:]
        issues = [:]
        trackIDs = []
        tracks = []
        loadError = nil
        generation += 1
        isLoadingSelection = false
    }

    /// Re-read the shown tracks (after an edit, or when something else changed them). Drafts
    /// stay.
    func reload() {
        load()
    }

    private func load() {
        let ids = trackIDs
        let generation = self.generation
        loadTask?.cancel()
        guard !ids.isEmpty else {
            isLoadingSelection = false
            return
        }
        loadTask = Task { [weak self] in
            guard let self else { return }
            let loaded: [Track]
            do {
                loaded = try await self.dependencies.loadTracks(ids)
            } catch {
                guard !Task.isCancelled, generation == self.generation else { return }
                // Never leave another selection's tracks on screen to type into (S4).
                AppLogger.shared.error("Info couldn’t read the selected tracks: \(error)", source: "Inspector")
                self.tracks = []
                self.loadError = "Couldn’t read the selected tracks — \(UndoFailure.cause(of: error))."
                self.isLoadingSelection = false
                return
            }
            guard !Task.isCancelled, generation == self.generation, ids == self.trackIDs else { return }
            self.tracks = loaded
            self.loadedGeneration = generation
            self.loadError = nil
            self.isLoadingSelection = false
        }
    }

    // MARK: Field values

    /// What the field shows: the draft, else the tracks' common value, else `""` (`Mixed`).
    func text(for field: TrackTagField) -> String {
        if let draft = drafts[field], draft.generation == generation { return draft.text }
        return commonText(field) ?? ""
    }

    /// The value all shown tracks share; nil when they differ.
    func commonText(_ field: TrackTagField) -> String? {
        let values = Set(tracks.map { field.text(of: $0) })
        return values.count <= 1 ? (values.first ?? "") : nil
    }

    func isMixed(_ field: TrackTagField) -> Bool {
        commonText(field) == nil
    }

    /// Prompt of an empty field: `Mixed`; Album artist shows the artist it falls back to.
    func placeholder(for field: TrackTagField) -> String {
        if isMixed(field) { return "Mixed" }
        if field == .albumArtist, let artist = commonText(.artist), !artist.isEmpty { return artist }
        return ""
    }

    /// Typed text for `field`, from a field rendered for `generation`. Text of an earlier
    /// selection is ignored.
    func setText(_ text: String, for field: TrackTagField, generation: Int) {
        guard generation == self.generation, canEdit, !trackIDs.isEmpty else { return }
        if var draft = drafts[field] {
            guard draft.text != text else { return }
            draft.text = text
            drafts[field] = draft
        } else {
            let original = self.text(for: field)
            guard text != original else { return }
            drafts[field] = Draft(
                field: field,
                // The selection's ids that were loaded for this generation — never more (S4).
                trackIDs: trackIDs.filter(Set(tracks.compactMap(\.id)).contains),
                generation: generation,
                original: original,
                text: text,
                subjectTitle: tracks.count == 1 ? tracks.first?.title : nil
            )
        }
        if issues[field]?.kind == .invalid { issues[field] = nil }
    }

    /// Esc: back to the stored value.
    func revert(_ field: TrackTagField) {
        drafts[field] = nil
        issues[field] = nil
    }

    // MARK: Committing

    /// Return / leaving the field: commit in the background.
    func commit(_ field: TrackTagField) {
        enqueue { _ = await self.commitNow(field) }
    }

    /// Commit and wait (tests, `Try Again`).
    @discardableResult
    func commitNow(_ field: TrackTagField) async -> CommitResult {
        guard let draft = drafts[field], draft.generation == generation else { return .nothingToCommit }
        return await save(draft, current: true)
    }

    /// `Try Again` under a field whose save failed.
    func retry(_ field: TrackTagField) {
        commit(field)
    }

    /// The column is closing: commit what is open.
    func commitAll() {
        for field in drafts.keys { commit(field) }
    }

    /// Save `draft` to **its own** tracks. `current`: the draft is still on screen (issues are
    /// shown under the field); otherwise the selection moved on (an invalid draft is dropped,
    /// a failure goes to the status bar).
    private func save(_ draft: Draft, current: Bool) async -> CommitResult {
        guard draft.text != draft.original else {
            if current, drafts[draft.field] == draft { drafts[draft.field] = nil; issues[draft.field] = nil }
            return .unchanged
        }
        let value: TrackTagValue
        switch draft.field.parse(draft.text) {
        case .failure(let error):
            if current {
                issues[draft.field] = FieldIssue(kind: .invalid, message: error.message)
            } else {
                // Dropped with the selection change: say so once.
                dependencies.reportFailure("\(draft.field.label) wasn’t changed — \(error.shortReason)")
            }
            return .invalid
        case .success(let parsed):
            value = parsed
        }
        if current { saving.insert(draft.field) }
        defer { if current { saving.remove(draft.field) } }
        do {
            try await dependencies.commit(value, draft.field, draft.trackIDs, draft.subjectTitle)
        } catch {
            if current, drafts[draft.field] == draft {
                issues[draft.field] = FieldIssue(kind: .saveFailed, message: "Couldn’t save this change — \(UndoFailure.cause(of: error)).")
            } else {
                dependencies.reportFailure(UndoFailure.sentence("Couldn’t save the \(draft.field.sentenceName) of \(Self.subject(draft))", error))
            }
            return .failed
        }
        // Typing may have continued while saving: only the saved text leaves.
        if drafts[draft.field] == draft {
            drafts[draft.field] = nil
            issues[draft.field] = nil
        }
        if draft.generation == generation { reload() }
        return .saved
    }

    private static func subject(_ draft: Draft) -> String {
        if draft.trackIDs.count == 1, let title = draft.subjectTitle { return "“\(title)”" }
        return StatusBarText.tracks(draft.trackIDs.count)
    }

    // MARK: Work

    private func enqueue(_ body: @escaping @MainActor () async -> Void) {
        let task = Task { await body() }
        work.append(task)
    }

    /// Waits for every commit and load started so far (tests).
    func waitUntilIdle() async {
        while !work.isEmpty {
            let pending = work
            work.removeAll()
            for task in pending { await task.value }
        }
        await loadTask?.value
    }
}
