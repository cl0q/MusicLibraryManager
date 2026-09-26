import Foundation
import Testing
@testable import MLM

struct ProcessCancellationTests {
    @Test func cancellationTerminatesRunningChildPromptly() async throws {
        try #require(FileManager.default.isExecutableFile(atPath: "/bin/sleep"))

        let task = Task {
            try? await ProcessRunner.run(
                "/bin/sleep",
                arguments: ["30"],
                timeout: 60
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        await task.value

        #expect(Date().timeIntervalSince(start) < 5,
                "Cancellation should terminate the child instead of waiting for sleep.")
    }
}
