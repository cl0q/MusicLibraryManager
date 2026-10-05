import Testing
import Foundation

/// Source-scan tests verifying the shell layout structure:
/// - PlayerBar lives in a native ToolbarItem(placement: .principal) of the shell toolbar
/// - The trailing column is the system `.inspector`, not an HSplitView (W1-1, DEC-007)
/// - TrackDetailView puts waveform above header
/// - Cmd+F is wired via NSEvent local monitor
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

    @Test
    func contentView_cmdFMonitor() throws {
        let src = try readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(src.contains("addLocalMonitorForEvents"),
                "ContentView must use NSEvent.addLocalMonitorForEvents for Cmd+F")
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
        for item in ["BackForwardButtons()", "AddMenu()", "ActivityToolbarButton()", "InfoToggleButton()"] {
            #expect(toolbar.contains(item), "toolbar misses \(item)")
        }
        let library = try readSource("MLM/Views/Library/LibraryView.swift")
        #expect(!library.contains(".toolbar"), "All Tracks must not add toolbar items (UC-TB-02)")
        let folders = try readSource("MLM/Views/Folders/FoldersView.swift")
        #expect(!folders.contains(".toolbar"), "Folders must not add toolbar items (UC-TB-02)")
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

    @Test
    func trackDetailView_waveformBeforeHeader() throws {
        let src = try readSource("MLM/Views/TrackDetail/TrackDetailView.swift")
        guard let waveformIdx = src.range(of: "waveformSection")?.lowerBound,
              let headerIdx = src.range(of: "headerSection")?.lowerBound else {
            Issue.record("TrackDetailView must contain both waveformSection and headerSection")
            return
        }
        #expect(waveformIdx < headerIdx,
                "waveformSection must appear before headerSection in TrackDetailView body")
    }

    // MARK: - Task 3: Cmd+F via NSEvent monitor (not hidden button)

    @Test
    func mlmApp_noShortcutOnMenuButton() throws {
        let src = try readSource("MLM/App/MLMApp.swift")
        // The Search Library menu button must NOT have .keyboardShortcut("f")
        let searchButtonRange = src.range(of: "Button(\"Search Library\")")
        guard let buttonStart = searchButtonRange?.lowerBound else {
            Issue.record("MLMApp must contain a Search Library menu button")
            return
        }
        // Look at the next ~300 chars after the button declaration
        let afterButton = src[buttonStart...]
        let snippet = String(afterButton.prefix(300))
        #expect(!snippet.contains(".keyboardShortcut(\"f\")"),
                "MLMApp Search Library menu button must NOT have .keyboardShortcut(\"f\") — the NSEvent monitor owns Cmd+F")
    }

    // MARK: - Task 4: Typing latency

    @Test
    func searchVM_containsNonisolated() throws {
        let src = try readSource("MLM/ViewModels/GlobalSearchPresentationViewModel.swift")
        #expect(src.contains("nonisolated"),
                "GlobalSearchPresentationViewModel must contain nonisolated helpers for off-main work")
    }

    @Test
    func trackRepository_searchHasLimit() throws {
        let src = try readSource("MLM/Database/TrackRepository.swift")
        // Find the search function signature
        #expect(src.contains("func search(query: String, limit: Int?"),
                "TrackRepository.search must accept a limit: Int? parameter")
    }
}
