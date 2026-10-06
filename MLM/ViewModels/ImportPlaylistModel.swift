import Foundation
import Observation

// MARK: - S-IMPORT: Import Playlist from Source (DEC-026, THOUGHTS §7.11, import.html)

/// The sources the import sheet lists (step 1), in the design's order.
enum ImportSourceKind: String, CaseIterable, Identifiable, Sendable {
    case soundcloud, spotify, youtube, appleMusic

    var id: String { rawValue }

    var name: String {
        switch self {
        case .soundcloud: "SoundCloud"
        case .spotify: "Spotify"
        case .youtube: "YouTube"
        case .appleMusic: "Apple Music"
        }
    }

    /// The account behind it (`nil`: YouTube needs none).
    var service: TokenStorage.Service? {
        switch self {
        case .soundcloud: .soundcloud
        case .spotify: .spotify
        case .appleMusic: .appleMusic
        case .youtube: nil
        }
    }

    var linkSource: LinkSource? {
        switch self {
        case .soundcloud: .soundcloud
        case .spotify: .spotify
        case .youtube: .youtube
        case .appleMusic: nil
        }
    }

    init?(_ source: LinkSource) {
        switch source {
        case .soundcloud: self = .soundcloud
        case .spotify: self = .spotify
        case .youtube: self = .youtube
        }
    }

    /// Lists the account's playlists (YouTube: links only; Apple Music: not available).
    var listsAccountPlaylists: Bool { self == .soundcloud || self == .spotify }
    /// Takes a pasted playlist link.
    var takesLinks: Bool { self != .appleMusic }

    var linkPlaceholder: String {
        switch self {
        case .soundcloud: "https://soundcloud.com/…/sets/…"
        case .spotify: "https://open.spotify.com/playlist/…"
        case .youtube: "https://www.youtube.com/playlist?list=…"
        case .appleMusic: ""
        }
    }
}

/// What the import sheet needs from the app; faked in tests (no network, temporary database).
@MainActor
struct ImportPlaylistEnvironment {
    var provider: (ImportSourceKind) -> (any RemotePlaylistProvider)?
    var accounts: any SourceAccountStateReading
    var queries: ImportLibraryQueries?
    var makeImporter: () -> PlaylistImporter?
    /// A download operation is running or queued: a new import queues behind it.
    var downloadsRunning: () -> Bool = { false }
    /// `“Liked on SoundCloud” is still importing (12 of 44).` — the running import, for the
    /// queued note on step 3.
    var runningImportSentence: () -> String? = { nil }
    /// Status-bar message (UC-STATUS-05) with its buttons.
    var post: (String, [StatusAction]) -> Void = { _, _ in }
    /// `Show Playlist` (an explicit action; the import itself never navigates, P3).
    var showPlaylist: (Int64) -> Void = { _ in }
    /// yt-dlp is installed (YouTube playlists need it, checked before the user waits, DEC-037).
    var isYtDlpAvailable: () -> Bool = { true }
    /// `Manage Accounts…` / `Open Settings ▸ Sources`.
    var openSettingsSources: () -> Void = {}
    /// The random order for `Random n` (shuffled once per loaded playlist).
    var shuffle: ([Int]) -> [Int] = { $0.shuffled() }
}

/// The import sheet's model (replaces the remote-playlists window's view model). Steps:
/// **Source** (accounts' playlists or a link) → **Preview** (every track with `New` /
/// `In library`, `All · First n · Random n`, `Download now`, `Keep linked to ‹Source›`) →
/// **Confirm**. The commit runs on its own task: closing the sheet (Esc, Cancel) never cancels
/// a running import, and the sheet never shows download progress — that is the playlist's
/// echo and Activity's (DEC-044; fixes PP-SOURCES-03/09).
@MainActor
@Observable
final class ImportPlaylistModel {
    enum Step: Int, Equatable { case source = 1, preview, confirm }

    enum ListPhase: Equatable {
        case idle, loading, loaded
        /// `SoundCloud didn’t answer` — the list couldn't be loaded.
        case failed(String)
    }

    /// Why the preview can't show (step 2).
    enum PreviewProblem: Equatable {
        case didNotAnswer(source: String, detail: String)
        case signInExpired(ImportSourceKind)
        case notConnected(ImportSourceKind)
        case privateOrUnavailable(source: String)
        case toolMissing
        case empty
    }

    enum PreviewPhase: Equatable {
        case idle
        case loading
        case loaded(RemotePlaylistPreview)
        case failed(PreviewProblem)
    }

    enum SelectionMode: String, CaseIterable, Identifiable {
        case all = "All"
        case first = "First n"
        case random = "Random n"
        var id: String { rawValue }
    }

    // MARK: Step 1

    private(set) var step: Step = .source
    var selectedSource: ImportSourceKind = .soundcloud {
        didSet { if oldValue != selectedSource { Task { await loadPlaylistsIfNeeded() } } }
    }
    var linkText = ""
    var playlistFilter = ""
    private(set) var playlists: [ImportSourceKind: [RemotePlaylistSummary]] = [:]
    private(set) var listPhases: [ImportSourceKind: ListPhase] = [:]
    private(set) var importedIDs: [ImportSourceKind: Set<String>] = [:]
    /// An error for the link, under the field; it never replaces the playlist list.
    private(set) var linkError: String?
    /// The playlist chosen in the list (Next enables).
    var selectedPlaylistID: String?

    // MARK: Step 2

    private(set) var previewPhase: PreviewPhase = .idle
    /// The source of the loaded (or loading) preview.
    private(set) var previewSource: ImportSourceKind = .soundcloud
    var selectionMode: SelectionMode = .all
    var count = 20
    private(set) var matches: [String: ImportPreviewMatch] = [:]
    private var randomOrder: [Int] = []
    var target: PlaylistImportTarget = .newPlaylist
    var downloadNow = true
    var keepLinked = true
    var alsoDownloadKnown = false
    /// The playlist already linked to the loaded source playlist (`Already imported`).
    private(set) var existingLinked: (id: Int64, name: String)?
    /// What reloads the preview (`Try Again`, after a sign-in).
    private var lastLoad: (@MainActor () async -> Void)?

    // MARK: Commit

    /// The commit is writing the playlist (seconds); the sheet shows it and closes when done.
    private(set) var isCommitting = false
    /// Inline error above the buttons (UC-SHEET-05).
    private(set) var commitError: String?
    /// The sheet asked to close (after a commit, or Cancel).
    private(set) var isFinished = false
    /// The running commit (tests await it; the sheet never cancels it).
    private(set) var commitTask: Task<Void, Never>?

    @ObservationIgnored let environment: ImportPlaylistEnvironment

    init(environment: ImportPlaylistEnvironment) {
        self.environment = environment
    }

    var accounts: any SourceAccountStateReading { environment.accounts }

    // MARK: - Step 1: sources and playlists

    /// The account state shown under a source row (`Connected`, `Sign-in expired`, …).
    func accountState(_ source: ImportSourceKind) -> SourceAccountState? {
        source.service.map { environment.accounts.state(of: $0) }
    }

    /// The row's second line.
    func sourceSubtitle(_ source: ImportSourceKind) -> String {
        switch source {
        case .youtube: return "Paste a playlist link"
        case .appleMusic: return "Not available yet"
        default: return accountState(source)?.word ?? ""
        }
    }

    /// The visible rows of the selected source's list (filtered).
    var visiblePlaylists: [RemotePlaylistSummary] {
        let all = playlists[selectedSource] ?? []
        let filter = playlistFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return all }
        return all.filter { $0.title.localizedCaseInsensitiveContains(filter) }
    }

    func isImported(_ playlist: RemotePlaylistSummary) -> Bool {
        importedIDs[selectedSource]?.contains(playlist.id) ?? false
    }

    var canGoNextFromSource: Bool {
        selectedPlaylistID != nil || LinkSuggestion.isLink(linkText)
    }

    /// Loads the selected source's account playlists once it is connected.
    func loadPlaylistsIfNeeded() async {
        let source = selectedSource
        guard source.listsAccountPlaylists, let service = source.service,
              environment.accounts.state(of: service).isConnected else { return }
        if case .loaded = listPhases[source] { return }
        if listPhases[source] == .loading { return }
        await loadPlaylists(source)
    }

    /// `Try Again` on the list.
    func loadPlaylists(_ source: ImportSourceKind) async {
        guard let provider = environment.provider(source) else { return }
        listPhases[source] = .loading
        do {
            let list = try await provider.fetchPlaylists()
            playlists[source] = list
            listPhases[source] = .loaded
            if let link = source.linkSource, let queries = environment.queries {
                importedIDs[source] = (try? await queries.importedPlaylistIDs(source: link)) ?? []
            }
        } catch where SourceSignInProblem.isRejectedSignIn(error) {
            if let service = source.service { environment.accounts.markSignInExpired(service) }
            listPhases[source] = .idle
        } catch {
            listPhases[source] = .failed("\(source.name) didn’t answer")
            AppLogger.shared.error("Loading \(source.name) playlists failed: \(error.localizedDescription)", source: "Import")
        }
    }

    /// Next on step 1: the chosen playlist, or the link in the field.
    func next() async {
        switch step {
        case .source:
            if LinkSuggestion.isLink(linkText) {
                await loadLink()
            } else if let id = selectedPlaylistID, let summary = (playlists[selectedSource] ?? []).first(where: { $0.id == id }) {
                await open(summary)
            }
        case .preview:
            guard case .loaded = previewPhase, !selectedTracks.isEmpty else { return }
            step = .confirm
        case .confirm:
            break
        }
    }

    func back() {
        commitError = nil
        switch step {
        case .source: break
        case .preview: step = .source
        case .confirm: step = .preview
        }
    }

    /// A click on a playlist row opens its preview (step 2).
    func open(_ summary: RemotePlaylistSummary) async {
        let source = selectedSource
        selectedPlaylistID = summary.id
        await loadPreview(source: source) { provider in try await provider.fetchPreview(for: summary) }
    }

    /// `Load` / Return in the link field.
    func loadLink() async {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard case .playlist(let linkSource, let url)? = LinkSuggestion.classify(text),
              let source = ImportSourceKind(linkSource) else {
            linkError = Self.notAPlaylistLink
            return
        }
        linkError = nil
        if selectedSource != source { selectedSource = source }
        await loadPreview(source: source) { provider in try await provider.fetchPreview(fromURL: url) }
    }

    static let notAPlaylistLink = "That link isn’t a playlist on SoundCloud, YouTube or Spotify."

    /// Opens step 2 with a playlist link already chosen (a pasted or dropped link, Add from Link).
    func start(with link: LinkSuggestion) async {
        guard case .playlist = link else { return }
        linkText = link.url
        await loadLink()
    }

    /// `Try Again` on step 2 and the reload after a sign-in: the chosen playlist is kept.
    func reloadPreview() async {
        await lastLoad?()
    }

    private func loadPreview(source: ImportSourceKind,
                             fetch: @escaping @MainActor (any RemotePlaylistProvider) async throws -> RemotePlaylistPreview) async {
        lastLoad = { [weak self] in await self?.loadPreview(source: source, fetch: fetch) }
        step = .preview
        previewSource = source
        previewPhase = .loading
        matches = [:]
        existingLinked = nil
        guard let provider = environment.provider(source) else {
            previewPhase = .failed(.didNotAnswer(source: source.name, detail: "The library isn’t open."))
            return
        }
        do {
            let preview = try await fetch(provider)
            await adopt(preview, source: source)
        } catch RemotePlaylistProviderError.notAPlaylistURL {
            // An error for the link belongs under the field (step 1), not in place of the list.
            step = .source
            previewPhase = .idle
            linkError = Self.notAPlaylistLink
        } catch {
            previewPhase = .failed(problem(for: error, source: source))
        }
    }

    private func adopt(_ preview: RemotePlaylistPreview, source: ImportSourceKind) async {
        if let link = source.linkSource, let queries = environment.queries {
            matches = (try? await queries.matches(for: preview.tracks, source: link)) ?? [:]
            existingLinked = try? await queries.linkedPlaylist(source: link, externalID: preview.externalID)
        }
        randomOrder = environment.shuffle(Array(preview.tracks.indices))
        count = min(max(1, count), max(1, preview.tracks.count))
        selectionMode = .all
        if let existingLinked {
            target = .existing(id: existingLinked.id, name: existingLinked.name)
        } else {
            target = .newPlaylist
        }
        keepLinked = true
        downloadNow = true
        alsoDownloadKnown = false
        previewPhase = .loaded(preview)
    }

    private func problem(for error: Error, source: ImportSourceKind) -> PreviewProblem {
        if let providerError = error as? RemotePlaylistProviderError {
            switch providerError {
            case .ytDlpUnavailable: return .toolMissing
            case .emptyPlaylist: return .empty
            case .previewUnavailable, .playlistUnavailable, .notAPlaylistURL: return .privateOrUnavailable(source: source.name)
            }
        }
        if SourceSignInProblem.isRejectedSignIn(error), let service = source.service {
            if environment.accounts.state(of: service) == .disconnected { return .notConnected(source) }
            environment.accounts.markSignInExpired(service)
            return .signInExpired(source)
        }
        return .didNotAnswer(source: source.name, detail: error.localizedDescription)
    }

    // MARK: - Step 2: the preview

    var preview: RemotePlaylistPreview? {
        if case .loaded(let preview) = previewPhase { return preview }
        return nil
    }

    /// Exactly the rows that will be imported, in playlist order.
    var selectedTracks: [RemotePlaylistTrack] {
        guard let preview else { return [] }
        let all = preview.tracks
        let n = min(max(1, count), all.count)
        switch selectionMode {
        case .all: return all
        case .first: return Array(all.prefix(n))
        case .random: return randomOrder.prefix(n).sorted().map { all[$0] }
        }
    }

    /// The row numbers (1-based, the playlist's order) of the selected rows.
    var selectedRows: [(number: Int, track: RemotePlaylistTrack)] {
        guard let preview else { return [] }
        let all = preview.tracks
        let n = min(max(1, count), all.count)
        let indices: [Int] = switch selectionMode {
        case .all: Array(all.indices)
        case .first: Array(all.indices.prefix(n))
        case .random: randomOrder.prefix(n).sorted()
        }
        return indices.map { ($0 + 1, all[$0]) }
    }

    func match(_ track: RemotePlaylistTrack) -> ImportPreviewMatch {
        matches[track.externalID] ?? .new
    }

    struct Counts: Equatable {
        var total = 0, new = 0, inLibrary = 0, downloaded = 0
        var known: Int { inLibrary + downloaded }
    }

    var counts: Counts {
        var counts = Counts()
        for track in selectedTracks {
            counts.total += 1
            switch match(track) {
            case .new: counts.new += 1
            case .inLibrary: counts.inLibrary += 1
            case .downloaded: counts.downloaded += 1
            }
        }
        return counts
    }

    /// `44 tracks · 31 new · 13 already in library`.
    var summaryLine: String {
        let c = counts
        return "\(ActivityNoun.track.counted(c.total)) · \(c.new.formatted(.number)) new · \(c.known.formatted(.number)) already in library"
    }

    var sourceName: String { previewSource.name }

    /// A second, unlinked copy is the only new playlist possible while one is linked already
    /// (one link per source playlist, so a refresh has one target).
    var linkIsAvailable: Bool {
        if case .newPlaylist = target, existingLinked != nil { return false }
        return previewSource != .appleMusic
    }

    var effectiveKeepLinked: Bool {
        if case .existing = target { return true }
        return keepLinked && linkIsAvailable
    }

    /// `New playlist “Late night rollers”` / `“Late night rollers” — Linked to SoundCloud`.
    var targetTitle: String {
        switch target {
        case .newPlaylist: return "New playlist “\(preview?.title ?? "")”"
        case .existing(_, let name): return "“\(name)” — Linked to \(sourceName)"
        }
    }

    var targetNote: String {
        let name = preview?.title ?? ""
        switch target {
        case .newPlaylist:
            if existingLinked != nil {
                return "A second playlist is created. The existing “\(existingLinked?.name ?? name)” is not changed."
            }
            return effectiveKeepLinked ? "A new playlist is created and linked to \(sourceName)." : "A new playlist is created."
        case .existing:
            if selectionMode != .all {
                return "Re-importing a part: the \(counts.total.formatted(.number)) selected tracks are added if they are missing. Nothing is removed — the other tracks of the playlist stay."
            }
            return "Tracks that are missing are added at the end. Nothing is removed."
        }
    }

    var downloadNote: String {
        if !downloadNow { return "Tracks are added as “Not downloaded”. Download them later from the playlist." }
        let new = counts.new
        guard new > 0 else { return "Nothing new to download." }
        return "\(new.formatted(.number)) new \(new == 1 ? "track is" : "tracks are") downloaded right after the import."
    }

    var linkNote: String {
        guard linkIsAvailable else { return "“\(existingLinked?.name ?? "")” is already linked to \(sourceName). This copy isn’t linked." }
        return effectiveKeepLinked
            ? "The playlist stays “Linked to \(sourceName)”; Refresh from \(sourceName) pulls later additions."
            : "One-time import: an ordinary playlist. It will not follow changes on \(sourceName)."
    }

    // MARK: - Step 3: confirmation

    /// `31 new tracks are added to the library. 13 are already in your library and are only
    /// added to the playlist (9 downloaded, 4 not downloaded).`
    var tracksDetail: String {
        let c = counts
        var text = "\(c.new.formatted(.number)) new \(c.new == 1 ? "track is" : "tracks are") added to the library."
        if c.known > 0 {
            text += " \(c.known.formatted(.number)) \(c.known == 1 ? "is" : "are") already in your library and \(c.known == 1 ? "is" : "are") only added to the playlist (\(c.downloaded.formatted(.number)) downloaded, \(c.inLibrary.formatted(.number)) not downloaded)."
        }
        return text
    }

    /// Tracks the import downloads now.
    var downloadCount: Int {
        guard downloadNow else { return 0 }
        return counts.new + (alsoDownloadKnown ? counts.inLibrary : 0)
    }

    var downloadValue: String { downloadNow ? "\(ActivityNoun.track.counted(downloadCount)) now" : "Not now" }

    var downloadValueNote: String {
        downloadNow ? "Starts right away, runs in the background."
            : "The playlist will say “Not downloaded · \(ActivityNoun.track.counted(counts.new + counts.inLibrary)) · Download all”."
    }

    var linkValue: String { effectiveKeepLinked ? "Linked to \(sourceName)" : "Not linked (one-time import)" }

    /// Shown only when some known tracks are not downloaded (S-IMPORT.N15).
    var offersAlsoDownload: Bool { downloadNow && counts.inLibrary > 0 }

    var alsoDownloadTitle: String {
        "Also download the \(ActivityNoun.track.counted(counts.inLibrary)) that \(counts.inLibrary == 1 ? "is" : "are") in your library but not downloaded"
    }

    /// The queued note: another import is running, this one waits (S-IMPORT.N13).
    var queuedNote: String? {
        guard downloadNow, downloadCount > 0, environment.downloadsRunning() else { return nil }
        let running = environment.runningImportSentence() ?? "Other downloads are running."
        return "\(running) This import is queued and starts when that one ends. You don’t need to wait here."
    }

    /// `Import 44 Tracks` (UC-SHEET-03).
    var importButtonTitle: String {
        let n = counts.total
        return "Import \(n.formatted(.number)) \(n == 1 ? "Track" : "Tracks")"
    }

    var canImport: Bool { step == .confirm && preview != nil && !selectedTracks.isEmpty && !isCommitting }

    /// The primary button on step 3. The commit runs on its own task; the sheet closes when the
    /// playlist exists (normally well under a second), or at once if the user closes it — the
    /// import goes on either way. Downloads go to the download lane as one operation whose
    /// subject is the playlist (a second import queues).
    func importNow() {
        guard canImport, let preview, let link = previewSource.linkSource,
              let provider = environment.provider(previewSource), let importer = environment.makeImporter() else {
            if step == .confirm, environment.makeImporter() == nil { commitError = "Couldn’t import — the library isn’t ready yet." }
            return
        }
        var request = PlaylistImportRequest(preview: preview, tracks: selectedTracks, source: link)
        request.target = target
        request.keepLinked = effectiveKeepLinked
        request.downloadNow = downloadNow
        request.alsoDownloadKnown = alsoDownloadKnown && downloadNow
        let queued = request.downloadNow && downloadCount > 0 && environment.downloadsRunning()
        let post = environment.post
        let showPlaylist = environment.showPlaylist
        let title = preview.title
        isCommitting = true
        commitError = nil
        commitTask = Task { [weak self] in
            do {
                let outcome = try await importer.run(request, sourceRowID: {
                    guard let id = try await provider.sourceRowForLinking().id else { throw RemotePlaylistProviderError.previewUnavailable }
                    return id
                })
                let show = StatusAction("Show Playlist") { showPlaylist(outcome.playlistID) }
                if let message = Self.statusMessage(outcome, queued: queued) {
                    post(message, [show])
                }
                self?.isCommitting = false
                self?.isFinished = true
            } catch {
                let cause = SourceSignInProblem.plainCause(error, source: link.rawValue)
                if let self, !self.isFinished {
                    self.isCommitting = false
                    self.commitError = "Couldn’t import “\(title)” — \(cause)"
                } else {
                    post("Couldn’t import “\(title)” — \(cause)", [])
                }
            }
        }
    }

    /// The status-bar line after the playlist exists. A running download announces itself
    /// (`Import started — 31 tracks`, UC-JOB-08), so only the other cases speak here.
    static func statusMessage(_ outcome: PlaylistImportOutcome, queued: Bool) -> String? {
        if outcome.downloadCount > 0 {
            return queued ? "Import queued — \(ActivityNoun.track.counted(outcome.downloadCount))" : nil
        }
        let total = outcome.addedToLibrary + outcome.alreadyInLibrary
        return "Imported “\(outcome.playlistName)” — \(ActivityNoun.track.counted(total)), nothing downloaded"
    }

    /// Cancel / Esc: closes the sheet only. A running commit continues (DEC-044).
    func close() {
        isFinished = true
    }
}
