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

    func reloadPlaylists(_ repository: PlaylistRepository?) async {
        guard let repository else { return }
        if let loaded = try? await repository.fetchAll() {
            playlists = loaded
        }
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

    /// `Untitled Playlist`, or `Untitled Playlist 2`, `3`, … when the name is taken.
    static func untitledPlaylistName(existing names: [String]) -> String {
        let base = "Untitled Playlist"
        let taken = Set(names.map { $0.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
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
            "Synced \(Self.relativeFormatter.localizedString(for: date, relativeTo: now))"
        case .connected:
            "Connected"
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.dateTimeStyle = .named
        formatter.unitsStyle = .full
        return formatter
    }()

    /// Fraction for the thin progress bar under a syncing row.
    var progress: Double? {
        guard case .syncing(let processed, let total) = self, total > 0 else { return nil }
        return min(1, Double(processed) / Double(total))
    }
}
