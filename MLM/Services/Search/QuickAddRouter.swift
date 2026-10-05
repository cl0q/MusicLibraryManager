import AppKit
import Foundation
import Observation

// MARK: - The hand-off from a pasted link to quick add (DEC-018, UC-SEARCH-05)

/// What W3-ADD provides: the S-QUICKADD sheet (a track link: detected item, `Download`,
/// already-in-library stated) and the S-IMPORT sheet (a playlist link, chosen already).
/// Set `QuickAddRouter.shared.presenter` when the sheets exist; until then the router does the
/// interim work itself.
@MainActor
protocol QuickAddPresenting: AnyObject {
    /// Present S-QUICKADD (track) or S-IMPORT (playlist) for `link`. `lookup` is what the
    /// search field already knows about it (`nil` while it was still looking it up).
    func presentQuickAdd(for link: LinkSuggestion, lookup: LinkLookup?)
}

/// The one place a link from the search field goes (the link row, Return on a link).
///
/// **Interim (until W3-ADD sets `presenter`):**
/// - track link → already in the library: shows it in All Tracks; else the single-track
///   download through `SearchDownloadService` with the status-bar line
///   `Download started — “‹title›”`;
/// - playlist link → the existing remote-playlist import (Sources) for that source, with the
///   link filled in and loading; a Spotify playlist (no link field there) opens the Spotify
///   playlists and says so;
/// - other links → `MLM can’t download from this site`.
@MainActor
final class QuickAddRouter {
    static let shared = QuickAddRouter()

    /// W3-ADD's sheets. Weak: the window owns them.
    weak var presenter: (any QuickAddPresenting)?

    /// The interim actions (the window installs them; tests use fakes).
    struct Interim {
        var lookUp: (LinkSuggestion) async -> LinkLookup = { _ in LinkLookup() }
        var download: (LinkSuggestion, LinkMetadata?) async -> SearchDownloadOutcome = { _, _ in .failed("no library is open") }
        var revealInLibrary: @MainActor (Int64) -> Void = { _ in }
        /// Opens the remote-playlist import for a source with the link; `false` when that
        /// import can't take a link (Spotify).
        var importPlaylist: @MainActor (LinkSource, String) -> Bool = { _, _ in false }
        var post: @MainActor (String) -> Void = { _ in }
    }

    var interim = Interim()

    /// The running interim task (tests await it).
    private(set) var task: Task<Void, Never>?

    /// `QuickAddRouter.open(url:)` — the seam named in the plan.
    func open(url: String, lookup: LinkLookup? = nil) {
        guard let link = LinkSuggestion.classify(url) else { return }
        open(link, lookup: lookup)
    }

    func open(_ link: LinkSuggestion, lookup: LinkLookup? = nil) {
        if let presenter {
            presenter.presentQuickAdd(for: link, lookup: lookup)
            return
        }
        let interim = self.interim
        switch link {
        case .track:
            task = Task {
                let known: LinkLookup
                if let lookup { known = lookup } else { known = await interim.lookUp(link) }
                if let id = known.libraryTrackID {
                    interim.revealInLibrary(id)
                    interim.post(SearchDownloadService.alreadyInLibraryMessage(known.metadata?.title ?? LinkSuggestion.shortURL(link.url)))
                    return
                }
                let outcome = await interim.download(link, known.metadata)
                if case .alreadyInLibrary(let id) = outcome { interim.revealInLibrary(id) }
                interim.post(SearchDownloadService.message(
                    for: outcome, title: known.metadata?.title ?? LinkSuggestion.shortURL(link.url)))
            }
        case .playlist(let source, let url):
            if !interim.importPlaylist(source, url) {
                interim.post(Self.spotifyPlaylistMessage)
            }
        case .unsupported:
            interim.post(LinkSuggestion.unsupportedLine)
        }
    }

    static let spotifyPlaylistMessage =
        "Spotify playlists can’t be opened from a link yet — choose the playlist in Spotify Playlists"
}

// MARK: - Link prefill for the remote-playlist import (interim, until W3-ADD's S-IMPORT)

/// A playlist link waiting for the remote-playlist import window of its source: the window
/// fills its link field with it and loads the preview.
@MainActor
@Observable
final class RemotePlaylistLinkRequest {
    static let shared = RemotePlaylistLinkRequest()

    struct Pending: Equatable {
        let id = UUID()
        let source: LinkSource
        let url: String
    }

    private(set) var pending: Pending?

    func request(_ url: String, source: LinkSource) {
        pending = Pending(source: source, url: url)
    }

    /// The waiting link for `source`, once.
    func take(_ source: LinkSource) -> String? {
        guard let pending, pending.source == source else { return nil }
        self.pending = nil
        return pending.url
    }
}
