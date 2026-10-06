import Foundation

/// The app's wiring of `DiscoverModel` and `SimilarModel`: repositories from the container, the
/// download pipeline, the analysis job and the playlist placement of `Keep and Add to Playlist`.
@MainActor
enum DiscoverLive {
    /// `nil` before a library is open.
    static func dependencies(_ container: DependencyContainer, shell: ShellActions?) -> DiscoverModel.Dependencies? {
        guard let manager = container.databaseManager, let tracks = container.trackRepository else { return nil }
        let pool = manager.pool
        return DiscoverModel.Dependencies(
            recommendations: RecommendationRepository(database: pool),
            reelCount: { (try? await container.reelRepository?.fetchAll().count) ?? 0 },
            libraryRoot: { (try? await container.configRepository?.getLibraryRoot()) ?? nil },
            matchPercent: { seedID, trackID in await matchPercent(seedID, trackID, tracks: tracks) },
            postChange: {
                let center = NotificationCenter.default
                // All Tracks reloads (kept ones join it) and the sidebar badge follows.
                center.post(name: .libraryDidImport, object: nil)
                center.post(name: .trackAvailabilityDidChange, object: nil)
            },
            placeInPlaylist: { group, ids, playlistID in
                guard let edits = shell?.edits else { return nil }
                return try await place(group: group, ids: ids, playlistID: playlistID, edits: edits)
            },
            swarm: container.swarmRecommendationService ?? SwarmRecommendationService(),
            startDownload: { recommendation, seed in
                container.downloadViewModel?.downloadDiscoveryTrack(
                    artist: recommendation.artist, title: recommendation.title,
                    soundcloudURL: recommendation.scDownloadUrl, source: recommendation.source,
                    seedTrack: seed, hold: true)
            },
            isAnalysed: { id in
                guard let pool = container.databaseManager?.pool else { return false }
                return (try? await InspectorQueries(database: pool).hasSimilarityAnalysis(trackID: id)) ?? false
            },
            analyse: { track in
                guard let url = await TrackFileLocator.localURL(for: track, container: container) else { return }
                InspectorAnalysis.shared.analyze(track, fileURL: url, container: container)
            },
            fetchTrack: { id in try? await tracks.fetchTrack(id: id) },
            playingTrack: { container.playbackViewModel?.currentTrack },
            isInLibrary: { artist, title in
                ((try? await tracks.fetchTrackByArtistAndTitle(artist: artist, title: title)) ?? nil) != nil
            }
        )
    }

    /// The cosine similarity of two analysed tracks as a percentage.
    static func matchPercent(_ seedID: Int64, _ trackID: Int64, tracks: TrackRepository) async -> Int? {
        guard let seed = (try? await tracks.fetchTrackEmbedding(id: seedID)) ?? nil,
              let other = (try? await tracks.fetchTrackEmbedding(id: trackID)) ?? nil else { return nil }
        let a = seed.masterEmbedding
        let b = other.masterEmbedding
        guard !a.isEmpty, a.count == b.count else { return nil }
        let cosine = VectorMath.cosineSimilarity(a, b)
        return Int((max(0, min(1, cosine)) * 100).rounded())
    }

    /// Add the kept tracks to a playlist as a part of the same undo step.
    static func place(group: UndoGroup, ids: [Int64], playlistID: Int64, edits: ShellEdits) async throws -> String? {
        guard let repository = edits.dependencies.playlists() else { return nil }
        let name = (try? await repository.fetch(id: playlistID))?.name ?? "the playlist"
        let effects = edits.effects
        _ = try await group.perform(
            do: { () async throws -> PlaylistAppendResult in
                let result = try await repository.appendTracksReturningEntries(playlistId: playlistID, trackIds: ids)
                await effects.changed(playlistID, repository: repository)
                return result
            },
            undo: { added in
                try await ShellEdits.undoAppend(added, playlistID: playlistID, name: name, repository: repository, effects: effects)
            },
            redo: { undone in
                try await ShellEdits.redoAppend(undone, playlistID: playlistID, name: name, repository: repository, effects: effects)
            })
        return name
    }
}
