import Testing
import Foundation
@testable import MLM

/// W1-2 menu bar (UC-MENU-01…05, UC-KEY-*, DEC-038): the catalog in `MenuCatalog.swift` is the
/// one source of truth for titles and keys; these tests hold it to the design and hold the
/// menu code to the catalog.
@Suite("Menu bar structure and shortcuts (W1-2)")
struct MenuBarStructureTests {

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: projectRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: Shortcuts

    /// Every key of the catalog, plus the keys the system keeps for itself.
    private var allShortcuts: [MenuShortcut] {
        MenuCommand.allCases.compactMap(\.shortcut) + MenuCommand.systemReservedShortcuts
    }

    @Test func everyShortcutHasOneMeaning() {
        var seen: [MenuShortcut: [String]] = [:]
        for command in MenuCommand.allCases {
            if let shortcut = command.shortcut { seen[shortcut, default: []].append(command.rawValue) }
        }
        for shortcut in MenuCommand.systemReservedShortcuts { seen[shortcut, default: []].append("system") }
        for (shortcut, owners) in seen where owners.count > 1 {
            Issue.record("\(shortcut) is bound \(owners.count)×: \(owners)")
        }
    }

    @Test func spaceAndPlainReturnAreNeverMenuKeys() {
        // MLM binds no Space at all; the system's ⌃⌘Space (Emoji & Symbols) is reserved, not MLM's.
        for shortcut in MenuCommand.allCases.compactMap(\.shortcut) {
            #expect(shortcut.key != .space, "Space is never a menu key (UC-KEY-37, §10 Q1)")
        }
        for shortcut in allShortcuts {
            if shortcut.key == .returnKey {
                #expect(!shortcut.modifiers.isEmpty, "plain Return is never a menu key (UC-KEY-37)")
            }
            #expect(!shortcut.modifiers.isEmpty, "\(shortcut): menu keys carry a modifier")
        }
        #expect(MenuCommand.playPause.shortcut == nil, "Playback ▸ Play/Pause has no shortcut (§10 Q1)")
        #expect(MenuCommand.play.shortcut == nil)
        #expect(MenuCommand.preview.shortcut == nil)
    }

    /// The keys of UC-KEY-07…28 that are menu items, exactly; every other item has no key.
    @Test func shortcutsConformToTheKeyboardMap() {
        let expected: [MenuCommand: String] = [
            .settings: "⌘,", .hideApp: "⌘H", .hideOthers: "⌥⌘H", .quit: "⌘Q",
            .newPlaylist: "⌘N", .newPlaylistFromSelection: "⇧⌘N", .newPlaylistFolder: "⌥⌘N",
            .addFromLink: "⌘U", .importPlaylistFromSource: "⇧⌘I", .openLibrary: "⌘O", .closeWindow: "⌘W",
            .undo: "⌘Z", .redo: "⇧⌘Z", .cut: "⌘X", .copy: "⌘C", .paste: "⌘V",
            .selectAll: "⌘A", .deselectAll: "⇧⌘A", .search: "⌘F", .searchLibrary: "⌥⌘F",
            .toggleSidebar: "⌃⌘S", .toggleInfo: "⌘I", .toggleQueue: "⌥⌘U", .goToCurrentTrack: "⌘L",
            .enterFullScreen: "⌃⌘F",
            .playNext: "⌥↩", .addToQueue: "⌥⇧↩", .download: "⌘D", .refreshFromSource: "⌘R",
            .showInFinder: "⇧⌘R", .removeFromLibrary: "⌘⌫",
            .stop: "⌘.", .next: "⌘→", .previous: "⌘←", .skipForward: "⌥⌘→", .skipBack: "⌥⌘←",
            .volumeUp: "⌘↑", .volumeDown: "⌘↓",
            .goAllTracks: "⌘1", .goAlbums: "⌘2", .goGenres: "⌘3", .goFolders: "⌘4",
            .goDiscover: "⌘5", .goReview: "⌘6", .goBack: "⌘[", .goForward: "⌘]",
            .minimize: "⌘M", .activity: "⌥⌘0",
        ]
        for command in MenuCommand.allCases {
            #expect(command.shortcut?.description == expected[command],
                    "\(command): \(command.shortcut?.description ?? "none"), expected \(expected[command] ?? "none")")
        }
    }

    /// One concept per key (UC-KEY-39): ⌘R re-reads, ⌘N is New Playlist, ⌘8 is gone.
    @Test func resolvedConflictsStayResolved() {
        #expect(MenuCommand.allCases.filter { $0.shortcut == .cmd("r") } == [.refreshFromSource])
        #expect(MenuCommand.allCases.filter { $0.shortcut == .cmd("n") } == [.newPlaylist])
        #expect(!allShortcuts.contains(.cmd("8")) && !allShortcuts.contains(.cmd("7")))
        // Get Info shares View ▸ Show Info's ⌘I instead of registering it twice (UC-KEY-12).
        #expect(MenuCommand.getInfo.shortcut == nil)
    }

    /// Every menu key is defined once, in `.commands`; views only use the sheet roles and the
    /// Activity panel's Esc (UC-KEY-36). No key monitors, no window-wide arrow keys.
    @Test func viewsDeclareNoMenuKeys() throws {
        let allowed = [".keyboardShortcut(.cancelAction)", ".keyboardShortcut(.defaultAction)",
                       ".keyboardShortcut(.escape, modifiers: [])"]
        let views = projectRoot.appendingPathComponent("MLM")
        let files = FileManager.default.enumerator(at: views, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("addLocalMonitorForEvents"), "\(file.lastPathComponent): no NSEvent key monitors (UC-KIT-36)")
            guard !file.path.contains("/MLM/App/") else { continue }
            // The track context menu shows the keys next to its items (UC-CM-06, W2-A): those
            // key equivalents live only while that menu is open; each one mirrors the menu-bar
            // command's key (or the focused list's ↩ / ⌫), checked in `TrackListStructureTests`.
            guard !file.path.hasSuffix("/MLM/Views/TrackList/TrackMenu.swift") else { continue }
            // The same for the folder context menu (CM-FOLD-TREE, W3-FOLD): `Open ⌘↓`, `Scan This
            // Folder ⌘R`, `Show in Finder ⇧⌘R` — keys of the focused outline / the menu bar.
            guard !file.path.hasSuffix("/MLM/Views/Folders/FolderMenus.swift") else { continue }
            // UC-KEY-31: ⌘S is the genre staging bar's `Save n Changes` button — a key with no
            // menu item ("— (button)"), present only while changes are staged (W3-GEN).
            // UC-KEY-17: the reel context menu draws ⌫ on `Delete Reel…`; the key itself is the
            // list's `.onDeleteCommand` (W5-F2) — the menu teaches the key, it does not handle it.
            var fileAllowed = allowed
            if file.path.hasSuffix("/MLM/Views/Genres/GenreSuggestionsSection.swift") {
                fileAllowed += [".keyboardShortcut(\"s\", modifiers: .command)"]
            }
            if file.path.hasSuffix("/MLM/Views/Reels/ReelsView.swift") {
                fileAllowed += [".keyboardShortcut(.delete, modifiers: [])"]
            }
            for line in text.components(separatedBy: "\n") where line.contains(".keyboardShortcut(") {
                #expect(fileAllowed.contains { line.contains($0) },
                        "\(file.lastPathComponent): \(line.trimmingCharacters(in: .whitespaces)) — menu keys belong in .commands")
            }
        }
        let app = try source("MLM/App/MLMApp.swift")
        #expect(!app.contains("onKeyPress") && !app.contains("SeekHoldState"), "no window-wide ←/→ seek (DEC-047)")
    }

    // MARK: Menus

    @Test func tenMenusInOrder() {
        #expect(MenuBarMenu.allCases.map(\.rawValue) == [
            "MLM", "File", "Edit", "View", "Track", "Playback", "Library", "Go", "Window", "Help",
        ])
    }

    /// UC-MENU-05, item by item (submenu items follow their submenu; base titles).
    @Test func menuContentsMatchTheDesign() {
        let expected: [MenuBarMenu: [String]] = [
            .app: ["About MLM", "Settings…", "Services", "Hide MLM", "Hide Others", "Show All", "Quit MLM"],
            .file: ["New Playlist", "New Playlist from Selection", "New Playlist Folder", "New Sync Profile…",
                    "Add from Link…", "Import Playlist from Source…", "Import Files or Folder…", "Import M3U…",
                    "Export", "Playlist as M3U…", "Create ML Training Set…",
                    "New Library…", "Open Library…", "Open Recent", "Clear Menu", "Show Library File in Finder",
                    "Close Window"],
            .edit: ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All", "Deselect All",
                    "Find", "Search", "Search Library"],
            .view: ["Hide Sidebar", "Show Info", "Show Queue", "Columns", "Sort By", "Filter",
                    "Go to Current Track", "Enter Full Screen", "Customize Toolbar…"],
            .track: ["Play", "Preview", "Play Next", "Add to Queue", "Add to Playlist", "Add to Sync Profile",
                     "Get Info", "Go to Album", "Go to Artist", "Find Similar",
                     "Download", "Locate File…", "Refresh from Source",
                     "Show in Finder", "Copy", "Share…", "Remove from Playlist", "Remove from Library…"],
            .playback: ["Play", "Stop", "Next", "Previous", "Skip Forward 10 Seconds", "Skip Back 10 Seconds",
                        "Volume Up", "Volume Down", "Shuffle", "Repeat", "Play"],
            .library: ["Refresh from Sources", "Scan Library Folder", "Find Duplicates", "Find Albums",
                       "Maintenance", "Fingerprint All Tracks", "ReplayGain Analysis", "Danceability Analysis",
                       "Similarity Analysis", "Refresh Embedded Artwork", "Fetch Artwork from MusicBrainz",
                       "Reread Tags from Files…", "Read Track Numbers", "Clear Source Names from Album…", "Maintenance Settings…", "Back Up Now", "Library Settings…"],
            .go: ["All Tracks", "Albums", "Genres", "Folders", "Discover", "Review", "Back", "Forward",
                  "Playlists", "Sync Profiles"],
            .window: ["Minimize", "Zoom", "Activity", "Bring All to Front"],
            .help: ["Keyboard Shortcuts", "Show Tips Again"],
        ]
        for menu in MenuBarMenu.allCases {
            #expect(MenuCommand.items(in: menu).map(\.title) == expected[menu], "\(menu.rawValue) menu")
        }
    }

    /// Title Case, `…` only on items that ask for more, typographic characters (UC-COPY-02/05/06).
    @Test func titlesFollowTheCopyRules() {
        for command in MenuCommand.allCases {
            let title = command.title
            #expect(!title.contains("..."), "\(title): use …")
            #expect(!title.contains("\"") && !title.contains("'"), "\(title): typographic quotes only")
        }
        for command in [MenuCommand.findDuplicates, .findAlbums, .backUpNow, .scanLibraryFolder] {
            #expect(!command.title.hasSuffix("…"), "\(command.title) acts at once (UC-COPY-05, C20)")
        }
        for command in [MenuCommand.settings, .newSyncProfile, .addFromLink, .importM3U, .openLibrary,
                        .removeFromLibrary, .librarySettings, .maintenanceSettings, .locateFile] {
            #expect(command.title.hasSuffix("…"), "\(command.title) asks for more")
        }
    }

    // MARK: Pending commands

    @Test func pendingCommandsNameTheirOwnerAndReason() {
        let packages: Set<String> = ["W2-A", "W2-B", "W2-C", "W2-D", "W2-I", "W3-PL", "W3-ADD", "W3-LAUNCH",
                                     "W3-GEN", "W3-REV", "W3-SET", "W4-2", "W4-3", "W3-DISC"]
        let pending = MenuCommand.allCases.filter(\.isPending)
        #expect(!pending.isEmpty)
        for command in pending {
            let owner = command.pendingOwner
            #expect(owner.map(packages.contains) == true, "\(command): unknown owner \(owner ?? "none")")
            #expect(command.pendingReason?.hasSuffix(".") == true, "\(command): the reason is a sentence")
        }
    }

    // MARK: Menu code follows the catalog

    /// The menu file(s) of each menu, in the order their items appear.
    private let menuFiles: [MenuBarMenu: [String]] = [
        .file: ["MLM/App/Commands/FileCommands.swift", "MLM/App/LibraryCommands.swift"],
        .edit: ["MLM/App/Commands/EditCommands.swift"],
        .view: ["MLM/App/Commands/ViewCommands.swift"],
        .track: ["MLM/App/Commands/TrackCommands.swift"],
        .playback: ["MLM/App/Commands/PlaybackCommands.swift"],
        .library: ["MLM/App/Commands/LibraryMenuCommands.swift"],
        .go: ["MLM/App/Commands/GoCommands.swift"],
        .window: ["MLM/App/Commands/WindowCommands.swift"],
        .help: ["MLM/App/Commands/HelpCommands.swift"],
    ]

    /// Catalog commands referenced by the menu code, in source order, each once.
    private func referencedCommands(in text: String) throws -> [MenuCommand] {
        // `CommandButton(.x` / `CommandSubmenu(.x`, the Go menu's `(.goX, .destination)` rows, and
        // the Track menu's `rereadItem` (Refresh from Source, built per place below the body).
        let regex = try NSRegularExpression(pattern: #"(?:Command(?:Button|Submenu)\(\.(\w+))|(?:\(\.(go\w+), \.)|(rereadItem)\b|(TrackShareItem)\("#)
        var result: [MenuCommand] = []
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            var name: String?
            for group in 1...4 {
                if let range = Range(match.range(at: group), in: text) { name = String(text[range]) }
            }
            guard let name else { continue }
            let command = name == "rereadItem" ? MenuCommand.refreshFromSource
                : name == "TrackShareItem" ? MenuCommand.share : MenuCommand(rawValue: name)
            if let command, !result.contains(command) { result.append(command) }
        }
        return result
    }

    @Test func menuCodeBuildsEveryCatalogItemInOrder() throws {
        for (menu, files) in menuFiles {
            let text = try files.map(source).joined(separator: "\n")
            let built = try referencedCommands(in: text)
            let catalog = MenuCommand.items(in: menu).filter { $0.wiring != .system }
            #expect(built == catalog, "\(menu.rawValue): built \(built.map(\.rawValue))")
        }
        // The MLM menu is the system's plus the Settings scene's item.
        #expect(MenuCommand.items(in: .app).allSatisfy { $0.wiring == .system })
    }

    @Test func pendingItemsAreBuiltDisabled() throws {
        let text = try menuFiles.values.flatMap { $0 }.map(source).joined(separator: "\n")
        for command in MenuCommand.allCases where command.isPending {
            #expect(text.contains("CommandButton(.\(command.rawValue))") || text.contains("CommandSubmenu(.\(command.rawValue))"),
                    "\(command) must be built without an action (disabled with its reason)")
        }
    }

    @Test func appIsComposedFromTheMenuStructs() throws {
        let app = try source("MLM/App/MLMApp.swift")
        var cursor = app.startIndex
        for name in ["FileCommands(", "EditCommands()", "ViewCommands()", "TrackCommands()", "PlaybackCommands()",
                     "LibraryMenuCommands()", "GoCommands()", "WindowCommands()", "HelpCommands()"] {
            let range = try #require(app.range(of: name, range: cursor..<app.endIndex), "\(name) missing or out of order")
            cursor = range.upperBound
        }
        #expect(!app.contains("CommandMenu(") && !app.contains("Button("), "MLMApp only composes scenes and commands")
        #expect(app.contains("Window(KeyboardShortcutsWindow.title, id: KeyboardShortcutsWindow.id)"))
    }

    /// Get Info shows or hides Info, which follows the selection (W2-E, UC-KEY-12; was the
    /// Show Details path, review S2); S3: menus enable from the published summary.
    @Test func trackMenuReadsTheSummaryAndGetInfoShowsTheSelection() throws {
        let track = try source("MLM/App/Commands/TrackCommands.swift")
        #expect(track.contains("summary: selection?.summary,"))
        #expect(track.contains("let tracks: () -> [Track] = { selection?.selectedTracks ?? [] }"))
        #expect(track.contains("trailingColumn?.toggle(.info)"))
        #expect(!track.contains(".openTrackDetailForTrack"), "Info follows the selection; no last-activated track")
        let file = try source("MLM/App/Commands/FileCommands.swift")
        #expect(!file.contains("let selected = "), "File menu enables from the selected IDs")
        let playback = try source("MLM/App/Commands/PlaybackCommands.swift")
        #expect(playback.contains("activate: shellActions?.activateTrack"), "All Tracks plays through the window's activation")
    }

    @Test func viewMenuUsesSystemSidebarAndToolbarCommands() throws {
        let view = try source("MLM/App/Commands/ViewCommands.swift")
        #expect(view.contains("SidebarCommands()"))
        #expect(view.contains("ToolbarCommands()"))
        let edit = try source("MLM/App/Commands/EditCommands.swift")
        #expect(edit.contains("CommandGroup(replacing: .textEditing)"))
        let help = try source("MLM/App/Commands/HelpCommands.swift")
        #expect(help.contains("CommandGroup(replacing: .help)"))
    }

    // MARK: Keyboard Shortcuts window

    @Test func keyboardShortcutsWindowListsEveryMenuKey() {
        let mapped = Set(KeyboardMap.groups.flatMap(\.rows).compactMap(\.command))
        let shown = Set(KeyboardMap.visibleGroups.flatMap(\.rows).compactMap(\.command))
        for command in MenuCommand.allCases where command.shortcut != nil {
            #expect(mapped.contains(command), "\(command) (\(command.shortcut!)) missing from the keyboard map")
            #expect(shown.contains(command) == !command.isPending,
                    "\(command): the window lists a menu key exactly when it works")
        }
        let space = KeyboardMap.groups.flatMap(\.rows).first { $0.keys == "Space" }
        #expect(space?.action.hasPrefix("Preview") == true, "Space = Preview is on the map")
        #expect(!KeyboardMap.groups.flatMap(\.rows).contains { $0.keys == "Space" && $0.action.contains("Pause") },
                "Space is never Play/Pause (§10 Q1)")
    }

    /// Review S6: the window never lists a key that doesn't work yet.
    @Test func keyboardShortcutsWindowListsOnlyWorkingKeys() {
        let shown = KeyboardMap.visibleGroups.flatMap(\.rows)
        #expect(!shown.isEmpty)
        for row in shown {
            #expect(row.owner == nil, "\(row.keys) is owned by \(row.owner ?? "") and not built yet")
            #expect(row.command?.isPending != true, "\(row.keys): its menu command is pending")
            #expect(!row.keys.isEmpty)
        }
        // ⌘↓ is Volume Down, and on the focused Folders outline it opens the folder (W3-FOLD, DEC-053).
        #expect(shown.contains { $0.action.contains("as the root") })
        for keys in ["⌫", "K"] {
            #expect(!shown.contains { $0.keys == keys }, "\(keys) doesn't work yet")
        }
        // ⌘S saves a genre's staged changes since W3-GEN (UC-KEY-31).
        #expect(shown.contains { $0.keys == "⌘S" })
        // Space preview and the preview keys work since W2-C.
        #expect(shown.contains { $0.keys == "Space" })
        let previewing = KeyboardMap.visibleGroups.first { $0.title == "While previewing" }
        #expect(previewing?.rows.map(\.keys) == ["← / →", "↑ / ↓", "↩", "Esc"])
        #expect(!KeyboardMap.visibleGroups.contains { $0.rows.isEmpty })
    }

    /// Review nit: help texts of pending items are user words — no package IDs, no `….`.
    @Test func pendingReasonsAreUserFacing() {
        for command in MenuCommand.allCases {
            guard let reason = command.pendingReason else { continue }
            #expect(reason.range(of: #"W\d-"#, options: .regularExpression) == nil, "\(command): \(reason)")
            #expect(!reason.contains("…."), "\(command): \(reason)")
        }
    }
}
