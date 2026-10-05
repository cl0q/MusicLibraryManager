import Foundation
import Testing
@testable import MLM

/// A sleep that only returns when the test releases it — the injectable clock of
/// `StatusBarCenter`.
private actor ManualSleeper {
    private var waiters: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async {
        await withCheckedContinuation { continuation in
            waiters.append((duration, continuation))
        }
    }

    var durations: [Duration] { waiters.map(\.duration) }
    var pendingCount: Int { waiters.count }

    func releaseFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    /// Wait until `count` sleeps are pending.
    func waitForPending(_ count: Int) async {
        while waiters.count < count {
            await Task.yield()
        }
    }
}

@Suite("Status bar center")
@MainActor
struct StatusBarCenterTests {
    private let sleeper = ManualSleeper()

    private func makeCenter(announced: AnnouncementLog? = nil) -> StatusBarCenter {
        let sleeper = self.sleeper
        let announced = announced ?? AnnouncementLog()
        return StatusBarCenter(
            sleep: { duration in await sleeper.sleep(duration) },
            announce: { announced.messages.append($0) }
        )
    }

    @MainActor
    final class AnnouncementLog {
        var messages: [String] = []
    }

    @Test func aMessageShowsForEightSecondsThenTheDefaultReturns() async {
        let log = AnnouncementLog()
        let center = makeCenter(announced: log)
        center.post("Added 3 tracks to “Warm-up”")
        #expect(center.message?.text == "Added 3 tracks to “Warm-up”")
        #expect(log.messages == ["Added 3 tracks to “Warm-up”"], "Messages are announced to VoiceOver")

        await sleeper.waitForPending(1)
        #expect(await sleeper.durations == [.seconds(8)])
        #expect(StatusBarCenter.messageLifetime == .seconds(8))

        await sleeper.releaseAll()
        await center.expiryTask?.value
        #expect(center.message == nil)
    }

    @Test func aNewerMessageReplacesTheCurrentOneAtOnce() async {
        let center = makeCenter()
        center.post("First")
        await sleeper.waitForPending(1)
        center.post("Second")
        #expect(center.message?.text == "Second")
        await sleeper.waitForPending(2)

        // The first message's timer running out must not remove the second message.
        await sleeper.releaseFirst()
        for _ in 0..<20 { await Task.yield() }
        #expect(center.message?.text == "Second")

        await sleeper.releaseAll()
        await center.expiryTask?.value
        #expect(center.message == nil)
    }

    @Test func atMostTwoActionsAndPressingOneRunsItAndClearsTheMessage() async throws {
        let center = makeCenter()
        var undone = false
        center.post(
            "Removed 9 tracks from “Warm-up” — the files stay in the library",
            actions: [.undo { undone = true }, StatusAction("Show") {}, StatusAction("Extra") {}]
        )
        let message = try #require(center.message)
        #expect(message.actions.map(\.title) == ["Undo", "Show"])

        center.perform(message.actions[0])
        #expect(undone)
        #expect(center.message == nil)
        await sleeper.releaseAll()
    }

    @Test func dismissOnlyRemovesTheMessageItNames() async {
        let center = makeCenter()
        let old = center.post("Old")
        center.post("New")
        center.dismiss(old)
        #expect(center.message?.text == "New")
        await sleeper.releaseAll()
    }

    @Test func loadingShowsOnlyAfterThreeHundredMilliseconds() async {
        let center = makeCenter()
        let token = center.beginLoading("Refreshing from SoundCloud…")
        #expect(!center.isLoadingVisible)
        #expect(center.loadingPhase == "Refreshing from SoundCloud…")
        await sleeper.waitForPending(1)
        #expect(await sleeper.durations == [.milliseconds(300)])

        await sleeper.releaseAll()
        await center.loadingRevealTask?.value
        #expect(center.isLoadingVisible)

        center.endLoading(token)
        #expect(!center.isLoadingVisible)
        #expect(center.loadingPhase == nil)
    }

    @Test func fastWorkNeverShowsTheSpinner() async {
        let center = makeCenter()
        let token = center.beginLoading("Reading…")
        await sleeper.waitForPending(1)
        let reveal = center.loadingRevealTask
        center.endLoading(token)
        await sleeper.releaseAll()
        await reveal?.value
        #expect(!center.isLoadingVisible)
    }

    @Test func overlappingLoadsShowUntilTheLastEnds() async {
        let center = makeCenter()
        let first = center.beginLoading("First…")
        let second = center.beginLoading("Second…")
        await sleeper.waitForPending(1)
        await sleeper.releaseAll()
        await center.loadingRevealTask?.value
        #expect(center.isLoadingVisible)
        center.endLoading(second)
        #expect(center.isLoadingVisible)
        #expect(center.loadingPhase == "First…")
        center.endLoading(first)
        #expect(!center.isLoadingVisible)
        center.endLoading(first) // unknown token: ignored
    }
}
