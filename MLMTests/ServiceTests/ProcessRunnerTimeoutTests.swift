import Foundation
import Testing
@testable import MLM

/// Tests for ProcessRunner timeout support.
///
/// All tests are hermetic and offline — they use `/bin/sleep`, `/bin/echo`,
/// and `/bin/sh` only, gated on availability via `ProcessRunner.findExecutable`.
struct ProcessRunnerTimeoutTests {

    // MARK: - Helpers

    private static let sleepAvailable: Bool = {
        ProcessRunner.findExecutable("sleep") != nil
            || FileManager.default.isExecutableFile(atPath: "/bin/sleep")
    }()

    private static let shAvailable: Bool = {
        FileManager.default.isExecutableFile(atPath: "/bin/sh")
    }()

    private static let echoAvailable: Bool = {
        FileManager.default.isExecutableFile(atPath: "/bin/echo")
    }()

    private let sleepPath = "/bin/sleep"
    private let shPath = "/bin/sh"
    private let echoPath = "/bin/echo"

    // MARK: - Basic timeout behavior

    /// A long-running process (`sleep 30`) with a short timeout is killed
    /// and returns promptly with `timedOut == true`.
    @Test
    func longRunningProcessIsKilledOnTimeout() async throws {
        try #require(Self.sleepAvailable, "/bin/sleep required")

        let start = Date()
        let result = try await ProcessRunner.run(
            sleepPath,
            arguments: ["30"],
            timeout: 1.5
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(result.timedOut, "Result should report timedOut == true")
        #expect(!result.isSuccess, "Timed-out result should not be success")
        #expect(elapsed < 5.0,
                "Expected prompt return (\(String(format: "%.2f", elapsed))s), but took too long — timeout may not be working")
    }

    /// Wall-clock time for a timed-out process must be far below the
    /// process's natural duration — otherwise the test passes vacuously
    /// (the process ran to completion).
    @Test
    func timeoutReturnsWellBeforeNaturalDuration() async throws {
        try #require(Self.sleepAvailable, "/bin/sleep required")

        let start = Date()
        _ = try await ProcessRunner.run(
            sleepPath,
            arguments: ["60"],
            timeout: 1.0
        )
        let elapsed = Date().timeIntervalSince(start)

        #expect(elapsed < 10.0,
                "Elapsed \(String(format: "%.2f", elapsed))s — should be ~1s, not 60s")
    }

    /// After a timeout, the spawned process must actually be dead, not
    /// merely abandoned. We verify by spawning a shell that writes its
    /// pid to a file, then checking that pid is gone.
    @Test
    func processIsActuallyDeadAfterTimeout() async throws {
        try #require(Self.shAvailable, "/bin/sh required")

        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlm_timeout_pid_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let script = "echo $$ > '\(pidFile.path)'; exec /bin/sleep 30"
        let result = try await ProcessRunner.run(
            shPath,
            arguments: ["-c", script],
            timeout: 1.0
        )

        #expect(result.timedOut)

        // Read the pid the shell wrote
        guard let pidString = try? String(contentsOf: pidFile).trimmingCharacters(in: .whitespacesAndNewlines),
              let childPid = pid_t(pidString) else {
            Issue.record("Could not read child pid from \(pidFile)")
            return
        }

        // kill(pid, 0) checks existence without sending a signal
        let exists = kill(childPid, 0) == 0
        #expect(!exists,
                "Child process \(childPid) should be gone after timeout + kill")
    }

    // MARK: - No-timeout backward compatibility

    /// With no timeout argument, a fast process returns normally —
    /// `timedOut` is false, exit code is 0, stdout is captured.
    @Test
    func noTimeoutReturnsNormally() async throws {
        try #require(Self.echoAvailable, "/bin/echo required")

        let result = try await ProcessRunner.run(
            echoPath,
            arguments: ["hello"]
        )

        #expect(!result.timedOut, "timedOut should be false when no timeout is set")
        #expect(result.isSuccess, "Exit code should be 0")
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    /// Source compatibility: calling `ProcessRunner.run` without the
    /// timeout parameter compiles and behaves identically to before.
    @Test
    func sourceCompatibilityWithoutTimeoutArg() async throws {
        try #require(Self.echoAvailable, "/bin/echo required")

        // This call must compile without the timeout argument
        let result: ProcessRunner.ProcessResult = try await ProcessRunner.run(
            echoPath,
            arguments: ["compat"]
        )

        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "compat")
        #expect(result.stderr.isEmpty)
    }

    // MARK: - Partial output preservation

    /// Output written to stderr before the timeout fires must survive
    /// in the returned result — partial output is valuable diagnostic evidence.
    @Test
    func partialStderrSurvivesTimeout() async throws {
        try #require(Self.shAvailable, "/bin/sh required")

        let script = "echo 'diagnostic: phase 1 complete' >&2; /bin/sleep 30"
        let result = try await ProcessRunner.run(
            shPath,
            arguments: ["-c", script],
            timeout: 1.5
        )

        #expect(result.timedOut)
        #expect(result.stderr.contains("diagnostic: phase 1 complete"),
                "Partial stderr should be preserved. Got: \(result.stderr)")
    }

    /// Partial stdout written before timeout is also preserved.
    @Test
    func partialStdoutSurvivesTimeout() async throws {
        try #require(Self.shAvailable, "/bin/sh required")

        let script = "echo 'output-before-sleep'; /bin/sleep 30"
        let result = try await ProcessRunner.run(
            shPath,
            arguments: ["-c", script],
            timeout: 1.5
        )

        #expect(result.timedOut)
        #expect(result.stdout.contains("output-before-sleep"),
                "Partial stdout should be preserved. Got: \(result.stdout)")
    }

    // MARK: - Generous timeout does not affect fast processes

    /// A fast process with a generous timeout completes normally —
    /// `timedOut` is false, exit code is 0.
    @Test
    func fastProcessWithGenerousTimeoutIsUnaffected() async throws {
        try #require(Self.echoAvailable, "/bin/echo required")

        let result = try await ProcessRunner.run(
            echoPath,
            arguments: ["fast"],
            timeout: 30.0
        )

        #expect(!result.timedOut)
        #expect(result.isSuccess)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "fast")
    }

    // MARK: - Nonexistent binary

    /// A nonexistent binary still produces the existing error behavior —
    /// it throws, it does NOT return a timed-out result.
    @Test
    func nonexistentBinaryThrowsNotTimeout() async throws {
        let bogusPath = "/nonexistent/binary/\(UUID().uuidString)"

        do {
            _ = try await ProcessRunner.run(
                bogusPath,
                arguments: [],
                timeout: 5.0
            )
            Issue.record("Expected throw for nonexistent binary")
        } catch {
            // Expected — should be a launch error, not a timeout
            // The error should NOT be a timeout
        }
    }

    /// A nonexistent binary without timeout also throws (backward compat).
    @Test
    func nonexistentBinaryThrowsWithoutTimeout() async throws {
        let bogusPath = "/nonexistent/binary/\(UUID().uuidString)"

        do {
            _ = try await ProcessRunner.run(bogusPath, arguments: [])
            Issue.record("Expected throw for nonexistent binary")
        } catch {
            // Expected
        }
    }

    // MARK: - Stress test: many sequential timeout runs

    /// 20 sequential short-timeout runs must complete without hanging,
    /// leaking continuations, or crashing. Total wall time should be
    /// well under 30s.
    @Test
    func manySequentialTimeoutRunsDoNotHang() async throws {
        try #require(Self.sleepAvailable, "/bin/sleep required")

        let count = 20
        let start = Date()

        for i in 0..<count {
            let result = try await ProcessRunner.run(
                sleepPath,
                arguments: ["30"],
                timeout: 0.3
            )
            #expect(result.timedOut, "Run \(i) should time out")
        }

        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 30.0,
                "20 sequential 0.3s timeouts took \(String(format: "%.1f", elapsed))s — expected < 30s (possible continuation leak)")
    }

    // MARK: - ProcessResult member checks

    /// `timedOut` defaults to false for a normal exit.
    @Test
    func timedOutIsFalseForNormalExit() async throws {
        try #require(Self.echoAvailable, "/bin/echo required")

        let result = try await ProcessRunner.run(echoPath, arguments: ["ok"])
        #expect(result.timedOut == false)
    }

    /// `isSuccess` is false for a timed-out process.
    @Test
    func isSuccessIsFalseForTimedOutProcess() async throws {
        try #require(Self.sleepAvailable, "/bin/sleep required")

        let result = try await ProcessRunner.run(
            sleepPath,
            arguments: ["30"],
            timeout: 0.5
        )
        #expect(!result.isSuccess)
        #expect(result.timedOut)
    }

    /// A process killed by signal (non-zero exit) without timeout has
    /// `timedOut == false` but `isSuccess == false`.
    @Test
    func signalDeathWithoutTimeoutIsNotTimedOut() async throws {
        try #require(Self.shAvailable, "/bin/sh required")

        // `kill $$` sends SIGTERM to the shell
        let result = try await ProcessRunner.run(
            shPath,
            arguments: ["-c", "kill $$"]
        )

        #expect(!result.timedOut, "Should not be marked as timed out")
        #expect(!result.isSuccess, "Should not be success (killed by signal)")
    }

    // MARK: - runBinary backward compatibility

    /// runBinary without timeout still works (backward compat).
    @Test
    func runBinaryWithoutTimeoutWorks() async throws {
        try #require(Self.echoAvailable, "/bin/echo required")

        let data = try await ProcessRunner.runBinary(
            echoPath,
            arguments: ["binary-test"]
        )
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(text == "binary-test")
    }

    /// runBinary with a timeout that expires throws (not returns empty data).
    @Test
    func runBinaryThrowsOnTimeout() async throws {
        try #require(Self.sleepAvailable, "/bin/sleep required")

        do {
            _ = try await ProcessRunner.runBinary(
                sleepPath,
                arguments: ["30"],
                timeout: 0.5
            )
            Issue.record("Expected throw on timeout")
        } catch {
            // Expected — runBinary throws on timeout
        }
    }
}
