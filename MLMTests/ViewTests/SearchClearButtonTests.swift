import Testing
import Foundation

/// Source-scan tests for the toolbar search field. Since W1-1 it is the system `.searchable`
/// field (its clear button is the system's); clearing resets the query, dismisses the search
/// pane, and leaving a place drops focus.
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
    func shell_usesTheSystemSearchField() throws {
        let src = try readSource(Self.searchPath)
        #expect(src.contains(".searchable(text:"),
                "The toolbar search field is the system .searchable field (UC-SEARCH-01)")
    }

    // MARK: - Clearing

    @Test
    func clearing_callsDismiss() throws {
        let src = try readSource(Self.searchPath)
        #expect(src.contains("coordinator.dismiss()"),
                "Clearing the field must dismiss the search pane")
    }

    @Test
    func clearing_resetsQuery() throws {
        let src = try readSource(Self.searchPath)
        #expect(src.contains("coordinator.query = \"\""),
                "Clearing the field must reset SearchCoordinator.query to an empty string")
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
