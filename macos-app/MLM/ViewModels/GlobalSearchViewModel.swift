import Foundation

/// ViewModel for the global cross-source search — fans a query out to all
/// available remote sources concurrently and aggregates the hits.
@Observable
@MainActor
final class GlobalSearchViewModel {

    // MARK: - State

    var query: String = ""
    private(set) var results: [RemoteSearchResult] = []
    private(set) var isSearching = false
    private(set) var errorMessage: String?
    /// External IDs currently being downloaded (for per-row spinners).
    private(set) var downloading: Set<String> = []

    // MARK: - Dependencies

    private let soundCloudClient: SoundCloudClient?
    private let spotifyClient: SpotifyClient?
    private let youtubeDownloader: YouTubeDownloader
    private let dabClient: DABClient?
    private let trackRepository: TrackRepository
    private let sourceRepository: SourceRepository
    private let downloadViewModel: DownloadViewModel

    // MARK: - Init

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

    // MARK: - Search

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            return
        }
        isSearching = true
        errorMessage = nil
        results = []
        defer { isSearching = false }

        // Fan out to every source concurrently; a failing source is skipped
        // rather than failing the whole search.
        await withTaskGroup(of: [RemoteSearchResult].self) { group in
            if let sc = soundCloudClient {
                group.addTask { (try? await sc.search(query: trimmed)) ?? [] }
            }
            if let sp = spotifyClient {
                group.addTask { (try? await sp.search(query: trimmed)) ?? [] }
            }
            let yt = youtubeDownloader
            group.addTask {
                let entries = (try? await yt.search(query: trimmed)) ?? []
                return entries.map { e in
                    RemoteSearchResult(
                        id: "yt-\(e.id)",
                        source: .youtube,
                        artist: e.uploader ?? "Unknown",
                        title: e.title,
                        durationSeconds: e.durationSeconds,
                        externalId: e.id,
                        sourceURL: e.url
                    )
                }
            }
            if let dab = dabClient {
                group.addTask {
                    let tracks = (try? await dab.searchTracks(query: trimmed)) ?? []
                    return tracks.map { t in
                        RemoteSearchResult(
                            id: "dab-\(t.id)",
                            source: .dab,
                            artist: t.artist,
                            title: t.title,
                            durationSeconds: t.duration.map { Int($0) },
                            externalId: String(t.id),
                            sourceURL: nil
                        )
                    }
                }
            }

            var collected: [RemoteSearchResult] = []
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            results = collected
        }

        if results.isEmpty {
            errorMessage = "Keine Treffer gefunden."
        }
    }

    // MARK: - Link resolving

    /// Resolve an arbitrary URL (SoundCloud/YouTube/…) into downloadable
    /// options via yt-dlp metadata extraction. Replaces the results list.
    func resolveLink(_ url: String) async {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased().hasPrefix("http") else {
            errorMessage = "Bitte eine gültige URL einfügen (beginnt mit http)."
            return
        }
        isSearching = true
        errorMessage = nil
        results = []
        defer { isSearching = false }

        let source = Self.detectSource(from: trimmed)
        do {
            let entries = try await youtubeDownloader.fetchURLInfo(url: trimmed)
            results = entries.map { e in
                RemoteSearchResult(
                    id: "link-\(source.rawValue)-\(e.id)",
                    source: source,
                    artist: e.uploader ?? "Unknown",
                    title: e.title,
                    durationSeconds: e.durationSeconds,
                    externalId: e.id,
                    sourceURL: e.url
                )
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        if results.isEmpty && errorMessage == nil {
            errorMessage = "Keine herunterladbaren Inhalte an dieser URL gefunden."
        }
    }

    /// Guess the source from a URL host so downloads use the right backend
    /// (SoundCloud → scdl, everything else → yt-dlp which also handles
    /// arbitrary yt-dlp-supported sites via downloadByURL).
    static func detectSource(from url: String) -> RemoteSearchResult.Source {
        if url.lowercased().contains("soundcloud.com") { return .soundcloud }
        return .youtube
    }

    // MARK: - Download

    /// Persist a search hit as a remote track and start its download,
    /// pinned to the hit's source.
    func download(_ result: RemoteSearchResult) async {
        guard !downloading.contains(result.id) else { return }
        downloading.insert(result.id)
        defer { downloading.remove(result.id) }

        do {
            let sourceName = sourceName(for: result.source)
            let source = try await sourceRepository.upsert(name: sourceName, userId: "search")
            guard let sourceId = source.id else { return }

            // Reuse an existing linked track if we already have it.
            let track: Track
            if let existing = try? await trackRepository.fetchTrackByExternalId(
                result.externalId, sourceName: sourceName
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
            errorMessage = error.localizedDescription
        }
    }

    private func sourceName(for source: RemoteSearchResult.Source) -> String {
        switch source {
        case .soundcloud: return "soundcloud"
        case .spotify: return "spotify"
        case .youtube: return "youtube"
        case .dab: return "dab"
        }
    }
}
