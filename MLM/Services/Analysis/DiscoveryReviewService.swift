import Foundation

/// Shared accept/delete behavior for Discover and the Similar sheet.
/// Keeping this here prevents the two surfaces from evolving different
/// persistence and file-removal semantics.
final class DiscoveryReviewService: Sendable {
    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository

    init(trackRepository: TrackRepository, configRepository: ConfigRepository) {
        self.trackRepository = trackRepository
        self.configRepository = configRepository
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
            try FileManager.default.removeItem(at: fileURL)
        }
        try await trackRepository.delete(id: trackID)
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
