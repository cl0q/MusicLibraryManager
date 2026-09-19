import Testing
import Foundation
@testable import MLM

@Suite("SearchCoordinatorTests")
@MainActor
struct SearchCoordinatorTests {

    // MARK: - submit / dismiss

    @Test func submitSetsIsPresented() {
        let coordinator = SearchCoordinator()
        #expect(coordinator.isPresented == false)
        coordinator.submit()
        #expect(coordinator.isPresented == true)
    }

    @Test func dismissClearsIsPresented() {
        let coordinator = SearchCoordinator()
        coordinator.submit()
        #expect(coordinator.isPresented == true)
        coordinator.dismiss()
        #expect(coordinator.isPresented == false)
    }

    // MARK: - queryChanged

    @Test func queryChangedWithLocalTableFalseAndNonEmptyQuerySetsPresented() {
        let coordinator = SearchCoordinator()
        coordinator.query = "hello"
        coordinator.queryChanged(hasLocalTable: false)
        #expect(coordinator.isPresented == true)
    }

    @Test func queryChangedWithLocalTableFalseAndEmptyQueryDoesNotPresent() {
        let coordinator = SearchCoordinator()
        coordinator.query = ""
        coordinator.queryChanged(hasLocalTable: false)
        #expect(coordinator.isPresented == false)
    }

    @Test func queryChangedWithLocalTableFalseAndWhitespaceOnlyDoesNotPresent() {
        let coordinator = SearchCoordinator()
        coordinator.query = "   "
        coordinator.queryChanged(hasLocalTable: false)
        #expect(coordinator.isPresented == false)
    }

    @Test func queryChangedWithLocalTableTrueDoesNotPresent() {
        let coordinator = SearchCoordinator()
        coordinator.query = "hello"
        coordinator.queryChanged(hasLocalTable: true)
        #expect(coordinator.isPresented == false)
    }

    @Test func queryChangedWithLocalTableTrueAndEmptyQueryDoesNotPresent() {
        let coordinator = SearchCoordinator()
        coordinator.query = ""
        coordinator.queryChanged(hasLocalTable: true)
        #expect(coordinator.isPresented == false)
    }

    // MARK: - context

    @Test func defaultContextIsLibrary() {
        let coordinator = SearchCoordinator()
        #expect(coordinator.context == .library)
    }

    @Test func contextCanBeSetToPlaylist() {
        let coordinator = SearchCoordinator()
        coordinator.context = .playlist(42)
        #expect(coordinator.context == .playlist(42))
    }

    @Test func contextCanBeSetToOther() {
        let coordinator = SearchCoordinator()
        coordinator.context = .other
        #expect(coordinator.context == .other)
    }

    // MARK: - query binding

    @Test func queryDefaultsToEmpty() {
        let coordinator = SearchCoordinator()
        #expect(coordinator.query.isEmpty)
    }

    @Test func queryCanBeSet() {
        let coordinator = SearchCoordinator()
        coordinator.query = "test"
        #expect(coordinator.query == "test")
    }
}
