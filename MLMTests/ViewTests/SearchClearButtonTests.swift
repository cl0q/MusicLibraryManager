import Testing
import Foundation

/// Source-scan tests for the toolbar search field. Since W1-1 it is the system `.searchable`
/// field (its clear button is the system's); clearing resets the query and returns the scope to
/// `This view` (W2-I: there is no search pane), and leaving search drops focus.
@Suite("SearchClearButtonTests")
struct SearchClearButtonTests {

    private static var repoRoot: URL {
        let url = URL(fileURLWithPath: #filePath)
        return url
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readSource(_ relativePath: String) throws -> String {
        let url = Self.repoRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static let searchPath = "MLM/Views/Shell/ShellSearch.swift"

    // MARK: - System search field

    @Test
    func shell_usesTheSystemSearchFieldWithTokensScopesAndSuggestions() throws {
        let src = try readSource(Self.searchPath)
        #expect(src.contains(".searchable(") && src.contains("tokens: $model.tokens"),
                "The toolbar search field is the system .searchable field with tokens (UC-SEARCH-01/04)")
        #expect(src.contains(".searchScopes($model.scope, activation: .onSearchPresentation)"), "UC-SEARCH-02")
        #expect(src.contains(".searchSuggestions {"), "UC-SEARCH-04/05")
    }

    // MARK: - Clearing

    /// W2-I: clearing commits the empty filter at once and returns the scope to `This view`
    /// (behaviour in ToolbarSearchModelTests); there is no results pane to dismiss.
    @Test
    func clearing_commitsAtOnceAndEndsTheWiderScope() throws {
        let src = try readSource(Self.searchPath)
        #expect(src.contains("guard hasInput else {"))
        #expect(src.contains("scope = .thisView"))
        #expect(!src.contains("coordinator.dismiss()"), "No pane to dismiss (DEC-017)")
    }

    @Test
    func reset_dropsFocus() throws {
        let src = try readSource(Self.searchPath)
        #expect(src.contains("isPresented = false"),
                "Leaving search must drop the field's focus")
    }

    // MARK: - Return

    @Test
    func shell_containsOnSubmit() throws {
        let src = try readSource(Self.searchPath)
        #expect(src.contains(".onSubmit(of: .search)"),
                "Return in the search field must submit")
    }
}
