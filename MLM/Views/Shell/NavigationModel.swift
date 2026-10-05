import Observation
import SwiftUI

// MARK: - Sidebar destinations

/// A row of the sidebar (UC-SIDE-01, UC-SURF-01). Selecting one replaces the content column.
///
/// The six fixed rows have number shortcuts (⌘1…⌘6, UC-KEY-23); playlists and sync profiles
/// are dynamic rows identified by their database id.
///
/// **Adding a destination (later packages):** add a case here, give it a `title`,
/// `systemImage` and (if it shows a track list) `listsTracks`, then route it in
/// `DestinationView` (`MLM/Views/Shell/DestinationView.swift`). The sidebar row itself lives in
/// `SidebarView`.
enum SidebarDestination: Hashable, Codable, Sendable {
    case allTracks
    case albums
    case genres
    case folders
    case discover
    case review
    case allPlaylists
    case playlist(Int64)
    case syncProfile(Int64)

    /// The fixed rows reachable with ⌘1…⌘6, in shortcut order (UC-SIDE-12, UC-KEY-23).
    static let numbered: [SidebarDestination] = [
        .allTracks, .albums, .genres, .folders, .discover, .review,
    ]

    /// Rows of the Library section, in order (UC-SIDE-01).
    static let librarySection: [SidebarDestination] = [.allTracks, .albums, .genres, .folders]

    /// Rows of the Inbox section, in order (UC-SIDE-01).
    static let inboxSection: [SidebarDestination] = [.discover, .review]

    /// The ⌘-number key of a fixed row; `nil` for All Playlists, playlists and sync profiles.
    var numberKey: KeyEquivalent? {
        guard let index = Self.numbered.firstIndex(of: self) else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }

    /// Title of a fixed row. Playlists and sync profiles are titled by their name
    /// (see `NavigationModel.title(names:)`); this is the fallback while the name loads.
    var fixedTitle: String {
        switch self {
        case .allTracks: "All Tracks"
        case .albums: "Albums"
        case .genres: "Genres"
        case .folders: "Folders"
        case .discover: "Discover"
        case .review: "Review"
        case .allPlaylists: "All Playlists"
        case .playlist: "Playlist"
        case .syncProfile: "Sync Profile"
        }
    }

    var systemImage: String {
        switch self {
        case .allTracks: "music.note"
        case .albums: "square.stack"
        case .genres: "guitars"
        case .folders: "folder"
        case .discover: "sparkles"
        case .review: "checklist"
        case .allPlaylists: "square.grid.2x2"
        case .playlist: "music.note.list"
        case .syncProfile: "externaldrive"
        }
    }

    /// Whether the destination lists tracks, so the drive banner applies (UC-LAYOUT-02).
    var listsTracks: Bool {
        switch self {
        case .allTracks, .folders, .discover, .review, .playlist, .syncProfile: true
        case .albums, .genres, .allPlaylists: false
        }
    }
}

// MARK: - Pushed details

/// A detail pushed onto the content column's `NavigationStack` (UC-SURF-02, UC-LAYOUT-05).
/// Back (⌘[) returns to where the user came from.
///
/// **Adding a pushed route (later packages):** the reserved cases below are already routed
/// to a placeholder in `DestinationView.routeView(_:)`; replace the placeholder with the real
/// view and push with `navigation.push(.album(id))`.
enum DetailRoute: Hashable, Codable, Sendable {
    /// A playlist opened from the All Playlists grid. `showFailedTracks` opens it with the
    /// failed-download section expanded (the grid's "Show failed" action).
    case playlist(Int64, showFailedTracks: Bool = false)
    /// Reserved for W4-2 (album detail).
    case album(Int64)
    /// Reserved for W3-GEN (genre detail).
    case genre(String)
    /// Reserved for W3-DISC (`Similar to ‹track›`).
    case similar(trackID: Int64)
    /// Temporary home of the former Sources section (accounts and playlist import) until
    /// W3-SET (Settings ▸ Sources) and W3-ADD (import sheet) replace it.
    case sources

    var fallbackTitle: String {
        switch self {
        case .playlist: "Playlist"
        case .album: "Album"
        case .genre(let name): name
        case .similar: "Similar"
        case .sources: "Sources"
        }
    }

    var listsTracks: Bool {
        switch self {
        case .playlist, .album, .genre, .similar: true
        case .sources: false
        }
    }
}

// MARK: - Navigation state

/// Owns the sidebar selection and, per destination, the pushed-detail path with a
/// forward history (Back ⌘[ / Forward ⌘], UC-KEY-24).
///
/// Rules:
/// - Each sidebar destination keeps its own path while the app runs, so navigating away and
///   back restores where the user was (e.g. All Playlists ▸ “Warm-up”).
/// - Selecting the destination that is already selected pops it to its root (Finder / Music
///   behaviour for re-choosing the current place).
/// - Back pops one pushed detail and remembers it for Forward; pushing something new clears
///   that destination's forward history (browser behaviour). Back/Forward act on pushed
///   details only — they never switch sidebar destinations (UC-TB-01).
/// - When a playlist or sync profile disappears, its sidebar destination falls back to
///   All Playlists / All Tracks and every pushed route to that playlist is removed
///   (`removePlaylist(_:)`, `removeSyncProfile(_:)`).
///
/// Exposed to views through `@Environment(NavigationModel.self)` and to menu commands through
/// `@FocusedValue(\.navigationModel)`.
@MainActor
@Observable
final class NavigationModel {
    /// The selected sidebar row.
    private(set) var selection: SidebarDestination

    private var paths: [SidebarDestination: [DetailRoute]] = [:]
    private var forwardStacks: [SidebarDestination: [DetailRoute]] = [:]

    init(selection: SidebarDestination = .allTracks) {
        self.selection = selection
    }

    // MARK: Reading

    /// The pushed path of the selected destination (root = empty).
    var path: [DetailRoute] { paths[selection] ?? [] }

    /// The route on top of the stack, or `nil` at the destination's root.
    var currentRoute: DetailRoute? { path.last }

    /// All Tracks is the visible place: selected, with nothing pushed over it. Gates commands
    /// of the kept-alive All Tracks view (its ⌘R) while another place shows.
    var isAllTracksVisible: Bool { selection == .allTracks && path.isEmpty }

    var canGoBack: Bool { !path.isEmpty }
    var canGoForward: Bool { !(forwardStacks[selection] ?? []).isEmpty }

    /// Whether the visible place lists tracks (drive banner, UC-LAYOUT-02).
    var currentPlaceListsTracks: Bool {
        currentRoute?.listsTracks ?? selection.listsTracks
    }

    /// The window title for the visible place (UC-WIN-06), with dynamic names supplied by
    /// the caller (playlist and sync-profile names live in `SidebarModel`).
    func title(names: PlaceNames) -> String {
        if let route = currentRoute {
            switch route {
            case .playlist(let id, _):
                return names.playlist(id) ?? route.fallbackTitle
            case .similar(let trackID):
                if let title = names.track(trackID) { return "Similar to “\(title)”" }
                return route.fallbackTitle
            default:
                return route.fallbackTitle
            }
        }
        switch selection {
        case .playlist(let id): return names.playlist(id) ?? selection.fixedTitle
        case .syncProfile(let id): return names.syncProfile(id) ?? selection.fixedTitle
        default: return selection.fixedTitle
        }
    }

    // MARK: Changing

    /// Select a sidebar row. Re-selecting the current row pops it to its root.
    func select(_ destination: SidebarDestination) {
        if destination == selection {
            popToRoot()
        } else {
            selection = destination
        }
    }

    /// Push a detail onto the selected destination's stack. Clears its forward history.
    func push(_ route: DetailRoute) {
        paths[selection, default: []].append(route)
        forwardStacks[selection] = []
    }

    /// Back (⌘[): pop the top detail and keep it for Forward.
    func goBack() {
        guard var current = paths[selection], let popped = current.popLast() else { return }
        paths[selection] = current
        forwardStacks[selection, default: []].append(popped)
    }

    /// Forward (⌘]): re-push the detail most recently left with Back.
    func goForward() {
        guard var forward = forwardStacks[selection], let next = forward.popLast() else { return }
        forwardStacks[selection] = forward
        paths[selection, default: []].append(next)
    }

    /// Return the selected destination to its root; popped details stay available to Forward.
    func popToRoot() {
        while canGoBack { goBack() }
    }

    /// Binding target for `NavigationStack(path:)`. A system pop (shorter prefix) feeds the
    /// forward history like Back; anything else is treated as a push.
    func setPath(_ newPath: [DetailRoute]) {
        let old = path
        guard newPath != old else { return }
        if newPath.count < old.count, Array(old.prefix(newPath.count)) == newPath {
            let popped = old.suffix(from: newPath.count)
            forwardStacks[selection, default: []].append(contentsOf: popped.reversed())
        } else {
            forwardStacks[selection] = []
        }
        paths[selection] = newPath
    }

    /// A playlist was deleted: leave its sidebar destination and drop every route to it.
    func removePlaylist(_ id: Int64) {
        paths[.playlist(id)] = nil
        forwardStacks[.playlist(id)] = nil
        for key in Array(paths.keys) {
            paths[key]?.removeAll { $0.playlistID == id }
        }
        for key in Array(forwardStacks.keys) {
            forwardStacks[key]?.removeAll { $0.playlistID == id }
        }
        if selection == .playlist(id) { selection = .allPlaylists }
    }

    /// A sync profile was deleted: leave its sidebar destination.
    func removeSyncProfile(_ id: Int64) {
        paths[.syncProfile(id)] = nil
        forwardStacks[.syncProfile(id)] = nil
        if selection == .syncProfile(id) { selection = .allTracks }
    }
}

private extension DetailRoute {
    var playlistID: Int64? {
        if case .playlist(let id, _) = self { return id }
        return nil
    }
}

/// Name lookups for window titles; supplied by whoever knows the names.
struct PlaceNames {
    var playlist: (Int64) -> String? = { _ in nil }
    var syncProfile: (Int64) -> String? = { _ in nil }
    var track: (Int64) -> String? = { _ in nil }
}

// MARK: - Focused values for menu commands

extension FocusedValues {
    /// The main window's navigation (⌘1…⌘6, ⌘[ ⌘], Go menu).
    @Entry var navigationModel: NavigationModel?
    /// The main window's trailing column (⌘I Info, ⌥⌘U Queue).
    @Entry var trailingColumn: TrailingColumnState?
    /// The main window's status bar (confirmations with Undo; W2-F wires Edit ▸ Undo).
    @Entry var statusBarCenter: StatusBarCenter?
    /// Window-level actions that menu items share with the toolbar and sidebar.
    @Entry var shellActions: ShellActions?
    /// The playback view model of the main window (Playback menu).
    @Entry var playbackViewModel: PlaybackViewModel?
}
