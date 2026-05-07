import Foundation

// MARK: - Application Notifications

/// Centralized notification names for cross-view communication.
///
/// Uses `NotificationCenter.default` to decouple ViewModels from each other.
/// SwiftUI views observe via `.onReceive(NotificationCenter.default.publisher(for:))`.
extension Notification.Name {

    // MARK: Library Data

    /// Posted after a successful import operation (full scan or folder import).
    ///
    /// Observers should reload their track data from the database.
    /// Posted by `ImportViewModel` after `importLibrary()` or `importFromDirectory()` completes.
    ///
    /// - `userInfo["succeeded"]`: `Int` — number of tracks imported
    /// - `userInfo["skipped"]`: `Int` — number of tracks skipped (already in DB)
    static let libraryDidImport = Notification.Name("MLMLibraryDidImport")

    /// Posted when tracks are deleted from the library.
    ///
    /// Observers should reload their track data.
    /// - `userInfo["deletedIDs"]`: `[Int64]` — IDs of deleted tracks
    static let libraryDidDeleteTracks = Notification.Name("MLMLibraryDidDeleteTracks")

    /// Posted when the library root configuration changes.
    ///
    /// - `userInfo["path"]`: `String` — new library root path
    static let libraryRootDidChange = Notification.Name("MLMLibraryRootDidChange")

    // MARK: Playback (reserved for Phase 5)

    /// Posted when the currently playing track changes.
    static let playbackTrackDidChange = Notification.Name("MLMPlaybackTrackDidChange")

    /// Posted when playback state changes (play/pause/stop).
    static let playbackStateDidChange = Notification.Name("MLMPlaybackStateDidChange")

    // MARK: Playlists

    /// Posted when a playlist is created, deleted, renamed, pinned, or its tracks change.
    ///
    /// Observers should reload playlist data. Used to keep PlaylistsView,
    /// TrackContextMenu submenu, and SidebarView in sync.
    static let playlistDidChange = Notification.Name("MLMPlaylistDidChange")

    // MARK: Sync (reserved for Phase 12)

    /// Posted when a sync operation completes.
    static let syncDidComplete = Notification.Name("MLMSyncDidComplete")

    // MARK: Downloads (reserved for Phase 11)

    /// Posted when a download completes and a track moves from Remote to Local.
    static let downloadDidComplete = Notification.Name("MLMDownloadDidComplete")
}
