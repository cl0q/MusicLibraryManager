import Foundation

/// State and operations for the toolbar-owned global search presentation.
/// Local results are available immediately; remote sources fan out concurrently
/// only when scope == .allSources.
@Observable
@MainActor
final class GlobalSearchPresentationViewModel {
    struct SourceFailure: Identifiable {
        let source: String
        let message: String

        var id: String { source }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case library = "Library"
        case allSources = "All sources"

        var id: Self { self }
    }

    private(set) var results: [Track] = []
    private(set) var sourceFailures: [SourceFailure] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?

    var context: SearchResultsMerger.Context = .library
    var contextPlaylistID: Int64?
    private(set) var playlistContextTracks: [Track] = []

    private let trackRepository: TrackRepository
    private let playlistRepository: PlaylistRepository?
    private let sourceRepository: SourceRepository
    private let soundCloudClient: SoundCloudClient?
    private let spotifyClient: SpotifyClient?
    private let youtubeDownloader: YouTubeDownloader
    private let dabClient: DABClient?
    private var activeRequest = UUID()

    init(
        soundCloudClient: SoundCloudClient?,
        spotifyClient: SpotifyClient?,
        youtubeDownloader: YouTubeDownloader,
        dabClient: DABClient?,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        playlistRepository: PlaylistRepository? = nil
    ) {
        self.soundCloudClient = soundCloudClient
        self.spotifyClient = spotifyClient
        self.youtubeDownloader = youtubeDownloader
        self.dabClient = dabClient
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.playlistRepository = playlistRepository
    }

    func search(query: String, scope: Scope) async {
        let request = UUID()
        activeRequest = request
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            results = []
            sourceFailures = []
            errorMessage = nil
            playlistContextTracks = []
            return
        }

        isSearching = true
        errorMessage = nil
        results = []
        sourceFailures = []
        defer {
            if activeRequest == request {
                isSearching = false
            }
        }

        // Fetch context tracks (playlist rows if applicable)
        var contextTracks: [Track] = []
        if context == .playlist, let playlistID = contextPlaylistID, let playlistRepository {
            if let tracks = try? await playlistRepository.fetchTracks(playlistId: playlistID) {
                contextTracks = tracks.filter { $0.matches(searchQuery: trimmed) }
            }
        }
        playlistContextTracks = contextTracks

        guard activeRequest == request, !Task.isCancelled else { return }

        // Local search — heavy DB work off the main actor
        let trackRepo = trackRepository
        let localTracks: [Track]
        do {
            localTracks = try await Self.performLocalSearch(trackRepository: trackRepo, query: trimmed)
        } catch {
            guard activeRequest == request else { return }
            errorMessage = "Could not search the library. Try again."
            return
        }

        guard activeRequest == request, !Task.isCancelled else { return }

        // Remote search (only for .allSources)
        var remoteTracks: [Track] = []
        if scope == .allSources {
            let remoteResults = await searchRemoteSources(for: trimmed, request: request)
            guard activeRequest == request, !Task.isCancelled else { return }

            if !remoteResults.isEmpty {
                let materializer = RemoteTrackMaterializer(
                    trackRepository: trackRepository,
                    sourceRepository: sourceRepository
                )
                do {
                    remoteTracks = try await materializer.materialize(remoteResults)
                } catch {
                    guard activeRequest == request else { return }
                    errorMessage = "Could not save remote results. Try again."
                }
            }
        }

        guard activeRequest == request, !Task.isCancelled else { return }

        // Merge off the main actor
        results = await Self.mergeSearchResults(
            contextTracks: contextTracks,
            libraryTracks: localTracks,
            remoteTracks: remoteTracks
        )
    }

    // MARK: - Nonisolated helpers (off-main work)

    nonisolated private static func performLocalSearch(
        trackRepository: TrackRepository,
        query: String
    ) async throws -> [Track] {
        try await trackRepository.search(query: query, limit: 500)
    }

    nonisolated private static func mergeSearchResults(
        contextTracks: [Track],
        libraryTracks: [Track],
        remoteTracks: [Track]
    ) async -> [Track] {
        SearchResultsMerger.merge(
            contextTracks: contextTracks,
            libraryTracks: libraryTracks,
            remoteTracks: remoteTracks
        )
    }

    private func searchRemoteSources(for query: String, request: UUID) async -> [RemoteSearchResult] {
        var allResults: [RemoteSearchResult] = []
        var failures: [SourceFailure] = []

        await withTaskGroup(of: RemoteSourceResult.self) { group in
            if let soundCloudClient {
                group.addTask {
                    do {
                        let results = try await soundCloudClient.search(query: query)
                        return .results(results)
                    } catch {
                        return .failure("SoundCloud", error.localizedDescription)
                    }
                }
            }

            if let spotifyClient {
                group.addTask {
                    do {
                        let results = try await spotifyClient.search(query: query)
                        return .results(results)
                    } catch {
                        return .failure("Spotify", error.localizedDescription)
                    }
                }
            }

            group.addTask {
                do {
                    let entries = try await self.youtubeDownloader.search(query: query)
                    let results = entries.map { entry in
                        RemoteSearchResult(
                            id: "yt-\(entry.id)",
                            source: .youtube,
                            artist: entry.uploader ?? "Unknown",
                            title: entry.title,
                            durationSeconds: entry.durationSeconds,
                            externalId: entry.id,
                            sourceURL: entry.url
                        )
                    }
                    return .results(results)
                } catch {
                    return .failure("YouTube", error.localizedDescription)
                }
            }

            if let dabClient {
                group.addTask {
                    do {
                        let tracks = try await dabClient.searchTracks(query: query)
                        let results = tracks.map { track in
                            RemoteSearchResult(
                                id: "dab-\(track.id)",
                                source: .dab,
                                artist: track.artist,
                                title: track.title,
                                durationSeconds: track.duration.map { Int($0) },
                                externalId: String(track.id),
                                sourceURL: nil
                            )
                        }
                        return .results(results)
                    } catch {
                        return .failure("DAB", error.localizedDescription)
                    }
                }
            }

            for await result in group {
                guard activeRequest == request, !Task.isCancelled else { break }
                switch result {
                case .results(let tracks):
                    allResults.append(contentsOf: tracks)
                case .failure(let source, let message):
                    failures.append(SourceFailure(source: source, message: message))
                }
            }
        }

        if activeRequest == request {
            sourceFailures = failures
        }
        return allResults
    }

    private enum RemoteSourceResult {
        case results([RemoteSearchResult])
        case failure(String, String)
    }
}
