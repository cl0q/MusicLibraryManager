import Foundation
import Testing
@testable import MLM

@Suite("Inaccessible token backoff schedule")
struct TokenRefreshBackoffTests {

    @Test func intervalProgression() {
        var backoff = InaccessibleBackoff()
        #expect(backoff.failures == 0)

        backoff.recordFailure()
        #expect(backoff.nextInterval == 60)   // 1st: 60s

        backoff.recordFailure()
        #expect(backoff.nextInterval == 120)  // 2nd: 2min

        backoff.recordFailure()
        #expect(backoff.nextInterval == 300)  // 3rd: 5min

        backoff.recordFailure()
        #expect(backoff.nextInterval == 600)  // 4th: 10min

        backoff.recordFailure()
        #expect(backoff.nextInterval == 1800) // 5th: capped at 30min

        backoff.recordFailure()
        #expect(backoff.failures == 6)
        #expect(backoff.nextInterval == 1800) // stays capped
    }

    @Test func resetOnSuccess() {
        var backoff = InaccessibleBackoff()
        backoff.recordFailure()
        backoff.recordFailure()
        backoff.recordFailure()

        backoff.reset()
        #expect(backoff.failures == 0)

        // Schedule restarts from the beginning after a success.
        backoff.recordFailure()
        #expect(backoff.nextInterval == 60)
    }

    @Test func scheduleConstants() {
        #expect(InaccessibleBackoff.intervals == [60, 120, 300, 600])
        #expect(InaccessibleBackoff.cappedInterval == 1800)
    }
}
