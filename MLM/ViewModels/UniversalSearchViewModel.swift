import Foundation

/// The current state of the universal search view.
enum UniversalSearchState: Equatable {
    case idle
    case resolving
    case searching
    case resolved(UniversalSearchResult)
    case playlistPreview
    case results
    case error(String)

    static func == (lhs: UniversalSearchState, rhs: UniversalSearchState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.resolving, .resolving), (.searching, .searching),
             (.playlistPreview, .playlistPreview), (.results, .results):
            return true
        case (.resolved(let l), .resolved(let r)):
            return l == r
        case (.error(let l), .error(let r)):
            return l == r
        default:
            return false
        }
    }
}

/// A resolved search result for a URL input.
struct UniversalSearchResult: Equatable {
    let source: ArtworkResolver.Source
    let url: String
    let title: String?
    let artist: String?
    let artworkURL: String?
    let durationSeconds: Int?
}

/// View model for the universal search view.
@Observable
final class UniversalSearchViewModel {
    var query: String = ""
    var state: UniversalSearchState = .idle
    private(set) var textResults: [Track] = []
    private var activeRequest = UUID()

    func submit(_ input: String) async {
        let request = UUID()
        activeRequest = request
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard let action = UniversalSearchRouter.route(trimmed) else {
            return
        }

        switch action {
        case .downloadURL(let source, let url, let artworkURL):
            state = .resolving
            switch source {
            case .youtube:
                // Fetch real metadata from yt-dlp
                var title: String? = nil
                var artist: String? = nil
                var duration: Int? = nil
                let downloader = YouTubeDownloader()
                if downloader.isAvailable {
                    if let entries = try? await downloader.fetchURLInfo(url: url),
                       let entry = entries.first {
                        title = entry.title
                        artist = entry.uploader
                        duration = entry.durationSeconds
                    }
                }
                guard activeRequest == request, !Task.isCancelled else { return }
                let videoID = URLDetector.extractYouTubeVideoID(url)
                let thumb = artworkURL
                    ?? videoID.map { "https://i.ytimg.com/vi/\($0)/maxresdefault.jpg" }
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: title ?? "YouTube Video",
                    artist: artist,
                    artworkURL: thumb,
                    durationSeconds: duration
                ))
            case .soundcloud:
                // Fetch real metadata from SoundCloud API
                var title: String? = nil
                var artist: String? = nil
                var duration: Int? = nil
                var thumb = artworkURL
                if let client = DependencyContainer.shared.soundCloudClient,
                   let track = try? await client.resolveTrack(url: url) {
                    title = track.title
                    artist = track.user?.username
                    duration = track.duration.map { $0 / 1000 }
                    thumb = track.artworkUrl ?? thumb
                }
                guard activeRequest == request, !Task.isCancelled else { return }
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: title ?? "SoundCloud Track",
                    artist: artist,
                    artworkURL: thumb,
                    durationSeconds: duration
                ))
            case .directAudio:
                let filename = (url as NSString).lastPathComponent
                let cleanName = (filename as NSString).deletingPathExtension
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: cleanName,
                    artist: nil,
                    artworkURL: nil,
                    durationSeconds: nil
                ))
            case .genericWeb:
                state = .resolved(UniversalSearchResult(
                    source: source,
                    url: url,
                    title: nil,
                    artist: nil,
                    artworkURL: nil,
                    durationSeconds: nil
                ))
            }

        case .importPlaylist:
            state = .playlistPreview

        case .fetchWebContent(let url):
            state = .resolving
            state = .resolved(UniversalSearchResult(
                source: .genericWeb,
                url: url,
                title: nil,
                artist: nil,
                artworkURL: nil,
                durationSeconds: nil
            ))

        case .searchText:
            state = .searching
        textResults = []
        guard let repository = DependencyContainer.shared.trackRepository else {
            state = .error("Library search is unavailable.")
            return
        }
        do {
            let results = try await repository.search(query: trimmed, limit: 50)
            guard activeRequest == request, !Task.isCancelled else { return }
            textResults = results
            state = .results
        } catch {
            guard activeRequest == request, !Task.isCancelled else { return }
            state = .error("Could not search the library. Please try again.")
        }
        }
    }

    func clear() {
        activeRequest = UUID()
        query = ""
        textResults = []
        state = .idle
    }
}
