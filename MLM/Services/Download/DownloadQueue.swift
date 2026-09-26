import Foundation

/// Persistent retry queue for failed downloads.
///
/// Mirrors the Rust `RetryQueue`. Stores failed download attempts as
/// JSON in the managed `Transcode originals` folder with atomic writes.
final class DownloadQueue {

    struct QueueItem: Codable, Identifiable {
        var id: String { "\(trackId)-\(source)" }
        let trackId: Int64
        let query: String
        let source: String  // "dab", "youtube", "soundcloud"
        var artist: String?
        var title: String?
        var attemptCount: Int
        var lastError: String?
        let queuedAt: String
        /// The `PreferredSource.storageKey` this item was originally pinned
        /// to (nil for legacy items or unpinned/auto attempts). Carried
        /// through so `retryFailed()` can rebuild the exact same pin
        /// instead of silently defaulting to `.auto` — see SCDL-01.
        var preferredSource: String?
        /// The SoundCloud permalink URL for pinned SC retries. Optional so
        /// legacy `.retry_queue.json` files (written before this field
        /// existed) still decode without throwing.
        var soundcloudURL: String?
        /// Direct YouTube URL for exact-video retries.
        var youtubeURL: String?

        enum CodingKeys: String, CodingKey {
            case trackId = "track_id"
            case query, source, artist, title
            case attemptCount = "attempt_count"
            case lastError = "last_error"
            case queuedAt = "queued_at"
            case preferredSource = "preferred_source"
            case soundcloudURL = "soundcloud_url"
            case youtubeURL = "youtube_url"
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
    ///
    /// - Parameters:
    ///   - preferredSource: The `PreferredSource.storageKey` this attempt was
    ///     pinned to (nil for unpinned/auto attempts). Carried through so a
    ///     later `retryFailed()` can rebuild the exact same pin — see SCDL-01.
    ///   - soundcloudURL: The SoundCloud permalink URL, when the attempt was
    ///     pinned to SoundCloud.
    func enqueue(
        trackId: Int64,
        query: String,
        source: String,
        error: String,
        artist: String? = nil,
        title: String? = nil,
        preferredSource: String? = nil,
        soundcloudURL: String? = nil,
        youtubeURL: String? = nil
    ) throws {
        let previousItems = items
        // Check if already queued
        if let idx = items.firstIndex(where: { $0.trackId == trackId && $0.source == source }) {
            items[idx].attemptCount += 1
            items[idx].lastError = error
            items[idx].artist = artist ?? items[idx].artist
            items[idx].title = title ?? items[idx].title
            items[idx].preferredSource = preferredSource ?? items[idx].preferredSource
            items[idx].soundcloudURL = soundcloudURL ?? items[idx].soundcloudURL
            items[idx].youtubeURL = youtubeURL ?? items[idx].youtubeURL
        } else {
            let item = QueueItem(
                trackId: trackId,
                query: query,
                source: source,
                artist: artist,
                title: title,
                attemptCount: 1,
                lastError: error,
                queuedAt: ISO8601DateFormatter().string(from: Date()),
                preferredSource: preferredSource,
                soundcloudURL: soundcloudURL,
                youtubeURL: youtubeURL
            )
            items.append(item)
        }

        // Keep capped items on disk. The global batch retry deliberately
        // skips them, but Activity still exposes each one for an explicit
        // retry instead of silently discarding a durable failure.
        do {
            try save()
        } catch {
            items = previousItems
            throw error
        }
    }

    /// Remove a successfully retried item.
    func dequeue(trackId: Int64, source: String) throws {
        let previousItems = items
        items.removeAll { $0.trackId == trackId && $0.source == source }
        do {
            try save()
        } catch {
            items = previousItems
            throw error
        }
    }

    /// Remove successfully persisted retries regardless of their source key.
    func dequeue(trackIds: Set<Int64>) throws {
        guard !trackIds.isEmpty else { return }
        let previousItems = items
        items.removeAll { trackIds.contains($0.trackId) }
        do {
            try save()
        } catch {
            items = previousItems
            throw error
        }
    }

    /// Get items eligible for the legacy global retry control. Capped items
    /// remain available through Activity's per-row Retry action.
    func retryableItems() -> [QueueItem] {
        items.filter { $0.attemptCount < maxAttempts }
    }

    /// Clear the entire queue.
    func clear() throws {
        let previousItems = items
        items.removeAll()
        do {
            try save()
        } catch {
            items = previousItems
            throw error
        }
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

    private func save() throws {
        let data = try JSONEncoder().encode(items)
        try FileManager.default.createDirectory(
            at: queuePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let temporaryPath = queuePath.appendingPathExtension("new")
        let backupName = queuePath.lastPathComponent + ".backup"
        do {
            try? FileManager.default.removeItem(at: temporaryPath)
            try data.write(to: temporaryPath, options: .atomic)
            if FileManager.default.fileExists(atPath: queuePath.path) {
                _ = try FileManager.default.replaceItemAt(
                    queuePath,
                    withItemAt: temporaryPath,
                    backupItemName: backupName,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporaryPath, to: queuePath)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryPath)
            throw error
        }
    }
}
