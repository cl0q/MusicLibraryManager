import Foundation

// MARK: - Track menu: the pure model (CM-TRACK, DEC-039, UC-CM-01…09)

/// One item of the track menu. The view (`TrackMenu`) renders it; the order and presence
/// rules live in `TrackMenuModel.make` and are unit-tested.
///
/// Items whose feature arrives with a later package are **absent** (context menus never show
/// dead or placeholder items, UC-CM-01): Go to Album (W4-2), Find Similar (W3-DISC), Share…
/// (W5-2). The Queue's own rows (CM-QUEUE, W2-D) use `TrackMenuContext.queueRows`.
enum TrackMenuItem: Hashable, Sendable {
    /// Disabled first line: `3 tracks` (UC-CM-04).
    case countHeader(Int)
    /// Disabled line `“Lexxar” is not connected` above disabled file actions (UC-CM-05).
    case driveHeader(volumeName: String)
    /// Play ↩ (single: the primary action — downloads first when needed; several: the playable ones).
    case play(enabled: Bool)
    /// Preview (Space): one local track; disabled while its disk is away (UC-CM-04/05, W2-C).
    case preview(enabled: Bool)
    case playNext
    /// Add to Queue ⌥⇧↩ (W2-D): the end of the Play Next items.
    case addToQueue
    /// Queue rows in Next: Move to End of Queue (CM-QUEUE).
    case moveToEndOfQueue
    case addToPlaylist
    case addToSyncProfile
    case getInfo
    /// Go to Album: pushes the album's page (one track that belongs to an album, W4-2).
    case goToAlbum(Int64)
    /// Go to Artist: All Tracks filtered by `artist: ‹name›` (one track with an artist, W2-I).
    case goToArtist(String)
    /// `Download` · `Retry Download` · `Download 3 Not-Downloaded Tracks`.
    case download(title: String)
    /// File missing, has a source: fetch it again.
    case downloadAgain
    /// File missing / Download failed: point the track at its file (W2-C).
    case locateFile
    /// `Find Similar` (one track): pushes `Similar to “‹title›”` (W3-DISC-A).
    case findSimilar
    /// `Keep and Add to Playlist ▸` on a held recommendation: the list's `perform` receives
    /// `keepAndAdd:‹playlist id›` (W3-DISC-A).
    case keepAndAddToPlaylist
    case showInFinder(enabled: Bool)
    case copy(filePath: Bool, link: Bool)
    /// `Remove from Playlist` / `Remove from “Warm-up”` (reversible, normal colour, ⌫).
    case removeFromContainer(title: String)
    /// `Remove from Library…` (irreversible, destructive, last, ⌘⌫).
    case removeFromLibrary(enabled: Bool)
    /// A Next row of the context lane: `Show in “‹context›”` (CM-QUEUE) — the list it plays from.
    case showInContext(name: String)
    /// History / Now playing rows: `Clear History` (CM-QUEUE.N01).
    case clearHistory
    /// An item only one place has (`Add to “Techno”`, `Use as Reference for Suggestions`, `Not
    /// Now` — W3-GEN), run through the list's `TrackListConfiguration.menuExtras`.
    case extra(TrackMenuExtra)
}

/// A place's own track-menu item, placed into one of the DEC-039 groups.
struct TrackMenuExtra: Hashable, Sendable {
    /// What the place's `perform` recognises.
    let id: String
    let title: String
    var isEnabled = true
}

/// A place's own items per group: `addTo` goes first in the Add-to group, `info` last in the
/// Info group, `remove` before `Remove from Library…` (UC-CM catalogue, CM-STUDIO-*).
struct TrackMenuExtras: Equatable, Sendable {
    var addTo: [TrackMenuExtra] = []
    var info: [TrackMenuExtra] = []
    /// First in the Fix group — `Keep This Version` (W3-REV, CM-REV-VERSION).
    var fix: [TrackMenuExtra] = []
    var remove: [TrackMenuExtra] = []

    static let none = TrackMenuExtras()
}

/// Which rows of the Queue panel a menu is for (CM-QUEUE, CM-QUEUE.N01).
enum QueueMenuRows: Equatable, Sendable {
    /// Rows of Next. `contextName` is set for one row of the context lane whose list still
    /// exists (`Show in “‹context›”`).
    case next(contextName: String?)
    /// History rows and / or the Now playing row; `canPlay` is false for the playing row alone.
    case history(canPlay: Bool)
}

/// The subject of a track menu: the selected rows (or the right-clicked row) in display order.
struct TrackMenuSubject: Sendable {
    let rows: [TrackRow]
    let live: TrackTableLiveState

    var count: Int { rows.count }
}

/// What the list around the subject supports.
struct TrackMenuContext: Equatable, Sendable {
    var container: TrackListContainer
    var canActivate: Bool
    var canRemoveFromContainer: Bool
    var canAddToSyncProfile: Bool
    /// Space previews a row of this list (every track table, W2-C).
    var canPreview = true
    /// Locate File… can re-point a File missing / Download failed row (W2-C).
    var canLocate = true
    /// The rows are the Queue panel's (W2-D): its own safe menu (CM-QUEUE).
    var queueRows: QueueMenuRows? = nil
    /// The place's own items for these rows (W3-GEN).
    var extras: TrackMenuExtras = .none
    /// `Find Similar` is offered for one track (W3-DISC-A).
    var canFindSimilar = true

    /// `Remove from Playlist` inside one playlist (UC-CM-08), `Remove from “‹profile›”`.
    var removeTitle: String {
        switch container {
        case .playlist: "Remove from Playlist"
        case .syncProfile(_, let name), .genre(_, let name), .album(_, let name): "Remove from “\(name)”"
        case .queue: "Remove from Queue"
        case .library, .folder, .reviewGroup, .recommendations, .similar, .none: "Remove"
        }
    }
}

/// The track menu as sections in DEC-039 group order: Primary · Queue · Add to · Info ·
/// Fix · Locate/Share · Remove. Empty groups disappear.
struct TrackMenuModel: Equatable, Sendable {
    let sections: [[TrackMenuItem]]

    var items: [TrackMenuItem] { sections.flatMap { $0 } }

    static func make(subject: TrackMenuSubject, context: TrackMenuContext) -> TrackMenuModel {
        let rows = subject.rows
        guard !rows.isEmpty else { return TrackMenuModel(sections: []) }
        let single = rows.count == 1
        var reachableLocal = 0
        var unreachable = 0
        var downloadable = 0
        var hasLink = false
        for row in rows {
            if TrackRowPresentation.isUnreachable(availability: row.availability, fileLocation: row.fileLocation, live: subject.live) {
                unreachable += 1
            } else {
                switch row.availability {
                case .local: reachableLocal += 1
                case .failed, .notDownloaded: downloadable += 1
                case .fileMissing, .downloading: break
                }
            }
            if !hasLink, TrackLinks.sourceURL(row.track) != nil { hasLink = true }
        }
        let offlineName = unreachable > 0 ? subject.live.offlineVolumeName : nil

        var header: [TrackMenuItem] = []
        if !single { header.append(.countHeader(rows.count)) }
        if let offlineName { header.append(.driveHeader(volumeName: offlineName)) }

        // 1 Primary
        var primary: [TrackMenuItem] = []
        if context.canActivate {
            if single {
                let row = rows[0]
                if unreachable > 0 {
                    primary.append(.play(enabled: false))
                } else if row.availability != .fileMissing {
                    primary.append(.play(enabled: true))  // local plays; others download, then play
                }
            } else if reachableLocal > 0 {
                primary.append(.play(enabled: true))
            } else if unreachable > 0 {
                primary.append(.play(enabled: false))
            }
        }
        // Preview needs one track with a file (UC-CM-04); disabled while its disk is away.
        if single, context.canPreview {
            let row = rows[0]
            if unreachable > 0 {
                primary.append(.preview(enabled: false))
            } else if row.availability == .local {
                primary.append(.preview(enabled: true))
            }
        }

        if context.container == .recommendations {
            let preview = primary.filter { item in if case .preview = item { return true } else { return false } }
            return makeRecommendationMenu(rows: rows, header: header, preview: preview, unreachable: unreachable,
                                          reachableLocal: reachableLocal, hasLink: hasLink, context: context)
        }

        if let queueRows = context.queueRows {
            return makeQueueMenu(queueRows, rows: rows, header: header, reachableLocal: reachableLocal,
                                 unreachable: unreachable, downloadable: downloadable, hasLink: hasLink, context: context)
        }

        // 2 Queue — Play Next and Add to Queue queue files that can play now.
        var queue: [TrackMenuItem] = []
        if reachableLocal > 0 { queue += [.playNext, .addToQueue] }

        // 3 Add to
        var addTo: [TrackMenuItem] = context.extras.addTo.map(TrackMenuItem.extra) + [.addToPlaylist]
        if context.canAddToSyncProfile { addTo.append(.addToSyncProfile) }

        // 4 Info
        var info: [TrackMenuItem] = [.getInfo]
        if single, let album = Self.albumToGo(to: rows[0].track, in: context.container) { info.append(.goToAlbum(album)) }
        if single, let artist = TrackMetadataPresentation.artistDisplay(rows[0].track.artist) {
            info.append(.goToArtist(artist))
        }
        // `Find Similar` (W3-DISC-A): one track, in every list that is a place of the library.
        if single, context.canFindSimilar {
            if case .reviewGroup = context.container {} else { info.append(.findSimilar) }
        }
        // A place's own items stay last in the Info group.
        info += context.extras.info.map(TrackMenuItem.extra)

        // 5 Fix
        var fix: [TrackMenuItem] = context.extras.fix.map(TrackMenuItem.extra)
        if single {
            switch rows[0].availability {
            case .notDownloaded where unreachable == 0: fix.append(.download(title: "Download"))
            case .failed where unreachable == 0:
                fix.append(.download(title: "Retry Download"))
                if context.canLocate { fix.append(.locateFile) }
            case .fileMissing where unreachable == 0:
                if context.canLocate { fix.append(.locateFile) }
                if TrackLinks.hasSource(rows[0].track) { fix.append(.downloadAgain) }
            default: break
            }
        } else if downloadable > 0 {
            fix.append(.download(title: downloadable == 1
                ? "Download 1 Not-Downloaded Track"
                : "Download \(downloadable.formatted(.number)) Not-Downloaded Tracks"))
        }

        // 6 Locate / share
        var locate: [TrackMenuItem] = []
        if reachableLocal > 0 {
            locate.append(.showInFinder(enabled: true))
        } else if unreachable > 0 {
            locate.append(.showInFinder(enabled: false))
        }
        locate.append(.copy(filePath: reachableLocal > 0, link: hasLink))

        // 7 Remove — reversible first, the irreversible one last (UC-CM-07).
        var remove: [TrackMenuItem] = []
        switch context.container {
        case .playlist, .syncProfile, .genre, .album:
            if context.canRemoveFromContainer { remove.append(.removeFromContainer(title: context.removeTitle)) }
        case .queue, .library, .folder, .reviewGroup, .recommendations, .similar, .none:
            break
        }
        // A place's own items in the Remove group (`Not Now` on a suggestion, W3-GEN).
        remove += context.extras.remove.map(TrackMenuItem.extra)
        switch context.container {
        case .queue, .syncProfile:
            break  // Remove from Library does not exist there (UC-CM-07)
        case .recommendations, .similar:
            break  // not in the library yet / Similar never deletes (V-SIMILAR.N07)
        case .library, .playlist, .folder, .genre, .album, .reviewGroup, .none:
            // Trashing files needs their disk (UC-CM-05).
            remove.append(.removeFromLibrary(enabled: unreachable == 0))
        }

        let sections = [header, primary, queue, addTo, info, fix, locate, remove].filter { !$0.isEmpty }
        return TrackMenuModel(sections: sections)
    }

    /// The album `Go to Album` opens for a track — its `album_id`, except inside that very album.
    static func albumToGo(to track: Track, in container: TrackListContainer) -> Int64? {
        guard let albumID = track.albumId else { return nil }
        if case .album(let current, _) = container, current == albumID { return nil }
        return albumID
    }

    /// The menu of a held recommendation (V-INBOX.N07, CM-REC): Preview — Keep · Keep and Add to
    /// Playlist ▸ — Go to Seed Track · Find Similar — Show in Finder · Copy ▸ — Dismiss. Nothing
    /// that plays or queues, nothing that treats it as a library track yet.
    private static func makeRecommendationMenu(
        rows: [TrackRow], header: [TrackMenuItem], preview: [TrackMenuItem], unreachable: Int,
        reachableLocal: Int, hasLink: Bool, context: TrackMenuContext
    ) -> TrackMenuModel {
        let single = rows.count == 1
        let keep: [TrackMenuItem] = context.extras.addTo.map(TrackMenuItem.extra) + [.keepAndAddToPlaylist]
        var info: [TrackMenuItem] = context.extras.info.map(TrackMenuItem.extra)
        if single { info.append(.findSimilar) }
        var locate: [TrackMenuItem] = []
        if reachableLocal > 0 {
            locate.append(.showInFinder(enabled: true))
        } else if unreachable > 0 {
            locate.append(.showInFinder(enabled: false))
        }
        locate.append(.copy(filePath: reachableLocal > 0, link: hasLink))
        let remove = context.extras.remove.map(TrackMenuItem.extra)
        let sections = [header, preview, keep, info, locate, remove].filter { !$0.isEmpty }
        return TrackMenuModel(sections: sections)
    }

    /// The Queue panel's menu (CM-QUEUE / CM-QUEUE.N01): the same group order, a safe Remove
    /// group — `Remove from Queue` for Next rows, `Clear History` for History rows — and never
    /// `Remove from Library…` (UC-CM-07). Add to Queue is left out for rows already in Next.
    private static func makeQueueMenu(
        _ queueRows: QueueMenuRows, rows: [TrackRow], header: [TrackMenuItem], reachableLocal: Int,
        unreachable: Int, downloadable: Int, hasLink: Bool, context: TrackMenuContext
    ) -> TrackMenuModel {
        let single = rows.count == 1
        var primary: [TrackMenuItem] = []
        var queue: [TrackMenuItem] = []
        var info: [TrackMenuItem] = [.getInfo]
        var fix: [TrackMenuItem] = []
        var remove: [TrackMenuItem] = []
        switch queueRows {
        case .next(let contextName):
            // Play ↩ (jump to it) · Preview — Play Next · Move to End of Queue.
            if single {
                primary.append(.play(enabled: unreachable == 0))
                if context.canPreview, unreachable > 0 || rows[0].availability == .local {
                    primary.append(.preview(enabled: unreachable == 0))
                }
            }
            queue = [.playNext, .moveToEndOfQueue]
            if single, let album = Self.albumToGo(to: rows[0].track, in: context.container) { info.append(.goToAlbum(album)) }
            if single, let artist = TrackMetadataPresentation.artistDisplay(rows[0].track.artist) {
                info.append(.goToArtist(artist))
            }
            if single, let contextName { info.append(.showInContext(name: contextName)) }
            if downloadable > 0 {
                let title: String
                if single {
                    if case .failed = rows[0].availability { title = "Retry Download" } else { title = "Download" }
                } else {
                    title = downloadable == 1
                        ? "Download 1 Not-Downloaded Track"
                        : "Download \(downloadable.formatted(.number)) Not-Downloaded Tracks"
                }
                fix.append(.download(title: title))
            }
            remove = [.removeFromContainer(title: "Remove from Queue")]
        case .history(let canPlay):
            if single, let album = Self.albumToGo(to: rows[0].track, in: context.container) { info.append(.goToAlbum(album)) }
            if single, canPlay { primary.append(.play(enabled: unreachable == 0)) }
            if reachableLocal > 0 { queue = [.playNext, .addToQueue] }
            remove = [.clearHistory]
        }
        var locate: [TrackMenuItem] = []
        if reachableLocal > 0 {
            locate.append(.showInFinder(enabled: true))
        } else if unreachable > 0 {
            locate.append(.showInFinder(enabled: false))
        }
        locate.append(.copy(filePath: reachableLocal > 0, link: hasLink))
        let addTo: [TrackMenuItem] = context.canAddToSyncProfile ? [.addToPlaylist, .addToSyncProfile] : [.addToPlaylist]
        let sections = [header, primary, queue, addTo, info, fix, locate, remove].filter { !$0.isEmpty }
        return TrackMenuModel(sections: sections)
    }
}

// MARK: - Links

enum TrackLinks {
    /// The track's source page (`Copy ▸ Link`): the original path when it is a web URL.
    static func sourceURL(_ track: Track) -> URL? {
        let raw = track.originalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.hasPrefix("https://") || raw.hasPrefix("http://"), let url = URL(string: raw) else { return nil }
        return url
    }

    /// Source identifiers the importers write into `original_path` (`soundcloud://123`,
    /// `spotify://track/…`, `RemoteTrackMaterializer`'s `‹source›://‹id›`).
    static let sourceSchemes: Set<String> = ["soundcloud", "spotify", "youtube", "dab", "qobuz", "applemusic", "apple-music", "deezer", "tidal"]

    /// The track came from a real remote source — a web URL or a known source identifier — so
    /// the download pipeline can fetch it again (`Download Again`, §15.4). Imported files,
    /// Reels (`reels://`) and anything unknown don't qualify.
    static func hasSource(_ track: Track) -> Bool {
        if sourceURL(track) != nil { return true }
        let raw = track.originalPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let range = raw.range(of: "://"), range.lowerBound > raw.startIndex,
              raw[range.upperBound...].contains(where: { !$0.isWhitespace }) else { return false }
        return sourceSchemes.contains(String(raw[..<range.lowerBound]))
    }
}
