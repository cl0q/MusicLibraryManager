import Foundation

/// Application-wide logging service.
///
/// Collects log entries in-memory for display in the Activity Panel's
/// Logs tab. Thread-safe via actor isolation.
@Observable
final class AppLogger {
    static let shared = AppLogger()

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    struct LogEntry: Identifiable {
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

    private(set) var entries: [LogEntry] = []
    private let lock = NSLock()

    private init() {}

    /// Log a message.
    func log(_ message: String, level: Level = .info, source: String? = nil) {
        let entry = LogEntry(timestamp: Date(), level: level, message: message, source: source)
        lock.lock()
        entries.append(entry)
        if entries.count > Self.maxEntries {
            entries.removeFirst(entries.count - Self.maxEntries)
        }
        lock.unlock()
    }

    /// Clear all log entries.
    func clear() {
        lock.lock()
        entries.removeAll()
        lock.unlock()
    }
}
