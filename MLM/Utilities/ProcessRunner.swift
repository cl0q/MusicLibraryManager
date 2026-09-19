import Foundation
import Darwin

/// Helper for running external CLI processes (ffmpeg, yt-dlp, scdl, fpcalc).
///
/// Wraps Foundation's `Process` class with async/await and stdout/stderr streaming.
final class ProcessRunner {

    /// Thread-safe output buffer for collecting process output.
    private final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()

        func append(_ data: Data) {
            lock.lock()
            buffer.append(data)
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    /// Thread-safe mutable flag, used to record whether a timeout fired
    /// while the continuation is still suspended.
    private final class TimedOutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false

        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    /// Result of a process execution.
    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        /// `true` when the process was killed because it exceeded the timeout.
        /// Always `false` when no timeout was specified (backward compatible).
        let timedOut: Bool
        /// The child's pid. Useful for diagnostics.
        let processIdentifier: pid_t

        var isSuccess: Bool { exitCode == 0 && !timedOut }
    }

    /// Run a CLI process and wait for completion.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable (e.g., "/opt/homebrew/bin/ffmpeg")
    ///   - arguments: Command-line arguments
    ///   - workingDirectory: Optional working directory
    ///   - timeout: Maximum wall-clock seconds to wait. `nil` (default) = no
    ///     timeout — behaves identically to the pre-timeout API. When the
    ///     timeout elapses the child is sent SIGTERM; if it is still running
    ///     2 s later it is escalated to SIGKILL.
    ///   - onOutput: Optional line-by-line stdout callback for progress
    ///   - onStderr: Optional line-by-line stderr callback for progress
    /// - Returns: ProcessResult with exit code, stdout, and stderr
    ///
    /// ### Grandchild limitation
    /// Foundation's `Process` does not expose a way to place the child in its
    /// own process group, so `terminate()` / SIGKILL only reaches the direct
    /// child. If that child spawned grandchildren (e.g. `yt-dlp` → `ffmpeg`),
    /// those may survive as orphans. A real process-group kill would require
    /// replacing `Process` with raw `posix_spawn` + `POSIX_SPAWN_SETPGROUP`;
    /// that is a larger change and is left as a follow-up.
    static func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        onOutput: ((String) -> Void)? = nil,
        onStderr: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = enrichedEnvironment()

        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()

        // Stream stdout — collect all data in thread-safe buffer
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
                if let onOutput = onOutput, let line = String(data: data, encoding: .utf8) {
                    onOutput(line)
                }
            }
        }

        // Stream stderr similarly — yt-dlp writes [download] progress here.
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
                if let onStderr = onStderr, let line = String(data: data, encoding: .utf8) {
                    onStderr(line)
                }
            }
        }

        let timedOutFlag = TimedOutFlag()

        // Wait for process completion using checked continuation and terminationHandler.
        // The terminationHandler is the SOLE resumer of the continuation — the timeout
        // timer only kills the process, which then triggers terminationHandler naturally.
        // This preserves HEAD's exactly-once resumption guarantee.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }

            // Timeout: send SIGTERM, escalate to SIGKILL after grace period.
            // Does NOT resume the continuation — that is terminationHandler's job.
            if let timeout = timeout {
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOutFlag.value = true
                    process.terminate() // SIGTERM
                    // Escalate to SIGKILL if still running after 2 s grace
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        guard process.isRunning else { return }
                        kill(pid, SIGKILL)
                    }
                }
            }
        }

        // Disable readability handlers
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Flush any remaining data in the pipes — preserves partial output
        // captured before a timeout kill.
        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutBuffer.append(remainingStdout)
            if let onOutput = onOutput, let line = String(data: remainingStdout, encoding: .utf8) {
                onOutput(line)
            }
        }

        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrBuffer.append(remainingStderr)
            if let onStderr = onStderr, let line = String(data: remainingStderr, encoding: .utf8) {
                onStderr(line)
            }
        }

        let didTimeout = timedOutFlag.value

        if didTimeout, let t = timeout {
            let exeName = URL(fileURLWithPath: executable).lastPathComponent
            AppLogger.shared.log(
                "Process '\(exeName)' (pid \(process.processIdentifier)) timed out after \(t)s — killed",
                level: .error,
                source: "ProcessRunner"
            )
        }

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutBuffer.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.data, encoding: .utf8) ?? "",
            timedOut: didTimeout,
            processIdentifier: process.processIdentifier
        )
    }

    /// Run a CLI process and return the raw stdout binary Data.
    /// Useful for reading audio streams decodes (PCM) without UTF-8 corruption.
    ///
    /// ### Grandchild limitation
    /// See `run(_:arguments:workingDirectory:timeout:onOutput:onStderr:)`.
    static func runBinary(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = enrichedEnvironment()

        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }

        let stdoutPipe = Pipe()
        // Divert standard error to a separate pipe so it doesn't pollute standard output
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutBuffer = OutputBuffer()
        let stderrBuffer = OutputBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }

        // Drain/collect stderr to prevent blocking/deadlocks when the OS buffer fills up (finite capacity)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stderrBuffer.append(data)
            }
        }

        let timedOutFlag = TimedOutFlag()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }

            if let timeout = timeout {
                let pid = process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    guard process.isRunning else { return }
                    timedOutFlag.value = true
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                        guard process.isRunning else { return }
                        kill(pid, SIGKILL)
                    }
                }
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutBuffer.append(remainingStdout)
        }

        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrBuffer.append(remainingStderr)
        }

        let didTimeout = timedOutFlag.value

        if didTimeout, let t = timeout {
            let exeName = URL(fileURLWithPath: executable).lastPathComponent
            AppLogger.shared.log(
                "Process '\(exeName)' (pid \(process.processIdentifier)) timed out after \(t)s — killed",
                level: .error,
                source: "ProcessRunner"
            )
            let stderrString = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
            throw NSError(
                domain: "ProcessRunner",
                code: -1,
                userInfo: [
                    NSLocalizedDescriptionKey: "Binary '\(exeName)' timed out after \(t)s",
                    "stderr": stderrString
                ]
            )
        }

        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let stderrString = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
            AppLogger.shared.log("Binary '\(executable)' failed with exit code \(exitCode). stderr: \(stderrString)", level: .error, source: "ProcessRunner")
            throw NSError(
                domain: "ProcessRunner",
                code: Int(exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: "Binary '\(URL(fileURLWithPath: executable).lastPathComponent)' failed with exit code \(exitCode): \(stderrString.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "stderr": stderrString
                ]
            )
        }

        return stdoutBuffer.data
    }

    /// Parse a yt-dlp / scdl progress line for a percentage 0...1.
    ///
    /// yt-dlp emits lines like `[download]  93.1% of ~ 4.89MiB at ...`
    /// to stderr; the regex grabs the first decimal percentage on the
    /// line. Returns nil when the line carries no progress.
    static func parseProgressPercent(_ line: String) -> Double? {
        guard line.contains("[download]") else { return nil }
        guard let percentRange = line.range(of: #"\d+(\.\d+)?%"#, options: .regularExpression) else {
            return nil
        }
        let token = line[percentRange].dropLast()  // strip '%'
        guard let value = Double(token) else { return nil }
        return min(max(value / 100.0, 0), 1)
    }

    /// Build the environment dictionary passed to child processes.
    ///
    /// macOS apps launched via `open` inherit a stripped PATH from launchd
    /// (`/usr/bin:/bin:/usr/sbin:/sbin`). Subprocesses like scdl that shell
    /// out to yt-dlp / ffmpeg for client_id resolution would then fail
    /// silently and fall back to internal defaults that frequently return
    /// HTTP 403 from SoundCloud.
    ///
    /// We start from the parent process environment and prepend the bin
    /// directories we already use in findExecutable so child tools can
    /// locate each other on the same machine where the user installed them.
    ///
    /// **Thread-safety**: The environment is computed exactly once and cached.
    /// `ProcessInfo.processInfo.environment` is not safe to call concurrently
    /// from many threads (the returned dictionary's copy-on-write storage can
    /// race), so we eagerly snapshot it on first access behind a lock.
    private static let cachedEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/opt/local/bin",
        ]
        let existing = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existingDirs = Set(existing.split(separator: ":").map(String.init))
        let prepend = extraPaths.filter { !existingDirs.contains($0) }
        if !prepend.isEmpty {
            env["PATH"] = (prepend + [existing]).joined(separator: ":")
        }
        return env
    }()

    private static func enrichedEnvironment() -> [String: String] {
        cachedEnvironment
    }

    /// Find an executable in common locations.
    ///
    /// Searches in this order: app bundle, ~/.local/bin (pip --user installs
    /// land here), /opt/homebrew/bin, /usr/local/bin, /opt/local/bin (MacPorts),
    /// /usr/bin. macOS apps launched via `open` inherit a stripped PATH that
    /// does NOT include user-local bin directories, so we look them up by
    /// absolute path instead of trusting $PATH.
    static func findExecutable(_ name: String) -> String? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name) {
            return bundled.path
        }

        let home = NSHomeDirectory()
        let searchPaths = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]

        for path in searchPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }
}
