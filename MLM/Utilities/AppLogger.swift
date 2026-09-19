import Foundation
import os

/// Application-wide logging service.
///
/// Three sinks per log call:
/// - In-memory ring buffer (last 500 entries) — backs the Activity → Logs tab
/// - `~/Library/Logs/MLM/mlm.log` with rotation at 5 MB (kept: 3 backups)
///   (disabled automatically during test runs; see File-sink gating below)
/// - Apple unified logging (`os.Logger`, subsystem "com.ilczuk.mlm") —
///   appears in Console.app under MLM's subsystem and in Xcode's debug console
///
/// Thread-safe via NSLock around mutable state.
///
/// ## File-sink gating
///
/// When the process is detected as a test harness (XCTest / swift-testing),
/// the on-disk file sink is disabled so `~/Library/Logs/MLM/mlm.log` is not
/// polluted with fixture-driven noise. The in-memory ring buffer and unified
/// logging continue to work normally.
///
/// Detection is evaluated **once** at process start and cached in a static let.
///
/// Override environment variables:
/// - `MLM_LOGGER_FILE_SINK` = `force-on` | `force-off`
///   Forces the file sink on or off regardless of auto-detection.
/// - `MLM_LOGGER_FILE_DIRECTORY` = absolute path
///   Redirects the log directory (only meaningful when file sink is on).
@Observable
final class AppLogger {
    static let shared = AppLogger()

    enum Level: String, Sendable {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    struct LogEntry: Identifiable, Sendable {
        let id = UUID()
        let timestamp: Date
        let level: Level
        let message: String
        let source: String?

        var formattedTime: String {
            Self.formatter.string(from: timestamp)
        }

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()
    }

    /// Maximum number of log entries retained in memory.
    /// File-on-disk (`mlm.log`) keeps the full history beyond this window.
    private static let maxEntries = 5000

    /// Maximum log file size before rotation.
    private static let maxFileSize: UInt64 = 5 * 1024 * 1024  // 5 MB

    /// Number of rotated backup files to keep (mlm.log.1 … mlm.log.N).
    private static let backupCount = 3

    /// Subsystem for unified logging — appears in Console.app's filter.
    private static let subsystem = "com.ilczuk.mlm"

    // MARK: - File-sink gating

    /// Environment variable names for controlling the file sink.
    enum FileSinkEnv {
        /// `"force-on"` or `"force-off"` — overrides auto-detection.
        static let override = "MLM_LOGGER_FILE_SINK"
        /// Absolute path to redirect the log directory (only used when file sink is on).
        static let directory = "MLM_LOGGER_FILE_DIRECTORY"
    }

    /// Pure function: detect whether the process is a test harness.
    ///
    /// Signals checked (any one is sufficient):
    /// 1. `XCTestConfigurationFilePath` — set by `xctest` / `swift test`
    /// 2. `XCTestBundlePath` — set by some Xcode test runners
    /// 3. `__XCODE_BUILT_PRODUCTS_DIR_PATHS` — set during Xcode-driven test runs
    /// 4. `XCTestCase` class loadable via `NSClassFromString` — runtime confirmation
    ///
    /// The `classLookup` parameter exists so tests can supply a stub.
    static func isTestProcess(
        environment: [String: String],
        classLookup: (String) -> Any? = { NSClassFromString($0) }
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil { return true }
        if classLookup("XCTestCase") != nil { return true }
        return false
    }

    /// Resolve the explicit file-sink override from the environment.
    /// Returns `nil` when the variable is unset or has an unrecognised value.
    static func fileSinkOverride(environment: [String: String]) -> Bool? {
        switch environment[FileSinkEnv.override] {
        case "force-on": return true
        case "force-off": return false
        default: return nil
        }
    }

    /// Resolve whether the file sink should be enabled.
    /// Override wins over auto-detection when set.
    static func resolveFileSinkEnabled(
        environment: [String: String],
        classLookup: (String) -> Any? = { NSClassFromString($0) }
    ) -> Bool {
        if let override = fileSinkOverride(environment: environment) {
            return override
        }
        return !isTestProcess(environment: environment, classLookup: classLookup)
    }

    /// Cached result — evaluated exactly once per process.
    @ObservationIgnored static let fileSinkEnabled: Bool = resolveFileSinkEnabled(
        environment: ProcessInfo.processInfo.environment
    )

    // MARK: - Instance state

    private(set) var entries: [LogEntry] = []
    private let lock = NSLock()

    /// Optional sink — wired by ActivityViewModel to mirror entries into UI state.
    var sink: (@Sendable (LogEntry) -> Void)?

    @ObservationIgnored private let fileQueue = DispatchQueue(label: "mlm.applogger.file", qos: .utility)
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let fileSinkActive: Bool
    @ObservationIgnored private lazy var iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    @ObservationIgnored private lazy var loggers: [String: Logger] = [:]
    @ObservationIgnored private let loggerLock = NSLock()

    /// Default initializer — used by `AppLogger.shared`.
    /// Reads environment once (already cached in static lets) and configures
    /// the file sink accordingly. When the file sink is disabled, the log
    /// directory is NOT created.
    private init() {
        self.fileSinkActive = Self.fileSinkEnabled

        if let dirOverride = ProcessInfo.processInfo.environment[FileSinkEnv.directory] {
            self.fileURL = URL(fileURLWithPath: dirOverride).appendingPathComponent("mlm.log")
        } else {
            self.fileURL = Self.makeLogFileURL()
        }

        // Best-effort directory creation — only when the file sink is active.
        if fileSinkActive {
            try? FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
    }

    /// Internal initializer for testing file-sink behaviour with a controlled directory.
    /// Does NOT affect `AppLogger.shared`.
    internal init(fileSinkEnabled: Bool, fileSinkDirectory: URL) {
        self.fileSinkActive = fileSinkEnabled
        self.fileURL = fileSinkDirectory.appendingPathComponent("mlm.log")
        if fileSinkActive {
            try? FileManager.default.createDirectory(
                at: fileSinkDirectory,
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: - Logging API

    /// Log a message at the given level.
    func log(_ message: String, level: Level = .info, source: String? = nil) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message, source: source)

        // Sink 1: in-memory ring buffer (Mutated on Main Thread to avoid SwiftUI observation races)
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.entries.append(entry)
            if self.entries.count > Self.maxEntries {
                self.entries.removeFirst(self.entries.count - Self.maxEntries)
            }
            let sinkCopy = self.sink
            self.lock.unlock()
            sinkCopy?(entry)
        }

        // Sink 2: unified logging → Console.app + Xcode console
        osLogger(for: source).log(level: level.osLogType, "\(message, privacy: .public)")

        // Sink 3: file (async on serial queue, best-effort)
        // Gated: disabled during test runs so ~/Library/Logs/MLM/ stays clean.
        guard fileSinkActive else { return }
        fileQueue.async { [fileURL, iso8601] in
            Self.appendToFile(
                entry: entry,
                fileURL: fileURL,
                timestamp: iso8601.string(from: entry.timestamp)
            )
        }
    }

    func info(_ message: String, source: String? = nil) {
        log(message, level: .info, source: source)
    }

    func warn(_ message: String, source: String? = nil) {
        log(message, level: .warning, source: source)
    }

    func error(_ message: String, source: String? = nil) {
        log(message, level: .error, source: source)
    }

    func debug(_ message: String, source: String? = nil) {
        log(message, level: .debug, source: source)
    }

    /// Clear in-memory entries (does NOT delete the on-disk log file).
    func clear() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            self.entries.removeAll()
            self.lock.unlock()
        }
    }

    /// Absolute path to the current log file (for "Reveal in Finder").
    var logFileURL: URL { fileURL }

    // MARK: - Internals

    /// Cached `os.Logger` per source category. Categories show up as a
    /// filter dimension in Console.app.
    private func osLogger(for source: String?) -> Logger {
        let category = source ?? "default"
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let existing = loggers[category] {
            return existing
        }
        let logger = Logger(subsystem: Self.subsystem, category: category)
        loggers[category] = logger
        return logger
    }

    private static func makeLogFileURL() -> URL {
        let logs = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("MLM")
        return logs.appendingPathComponent("mlm.log")
    }

    /// Append one line to the file. Rotates first if the file is over
    /// `maxFileSize`. Runs on `fileQueue`.
    private static func appendToFile(entry: LogEntry, fileURL: URL, timestamp: String) {
        rotateIfNeeded(fileURL: fileURL)

        let line = "\(timestamp) [\(entry.level.rawValue)] " +
                   (entry.source.map { "[\($0)] " } ?? "") +
                   entry.message + "\n"
        guard let data = line.data(using: .utf8) else { return }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// If the current log file exceeds `maxFileSize`, rename it to
    /// `mlm.log.1` (cascading older backups up to `mlm.log.N`) and start fresh.
    private static func rotateIfNeeded(fileURL: URL) {
        let fm = FileManager.default
        guard
            let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
            let size = attrs[.size] as? UInt64,
            size >= maxFileSize
        else { return }

        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.lastPathComponent  // "mlm.log"

        // Drop the oldest backup.
        let oldest = dir.appendingPathComponent("\(base).\(backupCount)")
        try? fm.removeItem(at: oldest)

        // Cascade .N-1 → .N, .N-2 → .N-1, …, .1 → .2
        for i in stride(from: backupCount - 1, through: 1, by: -1) {
            let from = dir.appendingPathComponent("\(base).\(i)")
            let to = dir.appendingPathComponent("\(base).\(i + 1)")
            if fm.fileExists(atPath: from.path) {
                try? fm.moveItem(at: from, to: to)
            }
        }

        // Current → .1
        let firstBackup = dir.appendingPathComponent("\(base).1")
        try? fm.moveItem(at: fileURL, to: firstBackup)
    }
}

private extension AppLogger.Level {
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default  // OS unified logging has no "warning" — use default
        case .error: return .error
        }
    }
}
