import Foundation
import Testing
@testable import MLM

/// W5-1a G35: A-TRACK-REMOVE-FAILED is a SwiftUI alert with a counted title, the cause, what
/// happened to the rest, and `Show the ‹n› Tracks` / `OK` (UC-SHEET-16).
@Suite("TrackRemovalFailureTests")
@MainActor
struct TrackRemovalFailureTests {
    private func failure(failed: Int, total: Int, removed: Int, cause: String = "“Lexxar” is read-only") -> TrackRemovalFailure {
        let items = (1...failed).map { TrackRemovalFailure.Item(id: Int64($0), label: "A — T\($0)", cause: cause) }
        return .partial(failures: items, total: total, removed: removed)
    }

    @Test func partialRemovalSaysTheCountTheCauseAndWhereTheRestIs() {
        let result = failure(failed: 3, total: 14, removed: 11)
        #expect(result.title == "3 of 14 tracks couldn’t be removed")
        #expect(result.message == "Their files couldn’t be moved to the Trash: “Lexxar” is read-only. The other 11 tracks were removed.")
        #expect(result.showTitle == "Show the 3 Tracks")
        #expect(result.failedIDs == [1, 2, 3])
        #expect(result.details == "A — T1: “Lexxar” is read-only\nA — T2: “Lexxar” is read-only\nA — T3: “Lexxar” is read-only")
    }

    @Test func oneCauseIsNamedOnceAndSeveralAreJoined() {
        let mixed = TrackRemovalFailure.partial(failures: [
            .init(id: 1, label: "a", cause: "x"), .init(id: 2, label: "b", cause: "x"), .init(id: 3, label: "c", cause: "y"),
        ], total: 4, removed: 1)
        #expect(mixed.message == "Their files couldn’t be moved to the Trash: x; y. The other track was removed.")
        #expect(failure(failed: 2, total: 2, removed: 0).message == "Their files couldn’t be moved to the Trash: “Lexxar” is read-only.")
    }

    @Test func aDatabaseFailureSaysTheFilesAreInTheTrash() {
        let result = TrackRemovalFailure.libraryNotUpdated(ids: [4, 5], details: "x")
        #expect(result.title == "2 of 2 tracks couldn’t be removed")
        #expect(result.message == "The library couldn’t be updated. The files are in the Trash and can be put back.")
        #expect(result.showTitle == "Show the 2 Tracks")
    }

    @Test func showingTheTracksSelectsThemInAllTracksAndClosesTheAlert() {
        let center = TrackRemovalFailureCenter()
        let navigation = NavigationModel()
        navigation.select(.albums)
        center.present(failure(failed: 2, total: 3, removed: 1), showsWindow: false)
        center.showTracks(navigation: navigation)
        #expect(navigation.selection == .allTracks)
        #expect(center.pending == nil)
    }

    @Test func theAlertReplacesTheAppKitOne() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let actions = try String(contentsOf: root.appendingPathComponent("MLM/App/Commands/TrackCommandActions.swift"), encoding: .utf8)
        #expect(!actions.contains("NSAlert"))
        #expect(!actions.contains("Could Not Remove All Tracks"))
        #expect(actions.contains("struct TrackRemovalFailureAlert: ViewModifier"))
        let content = try String(contentsOf: root.appendingPathComponent("MLM/Views/ContentView/ContentView.swift"), encoding: .utf8)
        #expect(content.contains(".modifier(TrackRemovalFailureAlert())"))
    }
}
