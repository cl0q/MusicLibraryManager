import Foundation
import Observation

// MARK: - S-QUICKADD: Add from Link (DEC-018, UC-SEARCH-05, import.html)

/// What Add from Link needs from the app; faked in tests (no network).
@MainActor
struct QuickAddEnvironment {
    /// What a link is (metadata via yt-dlp, the library track it already is).
    var lookUp: (LinkSuggestion) async -> LinkLookup
    /// The single-track download through `SearchDownloadService` (one Activity operation).
    var download: (LinkSuggestion, LinkMetadata?) async -> SearchDownloadOutcome
    /// Downloads a library track that has no file yet.
    var downloadExisting: (Int64, LinkSource) async -> Void = { _, _ in }
    /// Adds the new track to a playlist (undoable).
    var addToPlaylist: (Int64, Int64) -> Void = { _, _ in }
    /// yt-dlp is installed (YouTube links need it).
    var isYtDlpAvailable: () -> Bool = { true }
    /// A download operation is running or queued (a new one queues, DEC-044).
    var downloadsRunning: () -> Bool = { false }
    var accounts: (any SourceAccountStateReading)?
    /// The library track's facts for `Already in your library` (`Added Mar 14, 2026 · FLAC`).
    var trackFacts: (Int64) async -> (title: String, hasFile: Bool, detail: String?)? = { _ in nil }
    var post: (String, [StatusAction]) -> Void = { _, _ in }
    /// `Show` / `Show in Library`: selects the track in All Tracks (an explicit action).
    var reveal: (Int64) -> Void = { _ in }
    /// `Import…`: hands a playlist link to S-IMPORT step 2.
    var importPlaylist: (LinkSuggestion) -> Void = { _ in }
    var openInBrowser: (URL) -> Void = { _ in }
    var openSettingsSources: () -> Void = {}
    /// Follows an `on.soundcloud.com` share link to its address (`nil`: it doesn't resolve).
    var resolveShortLink: (String) async -> String? = { _ in nil }
    /// The playlists that exist now (`nil`: unknown) — the remembered target is checked.
    var existingPlaylistIDs: () async -> Set<Int64>? = { nil }
    /// Debounce before looking up a typed link.
    var debounce: Duration = .milliseconds(400)
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

/// The small Add from Link sheet: one link, what it is, one primary action.
@MainActor
@Observable
final class QuickAddModel {
    enum Phase: Equatable {
        /// No link in the field.
        case empty
        case lookingUp(LinkSuggestion)
        /// A track MLM can download.
        case track(LinkSuggestion, LinkMetadata?)
        /// The link is a library track (`Already in your library`, or not downloaded yet).
        case inLibrary(LinkSuggestion, trackID: Int64, title: String, hasFile: Bool, detail: String?)
        case playlist(LinkSuggestion, LinkMetadata?)
        case unsupported(LinkSuggestion)
        /// Text that isn't a link at all.
        case notALink
        case toolMissing
        case signInExpired(LinkSource)
        case unavailable(LinkSource)
    }

    var urlText: String = "" {
        didSet { if urlText != oldValue { scheduleDetection() } }
    }
    private(set) var phase: Phase = .empty
    /// `Add to playlist` (None = All Tracks only). Remembered for the session.
    var playlistID: Int64? {
        didSet { Self.lastPlaylistID = playlistID }
    }
    private(set) var isFinished = false
    /// Inline error above the buttons (UC-SHEET-05).
    private(set) var error: String?
    private(set) var isStarting = false

    static var lastPlaylistID: Int64?

    @ObservationIgnored let environment: QuickAddEnvironment
    @ObservationIgnored private var detection: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(environment: QuickAddEnvironment, text: String = "", lookup: LinkLookup? = nil) {
        self.environment = environment
        self.playlistID = Self.lastPlaylistID
        self.urlText = text
        // A remembered playlist that was deleted meanwhile is forgotten (S8).
        if let remembered = playlistID {
            Task {
                if let existing = await environment.existingPlaylistIDs(), !existing.contains(remembered),
                   self.playlistID == remembered {
                    self.playlistID = nil
                }
            }
        }
        if let link = LinkSuggestion.classify(text), let lookup {
            Task { await self.resolve(link, known: lookup) }
        } else if !text.isEmpty {
            detectNow()
        }
    }

    /// `Paste a link to a track or a playlist.…`
    static let emptyText = "Paste a link to a track or a playlist. You can also paste a link into Search or drop it onto the window."
    static let placeholder = "Paste a SoundCloud, YouTube or Spotify link"
    static let footerRemark = "Goes to All Tracks · progress in Activity"

    // MARK: Detection

    private func scheduleDetection() {
        detection?.cancel()
        generation += 1
        let current = generation
        guard let link = LinkSuggestion.classify(urlText) else {
            phase = urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .notALink
            return
        }
        phase = .lookingUp(link)
        let sleep = environment.sleep
        let debounce = environment.debounce
        detection = Task { [weak self] in
            do { try await sleep(debounce) } catch { return }
            guard let self, self.generation == current else { return }
            await self.resolve(link, known: nil)
        }
    }

    /// Return in the field: look the link up again now.
    func detectNow() {
        detection?.cancel()
        generation += 1
        guard let link = LinkSuggestion.classify(urlText) else {
            phase = urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .empty : .notALink
            return
        }
        phase = .lookingUp(link)
        let current = generation
        detection = Task { [weak self] in
            guard let self, self.generation == current else { return }
            await self.resolve(link, known: nil)
        }
    }

    /// Awaits the running lookup (tests).
    func settle() async { await detection?.value }

    private func resolve(_ link: LinkSuggestion, known: LinkLookup?) async {
        let current = generation
        switch link {
        case .unsupported(_, let url):
            // `on.soundcloud.com/…` share links are followed to the real address first (S1).
            if SoundCloudLink.isShortLink(url) {
                phase = .lookingUp(link)
                let resolved = await environment.resolveShortLink(url)
                guard generation == current else { return }
                if let resolved, let real = LinkSuggestion.classify(resolved), real.source != nil {
                    await resolve(real, known: nil)
                    return
                }
            }
            phase = .unsupported(link)
            return
        case .track(let source, _), .playlist(let source, _):
            if source == .youtube, !environment.isYtDlpAvailable() {
                phase = .toolMissing
                return
            }
            phase = .lookingUp(link)
            let lookup: LinkLookup
            if let known { lookup = known } else { lookup = await environment.lookUp(link) }
            guard generation == current else { return }
            if case .playlist = link {
                phase = .playlist(link, lookup.metadata)
                return
            }
            if let id = lookup.libraryTrackID {
                let facts = await environment.trackFacts(id)
                guard generation == current else { return }
                phase = .inLibrary(link, trackID: id, title: facts?.title ?? lookup.metadata?.title ?? LinkSuggestion.shortURL(link.url),
                                   hasFile: facts?.hasFile ?? true, detail: facts?.detail)
                return
            }
            if lookup.metadata == nil {
                if let service = Self.service(for: source), let accounts = environment.accounts,
                   accounts.state(of: service).needsSignIn {
                    phase = .signInExpired(source)
                    return
                }
                // yt-dlp reads YouTube links; without an answer the video is private or gone.
                // SoundCloud links are downloaded by scdl even when yt-dlp can't read them.
                if source == .youtube {
                    phase = .unavailable(source)
                    return
                }
            }
            phase = .track(link, lookup.metadata)
        }
    }

    static func service(for source: LinkSource) -> TokenStorage.Service? {
        switch source {
        case .soundcloud: .soundcloud
        case .spotify: .spotify
        case .youtube: nil
        }
    }

    // MARK: Primary action

    enum Primary: Equatable {
        case download, showInLibrary, importPlaylist
    }

    /// The primary button for the phase; `nil` = a disabled `Download`.
    var primary: Primary? {
        switch phase {
        case .track: .download
        case .inLibrary(_, _, _, let hasFile, _): hasFile ? .showInLibrary : .download
        case .playlist: .importPlaylist
        default: nil
        }
    }

    var primaryTitle: String {
        switch primary {
        case .showInLibrary: "Show in Library"
        case .importPlaylist: "Import…"
        default: "Download"
        }
    }

    /// `2 downloads are running. This one starts after them.`
    var queuedNote: String? {
        guard primary == .download, environment.downloadsRunning() else { return nil }
        return "Other downloads are running. This one starts after them."
    }

    /// The primary button. A download closes the sheet once it is registered; nothing else in
    /// the window moves (P3).
    func performPrimary() async {
        guard let primary, !isStarting else { return }
        error = nil
        switch (primary, phase) {
        case (.download, .track(let link, let metadata)):
            isStarting = true
            let outcome = await environment.download(link, metadata)
            isStarting = false
            let title = metadata?.title ?? LinkSuggestion.shortURL(link.url)
            switch outcome {
            case .started(let trackID, _):
                // The download announces its own start in the status bar when it starts (Activity,
                // UC-JOB-08) — a queued one when its turn comes; nothing is posted twice here.
                if let playlistID { environment.addToPlaylist(playlistID, trackID) }
                isFinished = true
            case .alreadyInLibrary(let id):
                environment.post(SearchDownloadService.alreadyInLibraryMessage(title), [StatusAction("Show") { [environment] in environment.reveal(id) }])
                isFinished = true
            case .busy:
                error = TrackCommandState.downloadBusyReason
            case .failed(let cause):
                error = SearchDownloadService.failedMessage(cause)
            }
        case (.download, .inLibrary(let link, let trackID, _, _, _)):
            guard let source = link.source else { return }
            await environment.downloadExisting(trackID, source)
            if let playlistID { environment.addToPlaylist(playlistID, trackID) }
            isFinished = true
        case (.showInLibrary, .inLibrary(_, let trackID, _, _, _)):
            environment.reveal(trackID)
            isFinished = true
        case (.importPlaylist, .playlist(let link, _)):
            isFinished = true
            environment.importPlaylist(link)
        default:
            break
        }
    }

    func openInBrowser() {
        if case .unsupported(let link) = phase, let url = URL(string: link.url) {
            environment.openInBrowser(url)
        }
    }

    func cancel() {
        detection?.cancel()
        isFinished = true
    }
}
