import Foundation

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

    /// Result of a process execution.
    struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var isSuccess: Bool { exitCode == 0 }
    }

    /// Run a CLI process and wait for completion.
    ///
    /// - Parameters:
    ///   - executable: Path to the executable (e.g., "/opt/homebrew/bin/ffmpeg")
    ///   - arguments: Command-line arguments
    ///   - workingDirectory: Optional working directory
    ///   - onOutput: Optional line-by-line stdout callback for progress
    /// - Returns: ProcessResult with exit code, stdout, and stderr
    static func run(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
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

        // Wait for process completion using checked continuation and terminationHandler
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
            }
        }

        // Disable readability handlers
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Flush any remaining data in the pipes
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

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdoutBuffer.data, encoding: .utf8) ?? "",
            stderr: String(data: stderrBuffer.data, encoding: .utf8) ?? ""
        )
    }

    /// Run a CLI process and return the raw stdout binary Data.
    /// Useful for reading audio streams decodes (PCM) without UTF-8 corruption.
    static func runBinary(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
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

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {
                stdoutBuffer.append(data)
            }
        }

        // Drain stderr to prevent blocking/deadlocks when the OS buffer fills up (finite capacity)
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }

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
            }
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutBuffer.append(remainingStdout)
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
