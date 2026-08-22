import Foundation

/// State and operations for the toolbar-owned global search presentation.
/// It keeps local results available immediately and only fans out to remote
/// services after the user explicitly selects All sources.
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

    enum Mode: String, CaseIterable, Identifiable {
        case search = "Search"
        case link = "Link"

        var id: Self { self }
    }

    private(set) var localResults: [Track] = []
    private(set) var remoteResults: [RemoteSearchResult] = []
    private(set) var sourceFailures: [SourceFailure] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    private(set) var downloading: Set<String> = []

    /// YouTube search is available whenever yt-dlp is installed, even if no
    /// account-backed source is connected.
    var canSearchAllSources: Bool { true }

    private let soundCloudClient: SoundCloudClient?
    private let spotifyClient: SpotifyClient?
    private let youtubeDownloader: YouTubeDownloader
    private let dabClient: DABClient?
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let downloadViewModel: DownloadViewModel
    private var activeRequest = UUID()

    init(
        soundCloudClient: SoundCloudClient?,
        spotifyClient: SpotifyClient?,
        youtubeDownloader: YouTubeDownloader,
        dabClient: DABClient?,
        trackRepository: TrackRepository,
        sourceRepository: SourceRepository,
        downloadViewModel: DownloadViewModel
    ) {
        self.soundCloudClient = soundCloudClient
        self.spotifyClient = spotifyClient
        self.youtubeDownloader = youtubeDownloader
        self.dabClient = dabClient
        self.trackRepository = trackRepository
        self.sourceRepository = sourceRepository
        self.downloadViewModel = downloadViewModel
    }

    func search(query: String, scope: Scope, mode: Mode) async {
        let request = UUID()
        activeRequest = request
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmed.isEmpty else {
            localResults = []
            remoteResults = []
            sourceFailures = []
            errorMessage = nil
            return
        }

        isSearching = true
        errorMessage = nil
        localResults = []
        remoteResults = []
        sourceFailures = []
        defer {
            if activeRequest == request {
                isSearching = false
            }
        }

        if mode == .link {
            await resolveLink(trimmed, request: request)
            return
        }

        do {
            let local = try await trackRepository.search(query: trimmed)
            guard activeRequest == request, !Task.isCancelled else { return }
            localResults = local
        } catch {
            guard activeRequest == request else { return }
            errorMessage = "Could not search the library. Try again."
        }

        guard scope == .allSources, activeRequest == request, !Task.isCancelled else { return }
        await searchRemoteSources(for: trimmed, request: request)
    }

    func download(_ result: RemoteSearchResult) async {
        guard !downloading.contains(result.id) else { return }
        downloading.insert(result.id)
        defer { downloading.remove(result.id) }

        do {
            let sourceName = sourceName(for: result.source)
            let source = try await sourceRepository.upsert(name: sourceName, userId: "search")
            guard let sourceId = source.id else { return }

            let track: Track
            if let existing = try? await trackRepository.fetchTrackByExternalId(
                result.externalId,
                sourceName: sourceName
            ) {
                track = existing
            } else {
                var newTrack = Track(
                    artist: result.artist,
                    album: result.source.rawValue,
                    title: result.title,
                    format: sourceName,
                    originalPath: result.sourceURL ?? "\(sourceName)://\(result.externalId)"
                )
                newTrack.duration = result.durationSeconds
                let inserted = try await trackRepository.insert(newTrack)
                guard let id = inserted.id else { return }
                try await sourceRepository.linkTrackToSource(
                    trackId: id,
                    sourceId: sourceId,
                    externalId: result.externalId
                )
                track = inserted
            }

            await downloadViewModel.downloadTracks(
                [track],
                preferredSource: result.source.preferredSource
            )
        } catch {
            errorMessage = "Download failed: \(error.localizedDescription)"
        }
    }

    private func searchRemoteSources(for query: String, request: UUID) async {
        if let soundCloudClient {
            do {
                let results = try await soundCloudClient.search(query: query)
                guard activeRequest == request, !Task.isCancelled else { return }
                remoteResults.append(contentsOf: results)
            } catch {
                guard activeRequest == request, !Task.isCancelled else { return }
                sourceFailures.append(SourceFailure(source: "SoundCloud", message: error.localizedDescription))
            }
        }

        if let spotifyClient {
            do {
                let results = try await spotifyClient.search(query: query)
                guard activeRequest == request, !Task.isCancelled else { return }
                remoteResults.append(contentsOf: results)
            } catch {
                guard activeRequest == request, !Task.isCancelled else { return }
                sourceFailures.append(SourceFailure(source: "Spotify", message: error.localizedDescription))
            }
        }

        do {
            let entries = try await youtubeDownloader.search(query: query)
            guard activeRequest == request, !Task.isCancelled else { return }
            remoteResults.append(contentsOf: entries.map { entry in
                RemoteSearchResult(
                    id: "yt-\(entry.id)",
                    source: .youtube,
                    artist: entry.uploader ?? "Unknown",
                    title: entry.title,
                    durationSeconds: entry.durationSeconds,
                    externalId: entry.id,
                    sourceURL: entry.url
                )
            })
        } catch {
            guard activeRequest == request, !Task.isCancelled else { return }
            sourceFailures.append(SourceFailure(source: "YouTube", message: error.localizedDescription))
        }

        if let dabClient {
            do {
                let tracks = try await dabClient.searchTracks(query: query)
                guard activeRequest == request, !Task.isCancelled else { return }
                remoteResults.append(contentsOf: tracks.map { track in
                    RemoteSearchResult(
                        id: "dab-\(track.id)",
                        source: .dab,
                        artist: track.artist,
                        title: track.title,
                        durationSeconds: track.duration.map { Int($0) },
                        externalId: String(track.id),
                        sourceURL: nil
                    )
                })
            } catch {
                guard activeRequest == request, !Task.isCancelled else { return }
                sourceFailures.append(SourceFailure(source: "DAB", message: error.localizedDescription))
            }
        }
    }

    private func resolveLink(_ url: String, request: UUID) async {
        guard url.lowercased().hasPrefix("http") else {
            errorMessage = "Paste a valid URL beginning with http."
            return
        }

        do {
            let source = Self.detectSource(from: url)
            let entries = try await youtubeDownloader.fetchURLInfo(url: url)
            guard activeRequest == request, !Task.isCancelled else { return }
            remoteResults = entries.map { entry in
                RemoteSearchResult(
                    id: "link-\(source.rawValue)-\(entry.id)",
                    source: source,
                    artist: entry.uploader ?? "Unknown",
                    title: entry.title,
                    durationSeconds: entry.durationSeconds,
                    externalId: entry.id,
                    sourceURL: entry.url
                )
            }
            if remoteResults.isEmpty {
                errorMessage = "No downloadable items were found at this link."
            }
        } catch {
            guard activeRequest == request, !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }

    private static func detectSource(from url: String) -> RemoteSearchResult.Source {
        url.lowercased().contains("soundcloud.com") ? .soundcloud : .youtube
    }

    private func sourceName(for source: RemoteSearchResult.Source) -> String {
        switch source {
        case .soundcloud: "soundcloud"
        case .spotify: "spotify"
        case .youtube: "youtube"
        case .dab: "dab"
        }
    }
}
