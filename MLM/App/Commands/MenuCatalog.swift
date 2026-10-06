import SwiftUI

// MARK: - Key equivalents

/// A menu item's key equivalent as a plain value, so the catalog can be compared, displayed
/// and tested (`KeyboardShortcut` is neither `Hashable` nor printable).
struct MenuShortcut: Hashable, Sendable, CustomStringConvertible {
    enum Key: Hashable, Sendable {
        case character(Character)
        case leftArrow, rightArrow, upArrow, downArrow
        case delete
        case returnKey
        case space
    }

    struct Modifiers: OptionSet, Hashable, Sendable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1 << 0)
        static let shift = Modifiers(rawValue: 1 << 1)
        static let option = Modifiers(rawValue: 1 << 2)
        static let control = Modifiers(rawValue: 1 << 3)
    }

    let key: Key
    let modifiers: Modifiers

    /// ⌘ + `key` (+ `extra`).
    static func cmd(_ character: Character, _ extra: Modifiers = []) -> MenuShortcut {
        MenuShortcut(key: .character(character), modifiers: extra.union(.command))
    }

    static func cmd(_ key: Key, _ extra: Modifiers = []) -> MenuShortcut {
        MenuShortcut(key: key, modifiers: extra.union(.command))
    }

    var keyboardShortcut: KeyboardShortcut {
        KeyboardShortcut(keyEquivalent, modifiers: eventModifiers)
    }

    private var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character): KeyEquivalent(character)
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .delete: .delete
        case .returnKey: .return
        case .space: .space
        }
    }

    private var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// The menu glyphs in Apple's order (⌃⌥⇧⌘), e.g. `⌥⌘→`, `⇧⌘N`, `⌘?`.
    var description: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case .character(let character): text += String(character).uppercased()
        case .leftArrow: text += "←"
        case .rightArrow: text += "→"
        case .upArrow: text += "↑"
        case .downArrow: text += "↓"
        case .delete: text += "⌫"
        case .returnKey: text += "↩"
        case .space: text += "Space"
        }
        return text
    }
}

// MARK: - Menus

/// The ten menus of the menu bar, in order (UC-MENU-01, DEC-038).
enum MenuBarMenu: String, CaseIterable, Sendable {
    case app = "MLM"
    case file = "File"
    case edit = "Edit"
    case view = "View"
    case track = "Track"
    case playback = "Playback"
    case library = "Library"
    case go = "Go"
    case window = "Window"
    case help = "Help"
}

/// Who implements a menu item.
enum CommandWiring: Equatable, Sendable {
    /// MLM builds and wires it (`MLM/App/Commands/*`); it enables from focused state.
    case app
    /// The system provides it (AppKit / SwiftUI scene or `SidebarCommands` etc.); listed so the
    /// key map and the uniqueness test know about its key.
    case system
    /// The feature arrives with a later work package: the item is present and **disabled**
    /// with `reason` as its help text (UC-MENU-02, UC-COPY-13). The owning package wires it.
    case pending(owner: String, reason: String)
}

// MARK: - Catalog

/// Every item of the menu bar exactly as UC-MENU-05 lists it — the single source of truth for
/// titles, key equivalents and what is still pending. Menu code builds its items from here
/// (`CommandButton(.download, …)`); the Keyboard Shortcuts window and the shortcut tests read
/// it too.
///
/// **Wiring a pending command (later packages):** change its `wiring` from `.pending` to
/// `.app` below and give its `CommandButton` in the menu's file an `enabled:` state and an
/// action. The tests then require it to be enabled somewhere and drop it from the pending list.
///
/// Titles are the base titles; some items rename themselves at run time (`Pause`,
/// `Hide Info`, `Retry Download`, `Remove from “Warm-up”`, `Scan Library Folder`,
/// `Shuffle All Tracks`).
enum MenuCommand: String, CaseIterable, Sendable {
    // MLM
    case about, settings, services, hideApp, hideOthers, showAll, quit
    // File
    case newPlaylist, newPlaylistFromSelection, newPlaylistFolder, newSyncProfile
    case addFromLink, importPlaylistFromSource, importFilesOrFolder, importM3U
    case export, exportPlaylistAsM3U, createMLTrainingSet
    case newLibrary, openLibrary, openRecent, clearRecentLibraries, showLibraryFileInFinder
    case closeWindow
    // Edit
    case undo, redo, cut, copy, paste, delete, selectAll, deselectAll
    case find, search, searchLibrary
    // View
    case toggleSidebar, toggleInfo, toggleQueue
    case columns, sortBy, filter
    case goToCurrentTrack
    case enterFullScreen, customizeToolbar
    // Track
    case play, preview, playNext, addToQueue
    case addToPlaylist, addToSyncProfile
    case getInfo, goToAlbum, goToArtist, findSimilar
    case download, locateFile, refreshFromSource
    case showInFinder, copyTrack, share
    case removeFromContainer, removeFromLibrary
    // Playback
    case playPause, stop
    case next, previous, skipForward, skipBack
    case volumeUp, volumeDown
    case shuffleView, repeatMode
    case playView
    // Library
    case refreshFromSources, scanLibraryFolder
    case findDuplicates, findAlbums
    case maintenance
    case fingerprintAllTracks, replayGainAnalysis, danceabilityAnalysis, similarityAnalysis
    case refreshEmbeddedArtwork, fetchArtworkFromMusicBrainz, rereadTagsFromFiles
    case readTrackNumbers
    case maintenanceSettings
    case backUpNow, librarySettings
    // Go
    case goAllTracks, goAlbums, goGenres, goFolders, goDiscover, goReview
    case goBack, goForward
    case goPlaylists, goSyncProfiles
    // Window
    case minimize, zoom, activity, bringAllToFront
    // Help
    case mlmHelp, keyboardShortcuts, showTipsAgain

    struct Entry {
        let menu: MenuBarMenu
        let title: String
        let shortcut: MenuShortcut?
        let wiring: CommandWiring
        /// The submenu this item lives in (`Export ▸`, `Find ▸`, `Maintenance ▸`).
        var parent: MenuCommand? = nil
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    var entry: Entry {
        switch self {
        // MARK: MLM (M-APP) — system, plus the Settings scene's own item
        case .about: Entry(menu: .app, title: "About MLM", shortcut: nil, wiring: .system)
        case .settings: Entry(menu: .app, title: "Settings…", shortcut: .cmd(","), wiring: .system)
        case .services: Entry(menu: .app, title: "Services", shortcut: nil, wiring: .system)
        case .hideApp: Entry(menu: .app, title: "Hide MLM", shortcut: .cmd("h"), wiring: .system)
        case .hideOthers: Entry(menu: .app, title: "Hide Others", shortcut: .cmd("h", .option), wiring: .system)
        case .showAll: Entry(menu: .app, title: "Show All", shortcut: nil, wiring: .system)
        case .quit: Entry(menu: .app, title: "Quit MLM", shortcut: .cmd("q"), wiring: .system)

        // MARK: File (M-FILE)
        case .newPlaylist: Entry(menu: .file, title: "New Playlist", shortcut: .cmd("n"), wiring: .app)
        case .newPlaylistFromSelection:
            Entry(menu: .file, title: "New Playlist from Selection", shortcut: .cmd("n", .shift), wiring: .app)
        case .newPlaylistFolder:
            Entry(menu: .file, title: "New Playlist Folder", shortcut: .cmd("n", .option),
                  wiring: .app)
        case .newSyncProfile: Entry(menu: .file, title: "New Sync Profile…", shortcut: nil, wiring: .app)
        case .addFromLink:
            Entry(menu: .file, title: "Add from Link…", shortcut: .cmd("u"), wiring: .app)
        case .importPlaylistFromSource:
            Entry(menu: .file, title: "Import Playlist from Source…", shortcut: .cmd("i", .shift), wiring: .app)
        case .importFilesOrFolder: Entry(menu: .file, title: "Import Files or Folder…", shortcut: nil, wiring: .app)
        case .importM3U:
            Entry(menu: .file, title: "Import M3U…", shortcut: nil,
                  wiring: .app)
        case .export: Entry(menu: .file, title: "Export", shortcut: nil, wiring: .app)
        case .exportPlaylistAsM3U:
            Entry(menu: .file, title: "Playlist as M3U…", shortcut: nil,
                  wiring: .app, parent: .export)
        case .createMLTrainingSet:
            Entry(menu: .file, title: "Create ML Training Set…", shortcut: nil, wiring: .app, parent: .export)
        case .newLibrary: Entry(menu: .file, title: "New Library…", shortcut: nil, wiring: .app)
        case .openLibrary: Entry(menu: .file, title: "Open Library…", shortcut: .cmd("o"), wiring: .app)
        case .openRecent: Entry(menu: .file, title: "Open Recent", shortcut: nil, wiring: .app)
        case .clearRecentLibraries:
            Entry(menu: .file, title: "Clear Menu", shortcut: nil,
                  wiring: .pending(owner: "W3-LAUNCH", reason: "Open Recent lists every library MLM knows. Remove one from the list in the library picker."), parent: .openRecent)
        case .showLibraryFileInFinder: Entry(menu: .file, title: "Show Library File in Finder", shortcut: nil, wiring: .app)
        case .closeWindow: Entry(menu: .file, title: "Close Window", shortcut: .cmd("w"), wiring: .system)

        // MARK: Edit (M-EDIT)
        case .undo: Entry(menu: .edit, title: "Undo", shortcut: .cmd("z"), wiring: .system)
        case .redo: Entry(menu: .edit, title: "Redo", shortcut: .cmd("z", .shift), wiring: .system)
        case .cut: Entry(menu: .edit, title: "Cut", shortcut: .cmd("x"), wiring: .system)
        case .copy: Entry(menu: .edit, title: "Copy", shortcut: .cmd("c"), wiring: .system)
        case .paste: Entry(menu: .edit, title: "Paste", shortcut: .cmd("v"), wiring: .system)
        // ⌫ belongs to the focused list (`onDeleteCommand`, W2-A); the system item has no key.
        case .delete: Entry(menu: .edit, title: "Delete", shortcut: nil, wiring: .system)
        case .selectAll: Entry(menu: .edit, title: "Select All", shortcut: .cmd("a"), wiring: .system)
        case .deselectAll: Entry(menu: .edit, title: "Deselect All", shortcut: .cmd("a", .shift), wiring: .app)
        case .find: Entry(menu: .edit, title: "Find", shortcut: nil, wiring: .app)
        case .search: Entry(menu: .edit, title: "Search", shortcut: .cmd("f"), wiring: .app, parent: .find)
        case .searchLibrary: Entry(menu: .edit, title: "Search Library", shortcut: .cmd("f", .option), wiring: .app, parent: .find)

        // MARK: View (M-VIEW)
        case .toggleSidebar: Entry(menu: .view, title: "Hide Sidebar", shortcut: .cmd("s", .control), wiring: .system)
        case .toggleInfo: Entry(menu: .view, title: "Show Info", shortcut: .cmd("i"), wiring: .app)
        case .toggleQueue: Entry(menu: .view, title: "Show Queue", shortcut: .cmd("u", .option), wiring: .app)
        // Driven by the focused track table (`FocusedValues.trackTableViewOptions`, W2-A).
        case .columns: Entry(menu: .view, title: "Columns", shortcut: nil, wiring: .app)
        case .sortBy: Entry(menu: .view, title: "Sort By", shortcut: nil, wiring: .app)
        // The visible view's scopes (`FocusedValues.viewScopeMenu`, published by `ScopeBar`, W2-B).
        case .filter: Entry(menu: .view, title: "Filter", shortcut: nil, wiring: .app)
        case .goToCurrentTrack: Entry(menu: .view, title: "Go to Current Track", shortcut: .cmd("l"), wiring: .app)
        case .enterFullScreen: Entry(menu: .view, title: "Enter Full Screen", shortcut: .cmd("f", .control), wiring: .system)
        case .customizeToolbar: Entry(menu: .view, title: "Customize Toolbar…", shortcut: nil, wiring: .system)

        // MARK: Track (M-TRACK) — ↩ and Space belong to the focused list, never to a menu (UC-KEY-37)
        case .play: Entry(menu: .track, title: "Play", shortcut: nil, wiring: .app)
        // Space is the focused list's key, never this item's (UC-KEY-37, §10 Q1).
        case .preview: Entry(menu: .track, title: "Preview", shortcut: nil, wiring: .app)
        case .playNext: Entry(menu: .track, title: "Play Next", shortcut: MenuShortcut(key: .returnKey, modifiers: .option), wiring: .app)
        // W2-D: after the last Play Next item, before the rest of the list that plays.
        case .addToQueue:
            Entry(menu: .track, title: "Add to Queue", shortcut: MenuShortcut(key: .returnKey, modifiers: [.option, .shift]),
                  wiring: .app)
        case .addToPlaylist: Entry(menu: .track, title: "Add to Playlist", shortcut: nil, wiring: .app)
        case .addToSyncProfile: Entry(menu: .track, title: "Add to Sync Profile", shortcut: nil, wiring: .app)
        // ⌘I is registered once, by View ▸ Show Info (UC-KEY-12); this is the same command.
        case .getInfo: Entry(menu: .track, title: "Get Info", shortcut: nil, wiring: .app)
        case .goToAlbum:
            Entry(menu: .track, title: "Go to Album", shortcut: nil, wiring: .app)
        case .goToArtist:
            Entry(menu: .track, title: "Go to Artist", shortcut: nil, wiring: .app)
        case .findSimilar:
            Entry(menu: .track, title: "Find Similar", shortcut: nil, wiring: .app)
        case .download: Entry(menu: .track, title: "Download", shortcut: .cmd("d"), wiring: .app)
        case .locateFile: Entry(menu: .track, title: "Locate File…", shortcut: nil, wiring: .app)
        case .refreshFromSource: Entry(menu: .track, title: "Refresh from Source", shortcut: .cmd("r"), wiring: .app)
        case .showInFinder: Entry(menu: .track, title: "Show in Finder", shortcut: .cmd("r", .shift), wiring: .app)
        case .copyTrack: Entry(menu: .track, title: "Copy", shortcut: nil, wiring: .app)
        case .share:
            Entry(menu: .track, title: "Share…", shortcut: nil,
                  wiring: .pending(owner: "W5-2", reason: "Sharing a track isn’t available yet."))
        // ⌫ belongs to the focused list (W2-A, `onDeleteCommand`); the menu shows the command.
        case .removeFromContainer: Entry(menu: .track, title: "Remove from Playlist", shortcut: nil, wiring: .app)
        case .removeFromLibrary: Entry(menu: .track, title: "Remove from Library…", shortcut: .cmd(.delete), wiring: .app)

        // MARK: Playback (M-PLAYBACK) — Play / Pause has no key (§10 Q1, UC-KEY-37)
        case .playPause: Entry(menu: .playback, title: "Play", shortcut: nil, wiring: .app)
        case .stop: Entry(menu: .playback, title: "Stop", shortcut: .cmd("."), wiring: .app)
        case .next: Entry(menu: .playback, title: "Next", shortcut: .cmd(.rightArrow), wiring: .app)
        case .previous: Entry(menu: .playback, title: "Previous", shortcut: .cmd(.leftArrow), wiring: .app)
        case .skipForward: Entry(menu: .playback, title: "Skip Forward 10 Seconds", shortcut: .cmd(.rightArrow, .option), wiring: .app)
        case .skipBack: Entry(menu: .playback, title: "Skip Back 10 Seconds", shortcut: .cmd(.leftArrow, .option), wiring: .app)
        case .volumeUp: Entry(menu: .playback, title: "Volume Up", shortcut: .cmd(.upArrow), wiring: .app)
        case .volumeDown: Entry(menu: .playback, title: "Volume Down", shortcut: .cmd(.downArrow), wiring: .app)
        // `Shuffle ‹view›` / `Play ‹view›` at run time; the plain verb when no list is named.
        case .shuffleView: Entry(menu: .playback, title: "Shuffle", shortcut: nil, wiring: .app)
        case .repeatMode: Entry(menu: .playback, title: "Repeat", shortcut: nil, wiring: .app)
        case .playView: Entry(menu: .playback, title: "Play", shortcut: nil, wiring: .app)

        // MARK: Library (M-LIBRARY)
        case .refreshFromSources:
            Entry(menu: .library, title: "Refresh from Sources", shortcut: nil, wiring: .app)
        case .scanLibraryFolder: Entry(menu: .library, title: "Scan Library Folder", shortcut: nil, wiring: .app)
        case .findDuplicates:
            Entry(menu: .library, title: "Find Duplicates", shortcut: nil, wiring: .app)
        case .findAlbums:
            Entry(menu: .library, title: "Find Albums", shortcut: nil,
                  wiring: .pending(owner: "W4-3", reason: "Album suggestions aren’t available yet."))
        case .maintenance: Entry(menu: .library, title: "Maintenance", shortcut: nil, wiring: .app)
        case .fingerprintAllTracks: Self.maintenanceJob("Fingerprint All Tracks")
        case .replayGainAnalysis: Self.maintenanceJob("ReplayGain Analysis")
        case .danceabilityAnalysis: Self.maintenanceJob("Danceability Analysis")
        case .similarityAnalysis: Self.maintenanceJob("Similarity Analysis")
        case .refreshEmbeddedArtwork: Self.maintenanceJob("Refresh Embedded Artwork")
        case .fetchArtworkFromMusicBrainz: Self.maintenanceJob("Fetch Artwork from MusicBrainz")
        case .rereadTagsFromFiles: Self.maintenanceJob("Reread Tags from Files…")
        case .readTrackNumbers: Self.maintenanceJob("Read Track Numbers")
        case .maintenanceSettings:
            Entry(menu: .library, title: "Maintenance Settings…", shortcut: nil, wiring: .app, parent: .maintenance)
        case .backUpNow: Entry(menu: .library, title: "Back Up Now", shortcut: nil, wiring: .app)
        case .librarySettings: Entry(menu: .library, title: "Library Settings…", shortcut: nil, wiring: .app)

        // MARK: Go (M-NAVIGATE → Go)
        case .goAllTracks: Entry(menu: .go, title: "All Tracks", shortcut: .cmd("1"), wiring: .app)
        case .goAlbums: Entry(menu: .go, title: "Albums", shortcut: .cmd("2"), wiring: .app)
        case .goGenres: Entry(menu: .go, title: "Genres", shortcut: .cmd("3"), wiring: .app)
        case .goFolders: Entry(menu: .go, title: "Folders", shortcut: .cmd("4"), wiring: .app)
        case .goDiscover: Entry(menu: .go, title: "Discover", shortcut: .cmd("5"), wiring: .app)
        case .goReview: Entry(menu: .go, title: "Review", shortcut: .cmd("6"), wiring: .app)
        case .goBack: Entry(menu: .go, title: "Back", shortcut: .cmd("["), wiring: .app)
        case .goForward: Entry(menu: .go, title: "Forward", shortcut: .cmd("]"), wiring: .app)
        case .goPlaylists: Entry(menu: .go, title: "Playlists", shortcut: nil, wiring: .app)
        case .goSyncProfiles: Entry(menu: .go, title: "Sync Profiles", shortcut: nil, wiring: .app)

        // MARK: Window (M-WINDOW)
        case .minimize: Entry(menu: .window, title: "Minimize", shortcut: .cmd("m"), wiring: .system)
        case .zoom: Entry(menu: .window, title: "Zoom", shortcut: nil, wiring: .system)
        case .activity: Entry(menu: .window, title: "Activity", shortcut: .cmd("0", .option), wiring: .app)
        case .bringAllToFront: Entry(menu: .window, title: "Bring All to Front", shortcut: nil, wiring: .system)

        // MARK: Help (M-HELP)
        case .mlmHelp:
            Entry(menu: .help, title: "MLM Help", shortcut: .cmd("?"),
                  wiring: .pending(owner: "W5-2", reason: "MLM Help isn’t available yet. Choose Keyboard Shortcuts for the keys."))
        case .keyboardShortcuts: Entry(menu: .help, title: "Keyboard Shortcuts", shortcut: nil, wiring: .app)
        case .showTipsAgain:
            Entry(menu: .help, title: "Show Tips Again", shortcut: nil,
                  wiring: .pending(owner: "W5-2", reason: "Tips aren’t available yet."))
        }
    }

    /// A Maintenance ▸ job (DEC-044): starts (or queues) the same Activity operation as `Run`
    /// in Settings ▸ Maintenance (W3-SET, `MaintenanceJobs`).
    private static func maintenanceJob(_ title: String) -> Entry {
        Entry(menu: .library, title: title, shortcut: nil, wiring: .app, parent: .maintenance)
    }

    var menu: MenuBarMenu { entry.menu }
    var title: String { entry.title }
    var shortcut: MenuShortcut? { entry.shortcut }
    var wiring: CommandWiring { entry.wiring }
    var parent: MenuCommand? { entry.parent }

    var isPending: Bool {
        if case .pending = wiring { return true }
        return false
    }

    /// The package that wires a pending command.
    var pendingOwner: String? {
        if case .pending(let owner, _) = wiring { return owner }
        return nil
    }

    /// Help text of a disabled pending item (UC-COPY-13).
    var pendingReason: String? {
        if case .pending(_, let reason) = wiring { return reason }
        return nil
    }

    /// The items of `menu` in catalog (= menu) order.
    static func items(in menu: MenuBarMenu) -> [MenuCommand] {
        allCases.filter { $0.menu == menu }
    }

    /// Keys the system binds outside the catalog's items (View ▸ Show Toolbar, Edit ▸ Emoji &
    /// Symbols, window cycling), so no MLM command may take them.
    static let systemReservedShortcuts: [MenuShortcut] = [
        .cmd("t", .option),            // View ▸ Hide Toolbar (ToolbarCommands)
        .cmd(.space, .control),        // Edit ▸ Emoji & Symbols
        .cmd("`"),                     // cycle windows
        .cmd("v", [.option, .shift]),  // Edit ▸ Paste and Match Style
    ]
}
