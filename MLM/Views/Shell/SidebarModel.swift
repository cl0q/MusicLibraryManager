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

/// Data behind the sidebar rows that isn't owned elsewhere: playlists, Inbox badge counts,
/// which sync destinations are reachable, and the collapsed sections (per library).
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
    /// Profiles whose destination folder exists right now.
    private(set) var reachableProfileIDs: Set<Int64> = []

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
        guard let loaded = try? await fetch(), generation == playlistReloadGeneration else { return [] }
        let before = Set(playlists.compactMap(\.id))
        playlists = loaded
        let after = Set(loaded.compactMap(\.id))
        return before.subtracting(after).sorted()
    }

    @discardableResult
    func reloadPlaylists(_ repository: PlaylistRepository?) async -> [Int64] {
        guard let repository else { return [] }
        return await reloadPlaylists(fetch: { try await repository.fetchAll() })
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

    /// Second line of a playlist row: only when it isn't healthy. Today the only state the
    /// sidebar can know cheaply is a linked source whose sign-in can't be used
    /// (`‹Source› sign-in expired`, §15.3/§15.5); import / incomplete / not-downloaded words
    /// arrive with W3-PL.
    static func playlistSecondLine(
        sourceName: String?,
        unusableSignIns: Set<TokenStorage.Service>
    ) -> String? {
        guard let sourceName, let service = signInService(forSourceName: sourceName),
              unusableSignIns.contains(service) else { return nil }
        return "\(service.displayName) sign-in expired"
    }

    func reloadBadges(trackRepository: TrackRepository?, analysisRepository: AnalysisRepository?) async {
        if let analysisRepository, let counts = try? await analysisRepository.pendingReviewCounts() {
            reviewCount = counts.duplicates + counts.conflicts
        }
        if let trackRepository, let inbox = try? await trackRepository.fetchDiscoveryInboxTracks() {
            discoverCount = inbox.count
        }
    }

    /// Check which sync destinations exist. Called on load and on mount / unmount events —
    /// never while rendering rows.
    func refreshReachability(_ profiles: [SyncProfile]) {
        reachableProfileIDs = Set(profiles.compactMap { profile in
            guard let id = profile.id,
                  FileManager.default.fileExists(atPath: profile.outputFolder) else { return nil }
            return id
        })
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

// MARK: - Sync profile row state (UC-SIDE-07, §15.8)

/// The second line of a sync profile row, from the data that exists before W3-SYNC
/// (per-profile results such as `· 3 failed` arrive with it).
enum SyncProfileRowState: Equatable {
    case syncing(processed: Int, total: Int)
    case notConnected
    case toAdd(Int)
    case synced(Date)
    case connected

    /// Precedence: syncing → not connected → `n to add` → `Synced …` → `Connected`.
    static func make(
        isSyncing: Bool,
        processed: Int,
        total: Int,
        isReachable: Bool,
        pendingAdds: Int?,
        lastSynced: Date?
    ) -> SyncProfileRowState {
        if isSyncing { return .syncing(processed: processed, total: total) }
        if !isReachable { return .notConnected }
        if let pendingAdds, pendingAdds > 0 { return .toAdd(pendingAdds) }
        if let lastSynced { return .synced(lastSynced) }
        return .connected
    }

    /// Display words, verbatim from §15.8; relative time per UC-COPY-10 (`Synced 2 hours ago`).
    func text(relativeTo now: Date = Date()) -> String {
        switch self {
        case .syncing(let processed, let total):
            "Syncing \(processed.formatted(.number)) of \(total.formatted(.number))"
        case .notConnected:
            "Not connected"
        case .toAdd(let n):
            "\(n.formatted(.number)) to add"
        case .synced(let date):
            "Synced \(Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .named, unitsStyle: .wide).format(now))"
        case .connected:
            "Connected"
        }
    }

    /// Fraction for the thin progress bar under a syncing row.
    var progress: Double? {
        guard case .syncing(let processed, let total) = self, total > 0 else { return nil }
        return min(1, Double(processed) / Double(total))
    }
}

// MARK: - Sync profile page ↔ SyncViewModel selection

/// `SyncViewModel` acts on its `selectedProfile` (preview, Sync Now, settings edits), so the
/// visible sync-profile page and that selection must always name the same profile.
///
/// - Opening a page makes its profile the selection (`selectPage`).
/// - When something else selects another existing profile (create, duplicate, New Sync
///   Profile from Selection) while a profile page is visible, the page follows it
///   (`followSelection`), so what is shown is what Sync Now acts on.
enum SyncProfilePageAgreement: Equatable {
    case agree
    case followSelection(Int64)
    case selectPage

    static func reconcile(pageProfileID: Int64, selectedProfileID: Int64?, profileIDs: [Int64]) -> SyncProfilePageAgreement {
        if selectedProfileID == pageProfileID { return .agree }
        if let selected = selectedProfileID, profileIDs.contains(selected) { return .followSelection(selected) }
        return .selectPage
    }
}
