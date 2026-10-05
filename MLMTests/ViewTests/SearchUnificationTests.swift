import Testing
import Foundation

/// Source-scan tests verifying the search-unification refactor:
/// - LibraryView no longer has its own `.searchable` entry
/// - PlaylistDetailView no longer has an inline "Search tracks…" field
/// - ContentView uses `.onSubmit` and no longer has `globalSearchQuery`
@Suite("SearchUnificationTests")
struct SearchUnificationTests {

    // Repo root: this file lives at MLMTests/ViewTests/SearchUnificationTests.swift
    // so repo root = #filePath minus that suffix.
    private static var repoRoot: String {
        let filePath = #filePath
        // #filePath may be an absolute path or relative; strip the known suffix.
        let suffix = "MLMTests/ViewTests/SearchUnificationTests.swift"
        if let range = filePath.range(of: suffix) {
            return String(filePath[filePath.startIndex..<range.lowerBound])
        }
        // Fallback: walk up from file
        var url = URL(fileURLWithPath: filePath)
        for _ in 0..<3 { url.deleteLastPathComponent() }
        return url.path + "/"
    }

    private func readSource(_ relativePath: String) -> String {
        let fullPath = Self.repoRoot + relativePath
        return (try? String(contentsOfFile: fullPath, encoding: .utf8)) ?? ""
    }

    // MARK: - LibraryView

    @Test func libraryViewDoesNotContainSearchable() {
        let source = readSource("MLM/Views/Library/LibraryView.swift")
        #expect(!source.contains(".searchable"),
                "LibraryView should not contain .searchable — the toolbar search field in ContentView is the single entry point")
    }

    // MARK: - PlaylistDetailView

    @Test func playlistDetailViewDoesNotContainSearchTracks() {
        let source = readSource("MLM/Views/Playlists/PlaylistDetailView.swift")
        #expect(!source.contains("Search tracks"),
                "PlaylistDetailView should not contain 'Search tracks' — the inline search field was removed")
    }

    // MARK: - ContentView

    @Test func toolbarSearchContainsOnSubmit() {
        let source = readSource("MLM/Views/Shell/ShellSearch.swift")
        #expect(source.contains(".onSubmit"),
                "The shell's toolbar search field should contain .onSubmit")
    }

    @Test func contentViewDoesNotContainGlobalSearchQuery() {
        let source = readSource("MLM/Views/ContentView/ContentView.swift")
        #expect(!source.contains("globalSearchQuery"),
                "ContentView should not contain 'globalSearchQuery' — replaced by SearchCoordinator")
    }
}
