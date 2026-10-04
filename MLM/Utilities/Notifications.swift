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

    // MARK: Artwork

    /// Posted by `ArtworkBackfillService` after successful embedded-art extraction + DB save.
    ///
    /// Views (`TrackCoverView`, `LibraryTable`, etc.) observe and invalidate cache for the track.
    ///
    /// - `userInfo["trackId"]`: `Int64` — track whose artwork was updated
    /// - `userInfo["artworkPath"]`: `String` — absolute path to cached artwork file (1200px version)
    static let trackArtworkDidChange = Notification.Name("MLMTrackArtworkDidChange")

    // MARK: - Review Queue

    /// Posted when the duplicate review queue changes (deep scan completed, item resolved/dismissed).
    ///
    /// SidebarView observes this to refresh its pending-count badge on the Duplicates row.
    static let reviewQueueDidChange = Notification.Name("MLMReviewQueueDidChange")

    /// Opens Review, optionally expanding the pending group containing the
    /// supplied `trackId`. Used by Maintenance and the track inspector.
    static let showReview = Notification.Name("MLMShowReview")

    // MARK: - Sync

    /// Posted when a sync operation completes.
    static let syncDidComplete = Notification.Name("MLMSyncDidComplete")

    /// Posted when a sync profile is created, deleted, updated, or its content/settings change (Phase 38).
    ///
    /// SyncViewModel posts this after every mutation (addPlaylists, addTracks,
    /// removePlaylists, removeTracks, updateProfileSettings). Views (SyncView,
    /// SyncProfileDetailView, TrackContextMenu submenu, PlaylistCard submenu) observe
    /// and refresh their content. The VM does NOT observe this notification — only posts it.
    ///
    /// - `userInfo["profileId"]`: `Int64` — ID of the changed profile (optional; observers may reload all)
    static let syncProfileDidChange = Notification.Name("MLMSyncProfileDidChange")

    // MARK: Downloads

    /// Posted when a download completes and a track moves from Remote to Local.
    ///
    /// Fired once per batch by `DownloadViewModel.downloadTracks` after the
    /// database has been updated. Observers should refresh their track lists.
    /// - `userInfo["succeeded"]`: `Int` — number of tracks downloaded
    /// - `userInfo["failed"]`: `Int` — number of tracks that failed
    static let downloadDidComplete = Notification.Name("MLMDownloadDidComplete")

    /// Posted after an observer detects that a persisted playlist download
    /// aggregate changed. Unlike the completion tally, this also covers active
    /// downloading and queued states.
    static let downloadStateDidChange = Notification.Name("MLMDownloadStateDidChange")

    // MARK: UI Actions (Phase 19 — menu bar integration)

    /// Posted when the user presses ⌘F — views should focus their search field.
    static let focusSearchField = Notification.Name("MLMFocusSearchField")

    /// Posted when the user presses ⌘F globally from the menu bar.
    static let searchCommandTriggered = Notification.Name("MLMSearchCommandTriggered")

    /// Posted when the user presses ⌘F while in Folder view.
    static let focusFolderSearchField = Notification.Name("MLMFocusFolderSearchField")

    /// Posted when the user triggers "Import from Folder…" via the Library menu.
    static let showImportDialog = Notification.Name("MLMShowImportDialog")

    /// Posted when the user triggers "More Info" via the Library menu (⌘I).
    static let showTrackDetail = Notification.Name("MLMShowTrackDetail")

    /// Open the right-hand track detail inspector for one track.
    ///
    /// - `userInfo["trackId"]`: `Int64` — the track to show
    /// - `userInfo["play"]`: `Bool` — whether to start playback after opening (default `false`)
    static let openTrackDetailForTrack = Notification.Name("MLMOpenTrackDetailForTrack")

    /// Posted when the user picks "Settings…" (⌘,) from the app menu.
    /// ContentView listens and presents the Settings sheet.
    static let openSettings = Notification.Name("MLMOpenSettings")

    // MARK: - Sync UI (Phase 38)

    /// Posted when the user creates a profile from the sync-profile submenu.
    /// in TrackContextMenu or PlaylistCard.contextMenu.
    /// ContentView or SyncView observes this to navigate to the create-profile sheet.
    static let navigateToCreateSyncProfile = Notification.Name("MLMNavigateToCreateSyncProfile")

    /// Posted when the user opens the safe organized-path migration from the Library menu.
    static let triggerLibraryRepair = Notification.Name("MLMTriggerLibraryRepair")

    // MARK: - Selection Actions

    /// Posted when the user triggers "New Playlist..." with a track selection.
    static let triggerNewPlaylistFromSelection = Notification.Name("MLMTriggerNewPlaylistFromSelection")

    /// Posted when the user creates a profile with a track selection.
    static let triggerNewSyncProfileFromSelection = Notification.Name("MLMTriggerNewSyncProfileFromSelection")
    
    // MARK: - Qobuz / Squid Token Status
    
    /// Posted when the Qobuz squid.wtf captcha cookie status changes.
    static let qobuzCookieStatusDidChange = Notification.Name("MLMQobuzCookieStatusDidChange")
}
