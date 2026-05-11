import Foundation
import os

/// Application-wide logging service.
///
/// Three sinks per log call:
/// - In-memory ring buffer (last 500 entries) — backs the Activity → Logs tab
/// - `~/Library/Logs/MLM/mlm.log` with rotation at 5 MB (kept: 3 backups)
/// - Apple unified logging (`os.Logger`, subsystem "com.ilczuk.mlm") —
///   appears in Console.app under MLM's subsystem and in Xcode's debug console
///
/// Thread-safe via NSLock around mutable state.
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
    private static let maxEntries = 500

    /// Maximum log file size before rotation.
    private static let maxFileSize: UInt64 = 5 * 1024 * 1024  // 5 MB

    /// Number of rotated backup files to keep (mlm.log.1 … mlm.log.N).
    private static let backupCount = 3

    /// Subsystem for unified logging — appears in Console.app's filter.
    private static let subsystem = "com.ilczuk.mlm"

    private(set) var entries: [LogEntry] = []
    private let lock = NSLock()

    /// Optional sink — wired by ActivityViewModel to mirror entries into UI state.
    var sink: (@Sendable (LogEntry) -> Void)?

    @ObservationIgnored private let fileQueue = DispatchQueue(label: "mlm.applogger.file", qos: .utility)
    @ObservationIgnored private lazy var fileURL: URL = Self.makeLogFileURL()
    @ObservationIgnored private lazy var iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    @ObservationIgnored private lazy var loggers: [String: Logger] = [:]
    @ObservationIgnored private let loggerLock = NSLock()

    private init() {
        // Best-effort directory creation on first use.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
    }

    // MARK: - Logging API

    /// Log a message at the given level.
    func log(_ message: String, level: Level = .info, source: String? = nil) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message, source: source)

        // Sink 1: in-memory ring buffer
        lock.lock()
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        let sinkCopy = sink
        lock.unlock()
        sinkCopy?(entry)

        // Sink 2: unified logging → Console.app + Xcode console
        osLogger(for: source).log(level: level.osLogType, "\(message, privacy: .public)")

        // Sink 3: file (async on serial queue, best-effort)
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
        lock.lock()
        entries.removeAll()
        lock.unlock()
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
