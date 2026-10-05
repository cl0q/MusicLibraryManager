import AppKit
import SwiftUI

/// The track commands every list shares, implemented once for the Track menu (and, for
/// Remove from Library…, the track context menu). Each acts on the tracks it is given — the
/// focused selection in display order — through the existing services.
@MainActor
enum TrackCommandActions {
    /// Play Next: the playable tracks go right after the current one (existing queue lane).
    static func playNext(_ tracks: [Track], container: DependencyContainer = .shared) {
        let playable = tracks.filter(\.isLocal)
        guard !playable.isEmpty, let playback = container.playbackViewModel else { return }
        playback.insertPlayNext(playable)
    }

    /// Download / Retry Download: hands the tracks without a file to the download pipeline,
    /// which reports in Activity.
    static func download(_ tracks: [Track], container: DependencyContainer = .shared) {
        let missing = tracks.filter(\.isRemote)
        guard !missing.isEmpty, let downloads = container.downloadViewModel else { return }
        Task { await downloads.downloadTracks(missing) }
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

    /// Add to Playlist ▸ ‹playlist›: appends the tracks (existing repository call).
    static func addToPlaylist(_ playlistID: Int64, tracks: [Track], container: DependencyContainer = .shared) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty, let repository = container.playlistRepository else { return }
        Task {
            do {
                try await repository.appendTracks(playlistId: playlistID, trackIds: ids)
                NotificationCenter.default.post(name: .playlistDidChange, object: nil, userInfo: ["playlistId": playlistID])
            } catch {
                AppLogger.shared.error("Adding tracks to a playlist failed: \(error.localizedDescription)", source: "Library")
            }
        }
    }

    /// New Playlist from Selection / Add to Playlist ▸ New Playlist…: the existing sheet.
    static func newPlaylistFromSelection(_ tracks: [Track]) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }
        NotificationCenter.default.post(name: .triggerNewPlaylistFromSelection, object: nil, userInfo: ["trackIds": ids])
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

/// Remove from Library… (moved out of `TrackContextMenu` so the Track menu and the context menu
/// share it; behaviour unchanged, its copy is W2-A's): asks when local files would go to the
/// Trash, trashes them, then deletes the rows; a row whose file couldn't be trashed stays.
@MainActor
enum TrackLibraryRemoval {
    static func request(_ tracks: [Track], container: DependencyContainer) {
        let ids = tracks.compactMap(\.id)
        guard !ids.isEmpty else { return }
        if tracks.contains(where: \.isLocal) {
            // Next run-loop tick, so a context menu has finished closing before the alert.
            DispatchQueue.main.async {
                if confirm(count: tracks.count) {
                    remove(tracks, ids: ids, container: container)
                }
            }
        } else {
            remove(tracks, ids: ids, container: container)
        }
    }

    private static func confirm(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count > 1
            ? "Remove \(count) tracks from Library?"
            : "Remove track from Library?"
        alert.informativeText = "This moves local files to the Trash. You can restore them from there. Remote links are removed from the Library."
        alert.alertStyle = .warning
        let trash = alert.addButton(withTitle: "Move to Trash")
        trash.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func remove(_ snapshot: [Track], ids: [Int64], container: DependencyContainer) {
        guard let trackRepo = container.trackRepository else { return }
        Task {
            var removableIDs = Set(snapshot.filter(\.isRemote).compactMap(\.id))
            var failures: [String] = []
            var trashedItems: [(original: URL, trash: URL?)] = []

            // A local row is removable only after its file reached the Trash; keep the Trash
            // URL until the database change succeeds so a failed change stays recoverable.
            for track in snapshot where track.isLocal {
                guard let id = track.id else { continue }
                guard let url = await TrackFileLocator.localURL(for: track, container: container) else {
                    failures.append("\(track.artist) — \(track.title): file could not be located")
                    continue
                }
                do {
                    var trashed: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
                    removableIDs.insert(id)
                    trashedItems.append((url, trashed as URL?))
                } catch {
                    failures.append("\(track.artist) — \(track.title): \(error.localizedDescription)")
                }
            }

            let deletableIDs = ids.filter { removableIDs.contains($0) }
            do {
                if !deletableIDs.isEmpty {
                    try await trackRepo.delete(ids: deletableIDs)
                }
                AppLogger.shared.log("Removed \(deletableIDs.count) track(s) from library", level: .info, source: "Library")
                if !deletableIDs.isEmpty {
                    NotificationCenter.default.post(name: .libraryDidDeleteTracks, object: nil, userInfo: ["removedIds": deletableIDs])
                }
                if !failures.isEmpty {
                    presentFailure(
                        "Some tracks were kept in the Library because they could not be moved to Trash.",
                        details: failures.joined(separator: "\n")
                    )
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
                presentFailure(
                    "The Library database could not be updated. The moved files remain in Trash and can be restored.",
                    details: recovery.isEmpty ? error.localizedDescription : recovery
                )
            }
        }
    }

    private static func presentFailure(_ message: String, details: String) {
        let alert = NSAlert()
        alert.messageText = "Could Not Remove All Tracks"
        alert.informativeText = "\(message)\n\n\(details)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
