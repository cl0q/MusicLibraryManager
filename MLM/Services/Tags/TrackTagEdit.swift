import Foundation

/// **The** undoable tag edit (DEC-041, UC-UNDO-02/07/08, THOUGHTS §10 Q7): sets one field on
/// exactly the given tracks in one transaction, registers one undo step (also for 500
/// tracks), confirms in the status bar with `Undo`, refreshes the track lists in place and
/// queues the file tag writes (written at once when the library folder is reachable, later
/// otherwise).
///
/// Other packages (selection-bar batch edit, Review merges, genre merge) use it the same way:
/// ```swift
/// let edit = TrackTagEdit.live(undo: undoCenter)
/// try await edit.perform(.text("Techno"), field: .genre, trackIDs: ids)
/// // Edit ▸ Undo Edit Genre · status bar `Changed genre of 14 tracks · Undo`
/// ```
/// Undo puts back each track's exact previous value in the database; its file gets back what
/// it was meant to carry before the step — a value the user typed, or the file's own value from
/// before MLM's first write (B1). A file never receives the database's import-normalised value.
/// Code that changed tags in its own transaction queues the file write with
/// `TrackTagRepository.queueTypedValue(_:field:trackIDs:)` (an explicit typed value).
@MainActor
final class TrackTagEdit {
    struct Dependencies {
        var repository: @MainActor () -> TrackTagRepository?
        /// `Write tags to files` (Settings ▸ Library).
        var writesEnabled: @MainActor () async -> Bool
        /// The library folder can be written now.
        var isLibraryFolderReachable: @MainActor () async -> Bool
        /// `Lexxar` for `‹n› tag changes waiting for “Lexxar”`; nil for a folder on this Mac.
        var volumeName: @MainActor () -> String?
        var queue: TagWriteQueue
        /// Track rows changed: lists refresh in place.
        var tracksDidChange: @MainActor ([Int64]) -> Void

        @MainActor
        static func live(_ container: DependencyContainer = .shared, queue: TagWriteQueue? = nil) -> Dependencies {
            Dependencies(
                repository: { container.databaseManager.map { TrackTagRepository(database: $0.pool) } },
                writesEnabled: { await TagWriteSetting.isEnabled(container.configRepository) },
                isLibraryFolderReachable: {
                    TagWriteQueue.isReachable((try? await container.configRepository?.getLibraryRoot()) ?? nil)
                },
                volumeName: { LibraryDriveState.current(container).volumeName },
                queue: queue ?? .shared,
                tracksDidChange: TrackTagEdit.postTracksChanged
            )
        }
    }

    /// One step's record: what undo needs (the previous values) plus the confirmation facts.
    struct Step: Sendable {
        let field: TrackTagField
        let snapshots: [TrackTagSnapshot]
        /// Tag changes waiting for the drive after this step (nil: written now or not queued).
        let waiting: Int?
        let unsupported: [String: Int]
    }

    private let dependencies: Dependencies
    private let undo: UndoCenter?

    init(dependencies: Dependencies, undo: UndoCenter?) {
        self.dependencies = dependencies
        self.undo = undo
    }

    static func live(undo: UndoCenter?) -> TrackTagEdit {
        TrackTagEdit(dependencies: .live(), undo: undo)
    }

    /// Set `field` to `value` on exactly `trackIDs` as one undo step.
    ///
    /// - Parameters:
    ///   - singleTitle: the track's title for a one-track confirmation
    ///     (`Changed genre of “Glass Circuit”`); nil uses the count.
    ///   - failure: `Couldn’t …` for the status bar when the database refuses; nil when the
    ///     caller shows the failure where the edit was typed (Info, UC-SHEET-17).
    ///   - wording: the action name and the confirmation's first part when the edit is a named
    ///     command (`Merge Genres` · `Merged 3 genres into “Techno” — 46 tracks changed`); nil =
    ///     `Edit ‹Field›` · `Changed ‹field› of …`. The waiting / unsupported suffixes are kept.
    /// - Returns: the step, or nil when no track changed (no step, no message).
    /// - Throws: the database error (the edit didn't happen).
    @discardableResult
    func perform(
        _ value: TrackTagValue,
        field: TrackTagField,
        trackIDs: [Int64],
        singleTitle: String? = nil,
        failure: String? = nil,
        wording: Wording? = nil
    ) async throws -> Step? {
        let ids = TrackTagRepository.uniqued(trackIDs)
        guard !ids.isEmpty, let repository = dependencies.repository() else { return nil }
        let deps = dependencies
        let apply: @MainActor () async throws -> Step? = {
            let queue = await deps.writesEnabled()
            let result = try await repository.apply(value, to: field, trackIDs: ids, queueFileWrites: queue)
            guard result.changedCount > 0 else { return nil }
            let waiting = await Self.afterChange(result, deps: deps)
            return Step(field: field, snapshots: result.previous, waiting: waiting, unsupported: result.unsupported)
        }
        guard let undo else {
            // No window (tests of other parts, previews): apply without a step.
            return try await apply()
        }
        return try await undo.perform(
            wording?.actionName ?? field.actionName,
            failure: failure,
            do: apply,
            undo: { step in try await Self.restore(step, repository: repository, deps: deps) },
            redo: { step in try await Self.restore(step, repository: repository, deps: deps) },
            message: { step in
                Self.message(step, count: step.snapshots.count, singleTitle: ids.count == 1 ? singleTitle : nil,
                             volume: deps.volumeName(), headline: wording?.headline(step.snapshots.count))
            }
        )
    }

    /// Set `field` to `value` on `trackIDs` as one **part** of the caller's `UndoCenter.performGroup`
    /// (W4-3: accepting an album suggestion sets album, album artist and year together with the
    /// album join in one step). Same write, same file queueing and same exact undo as `perform`;
    /// it registers no step and posts no message of its own — the group does.
    ///
    /// - Returns: the part's step (nil when no track changed); its `waiting` / `unsupported`
    ///   facts are for the group's confirmation.
    @discardableResult
    func perform(_ value: TrackTagValue, field: TrackTagField, trackIDs: [Int64], in group: UndoGroup) async throws -> Step? {
        let ids = TrackTagRepository.uniqued(trackIDs)
        guard !ids.isEmpty, let repository = dependencies.repository() else { return nil }
        let deps = dependencies
        return try await group.perform(
            do: { () async throws -> Step? in
                let queue = await deps.writesEnabled()
                let result = try await repository.apply(value, to: field, trackIDs: ids, queueFileWrites: queue)
                guard result.changedCount > 0 else { return nil }
                let waiting = await Self.afterChange(result, deps: deps)
                return Step(field: field, snapshots: result.previous, waiting: waiting, unsupported: result.unsupported)
            },
            undo: { (step: Step?) async throws -> Step? in
                guard let step else { return nil }
                return try await Self.restore(step, repository: repository, deps: deps)
            },
            redo: { (step: Step?) async throws -> Step? in
                guard let step else { return nil }
                return try await Self.restore(step, repository: repository, deps: deps)
            })
    }

    /// The words of a tag edit that is a named command (genre rename, merge, drop, staged save):
    /// Edit ▸ Undo ‹actionName› and the status-bar headline for the number of changed tracks.
    struct Wording {
        let actionName: String
        let headline: @MainActor (Int) -> String
    }

    /// Undo and redo: put the snapshot's values back; the result holds what they replaced.
    private static func restore(_ step: Step, repository: TrackTagRepository, deps: Dependencies) async throws -> Step {
        let queue = await deps.writesEnabled()
        let result = try await repository.restore(step.snapshots, field: step.field, queueFileWrites: queue)
        guard result.changedCount > 0 else {
            throw UndoNothingLeft(note: "Nothing to undo — the tracks are no longer in the library")
        }
        let waiting = await afterChange(result, deps: deps)
        return Step(field: step.field, snapshots: result.previous, waiting: waiting, unsupported: result.unsupported)
    }

    /// Lists refresh; file writes start now or wait for the folder.
    private static func afterChange(_ result: TrackTagChangeResult, deps: Dependencies) async -> Int? {
        deps.tracksDidChange(result.previous.map(\.trackID))
        guard result.queuedForFiles > 0 else { return nil }
        NotificationCenter.default.post(name: .pendingTagWritesDidChange, object: nil)
        if await deps.isLibraryFolderReachable() {
            deps.queue.requestFlush()
            return nil
        }
        await deps.queue.refreshCount()
        return max(deps.queue.pendingCount, result.queuedForFiles)
    }

    // MARK: Wording

    /// `Changed genre of 14 tracks` · `Changed genre of “Glass Circuit”`, plus
    /// `· 3 tag changes waiting for “Lexxar”` when the folder is away and
    /// `· Tags of 2 files couldn’t be written — WAV isn’t supported`.
    static func message(_ step: Step, count: Int, singleTitle: String?, volume: String?, headline: String? = nil) -> String {
        var text: String
        if let headline {
            text = headline
        } else {
            text = "Changed \(step.field.sentenceName) of "
            if let singleTitle, count == 1 {
                text += "“\(singleTitle)”"
            } else {
                text += StatusBarText.tracks(count)
            }
        }
        if let waiting = step.waiting, waiting > 0 {
            text += " · " + waitingText(waiting, volume: volume)
        }
        let skipped = step.unsupported.values.reduce(0, +)
        if skipped > 0 {
            let reasons = step.unsupported.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
            let files = skipped == 1 ? "1 file" : "\(skipped.formatted(.number)) files"
            text += " · Tags of \(files) couldn’t be written — \(reasons.joined(separator: ", "))"
        }
        return text
    }

    /// `3 tag changes waiting for “Lexxar”` (UC-JOB-10).
    static func waitingText(_ count: Int, volume: String?) -> String {
        let changes = count == 1 ? "1 tag change" : "\(count.formatted(.number)) tag changes"
        return "\(changes) waiting for \(volume.map { "“\($0)”" } ?? "the library folder")"
    }

    /// `.trackMetadataDidChange` with the changed ids: track lists refresh those rows in place.
    static func postTracksChanged(_ ids: [Int64]) {
        NotificationCenter.default.post(name: .trackMetadataDidChange, object: nil, userInfo: ["trackIds": ids])
    }
}
