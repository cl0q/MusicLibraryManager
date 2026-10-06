import CoreTransferable
import Foundation

// MARK: - What the Queue panel shows (P-QUEUE, UC-TRAIL-05, V-QUEUE.E01–E05) — pure

/// One row of the Queue panel: a queue entry with its prebuilt track row (no formatting, no
/// disk access when drawing, UC-TABLE-20).
struct QueuePanelRow: Identifiable, Equatable {
    enum Place: Equatable {
        case nowPlaying
        case next(QueueLane)
        case history
    }

    /// The entry's own identity (selection, drag, menus, undo).
    var id: UUID { entry.id }
    let entry: QueueEntry
    let place: Place
    let row: TrackRow

    var track: Track { entry.track }
    var isInNext: Bool {
        if case .next = place { return true }
        return false
    }
}

/// An item of the `Next` section's list: the entries of both lanes with the
/// `From “‹context›”` divider between them, or the empty sentence.
enum QueueNextItem: Identifiable, Equatable {
    case entry(QueuePanelRow)
    case divider
    case empty

    static let dividerID = UUID(uuidString: "D1D1D1D1-0000-4000-8000-000000000001")!
    static let emptyID = UUID(uuidString: "E0E0E0E0-0000-4000-8000-000000000002")!

    var id: UUID {
        switch self {
        case .entry(let row): row.id
        case .divider: Self.dividerID
        case .empty: Self.emptyID
        }
    }
}

/// The three sections, built from the playback state (`PlaybackViewModel`) and the window's
/// live state (the drive).
struct QueuePanelContent: Equatable {
    var nowPlaying: QueuePanelRow?
    var playNext: [QueuePanelRow]
    var context: [QueuePanelRow]
    /// Most recent first, without the playing entry.
    var history: [QueuePanelRow]
    /// Where the context came from, when it still exists (`From “Warm-up”` is then a link).
    var origin: PlaybackOrigin?
    /// The context's name as the header shows it.
    var contextName: String?
    /// Seconds of Next that can play now (unplayable rows are not counted, P-QUEUE.N09).
    var playableSeconds: Int
    /// Nothing plays after the playing track: Next is empty and Repeat All has no pass to play
    /// again (W2-D review S1).
    var playbackStopsAfterCurrent = false

    static let empty = QueuePanelContent(nowPlaying: nil, playNext: [], context: [], history: [], origin: nil,
                                         contextName: nil, playableSeconds: 0)

    /// The current names of the lists a context can come from (a playlist renamed since it
    /// started playing shows its new name).
    struct ListNames {
        var playlists: [Int64: String] = [:]
        var syncProfiles: [Int64: String] = [:]

        init(playlists: [Playlist] = [], syncProfiles: [SyncProfile] = []) {
            for playlist in playlists { if let id = playlist.id { self.playlists[id] = playlist.name } }
            for profile in syncProfiles { if let id = profile.id { self.syncProfiles[id] = profile.name } }
        }
    }

    /// - Parameters:
    ///   - origin: where the context was played from (`PlaybackViewModel.playingOrigin`), already
    ///     validated (nil when its playlist or profile no longer exists).
    static func make(
        current: Track?,
        currentEntryID: UUID?,
        queue: PlaybackQueue,
        history: [QueueEntry],
        origin: PlaybackOrigin?,
        live: TrackTableLiveState,
        repeatsAll: Bool = false,
        listNames: ListNames = ListNames()
    ) -> QueuePanelContent {
        func row(_ entry: QueueEntry, _ place: QueuePanelRow.Place, position: Int) -> QueuePanelRow? {
            guard let id = entry.track.id else { return nil }
            var cache: [Substring: String] = [:]
            let built = TrackRowBuilder.row(for: entry.track, id: id, position: position, context: .library, dayCache: &cache)
            return QueuePanelRow(entry: entry, place: place, row: built)
        }
        var nowPlaying: QueuePanelRow?
        if let current {
            nowPlaying = row(QueueEntry(id: currentEntryID ?? Self.nowPlayingFallbackID, track: current), .nowPlaying, position: 0)
        }
        let playNext = queue.playNextEntries.enumerated().compactMap { row($1, .next(.playNext), position: $0 + 1) }
        let context = queue.contextEntries.enumerated().compactMap {
            row($1, .next(.context), position: playNext.count + $0 + 1)
        }
        // One row per identity in the whole list (never two rows with one id).
        let shown = Set((playNext + context).map(\.id)).union(nowPlaying.map { [$0.id] } ?? [])
        let past = history.filter { !shown.contains($0.id) }.reversed()
        let historyRows = past.enumerated().compactMap { row($1, .history, position: $0 + 1) }
        let seconds = (playNext + context).reduce(0) { total, item in
            Self.canPlayNow(item.row, live: live) ? total + max(item.track.duration ?? 0, 0) : total
        }
        var content = QueuePanelContent(nowPlaying: nowPlaying, playNext: playNext, context: context, history: historyRows,
                                        origin: origin, contextName: origin.flatMap { Self.name(of: $0, names: listNames) },
                                        playableSeconds: seconds)
        content.playbackStopsAfterCurrent = nowPlaying != nil && queue.isEmpty && !(repeatsAll && !queue.cycleEntries.isEmpty)
        return content
    }

    /// The Now playing row of a file without a History entry (a loaded file that isn't a
    /// queued library track).
    static let nowPlayingFallbackID = UUID(uuidString: "0A0A0A0A-0000-4000-8000-000000000003")!

    /// The row can play now: it has a file and its disk is there.
    static func canPlayNow(_ row: TrackRow, live: TrackTableLiveState) -> Bool {
        row.availability == .local
            && !TrackRowPresentation.isUnreachable(availability: row.availability, fileLocation: row.fileLocation, live: live)
    }

    /// The name of the list a context came from, as it is called now: `“Warm-up”`, `All Tracks`.
    static func name(of origin: PlaybackOrigin, names: ListNames = ListNames()) -> String? {
        switch origin.container {
        case .library: "All Tracks"
        case .playlist(let id, let name): "“\(names.playlists[id] ?? name)”"
        case .syncProfile(let id, let name): "“\(names.syncProfiles[id] ?? name)”"
        case .folder(let path, let name): path.isEmpty ? "Folders" : "“\(name)”"
        case .genre(_, let name): "“\(name)”"
        case .queue, .reviewGroup, .none: nil
        }
    }

    var next: [QueuePanelRow] { playNext + context }
    var isNextEmpty: Bool { playNext.isEmpty && context.isEmpty }
    var isEmpty: Bool { nowPlaying == nil && isNextEmpty && history.isEmpty }

    /// The `Next` section's list items, in display order.
    var nextItems: [QueueNextItem] {
        if isNextEmpty { return [.empty] }
        return playNext.map(QueueNextItem.entry) + (context.isEmpty ? [] : [.divider] + context.map(QueueNextItem.entry))
    }

    /// Every row in display order (Now playing, Next, History).
    var allRows: [QueuePanelRow] { (nowPlaying.map { [$0] } ?? []) + next + history }

    /// The rows of `ids` in display order.
    func rows(_ ids: Set<UUID>) -> [QueuePanelRow] {
        allRows.filter { ids.contains($0.id) }
    }

    /// Where a drop at `offset` in `nextItems` lands.
    func position(forDropAt offset: Int) -> QueuePosition {
        if isNextEmpty { return .top }
        return QueuePosition.forDisplayOffset(offset, playNextCount: playNext.count, hasDivider: !context.isEmpty)
    }

    /// A drop at `offset` in `nextItems`, named by what the insertion line sits next to — the
    /// row below it, the divider, or the end — so it is resolved against the queue when the
    /// drop applies, not against this (possibly older) list.
    func dropTarget(forDropAt offset: Int) -> QueueDropTarget {
        let items = nextItems
        guard offset < items.count else { return .end }
        switch items[max(offset, 0)] {
        case .entry(let row): return .before(row.id, fallback: position(forDropAt: offset))
        case .divider: return .endOfPlayNext
        case .empty: return .position(.top)
        }
    }

    /// Tracks Save as Playlist… keeps: Now playing + Next, in queue order (P-QUEUE.N15).
    var tracksToSave: [Track] {
        (nowPlaying.map { [$0.track] } ?? []) + next.map(\.track)
    }

    /// The menu kind for a subject (CM-QUEUE / CM-QUEUE.N01).
    func menuRows(for subject: [QueuePanelRow]) -> QueueMenuRows {
        if subject.contains(where: \.isInNext) {
            let contextRow = subject.count == 1 && subject[0].place == .next(.context)
            return .next(contextName: contextRow ? contextName : nil)
        }
        let onlyPlaying = subject.count == 1 && subject[0].place == .nowPlaying
        return .history(canPlay: !onlyPlaying)
    }
}

// MARK: - Words (`queue.html`, UC-EMPTY-03, §15.7)

enum QueuePanelWords {
    static let nowPlaying = "Now playing"
    static let next = "Next"
    static let history = "History"
    /// The player's idle word (§15.7) in the empty Now playing section.
    static let notPlaying = "Not playing"
    static let queueEmptyTitle = "Queue is empty"
    static let queueEmptySentence = "Return plays the selected track and queues what follows. Play Next (⌥↩) puts tracks here without interrupting."
    static let stopsAfterThisTrack = "Playback stops after this track."
    static let noHistory = "No history yet."
    static let clear = "Clear"
    static let saveAsPlaylist = "Save as Playlist…"
    static let keptNote = "Kept when you quit. MLM reopens with this queue, paused."
    static let unavailableTitle = "Playback isn’t available"
    static let unavailableSentence = "Open a library to play its tracks."
    /// The context divider when its list has no name (search results).
    static let unnamedContext = "From the played list"

    /// `From “Warm-up”` · `From All Tracks`.
    static func contextHeader(_ name: String?) -> String {
        name.map { "From \($0)" } ?? unnamedContext
    }

    /// `14 tracks · 52 min` — how much is queued; time only of what can play now.
    static func nextSummary(count: Int, playableSeconds: Int) -> String {
        "\(StatusBarText.tracks(count)) · \(TrackDurationText.total(playableSeconds))"
    }

    /// The line above the sections while the library's disk is away (P-QUEUE.N14).
    static func driveAway(_ volumeName: String) -> String {
        "“\(volumeName)” is not connected. The queue is kept; playback continues when “\(volumeName)” is back."
    }

    /// Help of a disabled `Clear`.
    static let clearDisabledHelp = "Nothing is queued in Next."
    /// Help of a disabled `Save as Playlist…`.
    static let saveDisabledHelp = "Nothing is playing or queued."

    // Save Queue as Playlist popover (P-QUEUE.N15, UC-SHEET-10, §23 C8)
    static let saveTitle = "Save Queue as Playlist"
    static let saveCreate = "Create"
    static let saveCancel = "Cancel"

    /// `Queue — 5 Oct 2026` (the date in the user's format, UC-COPY-10).
    static func defaultPlaylistName(date: Date = Date()) -> String {
        "Queue — \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    /// `12 tracks, in queue order`
    static func saveCount(_ count: Int) -> String {
        "\(StatusBarText.tracks(count)), in queue order"
    }

    /// `Created playlist “Queue — 5 Oct 2026” with 12 tracks`
    static func created(name: String, count: Int) -> String {
        "Created playlist “\(name)” with \(StatusBarText.tracks(count))"
    }

    static let saveActionName = "Save Queue as Playlist"
}

// MARK: - Drag and drop payload

/// What a Queue row drags, and what the Queue panel and the player accept: a track (from any
/// track list — `TrackDragData`'s JSON decodes as this) or a queue entry (a row of the panel,
/// for reordering). One representation under the track-drag type, so every existing track drop
/// target (playlists, sidebar) reads a dragged queue row as its track (`trackId`; the extra
/// `queueEntryId` is ignored there). The full cross-app payload is W2-H's.
struct QueueRowDrag: Codable, Transferable, Equatable, Sendable {
    let trackId: Int64
    var sourcePlaylistId: Int64?
    /// Set when the drag is a row of the Queue panel.
    var queueEntryId: UUID?

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .trackDrag)
    }
}
