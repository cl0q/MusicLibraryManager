import AppKit
import SwiftUI

/// The track commands every list shares, implemented once for the Track menu (and, for
/// Remove from Library…, the track context menu). Each acts on the tracks it is given — the
/// focused selection in display order — through the existing services.
@MainActor
enum TrackCommandActions {
    /// Play Next ⌥↩: the tracks with a file go to the top of Next — one undo step, confirmed
    /// `Playing next: … · Undo` on every route (Track menu, context menu, selection bar, drops
    /// on the player; W2-D). `undo`: the window's center (`UndoCenter.main` when nil).
    static func playNext(_ tracks: [Track], undo: UndoCenter? = nil, container: DependencyContainer = .shared) {
        guard let playback = container.playbackViewModel else { return }
        QueueEditCommands.queue(tracks, as: .playNext, playback: playback, undo: undo ?? .main)
    }

    /// Add to Queue ⌥⇧↩: after the last Play Next item, before the rest of the list that plays
    /// — one undo step, confirmed `Added to queue: … · Undo` (W2-D).
    static func addToQueue(_ tracks: [Track], undo: UndoCenter? = nil, container: DependencyContainer = .shared) {
        guard let playback = container.playbackViewModel else { return }
        QueueEditCommands.queue(tracks, as: .addToQueue, playback: playback, undo: undo ?? .main)
    }

    /// Download / Retry Download: hands the tracks without a file to the download pipeline,
    /// which reports in Activity.
    /// Returns the batch's ticket: its `cancel()` cancels exactly this batch (W3-ACT S1).
    @discardableResult
    static func download(_ tracks: [Track], container: DependencyContainer = .shared) -> DownloadTicket? {
        let missing = tracks.filter(\.isRemote)
        guard !missing.isEmpty, let downloads = container.downloadViewModel else { return nil }
        let ticket = DownloadTicket()
        Task { await downloads.downloadTracks(missing, ticket: ticket) }
        return ticket
    }

    /// Show in Finder: selects every selected file that can be found.
    static func showInFinder(_ tracks: [Track], container: DependencyContainer = .shared) {
        let local = tracks.filter(\.isLocal)
        guard !local.isEmpty else { return }
        Task {
            var urls: [URL] = []
            for track in local {
                if let url = await TrackFileLocator.localURL(for: track, container: container) { urls.append(url) }
            }
            if !urls.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(urls) }
        }
    }

    /// Copy ▸ Title — Artist: one `Title — Artist` line per track (UC-CM-13).
    static func copyTitleAndArtist(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        put(titleArtistLines(tracks))
    }

    static func titleArtistLines(_ tracks: [Track]) -> String {
        tracks.map { "\($0.title) — \($0.artist)" }.joined(separator: "\n")
    }

    /// Copy ▸ File Path: the plain path of every file that can be found, one per line.
    static func copyFilePaths(_ tracks: [Track], container: DependencyContainer = .shared) {
        let local = tracks.filter(\.isLocal)
        guard !local.isEmpty else { return }
        Task {
            var paths: [String] = []
            for track in local {
                if let url = await TrackFileLocator.localURL(for: track, container: container) { paths.append(url.path) }
            }
            if !paths.isEmpty { put(paths.joined(separator: "\n")) }
        }
    }

    /// Add to Playlist ▸ ‹playlist›: appends the tracks in display order as one undoable step
    /// (`Added 3 tracks to “Warm-up” · Undo`; Edit ▸ Undo Add to “Warm-up”). `shell` is the
    /// main window's `ShellActions` (`@FocusedValue(\.shellActions)`).
    static func addToPlaylist(_ playlistID: Int64, tracks: [Track], shell: ShellActions?) {
        shell?.addToPlaylist(playlistID, trackIDs: tracks.compactMap(\.id))
    }

    /// New Playlist from Selection ⇧⌘N / Add to Playlist ▸ New Playlist…: creates `Untitled
    /// Playlist` with the tracks in display order and names it inline in the sidebar — one
    /// undoable step, no sheet (S-SEL-NEWPLAYLIST).
    static func newPlaylistFromSelection(_ tracks: [Track], shell: ShellActions?) {
        shell?.newPlaylistFromSelection(trackIDs: tracks.compactMap(\.id))
    }

    /// Add to Sync Profile ▸ ‹profile› (CM-SUB-SYNC, UC-CM-12): one undo step, `Added ‹n› tracks
    /// to “‹profile›” · Undo`, nothing navigates and no profile page switches (W3-SYNC).
    static func addToSyncProfile(_ profile: SyncProfile, tracks: [Track], shell: ShellActions?) {
        guard let id = profile.id else { return }
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }
        if let shell {
            Task { await shell.edits.addTracks(ids, toSyncProfile: id, name: profile.name) }
        } else {
            Task { await DependencyContainer.shared.syncViewModel?.addTracks(ids, to: profile) }
        }
    }

    /// Add to Sync Profile ▸ New Sync Profile…: the existing sheet with the selection.
    static func newSyncProfileFromSelection(_ tracks: [Track]) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: .triggerNewSyncProfileFromSelection, object: nil, userInfo: ["trackIds": ids])
    }

    /// Remove from Library…: confirmed, files to the Trash (`TrackLibraryRemoval`).
    static func removeFromLibrary(_ tracks: [Track], container: DependencyContainer = .shared) {
        TrackLibraryRemoval.request(tracks, container: container)
    }

    private static func put(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

// MARK: - Files

/// Resolves a track to its file: library folder + organized path, falling back to the original
/// path when it is a real filesystem path. Only for an explicit file action — never per row.
enum TrackFileLocator {
    @MainActor
    static func localURL(for track: Track, container: DependencyContainer) async -> URL? {
        let root = (try? await container.configRepository?.getLibraryRoot()) ?? nil
        if let root, let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }
}

// MARK: - Remove from Library

/// The confirmation of Remove from Library… (A-TRACK-REMOVE, UC-SHEET-12…15): always asked —
/// removing from the library can't be undone in MLM, with or without files — and worded for
/// what actually happens. Pure, so the policy is unit-tested.
struct LibraryRemovalConfirmation: Equatable, Sendable {
    /// The question with the count.
    let title: String
    /// The consequence: what moves to the Trash, that the tracks leave their playlists and
    /// sync profiles, how to get files back.
    let message: String
    /// The destructive button: `Move to Trash` when files go there, else `Remove from Library`.
    let confirmTitle: String

    /// - Parameters:
    ///   - trackCount: tracks to remove.
    ///   - fileCount: how many of them have a file in the library folder.
    static func make(trackCount: Int, fileCount: Int) -> LibraryRemovalConfirmation {
        let one = trackCount == 1
        let title = "Remove \(StatusBarText.count(trackCount, "track", "tracks")) from the library?"
        let leaves = one
            ? "it is removed from its playlists and sync profiles"
            : "they are removed from their playlists and sync profiles"
        let message: String
        if fileCount == 0 {
            message = one
                ? "It has no file, so nothing moves to the Trash, and \(leaves)."
                : "They have no files, so nothing moves to the Trash, and \(leaves)."
            return LibraryRemovalConfirmation(title: title, message: message, confirmTitle: "Remove from Library")
        }
        if fileCount == trackCount {
            message = one
                ? "Its file moves to the Trash and \(leaves). You can put the file back from the Trash."
                : "Their files move to the Trash and \(leaves). You can put the files back from the Trash."
        } else {
            let files = fileCount == 1 ? "The file of 1 track moves" : "The files of \(fileCount.formatted(.number)) tracks move"
            message = "\(files) to the Trash, and all \(trackCount.formatted(.number)) are removed from their playlists and sync profiles. You can put the files back from the Trash."
        }
        return LibraryRemovalConfirmation(title: title, message: message, confirmTitle: "Move to Trash")
    }
}

/// The pending Remove from Library… question, shown by the main window's alert
/// (`LibraryRemovalAlert`). Both routes — Track ▸ Remove from Library… ⌘⌫ and the track context
/// menu — ask here, the same way.
@MainActor
@Observable
final class LibraryRemovalCenter {
    static let shared = LibraryRemovalCenter()

    struct Request: Identifiable {
        let id = UUID()
        let tracks: [Track]
        let confirmation: LibraryRemovalConfirmation
        /// Runs after the tracks left the library, with their ids (an album page removes the
        /// albums that were emptied, W4-2).
        var afterRemoval: (@MainActor ([Int64]) async -> Void)?
    }

    private(set) var pending: Request?

    /// - Parameters:
    ///   - confirmation: the question in the caller's words (an album's, A-ALB-REMOVE); the
    ///     track wording when nil.
    ///   - afterRemoval: runs once the rows are gone.
    func ask(_ tracks: [Track], confirmation: LibraryRemovalConfirmation? = nil,
             afterRemoval: (@MainActor ([Int64]) async -> Void)? = nil) {
        let removable = tracks.filter { $0.id != nil }
        guard !removable.isEmpty else { return }
        pending = Request(
            tracks: removable,
            confirmation: confirmation ?? .make(trackCount: removable.count, fileCount: removable.filter(\.isLocal).count),
            afterRemoval: afterRemoval
        )
        MainWindowPresenter.shared.show()
    }

    func confirm(container: DependencyContainer = .shared) {
        guard let request = pending else { return }
        pending = nil
        TrackLibraryRemoval.remove(request.tracks, ids: request.tracks.compactMap(\.id), container: container,
                                   afterRemoval: request.afterRemoval)
    }

    func cancel() {
        pending = nil
    }
}

/// The Remove from Library… alert on the main window: Cancel is the default button (Return,
/// DEC-052) and Esc; the destructive button is clicked or ⌘⌫ (UC-KEY-34).
struct LibraryRemovalAlert: ViewModifier {
    private var center: LibraryRemovalCenter { .shared }

    func body(content: Content) -> some View {
        content.alert(
            center.pending?.confirmation.title ?? "",
            isPresented: Binding(get: { center.pending != nil }, set: { if !$0 { center.cancel() } }),
            presenting: center.pending
        ) { request in
            Button(request.confirmation.confirmTitle, role: .destructive) {
                center.confirm()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            Button("Cancel", role: .cancel) {
                center.cancel()
            }
            .keyboardShortcut(.defaultAction)
        } message: { request in
            Text(request.confirmation.message)
        }
    }
}

/// Remove from Library… (moved out of `TrackContextMenu` so the Track menu and the context menu
/// share it): always confirmed (`LibraryRemovalConfirmation`), then trashes the files and deletes
/// the rows; a row whose file couldn't be trashed stays.
@MainActor
enum TrackLibraryRemoval {
    static func request(_ tracks: [Track], container: DependencyContainer) {
        guard tracks.contains(where: { $0.id != nil }) else { return }
        // Next run-loop tick, so a context menu has finished closing before the alert.
        DispatchQueue.main.async {
            LibraryRemovalCenter.shared.ask(tracks)
        }
    }

    /// Move one library file to the Trash while holding its `LibraryFileLock` (W5-F1), so a tag
    /// write or cover embed on the same file finishes first. Returns the Trash location.
    static func trashLocked(_ url: URL, lock: LibraryFileLock = .shared,
                            trash: @Sendable (URL) throws -> URL? = TrackLibraryRemoval.systemTrash) async throws -> URL? {
        try await LibraryFileLock.holding(url, in: lock) { try trash(url) }
    }

    nonisolated static let systemTrash: @Sendable (URL) throws -> URL? = { url in
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    static func remove(_ snapshot: [Track], ids: [Int64], container: DependencyContainer,
                       afterRemoval: (@MainActor ([Int64]) async -> Void)? = nil) {
        guard let trackRepo = container.trackRepository else { return }
        Task {
            var removableIDs = Set(snapshot.filter(\.isRemote).compactMap(\.id))
            var failures: [TrackRemovalFailure.Item] = []
            var trashedItems: [(original: URL, trash: URL?)] = []

            // A local row is removable only after its file reached the Trash; keep the Trash
            // URL until the database change succeeds so a failed change stays recoverable.
            for track in snapshot where track.isLocal {
                guard let id = track.id else { continue }
                guard let url = await TrackFileLocator.localURL(for: track, container: container) else {
                    failures.append(.init(id: id, label: "\(track.artist) — \(track.title)",
                                          cause: TrackRemovalFailure.notFoundCause))
                    continue
                }
                do {
                    let trashed = try await trashLocked(url)
                    removableIDs.insert(id)
                    trashedItems.append((url, trashed))
                } catch {
                    failures.append(.init(id: id, label: "\(track.artist) — \(track.title)", cause: error.localizedDescription))
                }
            }

            let deletableIDs = ids.filter { removableIDs.contains($0) }
            do {
                if !deletableIDs.isEmpty {
                    try await trackRepo.delete(ids: deletableIDs)
                }
                AppLogger.shared.log("Removed \(deletableIDs.count) track(s) from library", level: .info, source: "Library")
                if !deletableIDs.isEmpty {
                    await afterRemoval?(deletableIDs)
                    NotificationCenter.default.post(name: .libraryDidDeleteTracks, object: nil, userInfo: ["removedIds": deletableIDs])
                }
                if !failures.isEmpty {
                    TrackRemovalFailureCenter.shared.present(
                        .partial(failures: failures, total: ids.count, removed: deletableIDs.count))
                }
            } catch {
                let recovery = trashedItems.map { item in
                    "\(item.original.lastPathComponent) (Trash: \(item.trash?.path ?? "unknown location"))"
                }.joined(separator: "\n")
                AppLogger.shared.log(
                    "Failed to remove tracks after trashing files: \(error). Recovery: \(recovery)",
                    level: .error,
                    source: "Library"
                )
                TrackRemovalFailureCenter.shared.present(.libraryNotUpdated(ids: ids, details: recovery.isEmpty ? error.localizedDescription : recovery))
            }
        }
    }
}

// MARK: - A removal that did not finish (A-TRACK-REMOVE-FAILED, UC-SHEET-16)

/// What a Remove from Library… could not finish: files that could not be moved to the Trash (those
/// tracks stay), or the library database not updating after the files were trashed.
struct TrackRemovalFailure: Identifiable, Equatable {
    struct Item: Equatable {
        let id: Int64
        let label: String
        let cause: String
    }

    static let notFoundCause = "the file couldn’t be found"

    let id = UUID()
    /// The tracks that are still in the library.
    let failedIDs: [Int64]
    let total: Int
    let removed: Int
    /// The plain cause(s); nil when the database failed.
    let cause: String?
    /// The per-track system text (written to Activity ▸ Logs; an alert has no disclosure).
    let details: String

    static func partial(failures: [Item], total: Int, removed: Int) -> TrackRemovalFailure {
        var causes: [String] = []
        for item in failures where !causes.contains(item.cause) { causes.append(item.cause) }
        return TrackRemovalFailure(failedIDs: failures.map(\.id), total: total, removed: removed,
                                   cause: causes.joined(separator: "; "),
                                   details: failures.map { "\($0.label): \($0.cause)" }.joined(separator: "\n"))
    }

    /// Every file is in the Trash, but the rows stayed: nothing was removed from the library.
    static func libraryNotUpdated(ids: [Int64], details: String) -> TrackRemovalFailure {
        TrackRemovalFailure(failedIDs: ids, total: ids.count, removed: 0, cause: nil, details: details)
    }

    /// `3 of 14 tracks couldn’t be removed`
    var title: String { "\(failedIDs.count.formatted(.number)) of \(StatusBarText.tracks(total)) couldn’t be removed" }

    var message: String {
        guard let cause else { return "The library couldn’t be updated. The files are in the Trash and can be put back." }
        var text = "Their files couldn’t be moved to the Trash: \(cause)."
        if removed == 1 {
            text += " The other track was removed."
        } else if removed > 1 {
            text += " The other \(removed.formatted(.number)) tracks were removed."
        }
        return text
    }

    /// `Show the 3 Tracks`
    var showTitle: String {
        failedIDs.count == 1 ? "Show the Track" : "Show the \(failedIDs.count.formatted(.number)) Tracks"
    }
}

/// The pending partial-removal alert, shown by the main window (`TrackRemovalFailureAlert`).
@MainActor
@Observable
final class TrackRemovalFailureCenter {
    static let shared = TrackRemovalFailureCenter()

    private(set) var pending: TrackRemovalFailure?

    func present(_ failure: TrackRemovalFailure, showsWindow: Bool = true) {
        AppLogger.shared.log("\(failure.title). \(failure.details)", level: .error, source: "Library")
        pending = failure
        if showsWindow { MainWindowPresenter.shared.show() }
    }

    func dismiss() { pending = nil }

    /// `Show the ‹n› Tracks`: select them in All Tracks.
    func showTracks(navigation: NavigationModel, container: DependencyContainer = .shared) {
        guard let failure = pending else { return }
        pending = nil
        navigation.select(.allTracks)
        guard let library = container.libraryViewModel else { return }
        library.scope = .all
        library.selectedTrackIDs = Set(failure.failedIDs)
    }
}

struct TrackRemovalFailureAlert: ViewModifier {
    @Environment(NavigationModel.self) private var navigation
    private var center: TrackRemovalFailureCenter { .shared }

    func body(content: Content) -> some View {
        content.alert(
            center.pending?.title ?? "",
            isPresented: Binding(get: { center.pending != nil }, set: { if !$0 { center.dismiss() } }),
            presenting: center.pending
        ) { failure in
            Button(failure.showTitle) { center.showTracks(navigation: navigation) }
            Button("OK", role: .cancel) { center.dismiss() }
        } message: { failure in
            Text(failure.message)
        }
    }
}
