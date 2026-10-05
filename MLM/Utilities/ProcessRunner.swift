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

    /// Reads one pipe to end-of-file on its own background queue. Output is
    /// accumulated in order; `finished` is left once EOF has been reached.
    private final class StreamReader: @unchecked Sendable {
        private let handle: FileHandle
        private let buffer = OutputBuffer()
        private let group = DispatchGroup()
        private let onChunk: ((String) -> Void)?

        init(handle: FileHandle, onChunk: ((String) -> Void)? = nil) {
            self.handle = handle
            self.onChunk = onChunk
        }

        func start() {
            group.enter()
            DispatchQueue.global().async { [self] in
                while true {
                    // Empty `availableData` means EOF.
                    let data = handle.availableData
                    if data.isEmpty { break }
                    buffer.append(data)
                    if let onChunk, let line = String(data: data, encoding: .utf8) {
                        onChunk(line)
                    }
                }
                group.leave()
            }
        }

        /// Suspends until EOF was reached or `timeout` seconds passed.
        func waitForEOF(timeout: TimeInterval) async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async { [group] in
                    _ = group.wait(timeout: .now() + timeout)
                    continuation.resume()
                }
            }
        }

        var data: Data { buffer.data }
    }

    /// Coordinates termination and continuation resumption across process
    /// completion, task cancellation, and timeout racing on different threads.
    private final class ProcessCompletion: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var continuation: CheckedContinuation<Void, Error>?
        private var didResume = false
        private var cancellationRequested = false
        private var didTimeout = false

        init(process: Process) {
            self.process = process
        }

        func install(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func didStart() {
            lock.lock()
            let shouldTerminate = cancellationRequested
            lock.unlock()
            if shouldTerminate { requestTermination(timedOut: false) }
        }

        func requestTermination(timedOut: Bool) {
            lock.lock()
            if timedOut && !process.isRunning {
                lock.unlock()
                return
            }
            cancellationRequested = true
            didTimeout = didTimeout || timedOut
            let pid = process.isRunning ? process.processIdentifier : 0
            lock.unlock()

            guard pid > 0 else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.process.isRunning else { return }
                kill(pid, SIGKILL)
            }
        }

        func finish(throwing error: Error? = nil) {
            lock.lock()
            guard !didResume, let continuation else {
                lock.unlock()
                return
            }
            didResume = true
            self.continuation = nil
            lock.unlock()
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }

        var timedOut: Bool {
            lock.lock()
            defer { lock.unlock() }
            return didTimeout
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

        // Each stream is read to EOF on its own queue, started before the
        // process runs. stdout/stderr are only returned once both hit EOF.
        let stdoutReader = StreamReader(handle: stdoutPipe.fileHandleForReading, onChunk: onOutput)
        let stderrReader = StreamReader(handle: stderrPipe.fileHandleForReading, onChunk: onStderr)
        stdoutReader.start()
        stderrReader.start()

        let didTimeout = try await waitForExit(process, timeout: timeout) {
            closeWriteEnds(stdoutPipe, stderrPipe)
        }
        let eofBound: TimeInterval = didTimeout ? 2 : 30
        await stdoutReader.waitForEOF(timeout: eofBound)
        await stderrReader.waitForEOF(timeout: eofBound)

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
            stdout: String(data: stdoutReader.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrReader.data, encoding: .utf8) ?? "",
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

        let stdoutReader = StreamReader(handle: stdoutPipe.fileHandleForReading)
        let stderrReader = StreamReader(handle: stderrPipe.fileHandleForReading)
        stdoutReader.start()
        stderrReader.start()

        let didTimeout = try await waitForExit(process, timeout: timeout) {
            closeWriteEnds(stdoutPipe, stderrPipe)
        }
        let eofBound: TimeInterval = didTimeout ? 2 : 30
        await stdoutReader.waitForEOF(timeout: eofBound)
        await stderrReader.waitForEOF(timeout: eofBound)

        if didTimeout, let t = timeout {
            let exeName = URL(fileURLWithPath: executable).lastPathComponent
            AppLogger.shared.log(
                "Process '\(exeName)' (pid \(process.processIdentifier)) timed out after \(t)s — killed",
                level: .error,
                source: "ProcessRunner"
            )
            let stderrString = String(data: stderrReader.data, encoding: .utf8) ?? ""
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
            let stderrString = String(data: stderrReader.data, encoding: .utf8) ?? ""
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

        return stdoutReader.data
    }

    /// Close the parent's write ends of the output pipes (after launch).
    private static func closeWriteEnds(_ pipes: Pipe...) {
        for pipe in pipes { try? pipe.fileHandleForWriting.close() }
    }

    /// Wait for a process while ensuring cancellation and timeout only ever
    /// resume the continuation through the process termination handler.
    private static func waitForExit(
        _ process: Process,
        timeout: TimeInterval?,
        afterLaunch: @escaping () -> Void = {}
    ) async throws -> Bool {
        let completion = ProcessCompletion(process: process)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                completion.install(continuation)
                process.terminationHandler = { _ in
                    completion.finish()
                }
                do {
                    try process.run()
                    // Drop the parent's copies of the write ends so readers see EOF.
                    afterLaunch()
                    completion.didStart()
                } catch {
                    afterLaunch()
                    process.terminationHandler = nil
                    completion.finish(throwing: error)
                    return
                }

                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        completion.requestTermination(timedOut: true)
                    }
                }
            }
        } onCancel: {
            completion.requestTermination(timedOut: false)
        }
        try Task.checkCancellation()
        return completion.timedOut
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
