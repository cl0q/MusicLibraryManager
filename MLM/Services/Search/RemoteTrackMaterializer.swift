import Foundation

/// Materializes remote search results into persisted Track rows.
/// Follows the same convention as remote-playlist persistence:
/// - organizedPath is nil (track.isRemote == true)
/// - format stores the source name (e.g. "youtube", "soundcloud")
/// - originalPath stores the sourceURL or a synthetic "source://externalId" URI
/// - track_sources links the track to a source row with the externalId
final class RemoteTrackMaterializer: Sendable {
    private let sourceRepository: SourceRepository

    init(trackRepository: TrackRepository, sourceRepository: SourceRepository) {
        _ = trackRepository // Preserves the existing construction surface.
        self.sourceRepository = sourceRepository
    }

    func materialize(_ results: [RemoteSearchResult]) async throws -> [Track] {
        guard !results.isEmpty else { return [] }

        // A missing provider identity is deliberately not persisted: without
        // one there is no stable identity for a future materialization to
        // reconcile. Repeated hits in this input are materialized once then
        // expanded back into their original display order.
        var tracksByIdentity: [String: Track] = [:]
        var orderedIdentities: [String] = []
        for result in results {
            let sourceName = Self.sourceName(for: result.source)
            let externalId = result.externalId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !externalId.isEmpty else {
                AppLogger.shared.warn(
                    "Skipped remote search result without provider identity",
                    source: "Search"
                )
                continue
            }
            let identity = "\(sourceName)\u{1F}\(externalId)"
            orderedIdentities.append(identity)
            guard tracksByIdentity[identity] == nil else { continue }

            var newTrack = Track(
                artist: result.artist,
                album: result.source.rawValue,
                title: result.title,
                format: sourceName,
                originalPath: result.sourceURL ?? "\(sourceName)://\(externalId)"
            )
            newTrack.duration = result.durationSeconds
            if let canonical = try await sourceRepository.materializeRemoteTrack(
                newTrack,
                sourceName: sourceName,
                externalId: externalId
            ) {
                tracksByIdentity[identity] = canonical
            }
        }
        return orderedIdentities.compactMap { tracksByIdentity[$0] }
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
