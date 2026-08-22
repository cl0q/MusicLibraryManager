import Testing
@testable import MLM

@Suite("Shell information architecture", .serialized)
struct ShellInformationArchitectureTests {
    @Test func sidebarContainsOnlyTheCanonicalTopLevelSections() {
        #expect(SidebarSection.libraryCases.map(\.label) == [
            "Library", "Playlists", "Folders", "Sync", "Sources",
        ])
        #expect(SidebarSection.workCases.map(\.label) == ["Review", "Discover"])
        #expect(SidebarSection.topLevelCases.map(\.label) == [
            "Library", "Playlists", "Folders", "Sync", "Sources", "Review", "Discover",
        ])
    }

    @Test func navigateShortcutsCoverEveryTopLevelDestination() {
        #expect(SidebarSection.topLevelCases.map(\.keyboardShortcut) == [
            "1", "2", "3", "4", "5", "6", "7",
        ])
    }

    @Test func reviewAndDiscoverUseTheSpecifiedSymbols() {
        #expect(SidebarSection.review.icon == "doc.on.doc")
        #expect(SidebarSection.discover.icon == "sparkles")
    }
}
