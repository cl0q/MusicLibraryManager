import Foundation
import Observation

/// The four sidebar sections (UC-SIDE-01), used for their persisted expansion state.
enum SidebarSectionID: String, CaseIterable, Sendable {
    case library
    case inbox
    case playlists
    case sync

    var title: String {
        switch self {
        case .library: "Library"
        case .inbox: "Inbox"
        case .playlists: "Playlists"
        case .sync: "Sync"
        }
    }
}

/// Data behind the sidebar rows that isn't owned elsewhere: playlists, Inbox badge counts and
/// the collapsed sections (per library).
///
/// Sync profiles themselves come from `SyncViewModel.profiles` (already loaded at launch).
@MainActor
@Observable
final class SidebarModel {
    private(set) var playlists: [Playlist] = []
    /// Recommendations waiting for a verdict (UC-SIDE-05; reels are not counted yet).
    private(set) var discoverCount = 0
    /// Duplicate groups + metadata conflicts waiting (album suggestions arrive with W4-3).
    private(set) var reviewCount = 0

    private(set) var collapsedSections: Set<SidebarSectionID> = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var libraryKey = "default"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Section expansion (UC-SIDE-02: persisted per library)

    static func collapsedKey(libraryID: String) -> String {
        "sidebar.collapsedSections.\(libraryID)"
    }

    /// Load the expansion state of the open library.
    func useLibrary(id: String?) {
        let key = (id?.isEmpty == false ? id : nil) ?? "default"
        libraryKey = key
        let stored = defaults.stringArray(forKey: Self.collapsedKey(libraryID: key)) ?? []
        collapsedSections = Set(stored.compactMap(SidebarSectionID.init(rawValue:)))
        loadCollapsedFoldersIfNeeded()
    }

    func isExpanded(_ section: SidebarSectionID) -> Bool {
        !collapsedSections.contains(section)
    }

    func setExpanded(_ section: SidebarSectionID, _ expanded: Bool) {
        if expanded {
            collapsedSections.remove(section)
        } else {
            collapsedSections.insert(section)
        }
        defaults.set(collapsedSections.map(\.rawValue).sorted(), forKey: Self.collapsedKey(libraryID: libraryKey))
    }

    // MARK: Names (window titles)

    func playlistName(_ id: Int64) -> String? {
        playlists.first { $0.id == id }?.name
    }

    // MARK: Loading

    @ObservationIgnored private var playlistReloadGeneration = 0

    /// Reload the playlist rows. Overlapping reloads are ordered: only the most recently
    /// started one is applied, so a slow, older fetch can't bring back a stale list.
    ///
    /// - Returns: ids of playlists that were listed before and are gone now (the caller
    ///   leaves their destinations); empty when this reload was superseded or failed.
    @discardableResult
    func reloadPlaylists(fetch: () async throws -> [Playlist]) async -> [Int64] {
        playlistReloadGeneration += 1
        let generation = playlistReloadGeneration
        let result: [Playlist]?
        do {
            result = try await fetch()
        } catch {
            if generation == playlistReloadGeneration { playlistLoadFailed = true }
            return []
        }
        guard let loaded = result, generation == playlistReloadGeneration else { return [] }
        playlistLoadFailed = false
        hasLoadedPlaylists = true
        let before = Set(playlists.compactMap(\.id))
        playlists = loaded
        let after = Set(loaded.compactMap(\.id))
        // A requested inline rename never outlives its playlist (undone, deleted).
        if let requested = renameRequest, !after.contains(requested) { renameRequest = nil }
        return before.subtracting(after).sorted()
    }

    /// Reloads the playlists, the playlist folders (W3-PL) and the playlists' summaries together.
    @discardableResult
    func reloadPlaylists(_ repository: PlaylistRepository?) async -> [Int64] {
        guard let repository else { return [] }
        let folderRepository = repository.folders
        var loadedFolders: [PlaylistFolder]?
        var loadedSummaries: [Int64: PlaylistSummary]?
        let removed = await reloadPlaylists(fetch: {
            loadedFolders = try await folderRepository.fetchFolders()
            loadedSummaries = try? await repository.fetchSummaries()
            return try await repository.fetchAll()
        })
        if let loadedFolders {
            folders = loadedFolders
            if let requested = folderRenameRequest, !loadedFolders.contains(where: { $0.id == requested }) {
                folderRenameRequest = nil
            }
        }
        if let loadedSummaries { summaries = loadedSummaries }
        tree = PlaylistSidebarTree.build(folders: folders, playlists: playlists)
        return removed
    }

    // MARK: Playlist folders, tree, summaries (W3-PL, DEC-003)

    /// The first load finished (the grid shows placeholder cards until then, V-PL.E16).
    private(set) var hasLoadedPlaylists = false
    /// The last load failed (V-PL.N02 `Can’t load the playlists`).
    private(set) var playlistLoadFailed = false

    /// The playlist folders, in sidebar order.
    private(set) var folders: [PlaylistFolder] = []
    /// The Playlists section in the user's order.
    private(set) var tree = PlaylistSidebarTree.empty
    /// Every playlist's counts, duration and last-added date — one SQL aggregate (UC-TABLE-21).
    private(set) var summaries: [Int64: PlaylistSummary] = [:]

    /// Re-reads only the summaries (downloads, file checks): the rows' second lines follow.
    func reloadSummaries(_ repository: PlaylistRepository?) async {
        guard let repository, let loaded = try? await repository.fetchSummaries() else { return }
        if loaded != summaries { summaries = loaded }
    }

    /// Up to three playlists tracks were added to most recently (`Add to Playlist ▸ Recent`,
    /// UC-CM-11), newest first; `excluding` the current playlist.
    func recentPlaylists(excluding excluded: Int64? = nil, limit: Int = 3) -> [Playlist] {
        let byID = Dictionary(playlists.compactMap { p in p.id.map { ($0, p) } }, uniquingKeysWith: { first, _ in first })
        return summaries.values
            .filter { $0.lastAddedAt != nil && $0.playlistID != excluded && byID[$0.playlistID] != nil }
            .sorted { ($0.lastAddedAt ?? "") > ($1.lastAddedAt ?? "") }
            .prefix(limit)
            .compactMap { byID[$0.playlistID] }
    }

    func folderName(_ id: Int64) -> String? {
        folders.first { $0.id == id }?.name
    }

    // MARK: Folder expansion (UC-SIDE-02/08: remembered per library, not in the database)

    @ObservationIgnored private var collapsedFoldersLoadedFor: String?
    private(set) var collapsedFolders: Set<Int64> = []

    static func collapsedFoldersKey(libraryID: String) -> String {
        "sidebar.collapsedPlaylistFolders.\(libraryID)"
    }

    private func loadCollapsedFoldersIfNeeded() {
        guard collapsedFoldersLoadedFor != libraryKey else { return }
        collapsedFoldersLoadedFor = libraryKey
        let stored = defaults.array(forKey: Self.collapsedFoldersKey(libraryID: libraryKey)) as? [Int] ?? []
        collapsedFolders = Set(stored.map(Int64.init))
    }

    /// Pure read (no state change while a body evaluates); loaded in `useLibrary`.
    func isFolderExpanded(_ id: Int64) -> Bool {
        !collapsedFolders.contains(id)
    }

    func setFolderExpanded(_ id: Int64, _ expanded: Bool) {
        loadCollapsedFoldersIfNeeded()
        if expanded { collapsedFolders.remove(id) } else { collapsedFolders.insert(id) }
        defaults.set(collapsedFolders.map { Int($0) }.sorted(), forKey: Self.collapsedFoldersKey(libraryID: libraryKey))
    }

    // MARK: Name a new folder inline (S-PLFOLDER-NEW)

    /// A new folder whose sidebar name should go into edit mode once it is listed.
    private(set) var folderRenameRequest: Int64?

    func requestRename(folder id: Int64) {
        folderRenameRequest = id
        setExpanded(.playlists, true)
    }

    func takeFolderRenameRequest() -> PlaylistFolder? {
        guard let id = folderRenameRequest, let folder = folders.first(where: { $0.id == id }) else { return nil }
        folderRenameRequest = nil
        return folder
    }

    /// Ask the sidebar to show a playlist's row selected and scrolled into view (Show in All
    /// Playlists selects the card instead; this is for a playlist inside a collapsed folder).
    func reveal(playlist id: Int64) {
        if let folder = tree.folder(containing: id), let folderID = folder.id, !isFolderExpanded(folderID) {
            setFolderExpanded(folderID, true)
        }
    }

    // MARK: Playlist second line (UC-SIDE-06)

    /// Source names (`soundcloud`, `spotify`, …) by source id, for linked playlists.
    private(set) var sourceNames: [Int64: String] = [:]

    func reloadSources(_ repository: SourceRepository?) async {
        guard let repository, let sources = try? await repository.fetchAll() else { return }
        sourceNames = Dictionary(sources.compactMap { source in source.id.map { ($0, source.name) } },
                                 uniquingKeysWith: { first, _ in first })
    }

    /// The sign-in a source name stands for (`soundcloud` → SoundCloud).
    static func signInService(forSourceName name: String) -> TokenStorage.Service? {
        let lowered = name.lowercased()
        if lowered.contains("soundcloud") { return .soundcloud }
        if lowered.contains("spotify") { return .spotify }
        if lowered.contains("apple") { return .appleMusic }
        return nil
    }

    /// The `‹Source› sign-in expired` words of a linked playlist (§15.3/§15.5). The row's whole
    /// second line — import, incomplete, not downloaded too — is `PlaylistStatus` (W3-PL).
    static func playlistSecondLine(
        sourceName: String?,
        unusableSignIns: Set<TokenStorage.Service>
    ) -> String? {
        guard let sourceName, let service = signInService(forSourceName: sourceName),
              unusableSignIns.contains(service) else { return nil }
        return "\(service.displayName) sign-in expired"
    }

    /// UC-SIDE-05: Discover = recommendations waiting + reels not Done; Review = groups +
    /// conflicts + pending album suggestions (W4-3, IMP-086).
    func reloadBadges(
        trackRepository: TrackRepository?, analysisRepository: AnalysisRepository?, reelRepository: ReelRepository? = nil,
        albumSuggestions: AlbumSuggestionRepository? = nil
    ) async {
        if let analysisRepository, let counts = try? await analysisRepository.pendingReviewCounts() {
            let albums = (try? await albumSuggestions?.counts().pending) ?? 0
            reviewCount = counts.duplicates + counts.conflicts + albums
        }
        if let trackRepository, let inbox = try? await trackRepository.fetchDiscoveryInboxTracks() {
            let reels = (try? await reelRepository?.notDoneCount()) ?? 0
            discoverCount = inbox.count + reels
        }
    }

    // MARK: New playlist name (UC §23 C5)

    /// `Untitled Playlist`, or `Untitled Playlist 2`, `3`, … when the name is taken. The
    /// repository applies the same rule when it creates the playlist (`createNumbered`).
    static func untitledPlaylistName(existing names: [String]) -> String {
        PlaylistRepository.numberedName(
            base: ShellEdits.untitledPlaylistName,
            taken: Set(names.map { $0.lowercased() })
        )
    }

    // MARK: Name a new playlist inline (S-PL-NEWPLAYLIST, S-SEL-NEWPLAYLIST)

    /// A new playlist whose sidebar name should go into edit mode as soon as its row is listed.
    private(set) var renameRequest: Int64?

    /// Ask the sidebar to edit the name of a playlist just created; opens the Playlists section.
    func requestRename(playlist id: Int64) {
        renameRequest = id
        setExpanded(.playlists, true)
    }

    /// The requested playlist, once it is among the listed rows; clears the request.
    func takeRenameRequest() -> Playlist? {
        guard let id = renameRequest, let playlist = playlists.first(where: { $0.id == id }) else { return nil }
        renameRequest = nil
        return playlist
    }
}

// The sync profile rows' words are `SyncProfileState` (W3-SYNC, `MLM/Services/Sync/`); each
// profile has its own state, so there is no page ↔ selection agreement to keep any more.
