import Foundation

/// Persistent retry queue for failed downloads.
///
/// Mirrors the Rust `RetryQueue`. Stores failed download attempts as
/// JSON at `{flacDir}/.retry_queue.json` with atomic writes.
final class DownloadQueue {

    struct QueueItem: Codable, Identifiable {
        var id: String { "\(trackId)-\(source)" }
        let trackId: Int64
        let query: String
        let source: String  // "dab", "youtube", "soundcloud"
        var attemptCount: Int
        var lastError: String?
        let queuedAt: String

        enum CodingKeys: String, CodingKey {
            case trackId = "track_id"
            case query, source
            case attemptCount = "attempt_count"
            case lastError = "last_error"
            case queuedAt = "queued_at"
        }
    }

    private(set) var items: [QueueItem] = []
    private let queuePath: URL
    private let maxAttempts = 3

    init(directory: URL) {
        self.queuePath = directory.appendingPathComponent(".retry_queue.json")
        load()
    }

    // MARK: - Queue Operations

    /// Add a failed download to the retry queue.
    func enqueue(trackId: Int64, query: String, source: String, error: String) {
        // Check if already queued
        if let idx = items.firstIndex(where: { $0.trackId == trackId && $0.source == source }) {
            items[idx].attemptCount += 1
            items[idx].lastError = error
        } else {
            let item = QueueItem(
                trackId: trackId,
                query: query,
                source: source,
                attemptCount: 1,
                lastError: error,
                queuedAt: ISO8601DateFormatter().string(from: Date())
            )
            items.append(item)
        }

        // Remove items exceeding max attempts
        items.removeAll { $0.attemptCount >= maxAttempts }
        save()
    }

    /// Remove a successfully retried item.
    func dequeue(trackId: Int64, source: String) {
        items.removeAll { $0.trackId == trackId && $0.source == source }
        save()
    }

    /// Get items eligible for retry (below max attempts).
    func retryableItems() -> [QueueItem] {
        items.filter { $0.attemptCount < maxAttempts }
    }

    /// Clear the entire queue.
    func clear() {
        items.removeAll()
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: queuePath.path),
              let data = try? Data(contentsOf: queuePath),
              let decoded = try? JSONDecoder().decode([QueueItem].self, from: data) else {
            return
        }
        items = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        // Atomic write: temp + rename
        let tmpPath = queuePath.appendingPathExtension("tmp")
        do {
            try data.write(to: tmpPath, options: .atomic)
            try FileManager.default.moveItem(at: tmpPath, to: queuePath)
        } catch {
            // Fallback: direct write
            try? data.write(to: queuePath, options: .atomic)
        }
    }
}
