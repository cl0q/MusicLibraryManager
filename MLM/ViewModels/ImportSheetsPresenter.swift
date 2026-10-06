import AppKit
import Foundation
import Observation

// MARK: - The Add menu's sheets and Refresh from Sources (P-ADDMENU, S-QUICKADD, S-IMPORT)

/// The main window's Add-menu sheets: `Add from Link…` (S-QUICKADD) and `Import Playlist from
/// Source…` (S-IMPORT), and `Refresh from Sources`. It is W2-I's `QuickAddPresenting`: a link
/// from the search field, a dropped or pasted link all land here
/// (`QuickAddRouter.shared.presenter`). Owned by the window's `ShellActions`.
@MainActor
@Observable
final class ImportSheetsPresenter: QuickAddPresenting {
    enum Sheet: Identifiable {
        case quickAdd(QuickAddModel)
        case importPlaylist(ImportPlaylistModel)

        var id: ObjectIdentifier {
            switch self {
            case .quickAdd(let model): ObjectIdentifier(model)
            case .importPlaylist(let model): ObjectIdentifier(model)
            }
        }
    }

    /// The sheet over the main window.
    var sheet: Sheet?

    /// `Refresh from Sources` is running.
    private(set) var isRefreshing = false

    // Set by the window (`ImportSheetsHost`): actions that live in views.
    @ObservationIgnored var openSettingsSources: () -> Void = {}
    @ObservationIgnored var revealTrack: (Int64) -> Void = { _ in }
    @ObservationIgnored var addToPlaylist: (Int64, Int64) -> Void = { _, _ in }

    @ObservationIgnored private let container: DependencyContainer
    @ObservationIgnored private let statusBar: StatusBarCenter
    @ObservationIgnored private let navigation: NavigationModel
    @ObservationIgnored private var accountReader: (any SourceAccountStateReading)?

    init(container: DependencyContainer, statusBar: StatusBarCenter, navigation: NavigationModel) {
        self.container = container
        self.statusBar = statusBar
        self.navigation = navigation
    }

    // MARK: Accounts (swap point for W3-SET's account-state model)

    /// The source accounts; `nil` before a library is open.
    var accounts: (any SourceAccountStateReading)? {
        if let accountReader { return accountReader }
        accountReader = Self.makeAccountStates(container)
        return accountReader
    }

    /// **W3-SET:** replace this line's reader with the account-state model when it lands.
    static func makeAccountStates(_ container: DependencyContainer) -> (any SourceAccountStateReading)? {
        guard let tokens = container.tokenStorage, let sources = container.sourceRepository else { return nil }
        let viewModel = SourcesViewModel(
            tokenStorage: tokens, sourceRepository: sources, oauthManager: container.oauthManager,
            trackRepository: container.trackRepository, playlistRepository: container.playlistRepository,
            tokenAccessStatus: container.tokenAccessStatus, tokenRefreshService: container.tokenRefreshService)
        return SourcesViewModelAccountStates(viewModel: viewModel, tokenStorage: tokens,
                                             tokenAccessStatus: container.tokenAccessStatus,
                                             tokenRefreshService: container.tokenRefreshService)
    }

    func reloadAccounts() async {
        await accounts?.reload()
    }

    // MARK: QuickAddPresenting (W2-I)

    /// A link from the search field, a drop or a paste: a playlist link opens the import at
    /// the preview step; anything else opens Add from Link with the link (and what the field
    /// already knows about it).
    func presentQuickAdd(for link: LinkSuggestion, lookup: LinkLookup?) {
        if case .playlist = link {
            presentImport(with: link)
        } else {
            sheet = .quickAdd(QuickAddModel(environment: quickAddEnvironment(), text: link.url, lookup: lookup))
        }
    }

    // MARK: Menu commands

    /// `Add from Link…` ⌘U: the field is pre-filled when the pasteboard holds a link.
    func addFromLink(pasteboard: NSPasteboard = .general) {
        let text = Self.pasteboardLink(pasteboard.string(forType: .string))
        sheet = .quickAdd(QuickAddModel(environment: quickAddEnvironment(), text: text ?? ""))
    }

    /// The pasteboard's text when it is a single http(s) link.
    nonisolated static func pasteboardLink(_ text: String?) -> String? {
        guard let text, LinkSuggestion.isLink(text) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Import Playlist from Source…` ⇧⌘I: step 1.
    func importPlaylistFromSource() {
        let model = ImportPlaylistModel(environment: importEnvironment())
        sheet = .importPlaylist(model)
        Task {
            await accounts?.reload()
            await model.loadPlaylistsIfNeeded()
        }
    }

    /// A playlist link: the import at step 2 with the playlist loading.
    func presentImport(with link: LinkSuggestion) {
        let model = ImportPlaylistModel(environment: importEnvironment())
        sheet = .importPlaylist(model)
        Task { await model.start(with: link) }
    }

    /// Help text of the disabled `Refresh from Sources` (UC-TB-05).
    nonisolated static let noSourceConnected = "No source is connected"

    var canRefreshFromSources: Bool {
        !isRefreshing && (accounts?.anyConnected ?? false)
    }

    /// `Refresh from Sources`: every connected source, one Activity operation each; the
    /// result is in the status bar through the center (UC-JOB-08). Never downloads by itself.
    func refreshFromSources() {
        guard !isRefreshing, let accounts, let service = SourceRefreshService.live(container) else { return }
        let connected = TokenStorage.Service.allCases.filter { accounts.state(of: $0).isConnected }
        guard !connected.isEmpty else {
            statusBar.post("\(Self.noSourceConnected) · Open Settings ▸ Sources", actions: [
                StatusAction("Open Settings ▸ Sources") { [weak self] in self?.openSettingsSources() },
            ])
            return
        }
        service.onSignInExpired = { [weak accounts] in accounts?.markSignInExpired($0) }
        isRefreshing = true
        Task {
            await service.refreshAll(connected)
            isRefreshing = false
            await accounts.reload()
        }
    }

    // MARK: Environments

    private var downloadsRunning: () -> Bool {
        let activity = ActivityCenter.shared
        return { activity.activeOperations.contains { [.download, .recommendationDownload, .reelsDownload].contains($0.kind) } }
    }

    func quickAddEnvironment() -> QuickAddEnvironment {
        let container = self.container
        let statusBar = self.statusBar
        return QuickAddEnvironment(
            lookUp: { await LiveSearchSuggestionProvider().lookUp($0) },
            download: { link, metadata in
                guard let service = SearchDownloadService.live(container) else { return .failed("the library isn’t open") }
                return await service.download(link, metadata: metadata)
            },
            downloadExisting: { id, source in
                guard let track = try? await container.trackRepository?.fetchTrack(id: id),
                      let downloads = container.downloadViewModel else { return }
                Task { await downloads.downloadTracks([track], preferredSource: source.preferredDownloadSource) }
            },
            addToPlaylist: { [weak self] playlist, track in self?.addToPlaylist(playlist, track) },
            isYtDlpAvailable: { YouTubeDownloader().isAvailable },
            downloadsRunning: downloadsRunning,
            accounts: accounts,
            trackFacts: { id in
                guard let track = try? await container.trackRepository?.fetchTrack(id: id) else { return nil }
                return (track.title, !track.isRemote, Self.facts(track))
            },
            post: { text, actions in statusBar.post(text, actions: actions) },
            reveal: { [weak self] id in self?.revealTrack(id) },
            importPlaylist: { [weak self] link in self?.presentImport(with: link) },
            openInBrowser: { NSWorkspace.shared.open($0) },
            openSettingsSources: { [weak self] in self?.openSettingsSources() }
        )
    }

    /// `Added Mar 14, 2026 · FLAC` (the library track a link already is).
    nonisolated static func facts(_ track: Track) -> String? {
        var parts: [String] = []
        if let added = track.dateAddedLibrary ?? track.dateAdded,
           let date = ISO8601DateFormatter().date(from: added) {
            parts.append("Added \(date.formatted(date: .abbreviated, time: .omitted))")
        }
        if !track.isRemote, !track.format.isEmpty { parts.append(track.format.uppercased()) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    func importEnvironment() -> ImportPlaylistEnvironment {
        let container = self.container
        let statusBar = self.statusBar
        let navigation = self.navigation
        let accounts = self.accounts ?? EmptyAccountStates()
        var providers: [ImportSourceKind: any RemotePlaylistProvider] = [:]
        return ImportPlaylistEnvironment(
            provider: { kind in
                if let cached = providers[kind] { return cached }
                let made = Self.makeProvider(kind, container: container)
                providers[kind] = made
                return made
            },
            accounts: accounts,
            queries: container.databaseManager.map { ImportLibraryQueries(database: $0.pool) },
            makeImporter: {
                guard let tracks = container.trackRepository, let sources = container.sourceRepository,
                      let playlists = container.playlistRepository, let database = container.databaseManager,
                      let downloads = container.downloadViewModel else { return nil }
                return PlaylistImporter(trackRepository: tracks, sourceRepository: sources, playlistRepository: playlists,
                                        queries: ImportLibraryQueries(database: database.pool),
                                        downloads: LivePlaylistDownloadStarter(downloads: downloads))
            },
            downloadsRunning: downloadsRunning,
            runningImportSentence: { Self.runningImportSentence(ActivityCenter.shared) },
            post: { text, actions in statusBar.post(text, actions: actions) },
            showPlaylist: { navigation.select(.playlist($0)) },
            isYtDlpAvailable: { YouTubeDownloader().isAvailable },
            openSettingsSources: { [weak self] in self?.openSettingsSources() }
        )
    }

    /// `“Liked on SoundCloud” is still importing (12 of 44).` / `A download is running (3 of 10).`
    static func runningImportSentence(_ activity: ActivityCenter) -> String? {
        guard let running = activity.activeOperations.first(where: { $0.kind == .download && $0.state == .running }) else {
            return nil
        }
        let progress = ActivityPresentation.progressText(running.progress).map { " (\($0))" } ?? ""
        if running.subject.kind == .playlist, let name = running.subject.name {
            return "“\(name)” is still importing\(progress)."
        }
        return "A download is running\(progress)."
    }

    static func makeProvider(_ kind: ImportSourceKind, container: DependencyContainer) -> (any RemotePlaylistProvider)? {
        guard let sources = container.sourceRepository else { return nil }
        switch kind {
        case .soundcloud:
            guard let tokens = container.tokenStorage, let oauth = container.oauthManager,
                  let tracks = container.trackRepository else { return nil }
            let client = SoundCloudClient(tokenStorage: tokens, oauthManager: oauth, trackRepository: tracks,
                                          sourceRepository: sources, playlistRepository: container.playlistRepository)
            return SoundCloudPlaylistProvider(client: client, sourceRepository: sources)
        case .spotify:
            guard let tokens = container.tokenStorage, let oauth = container.oauthManager,
                  let tracks = container.trackRepository else { return nil }
            let client = SpotifyClient(tokenStorage: tokens, oauthManager: oauth, trackRepository: tracks,
                                       sourceRepository: sources, playlistRepository: container.playlistRepository)
            return SpotifyPlaylistProvider(client: client, sourceRepository: sources)
        case .youtube:
            return YouTubePlaylistProvider(downloader: YouTubeDownloader(), sourceRepository: sources)
        case .appleMusic:
            return nil
        }
    }
}

/// No library open: every source reads `Disconnected`.
@MainActor
final class EmptyAccountStates: SourceAccountStateReading {
    func state(of service: TokenStorage.Service) -> SourceAccountState {
        service == .appleMusic ? .notAvailable : .disconnected
    }
    func reload() async {}
    func markSignInExpired(_ service: TokenStorage.Service) {}
    func signIn(_ service: TokenStorage.Service) async throws { throw CancellationError() }
    func allowKeychainAccess(_ service: TokenStorage.Service) async -> Bool { false }
}
