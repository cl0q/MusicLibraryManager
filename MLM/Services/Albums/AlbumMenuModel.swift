import Foundation

// The album menus, as data (UC-CM-02, DEC-039) — pure, unit-tested (`AlbumMenuModelTests`).

/// Where an album's menu is shown: the card in the grid (CM-ALB-CARD) or the page's `More`
/// (CM-ALBD-MORE) — one builder, two subsets in one order.
enum AlbumMenuPlace: Equatable, Sendable {
    case card
    case more
}

enum AlbumMenuItem: Hashable, Sendable {
    case play
    case playNext
    case addToQueue
    case addToPlaylist
    case addToSyncProfile
    /// Get Info = Edit Album Info… (the same sheet, S-ALB-EDIT).
    case getInfo
    case goToArtist(String)
    case editAlbumInfo
    case chooseCover
    case editOrder
    case mergeWithAnother
    /// `Download ‹n› Missing`.
    case download(Int)
    case showInFinder
    case removeFromLibrary
}

enum AlbumMenuModel {
    /// What decides the sections.
    struct Facts: Equatable, Sendable {
        /// More than one album is the subject (a multi-selection of cards).
        var isMultiple = false
        /// The album artist for `Go to Artist`; nil for a compilation (plain text there).
        var artist: String?
        /// Tracks that have no file and aren't downloading.
        var missing = 0
    }

    /// Sections in the DEC-039 order: Primary · Queue · Add to · Info / edit · Fix · Locate · Remove.
    /// Groups that don't apply disappear.
    static func sections(_ place: AlbumMenuPlace, facts: Facts) -> [[AlbumMenuItem]] {
        let primary: [AlbumMenuItem] = place == .card ? [.play] : []
        let queue: [AlbumMenuItem] = [.playNext, .addToQueue]
        let addTo: [AlbumMenuItem] = [.addToPlaylist, .addToSyncProfile]
        var info: [AlbumMenuItem] = []
        switch place {
        case .card:
            if !facts.isMultiple {
                info.append(.getInfo)
                if let artist = facts.artist { info.append(.goToArtist(artist)) }
            }
        case .more:
            info = [.editAlbumInfo, .chooseCover, .editOrder, .mergeWithAnother]
        }
        let fix: [AlbumMenuItem] = facts.missing > 0 ? [.download(facts.missing)] : []
        return [primary, queue, addTo, info, fix, [.showInFinder], [.removeFromLibrary]].filter { !$0.isEmpty }
    }

    static func title(_ item: AlbumMenuItem) -> String {
        switch item {
        case .play: "Play"
        case .playNext: "Play Next"
        case .addToQueue: "Add to Queue"
        case .addToPlaylist: "Add to Playlist"
        case .addToSyncProfile: "Add to Sync Profile"
        case .getInfo: "Get Info"
        case .goToArtist: "Go to Artist"
        case .editAlbumInfo: "Edit Album Info…"
        case .chooseCover: "Choose Cover…"
        case .editOrder: "Edit Order"
        case .mergeWithAnother: "Merge with Another Album…"
        case .download(let n): "Download \(n.formatted(.number)) Missing"
        case .showInFinder: "Show in Finder"
        case .removeFromLibrary: "Remove from Library…"
        }
    }

    /// `Go to Artist` is plain text for a compilation (`Various Artists`).
    static func artistLink(albumArtist: String, isCompilation: Bool) -> String? {
        let trimmed = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isCompilation, !trimmed.isEmpty, trimmed.caseInsensitiveCompare("Various Artists") != .orderedSame else { return nil }
        return trimmed
    }
}

/// Type-to-select in the grid (UC-SEL-04): letters typed within a second of each other make one
/// prefix; a pause starts a new one. Pure, with the clock passed in.
struct AlbumTypeSelect: Equatable, Sendable {
    static let pause: TimeInterval = 1
    private(set) var buffer = ""
    private var last: Date?

    /// The prefix after `characters` were typed at `now`.
    mutating func type(_ characters: String, at now: Date) -> String {
        if let last, now.timeIntervalSince(last) > Self.pause { buffer = "" }
        last = now
        buffer += characters
        return buffer
    }

    /// The album whose title starts with `prefix` — searching after `current` first (typing the
    /// same letter again steps to the next one), case and diacritics ignored.
    static func match(_ prefix: String, in titles: [(id: Int64, title: String)], after current: Int64?) -> Int64? {
        let wanted = SearchFilter.fold(prefix)
        guard !wanted.isEmpty, !titles.isEmpty else { return nil }
        let start = current.flatMap { id in titles.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        let ordered = Array(titles[start...]) + Array(titles[..<start])
        if wanted.count > 1, let first = wanted.first, wanted.allSatisfy({ $0 == first }) {
            return ordered.first { SearchFilter.fold($0.title).hasPrefix(String(first)) }?.id
        }
        return ordered.first { SearchFilter.fold($0.title).hasPrefix(wanted) }?.id
    }
}
