import Testing
import Foundation

/// Source-scan tests verifying the global search bar has a clear (x) button
/// that resets query, dismisses search, and clears focus.
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

    private static let contentViewPath = "MLM/Views/ContentView/ContentView.swift"

    // MARK: - Clear button presence

    @Test
    func contentView_containsSearchClearButton() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("search_clear_button"),
                "ContentView must contain the search_clear_button accessibility identifier")
    }

    @Test
    func contentView_containsXmarkCircleFillIcon() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("xmark.circle.fill"),
                "ContentView search clear button must use xmark.circle.fill icon")
    }

    // MARK: - Three-part clear action

    @Test
    func contentView_clearButton_callsDismiss() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("searchCoordinator.dismiss()"),
                "Clear button action must call searchCoordinator.dismiss()")
    }

    @Test
    func contentView_clearButton_resetsQuery() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("searchCoordinator.query = \"\""),
                "Clear button action must reset searchCoordinator.query to empty string")
    }

    @Test
    func contentView_clearButton_resetsFocus() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("isGlobalSearchFocused = false"),
                "Clear button action must set isGlobalSearchFocused to false")
    }

    // MARK: - Existing search elements preserved

    @Test
    func contentView_stillContainsSearchField() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains("search_field"),
                "ContentView must still contain the search_field accessibility identifier")
    }

    @Test
    func contentView_stillContainsOnSubmit() throws {
        let src = try readSource(Self.contentViewPath)
        #expect(src.contains(".onSubmit"),
                "ContentView must still contain .onSubmit for the search field")
    }
}
