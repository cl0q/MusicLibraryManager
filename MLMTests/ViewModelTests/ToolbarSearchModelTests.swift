import Foundation
import Testing
@testable import MLM

// W1-1 review round, S10.

@Suite("Toolbar search model")
@MainActor
struct ToolbarSearchModelTests {
    private let sleeper = ManualSleeper()

    private func makeModel(_ coordinator: SearchCoordinator, localTable: Bool) -> ToolbarSearchModel {
        let sleeper = self.sleeper
        let model = ToolbarSearchModel(coordinator: coordinator, sleep: { await sleeper.sleep($0) })
        model.hasLocalTable = { localTable }
        return model
    }

    @Test func typingCommitsAfterTheDebounceAndFiltersALocalTable() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator, localTable: true)
        model.text = "techno"
        #expect(coordinator.query == "", "Nothing is committed before the debounce")
        await sleeper.waitForPending(1)
        #expect(await sleeper.durations == [ToolbarSearchModel.debounce])

        let task = model.debounceTask
        await sleeper.releaseAll()
        await task?.value
        #expect(coordinator.query == "techno")
        #expect(!coordinator.isPresented, "A place with its own table filters in place")
    }

    @Test func typingInAPlaceWithoutATableOpensTheSearchPane() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator, localTable: false)
        model.text = "glass"
        await sleeper.waitForPending(1)
        let task = model.debounceTask
        await sleeper.releaseAll()
        await task?.value
        #expect(coordinator.query == "glass")
        #expect(coordinator.isPresented)
    }

    @Test func aNewKeystrokeReplacesThePendingCommit() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator, localTable: true)
        model.text = "gl"
        await sleeper.waitForPending(1)
        let first = model.debounceTask
        model.text = "glass"
        await sleeper.waitForPending(2)
        let second = model.debounceTask
        await sleeper.releaseAll()
        await first?.value
        await second?.value
        #expect(coordinator.query == "glass")
    }

    @Test func mirroringAQueryChangedElsewhereDoesNotCommit() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator, localTable: false)
        model.mirror("from the pane")
        #expect(model.text == "from the pane")
        #expect(model.debounceTask == nil)
        #expect(coordinator.query == "")
        #expect(!coordinator.isPresented)
    }

    @Test func returnCommitsAtOnceAndOpensThePane() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator, localTable: true)
        model.text = "skee"
        model.submit()
        #expect(coordinator.query == "skee")
        #expect(coordinator.isPresented)
        await sleeper.releaseAll()
    }

    @Test func clearingTheFieldDismissesThePane() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator, localTable: false)
        model.text = "x"
        model.submit()
        #expect(coordinator.isPresented)
        model.text = ""
        #expect(coordinator.query == "")
        #expect(!coordinator.isPresented)
        await sleeper.releaseAll()
    }

    @Test func resetLeavesSearchEntirely() async {
        let coordinator = SearchCoordinator()
        let model = makeModel(coordinator, localTable: false)
        model.isPresented = true
        model.text = "y"
        model.submit()
        model.reset()
        #expect(model.text == "")
        #expect(!model.isPresented)
        #expect(coordinator.query == "")
        #expect(!coordinator.isPresented)
        await sleeper.releaseAll()
    }
}
