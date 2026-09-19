import Foundation

/// Materializes remote search results into persisted Track rows.
/// Follows the same convention as remote-playlist persistence:
/// - organizedPath is nil (track.isRemote == true)
/// - format stores the source name (e.g. "youtube", "soundcloud")
/// - originalPath stores the sourceURL or a synthetic "source://externalId" URI
/// - track_sources links the track to a source row with the externalId
final class RemoteTrackMaterializer: Sendable {
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository

    init(trackRepository: TrackRepository, sourceRepository: SourceRepository) {
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
    }

    func materialize(_ results: [RemoteSearchResult]) async throws -> [Track] {
        guard !results.isEmpty else { return [] }

        // Pre-resolve distinct sources once per batch (not once per track).
        let distinctSourceNames = Set(results.map { Self.sourceName(for: $0.source) })
        var sourceIds: [String: Int64] = [:]
        for name in distinctSourceNames {
            let source = try await sourceRepository.upsert(name: name, userId: "search")
            if let id = source.id {
                sourceIds[name] = id
            }
        }

        // Parallel per-track work, collecting results by original index.
        let indexedResults = Array(results.enumerated())
        return try await withThrowingTaskGroup(of: (Int, Track?).self) { group in
            for (index, result) in indexedResults {
                group.addTask { [trackRepository, sourceRepository, sourceIds] in
                    let sourceName = Self.sourceName(for: result.source)
                    if let existing = try await trackRepository.fetchTrackByExternalId(
                        result.externalId,
                        sourceName: sourceName
                    ) {
                        return (index, existing)
                    }
                    guard let sourceId = sourceIds[sourceName] else { return (index, nil) }

                    var newTrack = Track(
                        artist: result.artist,
                        album: result.source.rawValue,
                        title: result.title,
                        format: sourceName,
                        originalPath: result.sourceURL ?? "\(sourceName)://\(result.externalId)"
                    )
                    newTrack.duration = result.durationSeconds
                    let inserted = try await trackRepository.insert(newTrack)
                    guard let id = inserted.id else { return (index, nil) }
                    try await sourceRepository.linkTrackToSource(
                        trackId: id,
                        sourceId: sourceId,
                        externalId: result.externalId
                    )
                    return (index, inserted)
                }
            }

            var collected: [(Int, Track)] = []
            collected.reserveCapacity(results.count)
            for try await (index, track) in group {
                if let track { collected.append((index, track)) }
            }
            return collected.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
    }

    private static func sourceName(for source: RemoteSearchResult.Source) -> String {
        switch source {
        case .soundcloud: "soundcloud"
        case .spotify: "spotify"
        case .youtube: "youtube"
        case .dab: "dab"
        }
    }
}
