import Foundation

// MARK: - Can a queued track play now? (DEC-045, PP-MAIN-01)

/// Whether a track can play **now**, decided from its persisted availability and the drive
/// state only — never by probing the disk (UC-TABLE-20). The file itself is opened (and found
/// missing, if it is) only when the track is about to play.
enum PlaybackPlayability: Equatable, Hashable, Sendable {
    case playable
    /// Not downloaded, Download failed or still downloading — there is no file yet.
    case notDownloaded
    /// `File missing` (persisted, or found missing at open time while its folder was reachable).
    case fileMissing
    /// The file is on a disk that is not connected (DEC-014: never `File missing`).
    case driveNotConnected
    /// The file is there but macOS couldn't open or decode it (found at open time only).
    case unreadable

    var isPlayable: Bool { self == .playable }

    /// From persisted fields and the library disk's state (`offlineVolumePath` = the library
    /// disk's `/Volumes/‹name›` while it is not connected; `nil` = connected or on this Mac).
    static func of(_ track: Track, offlineVolumePath: String?) -> PlaybackPlayability {
        let availability = track.availability()
        if availability.hasFile, let offlineVolumePath,
           TrackRowBuilder.fileLocation(track.organizedPath).isOnVolume(offlineVolumePath) {
            return .driveNotConnected
        }
        switch availability {
        case .local: return .playable
        case .fileMissing: return .fileMissing
        case .notDownloaded, .failed, .downloading: return .notDownloaded
        }
    }
}

/// Playback ▸ Repeat (UC-MENU-05): Off · All · One.
enum PlaybackRepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one

    var title: String {
        switch self {
        case .off: "Off"
        case .all: "All"
        case .one: "One"
        }
    }

    /// Where the choice is remembered between launches (app-wide).
    static let defaultsKey = "playback_repeat_mode"
}

/// A track the queue passed over because it couldn't play.
struct SkippedTrack: Equatable, Sendable {
    let track: Track
    let reason: PlaybackPlayability
}

// MARK: - The decision (pure)

/// The one place that decides what plays next — Next, auto-advance at the end of a track,
/// Previous, and "play this row with the following rows as context" all go through it.
///
/// Pure: it sees the queue, the current track, the repeat mode and a `playability` verdict
/// per track (persisted availability + drive state, plus what the caller learned at open
/// time). It never loops forever: every call consumes each queued item at most once, and
/// Repeat All restarts the cycle at most once per call.
enum QueueAdvance {
    /// Why the queue is advancing.
    enum Trigger: Equatable, Sendable {
        /// Next ⌘→, the media key, the toolbar button.
        case userNext
        /// The current track played to its end.
        case trackEnded
    }

    struct Result: Equatable {
        /// What to play now; `nil` = nothing playable remains (or the queue is exhausted).
        var track: Track?
        /// The queue after taking `track` and the skipped items out.
        var queue: PlaybackQueue
        /// Tracks passed over, in queue order (each once).
        var skipped: [SkippedTrack]
        /// `track` is the current track again (Repeat One at the end of a track).
        var repeatsCurrent = false
    }

    /// Next / auto-advance.
    static func next(
        queue: PlaybackQueue,
        current: Track?,
        repeatMode: PlaybackRepeatMode,
        trigger: Trigger,
        playability: (Track) -> PlaybackPlayability
    ) -> Result {
        // Repeat One replays the track that just ended; Next still moves on (as in Music).
        if trigger == .trackEnded, repeatMode == .one, let current, playability(current).isPlayable {
            return Result(track: current, queue: queue, skipped: [], repeatsCurrent: true)
        }
        var proposed = queue
        var skipped: [SkippedTrack] = []
        var skippedIDs = Set<Int64>()
        var restarted = false
        while true {
            guard let candidate = proposed.advance() else {
                if repeatMode == .all, !restarted, proposed.restartCycle() {
                    restarted = true
                    continue
                }
                return Result(track: nil, queue: proposed, skipped: skipped)
            }
            let verdict = playability(candidate)
            if verdict.isPlayable {
                return Result(track: candidate, queue: proposed, skipped: skipped)
            }
            let key = candidate.id ?? Int64.min
            if candidate.id == nil || skippedIDs.insert(key).inserted {
                skipped.append(SkippedTrack(track: candidate, reason: verdict))
            }
        }
    }

    /// Previous (UC-TB-09): restart the current track when more than 3 s have played, else go
    /// to the most recent playable track in `history`; history items that can't play now are
    /// passed over (and dropped from history).
    enum PreviousDecision: Equatable {
        /// Seek the current track to 0.
        case restartCurrent(skipped: [SkippedTrack])
        /// Play `track`; `history` is the history without it and without the passed items.
        case play(Track, history: [Track], skipped: [SkippedTrack])
    }

    static func previous(
        history: [Track],
        current: Track?,
        position: TimeInterval,
        playability: (Track) -> PlaybackPlayability
    ) -> PreviousDecision {
        if current != nil, position > PlaybackQueue.backRestartThreshold {
            return .restartCurrent(skipped: [])
        }
        var proposed = history
        if let current, let index = proposed.lastIndex(where: { $0.id == current.id }) {
            proposed.remove(at: index)
        }
        var skipped: [SkippedTrack] = []
        while let candidate = proposed.popLast() {
            let verdict = playability(candidate)
            if verdict.isPlayable {
                return .play(candidate, history: proposed, skipped: skipped)
            }
            skipped.append(SkippedTrack(track: candidate, reason: verdict))
        }
        return .restartCurrent(skipped: skipped)
    }

    /// "Play this row; the rows after it are the context" (UC-KEY-02, UC-PRIM-01). The row
    /// itself was chosen by the user and is opened as asked; the following rows become the
    /// context (and the Repeat All cycle). Play Next items stay first.
    static func start(
        _ track: Track,
        in rows: [Track],
        queue: PlaybackQueue,
        cap: Int
    ) -> PlaybackQueue {
        let index = rows.firstIndex(where: { $0.id != nil && $0.id == track.id }) ?? rows.firstIndex(of: track)
        let following = index.map { Array(rows.dropFirst($0 + 1)) } ?? []
        var proposed = queue
        proposed.startContext(track, following: following, cap: cap)
        return proposed
    }
}
