import Foundation
import Testing
@testable import MLM

/// The redesigned sidebar (UC-SIDE-01…04, W1-1): four system sections, the fixed rows with
/// ⌘1…⌘6, every playlist and sync profile as a row, no Sources / Queue / Settings rows and no
/// pinned-playlists disclosure. Replaces the checks of the old `SidebarSection` enum.
@Suite("Shell information architecture", .serialized)
struct ShellInformationArchitectureTests {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    @Test func sidebarContainsOnlyTheFourDesignedSections() {
        #expect(SidebarSectionID.allCases.map(\.title) == ["Library", "Inbox", "Playlists", "Sync"])
        #expect(SidebarDestination.librarySection.map(\.fixedTitle) == ["All Tracks", "Albums", "Genres", "Folders"])
        #expect(SidebarDestination.inboxSection.map(\.fixedTitle) == ["Discover", "Review"])
    }

    @Test func goShortcutsCoverTheSixFixedRows() {
        #expect(SidebarDestination.numbered.map(\.numberKey) == ["1", "2", "3", "4", "5", "6"])
    }

    @Test func sidebarUsesSystemCollapsibleSectionsAndNoRemovedRows() throws {
        let src = try source("MLM/Views/Sidebar/SidebarView.swift")
        #expect(src.contains(".listStyle(.sidebar)"))
        #expect(src.contains("Section(isExpanded:"))
        #expect(src.contains("LibraryFooter()"))
        for removed in ["\"LIBRARY\"", "\"WORK\"", "SourcesView", "queueFooter", "settingsFooter",
                        "PinnedPlaylistsDisclosure", "MLMFont.sectionLabel", "Circle()"] {
            #expect(!src.contains(removed), "sidebar must not contain \(removed)")
        }
    }

    @Test func pinnedPlaylistsDisclosureIsGone() {
        let path = Self.repoRoot.appendingPathComponent("MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift").path
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func footerOffersTheLibraryMenu() throws {
        let src = try source("MLM/Views/Sidebar/LibraryFooter.swift")
        for item in ["Open Recent", "Open Library…", "New Library…", "Show Library File in Finder", "Library Settings…",
                     " — Not found", " — Not connected"] {
            #expect(src.contains(item), "footer menu misses \(item)")
        }
    }

    @Test func reviewAndDiscoverUseSystemBadges() throws {
        let src = try source("MLM/Views/Sidebar/SidebarView.swift")
        #expect(src.contains(".badge(badgeText(model.discoverCount))"))
        #expect(src.contains(".badge(badgeText(model.reviewCount))"))
        #expect(!src.contains("dup · "))
    }
}
