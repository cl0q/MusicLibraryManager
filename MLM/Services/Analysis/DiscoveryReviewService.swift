import Foundation

struct DeleteRecovery: Sendable {
    let trackID: Int64
    let originalURL: URL
    let trashedURL: URL
}

/// Shared accept/delete behavior for Discover and the Similar sheet.
/// Keeping this here prevents the two surfaces from evolving different
/// persistence and file-removal semantics.
final class DiscoveryReviewService: @unchecked Sendable {
    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository
    nonisolated(unsafe) private(set) var lastDeleteRecovery: DeleteRecovery?

    var trashFile: @Sendable (URL) throws -> URL
    var deleteFromDatabase: @Sendable (Int64) async throws -> Void

    init(
        trackRepository: TrackRepository,
        configRepository: ConfigRepository,
        trashFile: (@Sendable (URL) throws -> URL)? = nil,
        deleteFromDatabase: (@Sendable (Int64) async throws -> Void)? = nil
    ) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
        self.trashFile = trashFile ?? { url in
            var resultingURL: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
            guard let resultingURL else { throw CocoaError(.fileWriteUnknown) }
            return resultingURL as URL
        }
        self.deleteFromDatabase = deleteFromDatabase ?? { id in
            try await trackRepository.delete(id: id)
        }
    }

    func accept(track: Track, seedTrackID: Int64?, source: String) async throws {
        guard let trackID = track.id else { return }

        try await trackRepository.updateDiscoveryStatus(discoveredTrackId: trackID, status: "approved")
        if let seedTrackID {
            try await trackRepository.saveSimilarityFeedback(
                seedTrackId: seedTrackID,
                targetTrackId: trackID,
                feedbackValue: 1
            )
            let pullRate: Float = source.lowercased() == "soundcloud" ? 0.05 : 0.01
            try await trackRepository.applyVectorGravity(
                seedTrackId: seedTrackID,
                targetTrackId: trackID,
                pullRate: pullRate
            )
        }
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    func delete(track: Track) async throws {
        guard let trackID = track.id else { return }

        if let fileURL = try await localFileURL(for: track),
           FileManager.default.fileExists(atPath: fileURL.path) {
            let trashedURL = try trashFile(fileURL)
            lastDeleteRecovery = DeleteRecovery(trackID: trackID, originalURL: fileURL, trashedURL: trashedURL)
        }
        try await deleteFromDatabase(trackID)
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    private func localFileURL(for track: Track) async throws -> URL? {
        if let organizedPath = track.organizedPath, !organizedPath.isEmpty {
            if (organizedPath as NSString).isAbsolutePath {
                return URL(fileURLWithPath: organizedPath)
            }
            if let root = try await configRepository.getLibraryRoot(), !root.isEmpty {
                return URL(fileURLWithPath: root).appendingPathComponent(organizedPath)
            }
        }

        guard (track.originalPath as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: track.originalPath)
    }
}
