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
            // Reels that still wait for a verdict: everything but Done (W3-DISC-B, IMP-059).
            reelCount: { (try? await container.reelRepository?.notDoneCount()) ?? 0 },
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

// MARK: - Similar

extension DiscoverLive {
    /// `nil` before a library is open.
    static func similarDependencies(_ container: DependencyContainer) -> SimilarModel.Dependencies? {
        guard let manager = container.databaseManager, let tracks = container.trackRepository,
              let discover = dependencies(container, shell: nil) else { return nil }
        let recommendations = RecommendationRepository(database: manager.pool)
        return SimilarModel.Dependencies(
            fetchTrack: discover.fetchTrack,
            similarInLibrary: { seedID, limit in
                ((try? await tracks.fetchSimilarTracks(seedTrackId: seedID, limit: limit)) ?? []).map { ($0.track, $0.score) }
            },
            isAnalysed: discover.isAnalysed,
            analyse: discover.analyse,
            swarm: discover.swarm,
            startDownload: { recommendation, seed, hold in
                container.downloadViewModel?.downloadDiscoveryTrack(
                    artist: recommendation.artist, title: recommendation.title,
                    soundcloudURL: recommendation.scDownloadUrl, source: recommendation.source,
                    seedTrack: seed, hold: hold)
            },
            pipelineStatus: { recommendation in
                let key = recommendation.scDownloadUrl ?? "\(recommendation.artist) - \(recommendation.title)"
                return container.downloadViewModel?.discoveryStatuses[key]
            },
            placement: { recommendation, seedID in
                await placement(of: recommendation, seedID: seedID, tracks: tracks, recommendations: recommendations)
            }
        )
    }

    /// Where a suggestion already is: a track downloaded for this seed (matched by title, as the
    /// old sheet did), else the same artist and title anywhere in the library. A dismissed one is
    /// nowhere.
    static func placement(
        of recommendation: SwarmRecommendation, seedID: Int64, tracks: TrackRepository,
        recommendations: RecommendationRepository
    ) async -> SimilarModel.OnlineRow.Placement? {
        func normal(_ text: String) -> String { text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
        let wanted = normal(recommendation.title)
        let discovered = (try? await tracks.fetchDiscoveryTracksForSeed(seedTrackId: seedID)) ?? []
        var match = discovered.first { track in
            let title = normal(track.title)
            return title == wanted || title.contains(wanted) || wanted.contains(title)
        }
        if match == nil {
            match = (try? await tracks.fetchTrackByArtistAndTitle(artist: recommendation.artist, title: recommendation.title)) ?? nil
        }
        guard let id = match?.id else { return nil }
        switch (try? await recommendations.statuses(for: [id]))?[id] {
        case RecommendationRepository.Status.waiting: return .held
        case RecommendationRepository.Status.dismissed: return nil
        default: return .library
        }
    }
}
