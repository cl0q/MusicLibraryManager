import Foundation

/// A single search hit from a remote source, normalized for the global
/// cross-source search UI.
struct RemoteSearchResult: Identifiable, Hashable {
    enum Source: String, CaseIterable {
        case soundcloud = "SoundCloud"
        case spotify = "Spotify"
        case youtube = "YouTube"
        case dab = "DAB"

        /// Which download source a hit from this origin should be pinned to.
        var preferredSource: DownloadOrchestrator.PreferredSource {
            switch self {
            case .soundcloud: return .soundcloud
            case .youtube: return .youtube
            case .spotify, .dab: return .auto
            }
        }

        var icon: String {
            switch self {
            case .soundcloud: return "cloud.fill"
            case .spotify: return "music.note.list"
            case .youtube: return "play.rectangle.fill"
            case .dab: return "waveform"
            }
        }
    }

    let id: String
    let source: Source
    let artist: String
    let title: String
    /// Duration in seconds, if known.
    let durationSeconds: Int?
    /// External ID within the source (track id / video id).
    let externalId: String
    /// A downloadable/reference URL when the source provides one
    /// (SoundCloud permalink, YouTube watch URL). Nil for search-only
    /// metadata (Spotify/DAB → resolved via the fallback chain).
    let sourceURL: String?
}
