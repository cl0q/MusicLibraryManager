import Foundation
import Testing
@testable import MLM

struct ConcurrencyLimiterLeakTests {

    private enum TestError: Error { case oops }

    @Test func permitReleasedAfterThrow() async {
        let limiter = ConcurrencyLimiter(maxConcurrency: 1)

        await #expect(throws: TestError.self) {
            try await limiter.run { throw TestError.oops }
        }

        actor Flag {
            var done = false
            func set() { done = true }
        }
        let flag = Flag()

        let worker = Task {
            _ = await limiter.run { 42 }
            await flag.set()
        }

        try? await Task.sleep(for: .seconds(2))
        #expect(await flag.done, "Second run() hung — permit was leaked by the throw")
        worker.cancel()
    }

    @Test func permitAccountingUnderManyFailures() async {
        let limiter = ConcurrencyLimiter(maxConcurrency: 2)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        try await limiter.run { throw TestError.oops }
                    } catch {
                    }
                }
            }
        }

        actor Flag {
            var done = false
            func set() { done = true }
        }
        let flag = Flag()

        let worker = Task {
            _ = await limiter.run { 99 }
            await flag.set()
        }

        try? await Task.sleep(for: .seconds(2))
        #expect(await flag.done, "run() hung after parallel throws drained all permits")
        worker.cancel()
    }

    @Test func successReturnsValue() async {
        let limiter = ConcurrencyLimiter(maxConcurrency: 1)
        let result: Int = await limiter.run { 42 }
        #expect(result == 42)
    }

    @Test func nonThrowingClosureCompilesWithoutTry() async {
        let limiter = ConcurrencyLimiter(maxConcurrency: 1)
        let result: String = await limiter.run { "hello" }
        #expect(result == "hello")
    }
}
