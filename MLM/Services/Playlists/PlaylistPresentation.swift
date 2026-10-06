import Foundation

// MARK: - Playlist status (UC-STATE §15.5, DEC-023, UC-STATE-03)

/// A playlist's state in the §15.5 words — the one source of the header status sentence, the
/// sidebar row's second line and the card's subtitle (same words everywhere, UC-SIDE-06,
/// V-PL.E13, V-PLD.E13). Views never build these strings themselves.
enum PlaylistStatus: Equatable, Sendable {
    case healthy
    /// `‹Source› sign-in expired` — precedence 1.
    case signInExpired(source: String)
    /// `Importing · 12 of 44` — precedence 2 (the Activity numbers when an operation runs for
    /// it, UC-JOB-07). `progress` nil = not countable yet.
    case importing(progress: String?, fraction: Double?)
    /// `Incomplete · 9 failed` — precedence 3.
    case incomplete(failed: Int)
    /// `Not downloaded · 61 tracks` — precedence 4.
    case notDownloaded(count: Int)

    /// The words; nil when healthy (healthy playlists say nothing, UC-SIDE-04).
    var text: String? {
        switch self {
        case .healthy: nil
        case .signInExpired(let source): "\(source) sign-in expired"
        case .importing(let progress, _): progress.map { "Importing · \($0)" } ?? "Importing…"
        case .incomplete(let failed): "Incomplete · \(failed.formatted(.number)) failed"
        case .notDownloaded(let count): "Not downloaded · \(StatusBarText.tracks(count))"
        }
    }

    /// `Needs attention` (UC-SCOPE-04): not fully playable for a reason the user can fix. A
    /// running import is not attention.
    var needsAttention: Bool {
        switch self {
        case .signInExpired, .incomplete, .notDownloaded: true
        case .healthy, .importing: false
        }
    }

    /// The symbol before the words (UC-COLOR-05: a tint decorates a word, never replaces it).
    var systemImage: String? {
        switch self {
        case .healthy, .importing: nil
        case .signInExpired: "person.crop.circle.badge.exclamationmark"
        case .incomplete: "exclamationmark.triangle"
        case .notDownloaded: "icloud"
        }
    }

    /// Orange symbol tint for the failure states (§15.5 colour column).
    var isFailure: Bool {
        switch self {
        case .signInExpired, .incomplete: true
        default: false
        }
    }

    /// - Parameters:
    ///   - summary: the playlist's SQL aggregate (nil = no tracks).
    ///   - echo: Activity's inline echo for the playlist (UC-JOB-07).
    ///   - expiredSignIn: the display name of the playlist's source when its sign-in can't be
    ///     used (`SoundCloud`); nil otherwise.
    static func make(summary: PlaylistSummary?, echo: ActivityEcho?, expiredSignIn: String?) -> PlaylistStatus {
        if let expiredSignIn { return .signInExpired(source: expiredSignIn) }
        if let echo, echo.kind == .download, echo.state.isActive {
            return .importing(progress: echo.state == .running ? echo.progressText : nil, fraction: echo.fraction)
        }
        guard let summary, summary.totalTracks > 0 else { return .healthy }
        if summary.downloadingTracks > 0 {
            let done = summary.withFile
            return .importing(
                progress: "\(done.formatted(.number)) of \(summary.totalTracks.formatted(.number))",
                fraction: Double(done) / Double(summary.totalTracks)
            )
        }
        if summary.failedTracks > 0 { return .incomplete(failed: summary.failedTracks) }
        if summary.notDownloadedTracks > 0 { return .notDownloaded(count: summary.notDownloadedTracks) }
        return .healthy
    }

    /// The display name of a linked source whose sign-in can't be used, from its stored name.
    @MainActor
    static func expiredSignIn(sourceName: String?, unusable: Set<TokenStorage.Service>) -> String? {
        guard let sourceName, let service = SidebarModel.signInService(forSourceName: sourceName),
              unusable.contains(service) else { return nil }
        return service.displayName
    }
}

// MARK: - The Playlists section as a tree (UC-SIDE-01/08, DEC-003)

/// The sidebar's Playlists section — top-level rows (folders and playlists) in the user's
/// order, each folder with its playlists. The All Playlists grid in `Manual` order, the Go
/// menu and `Add to Playlist ▸` read the same tree.
struct PlaylistSidebarTree: Equatable, Sendable {
    enum Node: Equatable, Sendable, Identifiable {
        case folder(PlaylistFolder, playlists: [Playlist])
        case playlist(Playlist)

        var id: PlaylistSidebarItemID {
            switch self {
            case .folder(let folder, _): .folder(folder.id ?? 0)
            case .playlist(let playlist): .playlist(playlist.id ?? 0)
            }
        }
    }

    var nodes: [Node] = []

    static let empty = PlaylistSidebarTree()

    /// Builds the tree with `PlaylistSidebarOrder` (the repository's order). A playlist whose
    /// folder is gone is a top-level row (no foreign keys).
    static func build(folders: [PlaylistFolder], playlists: [Playlist]) -> PlaylistSidebarTree {
        let folderIDs = Set(folders.compactMap(\.id))
        var children: [Int64: [Playlist]] = [:]
        var top: [(PlaylistSidebarOrder.Key, Node)] = []
        for playlist in playlists {
            if let folderID = playlist.folderId, folderIDs.contains(folderID) {
                children[folderID, default: []].append(playlist)
            } else {
                top.append((PlaylistSidebarOrder.key(playlist), .playlist(playlist)))
            }
        }
        let order: (Playlist, Playlist) -> Bool = {
            PlaylistSidebarOrder.precedes(PlaylistSidebarOrder.key($0), PlaylistSidebarOrder.key($1))
        }
        for folder in folders {
            guard let id = folder.id else { continue }
            top.append((PlaylistSidebarOrder.key(folder), .folder(folder, playlists: (children[id] ?? []).sorted(by: order))))
        }
        return PlaylistSidebarTree(nodes: top.sorted { PlaylistSidebarOrder.precedes($0.0, $1.0) }.map(\.1))
    }

    /// Every playlist in sidebar order (a folder's playlists in its place).
    var playlists: [Playlist] {
        nodes.flatMap { node -> [Playlist] in
            switch node {
            case .folder(_, let playlists): playlists
            case .playlist(let playlist): [playlist]
            }
        }
    }

    var folders: [PlaylistFolder] {
        nodes.compactMap { node in
            if case .folder(let folder, _) = node { return folder }
            return nil
        }
    }

    /// The folder a playlist is in; nil at the top level.
    func folder(containing playlistID: Int64) -> PlaylistFolder? {
        for node in nodes {
            if case .folder(let folder, let playlists) = node, playlists.contains(where: { $0.id == playlistID }) {
                return folder
            }
        }
        return nil
    }

    /// The row after `item` among its siblings (where a moved row returns, the `before` of a
    /// move); nil when it is the last.
    func itemAfter(_ item: PlaylistSidebarItemID) -> PlaylistSidebarItemID? {
        if let index = nodes.firstIndex(where: { $0.id == item }) {
            return index + 1 < nodes.count ? nodes[index + 1].id : nil
        }
        for node in nodes {
            if case .folder(_, let playlists) = node, let index = playlists.firstIndex(where: { $0.id.map(PlaylistSidebarItemID.playlist) == item }) {
                return index + 1 < playlists.count ? playlists[index + 1].id.map(PlaylistSidebarItemID.playlist) : nil
            }
        }
        return nil
    }
}

// MARK: - All Playlists grid (V-PL)

/// The grid's sort control (V-PL.N01). `Recently Played` is left out: MLM keeps no play history
/// yet (W3-PL report).
enum PlaylistGridSort: String, CaseIterable, Identifiable, Sendable {
    case manual
    case name
    case recentlyAdded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manual: "Manual"
        case .name: "Name"
        case .recentlyAdded: "Recently Added"
        }
    }
}

/// The grid's scope bar (V-PL.E02, UC-SCOPE-02): `All` + the sources that have playlists +
/// `Needs attention`.
enum PlaylistGridScope: Hashable, Sendable {
    case all
    case local
    case source(PlaylistSourceIdentity)
    case needsAttention

    var title: String {
        switch self {
        case .all: "All"
        case .local: "Local"
        case .source(let identity): identity.displayName
        case .needsAttention: "Needs attention"
        }
    }

    /// Stored per view (UC-SCOPE-05).
    var storageKey: String {
        switch self {
        case .all: "all"
        case .local: "local"
        case .source(let identity): "source:\(identity.displayName)"
        case .needsAttention: "attention"
        }
    }
}

/// One card's data.
struct PlaylistGridItem: Equatable, Identifiable, Sendable {
    let playlist: Playlist
    let summary: PlaylistSummary?
    let status: PlaylistStatus
    /// The linked source, nil for a local playlist.
    let source: PlaylistSourceIdentity?

    var id: Int64 { playlist.id ?? 0 }
    var trackCount: Int { summary?.totalTracks ?? 0 }

    /// `SoundCloud · 44 tracks · Liked` (V-PL.E12/E14); the source has its dot in the view.
    var factsText: String {
        var parts: [String] = []
        if let source { parts.append(source.displayName) }
        parts.append(StatusBarText.tracks(trackCount))
        if playlist.isLiked == 1 { parts.append("Liked") }
        return parts.joined(separator: " · ")
    }

    func matches(_ scope: PlaylistGridScope) -> Bool {
        switch scope {
        case .all: true
        case .local: source == nil
        case .source(let identity): source == identity
        case .needsAttention: status.needsAttention
        }
    }
}

/// What the grid shows: folder groups in `Manual` order without filter or scope, else one flat
/// grid (V-PL.E08).
enum PlaylistGridLayout: Equatable {
    struct Group: Equatable, Identifiable {
        /// nil = top-level playlists between folders.
        let folder: PlaylistFolder?
        let items: [PlaylistGridItem]
        var id: String { folder.map { "folder-\($0.id ?? 0)" } ?? "top-\(items.first?.id ?? 0)" }
    }

    case grouped([Group])
    case flat([PlaylistGridItem])

    var items: [PlaylistGridItem] {
        switch self {
        case .grouped(let groups): groups.flatMap(\.items)
        case .flat(let items): items
        }
    }
}

enum PlaylistGridRules {
    /// Scopes on the bar: All, Local, the sources present (sorted by name), Needs attention.
    static func scopes(_ items: [PlaylistGridItem]) -> [PlaylistGridScope] {
        let sources = Set(items.compactMap(\.source)).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        return [.all, .local] + sources.map(PlaylistGridScope.source) + [.needsAttention]
    }

    static func count(_ items: [PlaylistGridItem], in scope: PlaylistGridScope) -> Int {
        items.filter { $0.matches(scope) }.count
    }

    /// - Parameters:
    ///   - tree: the sidebar's order (Manual).
    ///   - items: every card, by playlist id.
    ///   - filter: the toolbar's text for this place (name match, W2-I).
    static func layout(tree: PlaylistSidebarTree, items: [Int64: PlaylistGridItem], sort: PlaylistGridSort,
                       scope: PlaylistGridScope, filter: SearchFilter) -> PlaylistGridLayout {
        let visible: (Playlist) -> PlaylistGridItem? = { playlist in
            guard let id = playlist.id, let item = items[id], item.matches(scope),
                  filter.isEmpty || filter.matchesName(playlist.name) else { return nil }
            return item
        }
        if sort == .manual, scope == .all, filter.isEmpty {
            var groups: [PlaylistGridLayout.Group] = []
            var loose: [PlaylistGridItem] = []
            for node in tree.nodes {
                switch node {
                case .playlist(let playlist):
                    if let item = visible(playlist) { loose.append(item) }
                case .folder(let folder, let playlists):
                    if !loose.isEmpty { groups.append(.init(folder: nil, items: loose)); loose = [] }
                    groups.append(.init(folder: folder, items: playlists.compactMap(visible)))
                }
            }
            if !loose.isEmpty { groups.append(.init(folder: nil, items: loose)) }
            return .grouped(groups)
        }
        var flat = tree.playlists.compactMap(visible)
        switch sort {
        case .manual: break
        case .name:
            flat.sort { $0.playlist.name.localizedStandardCompare($1.playlist.name) == .orderedAscending }
        case .recentlyAdded:
            // Newest playlist first: ids grow with creation (a restored playlist keeps its id).
            flat.sort { ($0.playlist.id ?? 0) > ($1.playlist.id ?? 0) }
        }
        return .flat(flat)
    }

    /// Status bar (UC-STATUS-02): `28 playlists`, filtered `6 of 28 playlists`.
    static func statusText(shown: Int, total: Int) -> String {
        shown == total ? StatusBarText.playlists(total) : "\(shown.formatted(.number)) of \(StatusBarText.playlists(total))"
    }

    /// The filtered-empty sentence (`playlists.html` V-PL.E15/filtered):
    /// `Nothing is named “vaporwave” in SoundCloud.` / `No playlist in Needs attention.`
    static func filteredEmptyText(query: String, scope: PlaylistGridScope) -> String {
        var text = query.isEmpty ? "No playlist" : "Nothing is named “\(query)”"
        if scope != .all { text += " in \(scope.title)" }
        return text + "."
    }
}

// MARK: - Detail header facts (V-PLD.E04)

enum PlaylistFacts {
    /// `44 tracks · 2 h 51 min · Linked to SoundCloud` (§15.5); a local playlist names no source,
    /// an empty one has no duration.
    static func line(trackCount: Int, totalSeconds: Int, sourceName: String?) -> String {
        var parts = [StatusBarText.tracks(trackCount)]
        if trackCount > 0, totalSeconds > 0 { parts.append(TrackDurationText.total(totalSeconds)) }
        if let sourceName { parts.append("Linked to \(sourceName)") }
        return parts.joined(separator: " · ")
    }

    /// The kind label above the title (V-PLD).
    static func kindLabel(_ playlist: Playlist) -> String {
        playlist.isLiked == 1 ? "Liked playlist" : "Playlist"
    }
}
