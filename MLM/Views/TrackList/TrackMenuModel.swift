import Foundation

// MARK: - Track menu: the pure model (CM-TRACK, DEC-039, UC-CM-01…09)

/// One item of the track menu. The view (`TrackMenu`) renders it; the order and presence
/// rules live in `TrackMenuModel.make` and are unit-tested.
///
/// Items whose feature arrives with a later package are **absent** (context menus never show
/// dead or placeholder items, UC-CM-01): Preview (W2-C), Add to Queue (W2-D), Go to Album
/// (W4-2), Go to Artist (W2-I), Find Similar (W3-DISC), Locate File… (W2-C), Share… (W5-2),
/// Remove from Queue (W2-D).
enum TrackMenuItem: Hashable, Sendable {
    /// Disabled first line: `3 tracks` (UC-CM-04).
    case countHeader(Int)
    /// Disabled line `“Lexxar” is not connected` above disabled file actions (UC-CM-05).
    case driveHeader(volumeName: String)
    /// Play ↩ (single: the primary action — downloads first when needed; several: the playable ones).
    case play(enabled: Bool)
    case playNext
    case addToPlaylist
    case addToSyncProfile
    case getInfo
    /// `Download` · `Retry Download` · `Download 3 Not-Downloaded Tracks`.
    case download(title: String)
    /// File missing, has a source: fetch it again.
    case downloadAgain
    case showInFinder(enabled: Bool)
    case copy(filePath: Bool, link: Bool)
    /// `Remove from Playlist` / `Remove from “Warm-up”` (reversible, normal colour, ⌫).
    case removeFromContainer(title: String)
    /// `Remove from Library…` (irreversible, destructive, last, ⌘⌫).
    case removeFromLibrary(enabled: Bool)
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

    /// `Remove from Playlist` inside one playlist (UC-CM-08), `Remove from “‹profile›”`.
    var removeTitle: String {
        switch container {
        case .playlist: "Remove from Playlist"
        case .syncProfile(_, let name): "Remove from “\(name)”"
        case .queue: "Remove from Queue"
        case .library, .none: "Remove"
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

        // 2 Queue — Play Next queues files that can play now.
        var queue: [TrackMenuItem] = []
        if reachableLocal > 0 { queue.append(.playNext) }

        // 3 Add to
        var addTo: [TrackMenuItem] = [.addToPlaylist]
        if context.canAddToSyncProfile { addTo.append(.addToSyncProfile) }

        // 4 Info
        let info: [TrackMenuItem] = [.getInfo]

        // 5 Fix
        var fix: [TrackMenuItem] = []
        if single {
            switch rows[0].availability {
            case .notDownloaded where unreachable == 0: fix.append(.download(title: "Download"))
            case .failed where unreachable == 0: fix.append(.download(title: "Retry Download"))
            case .fileMissing where unreachable == 0 && TrackLinks.hasSource(rows[0].track): fix.append(.downloadAgain)
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
        case .playlist, .syncProfile:
            if context.canRemoveFromContainer { remove.append(.removeFromContainer(title: context.removeTitle)) }
        case .queue, .library, .none:
            break
        }
        switch context.container {
        case .queue, .syncProfile:
            break  // Remove from Library does not exist there (UC-CM-07)
        case .library, .playlist, .none:
            // Trashing files needs their disk (UC-CM-05).
            remove.append(.removeFromLibrary(enabled: unreachable == 0))
        }

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
