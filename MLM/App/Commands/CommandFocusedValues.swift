import SwiftUI

// MARK: - Focused values the menu bar reads (besides the W1-1 ones in NavigationModel.swift)

extension FocusedValues {
    /// The main window's toolbar search field (Edit ▸ Find ▸ Search ⌘F / Search Library ⌥⌘F).
    /// Scene-scoped, so ⌘F reaches it only while the main window is key (UC-KEY-25).
    @Entry var toolbarSearch: ToolbarSearchModel?
    /// The main window's sidebar contents (Go ▸ Playlists).
    @Entry var sidebarModel: SidebarModel?
    /// A linked playlist that can be refreshed from its source, published by the playlist page
    /// on screen (Track ▸ Refresh from ‹Source› ⌘R).
    @Entry var playlistSourceRefresh: PlaylistSourceRefresh?
    /// The playlist page on screen (W3-PL): Playback ▸ Play / Shuffle “‹playlist›”, Track ▸
    /// Download ‹n› Tracks with nothing selected (UC-KEY-14), Export ▸ Playlist as M3U….
    @Entry var playlistPage: PlaylistPageCommands?
    /// The playlists selected in All Playlists (Export ▸ Playlist as M3U… with one selected).
    @Entry var selectedPlaylists: [Playlist]?
}

/// What the playlist page on screen offers the menu bar.
struct PlaylistPageCommands {
    let playlist: Playlist
    /// Not-downloaded tracks (`Download ‹n› Tracks`).
    let notDownloaded: Int
    /// Something can play now (a local track, the disk connected).
    let canPlay: Bool
    let play: @MainActor () -> Void
    let shuffle: @MainActor () -> Void
    let downloadAll: @MainActor () -> Void
}

/// `Refresh from ‹Source›` of the playlist page on screen.
struct PlaylistSourceRefresh {
    let playlistID: Int64
    /// `SoundCloud`, `YouTube`, …; `nil` when the source isn't known yet.
    let sourceName: String?
    let isRunning: Bool
    let perform: @MainActor () -> Void
}

// MARK: - ⌘R: re-read the current place from outside (UC-KEY-15)

/// What ⌘R does in the visible place — one concept, titled per place (UC-KEY-15, M-TRACK.N12).
/// Pure, so the per-place titles are unit-tested.
enum RereadCommand: Equatable {
    /// All Tracks, Albums, Genres.
    case scanLibraryFolder
    /// Folders (W3-FOLD).
    case scanThisFolder
    /// A linked playlist.
    case refreshPlaylist(Int64)
    /// A sync profile.
    case recomputePlan(Int64)
    /// Review (W3-REV).
    case runScan
    /// Nothing outside to re-read here.
    case none

    static func resolve(selection: SidebarDestination, route: DetailRoute?, isSearching: Bool) -> RereadCommand {
        if isSearching { return .none }
        if let route {
            if case .playlist(let id, _) = route { return .refreshPlaylist(id) }
            return .none
        }
        switch selection {
        case .allTracks, .albums, .genres: return .scanLibraryFolder
        case .folders: return .scanThisFolder
        case .playlist(let id): return .refreshPlaylist(id)
        case .syncProfile(let id): return .recomputePlan(id)
        case .review: return .runScan
        case .discover, .allPlaylists: return .none
        }
    }

    /// The menu title in this place; `sourceName` names a linked playlist's source.
    func title(sourceName: String? = nil) -> String {
        switch self {
        case .scanLibraryFolder: MenuCommand.scanLibraryFolder.title
        case .scanThisFolder: "Scan This Folder"
        case .refreshPlaylist: sourceName.map { "Refresh from \($0)" } ?? MenuCommand.refreshFromSource.title
        case .recomputePlan: "Recompute Plan"
        case .runScan: "Run Scan"
        case .none: MenuCommand.refreshFromSource.title
        }
    }

    /// The package that implements ⌘R for a place that can't re-read yet.
    var pendingOwner: String? {
        switch self {
        case .scanThisFolder: "W3-FOLD"
        case .runScan: "W3-REV"
        default: nil
        }
    }
}
