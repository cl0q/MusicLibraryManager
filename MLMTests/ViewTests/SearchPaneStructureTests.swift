import Foundation
import Testing

struct SearchPaneStructureTests {

    private static let viewPath: String = {
        let thisFile = #filePath
        let dir = (thisFile as NSString).deletingLastPathComponent
        // MLMTests/ViewTests -> project root
        let projectRoot = (dir as NSString).deletingLastPathComponent
            .components(separatedBy: "/MLMTests").first ?? dir
        return projectRoot + "/MLM/Views/Search/GlobalSearchPresentationView.swift"
    }()

    private static let viewModelPath: String = {
        let thisFile = #filePath
        let dir = (thisFile as NSString).deletingLastPathComponent
        let projectRoot = (dir as NSString).deletingLastPathComponent
            .components(separatedBy: "/MLMTests").first ?? dir
        return projectRoot + "/MLM/ViewModels/GlobalSearchPresentationViewModel.swift"
    }()

    private func read(_ path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - View

    @Test func viewUsesTrackTable() throws {
        let source = try read(Self.viewPath)
        #expect(source.contains("TrackTable("))
    }

    @Test func viewUsesTopAlignment() throws {
        let source = try read(Self.viewPath)
        #expect(source.contains("alignment: .top"))
    }

    @Test func viewUsesSearchResultsTableAccessibilityID() throws {
        let source = try read(Self.viewPath)
        #expect(source.contains("search_results_table"))
    }

    @Test func viewDoesNotContainDownloadArrowIcon() throws {
        let source = try read(Self.viewPath)
        #expect(!source.contains("arrow.down.circle"))
    }

    @Test func viewDoesNotContainLinkMode() throws {
        let source = try read(Self.viewPath)
        #expect(!source.contains("Link"))
    }

    // MARK: - ViewModel

    @Test func viewModelDoesNotContainLinkMode() throws {
        let source = try read(Self.viewModelPath)
        #expect(!source.contains("case link"))
    }

    @Test func viewModelDoesNotContainDownloadingState() throws {
        let source = try read(Self.viewModelPath)
        #expect(!source.contains("downloading"))
    }
}
