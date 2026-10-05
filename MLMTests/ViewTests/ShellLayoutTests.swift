import Testing
import Foundation
@testable import MLM

/// Source-scan tests verifying the shell layout structure:
/// - PlayerBar lives in a native ToolbarItem(placement: .principal) of the shell toolbar
/// - The trailing column is the system `.inspector`, not an HSplitView (W1-1, DEC-007)
/// - Info ▸ Audio shows the inspected track's waveform (W2-E)
/// - ⌘F is Edit ▸ Find ▸ Search, not a key monitor (W1-2)
/// - Search VM uses nonisolated helpers for off-main work
/// - TrackRepository.search supports a limit parameter
@Suite("ShellLayoutTests")
struct ShellLayoutTests {

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent() // ViewTests
            .deletingLastPathComponent() // MLMTests
            .deletingLastPathComponent() // repo root
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Task 1: Native toolbar with PlayerBar in principal slot

    @Test
    func contentView_hasPrincipalToolbarItem() throws {
        let src = try readSource("MLM/Views/Shell/ShellToolbar.swift")
        #expect(src.contains("placement: .principal)") && src.contains("PlayerBar(viewModel:"),
                "PlayerBar must live in a ToolbarItem(placement: .principal) in the native toolbar")
    }

    @Test
    func contentView_noPlayerBarOverlay() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(!src.contains("overlay(alignment: .top)"),
                "ContentView must not use overlay(alignment: .top) for the PlayerBar")
    }

    @Test
    func mlmApp_noHiddenTitleBar() throws {
        let src = try readSource("MLM/App/MLMApp.swift")
        #expect(!src.contains(".hiddenTitleBar"),
                "MLMApp must NOT use .hiddenTitleBar — use the native title bar")
    }

    /// ⌘F is Edit ▸ Find ▸ Search, a menu key of the main window — no app-wide key monitor
    /// (W1-2, UC-KEY-25/36, PP-SHELL-06).
    @Test
    func cmdF_isTheFindMenuItemNotAKeyMonitor() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(!src.contains("addLocalMonitorForEvents"), "the app-wide ⌘F monitor is gone")
        #expect(src.contains(".focusedSceneValue(\\.toolbarSearch"), "Edit ▸ Find reaches the main window's field")
        let edit = try readSource("MLM/App/Commands/EditCommands.swift")
        // W3-ACT: in the Activity window ⌘F focuses the log search (UC-KEY-25).
        #expect(edit.contains("CommandButton(.search, enabled: search != nil || logSearch != nil)"))
        #expect(edit.contains("search.focus(scope: .thisView)"))
        #expect(edit.contains("search?.focus(scope: .library)"), "⌥⌘F searches the library (W2-I)")
    }

    @Test
    func contentView_noSidebarLeadingIcon() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(!src.contains("sidebar.leading"),
                "ContentView must not contain a custom sidebar.leading toggle — native toolbar provides it")
    }

    // MARK: - Task 2: Trailing column via the system .inspector (UC-TRAIL-01, UC-KIT-36)

    @Test
    func contentView_usesInspector() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(src.contains(".inspector(isPresented:"),
                "ContentView must host Info / Queue in the system .inspector")
        #expect(src.contains(".inspectorColumnWidth("),
                "The trailing column sets its width range")
    }

    @Test
    func contentView_noHSplitView() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(!src.contains("HSplitView"),
                "HSplitView for the inspector is banned (UC-KIT-36)")
    }

    @Test
    func toolbar_isCustomizableAndConstant() throws {
        let content = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(content.contains(".toolbar(id: \"mlm.main\")"))
        let toolbar = try readSource("MLM/Views/Shell/ShellToolbar.swift")
        for item in ["BackForwardButtons()", "AddMenu()", "ActivityToolbarItem()", "InfoToggleButton()"] {
            #expect(toolbar.contains(item), "toolbar misses \(item)")
        }
        let library = try readSource("MLM/Views/Library/LibraryView.swift")
        #expect(!library.contains(".toolbar"), "All Tracks must not add toolbar items (UC-TB-02)")
        let folders = try readSource("MLM/Views/Folders/FoldersView.swift")
        #expect(!folders.contains(".toolbar"), "Folders must not add toolbar items (UC-TB-02)")
    }

    @MainActor
    @Test
    func shortcuts_haveOneMeaningEach() throws {
        #expect(MenuCommand.importPlaylistFromSource.shortcut == .cmd("i", .shift),
                "⇧⌘I belongs to Import Playlist from Source… (UC-KEY-22)")
        #expect(MenuCommand.importFilesOrFolder.title == "Import Files or Folder…")
        #expect(MenuCommand.importFilesOrFolder.shortcut == nil)
        #expect(!MenuCommand.allCases.contains { $0.title == "Import from Folder…" || $0.title == "Sources…" })
        let file = try readSource("MLM/App/Commands/FileCommands.swift")
        #expect(file.contains("CommandButton(.importPlaylistFromSource, enabled: shellActions != nil)"))
        #expect(file.contains("CommandButton(.importFilesOrFolder, enabled: shellActions != nil)"))
        let grid = try readSource("MLM/Views/Playlists/PlaylistsView.swift")
        #expect(!grid.contains(".keyboardShortcut(\"n\""), "File ▸ New Playlist owns ⌘N")
    }

    @Test
    func searchPane_isDrawnAboveTheNavigationStack() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        let column = try #require(src.range(of: "private var detailColumn: some View {"))
        let stack = try #require(src.range(of: "private var navigationStack: some View {"))
        let detail = String(src[column.upperBound..<stack.lowerBound])
        #expect(detail.contains("SearchResultsView("),
                "Library / Online results are a sibling above the stack, so pushed routes can't cover them")
        #expect(!src[stack.upperBound...].contains("SearchResultsView("))
        #expect(!src.contains("GlobalSearchPresentationView") && !src.contains("UniversalSearch"),
                "The old results pane and the universal panel are gone (W2-I)")
        #expect(!src.contains(".disabled(!isAllTracks"), "The kept-alive All Tracks subtree is not disabled")
    }

    @Test
    func addMenu_hasExactlyTheDesignedItems() throws {
        let src = try readSource("MLM/Views/Shell/ShellToolbar.swift")
        let start = try #require(src.range(of: "struct AddMenu: View"))
        let end = try #require(src.range(of: "// MARK: - Activity item"))
        let menu = String(src[start.upperBound..<end.lowerBound])
        let titles = menu.matches(of: #/Button\("([^"]+)"\)/#).map { String($0.1) }
        #expect(titles == [
            "New Playlist", "New Playlist Folder", "Add from Link…", "Import Playlist from Source…",
            "Import Files or Folder…", "Import M3U…", "Refresh from Sources",
        ])
    }

    /// UC-TB-03: the player's title column collapses first, Add goes to the overflow before
    /// anything else; back/forward, player and Info stay (W1-2).
    @Test
    func toolbar_collapsesInTheDesignedOrder() throws {
        let toolbar = try readSource("MLM/Views/Shell/ShellToolbar.swift")
        let add = try #require(toolbar.range(of: "AddMenu()"))
        #expect(String(toolbar[add.upperBound...].prefix(80)).contains(".visibilityPriority(.low)"))
        for item in ["BackForwardButtons()", "PlayerBar(viewModel: playbackViewModel)", "InfoToggleButton()"] {
            let range = try #require(toolbar.range(of: item))
            #expect(String(toolbar[range.upperBound...].prefix(200)).contains(".visibilityPriority(.high)"), "\(item) never collapses")
        }
        let player = try readSource("MLM/Views/Player/PlayerBar.swift")
        #expect(player.contains("ViewThatFits(in: .horizontal)"))
        #expect(player.contains("playerRow(showsTrackInfo: true)") && player.contains("playerRow(showsTrackInfo: false)"))
        // The column's width is fixed, so the choice can't flip with the title's length (review S4).
        #expect(player.contains(".frame(width: Self.trackInfoWidth, alignment: .leading)"))
        #expect(!player.contains("minWidth: 80, maxWidth: 160"))
    }

    /// W2-E: the waveform is the inspected track's, on Info ▸ Audio (P-INSPECTOR-WAVEFORM),
    /// no longer a strip above the header showing the player's track.
    @Test
    func inspectorWaveformLivesOnTheAudioTab() throws {
        let audio = try readSource("MLM/Views/Inspector/InspectorAudioTab.swift")
        #expect(audio.contains("InspectorWaveform(track: track"))
        let info = try readSource("MLM/Views/Inspector/InspectorView.swift")
        #expect(!info.contains("WaveformView("))
    }

    // MARK: - Task 3: ⌘F and ⌥⌘F in Edit ▸ Find (W1-2)

    @MainActor
    @Test
    func find_searchAndSearchLibraryHaveTheirOwnKeys() throws {
        #expect(MenuCommand.search.shortcut == .cmd("f"), "Search ⌘F (UC-KEY-25)")
        #expect(MenuCommand.searchLibrary.shortcut == .cmd("f", .option), "Search Library ⌥⌘F (UC-KEY-25)")
        #expect(MenuCommand.search.parent == .find && MenuCommand.searchLibrary.parent == .find)
    }

    // MARK: - Task 4: Typing latency

    @Test
    func searchVM_containsNonisolated() throws {
        let src = try readSource("MLM/ViewModels/OnlineSearchModel.swift")
        #expect(src.contains("nonisolated"),
                "OnlineSearchModel asks its sources off the main actor")
    }

    @Test
    func trackRepository_searchHasLimit() throws {
        let src = try readSource("MLM/Database/TrackRepository.swift")
        // Find the search function signature
        #expect(src.contains("func search(query: String, limit: Int?"),
                "TrackRepository.search must accept a limit: Int? parameter")
    }
}
