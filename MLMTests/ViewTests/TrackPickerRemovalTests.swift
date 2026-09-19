import Testing
import Foundation
@testable import MLM

/// Contract for removing the "Add tracks to profile" 12k-row picker sheet and
/// replacing it with a tooltip/hint that points at the library context menu
/// (right-click a track -> "Sync to" submenu).
@Suite("TrackPickerRemovalTests")
struct TrackPickerRemovalTests {

    /// Project root derived from this test file's location
    /// (<root>/MLMTests/ViewTests/TrackPickerRemovalTests.swift).
    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ViewTests
            .deletingLastPathComponent()   // MLMTests
            .deletingLastPathComponent()   // root
    }

    private func source(_ relativePath: String) throws -> String {
        let url = projectRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test func trackAddHintPointsAtContextMenu() {
        let hint = SyncContentSections.trackAddHint
        #expect(!hint.isEmpty)
        let lower = hint.lowercased()
        #expect(lower.contains("context menu") || lower.contains("right-click"))
        // Must name the actual submenu label so users can find it.
        #expect(hint.contains("Sync to"))
    }

    @Test func trackPickerSheetSourceFileIsDeleted() throws {
        let url = projectRoot
            .appendingPathComponent("MLM")
            .appendingPathComponent("Views")
            .appendingPathComponent("Sync")
            .appendingPathComponent("Pickers")
            .appendingPathComponent("TrackPickerSheet.swift")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func syncContentSectionsDropsTrackPickerReferences() throws {
        let src = try source("MLM/Views/Sync/SyncContentSections.swift")
        #expect(!src.contains("TrackPickerSheet"))
        #expect(!src.contains("showTrackPicker"))
    }

    @Test func tracksEmptyStateNoLongerReferencesPlusButton() throws {
        let src = try source("MLM/Views/Sync/SyncContentSections.swift")
        #expect(!src.contains("select the plus button to add tracks"))
    }

    @Test func tracksSurfaceUsesHintInAtLeastTwoPlaces() throws {
        // Definition + at least one user-visible usage (tooltip / empty state).
        let src = try source("MLM/Views/Sync/SyncContentSections.swift")
        let occurrences = src.components(separatedBy: "trackAddHint").count - 1
        #expect(occurrences >= 2)
    }
}
