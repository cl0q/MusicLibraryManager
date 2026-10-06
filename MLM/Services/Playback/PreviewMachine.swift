import Foundation

// MARK: - Preview (P-PREVIEW variant A, DEC-009 as revised by §10 Q1, DEC-010, DEC-047)

/// What Space found on the selected rows of the focused list.
enum PreviewCandidate: Equatable, Sendable {
    /// One track whose file can be used now.
    case previewable(Track)
    /// A suggestion or result that isn't in the library: `page` is its SoundCloud or YouTube
    /// link, resolved to a stream when the preview starts (IMP-109). Nothing is downloaded into
    /// the library and nothing is saved.
    case stream(URL, title: String)
    /// The selection can't be previewed; the status bar says why (UC-STATUS-07).
    case refused(PlaybackWords.PreviewRefusal)
    /// Nothing is selected: Space does nothing, silently.
    case nothing

    /// The track a preview session shows and plays: the library track, or the stand-in of a
    /// stream (no id, `format == "stream"`, the link as its path).
    var previewTrack: Track? {
        switch self {
        case .previewable(let track): return track
        case .stream(let page, let title): return Track.previewStream(page: page, title: title)
        case .refused, .nothing: return nil
        }
    }

    /// From the focused table's selected rows in display order and the window's drive state
    /// (persisted availability only — no disk access, UC-TABLE-20).
    static func make(rows: [TrackRow], live: TrackTableLiveState) -> PreviewCandidate {
        guard let row = rows.first else { return .nothing }
        guard rows.count == 1 else { return .refused(.notSingle) }
        if TrackRowPresentation.isUnreachable(availability: row.availability, fileLocation: row.fileLocation, live: live) {
            return .refused(.driveNotConnected(volumeName: live.offlineVolumeName))
        }
        switch row.availability {
        case .local: return .previewable(row.track)
        case .fileMissing: return .refused(.fileMissing)
        case .notDownloaded, .failed, .downloading: return .refused(.notDownloaded)
        }
    }
}

/// What the main playback was doing when a preview started — restored when it ends.
struct MainPlaybackSnapshot: Equatable, Sendable {
    var trackID: Int64?
    var position: TimeInterval
    var wasPlaying: Bool

    static let nothing = MainPlaybackSnapshot(trackID: nil, position: 0, wasPlaying: false)
}

/// The previewed file, ready to open.
struct ResolvedPreview: Equatable, Sendable {
    let url: URL
    /// The analysed drop (`track_embeddings.drop_offset`), when there is one.
    let dropOffset: TimeInterval?
}

/// Where a preview starts (THOUGHTS §7.8, UC-KEY-01): the analysed drop, else 0:30; tracks
/// shorter than a minute start at a quarter of their length.
enum PreviewHotSpot {
    static let defaultStart: TimeInterval = 30
    static let shortTrack: TimeInterval = 60

    static func start(dropOffset: TimeInterval?, duration: TimeInterval) -> TimeInterval {
        guard duration.isFinite, duration > 0 else { return 0 }
        if let dropOffset, dropOffset > 0, dropOffset < duration - 1 { return dropOffset }
        if duration < shortTrack { return duration * 0.25 }
        return defaultStart
    }
}

/// Who owns a preview: the focused list it was started from (its selection moves it).
typealias PreviewOwner = String

/// The preview as a pure state machine. Each event returns the effects the driver
/// (`PreviewController`) carries out in order; nothing here touches audio, the disk or time.
///
/// ```
///            Space (previewable)                 resolved(ok)
///   idle ─────────────────────────▶ loading ───────────────────▶ playing ◀─┐ pause/resume
///    ▲                                │  ▲                          │  │ │  └─ (media key)
///    │  Space · Esc · finished ·      │  │ settle(new row)          │  │ └─ ←/→ seek ±5 s
///    │  unpreviewable selection ·     │  └──────────────────────────┘  │
///    │  resolve/open failed           │      ↑/↓ → pending (debounce)  │
///    ├────────────── end: stop preview, restore main ◀──────────────────┤
///    └────────────── Return: hand over (play for real), main not restored
/// ```
struct PreviewMachine: Equatable {
    enum Phase: Equatable {
        /// Waiting for the file and the hot spot of `track`.
        case loading(Track, token: Int)
        /// The preview audio runs (or is paused by the Play/Pause media key).
        case playing(Track, token: Int, isPaused: Bool)

        var track: Track {
            switch self {
            case .loading(let track, _), .playing(let track, _, _): track
            }
        }

        var token: Int {
            switch self {
            case .loading(_, let token), .playing(_, let token, _): token
            }
        }
    }

    struct Pending: Equatable {
        let candidate: PreviewCandidate
        let token: Int
    }

    struct Session: Equatable {
        let owner: PreviewOwner
        /// What to give back to the main playback; a pause during the preview clears
        /// `wasPlaying` (the user asked for silence, W2-C review S5).
        var main: MainPlaybackSnapshot
        var phase: Phase
        /// The selection moved; switch when the debounce for `token` settles.
        var pending: Pending?
    }

    enum Effect: Equatable {
        /// Pause the main playback (its position stays).
        case suspendMain
        /// Find the file and the hot spot of `track`; answer with `resolved(token:_:)`.
        case resolve(Track, token: Int)
        /// Open and play the preview from its hot spot; a failure answers `openFailed`.
        case startAudio(ResolvedPreview, token: Int)
        case stopAudio
        case pauseAudio
        case resumeAudio
        case seekAudio(by: TimeInterval)
        /// Resume the main playback where it was if it was playing (stays paused otherwise).
        case restoreMain(MainPlaybackSnapshot)
        /// Call `settle(token:)` after the debounce.
        case scheduleSettle(token: Int)
        /// Status-bar sentence (UC-STATUS-07).
        case report(PlaybackWords.PreviewRefusal)
        /// Return: stop the preview and play `track` for real (from the previewed position
        /// when it is the previewed track); the main playback is replaced, not restored.
        case handOver(Track, fromPreviewPosition: Bool)
        /// The visible state changed (player, Now Playing).
        case changed
    }

    private(set) var session: Session?
    private var lastToken = 0

    var isActive: Bool { session != nil }
    /// The list the running preview belongs to.
    var owner: PreviewOwner? { session?.owner }
    var track: Track? { session?.phase.track }
    var isLoading: Bool {
        if case .loading = session?.phase { return true }
        return false
    }
    var isPaused: Bool {
        if case .playing(_, _, let paused) = session?.phase { return paused }
        return false
    }

    private mutating func newToken() -> Int {
        lastToken += 1
        return lastToken
    }

    // MARK: Events

    /// Space on the focused list (also Track ▸ Preview): start a preview of the candidate, or
    /// end the running one (whatever is selected).
    mutating func toggle(owner: PreviewOwner, candidate: PreviewCandidate, main: MainPlaybackSnapshot) -> [Effect] {
        if session != nil { return end() }
        switch candidate {
        case .nothing:
            return []
        case .refused(let refusal):
            return [.report(refusal)]
        case .previewable, .stream:
            guard let track = candidate.previewTrack else { return [] }
            let token = newToken()
            session = Session(owner: owner, main: main, phase: .loading(track, token: token))
            return [.suspendMain, .resolve(track, token: token), .changed]
        }
    }

    /// Esc: ends a running preview. Returns whether the key was used (else it belongs to the
    /// next cancellable thing, UC-KEY-04).
    mutating func escape() -> (handled: Bool, effects: [Effect]) {
        guard session != nil else { return (false, []) }
        return (true, end())
    }

    /// The owner's selection changed: the preview follows it after the debounce (UC-KEY-06).
    /// Other lists' selections don't touch it.
    mutating func selectionChanged(owner: PreviewOwner, candidate: PreviewCandidate) -> [Effect] {
        guard var current = session, current.owner == owner else { return [] }
        if let track = candidate.previewTrack, Self.isSame(track, current.phase.track) {
            current.pending = nil
            session = current
            return []
        }
        let token = newToken()
        current.pending = Pending(candidate: candidate, token: token)
        session = current
        return [.scheduleSettle(token: token)]
    }

    /// The debounce for `token` ran out: switch to the pending row, or end when it can't be
    /// previewed (with its reason) or nothing single is selected.
    mutating func settle(token: Int) -> [Effect] {
        guard var current = session, let pending = current.pending, pending.token == token else { return [] }
        switch pending.candidate {
        case .previewable, .stream:
            guard let track = pending.candidate.previewTrack else { return [] }
            current.pending = nil
            current.phase = .loading(track, token: token)
            session = current
            return [.stopAudio, .resolve(track, token: token), .changed]
        case .refused(let refusal):
            return end() + [.report(refusal)]
        case .nothing:
            return end()
        }
    }

    /// The same library track, or the same stream link.
    private static func isSame(_ a: Track, _ b: Track) -> Bool {
        if a.isPreviewStream || b.isPreviewStream { return a.isPreviewStream && b.isPreviewStream && a.originalPath == b.originalPath }
        return a.id != nil && a.id == b.id
    }

    /// The file and hot spot of the loading track are known (or it turned out unusable).
    mutating func resolved(token: Int, _ result: Result<ResolvedPreview, PreviewResolveFailure>) -> [Effect] {
        guard var current = session, case .loading(let track, let loading) = current.phase, loading == token else { return [] }
        switch result {
        case .success(let resolved):
            current.phase = .playing(track, token: token, isPaused: false)
            session = current
            return [.startAudio(resolved, token: token), .changed]
        case .failure(let failure):
            return end() + [.report(failure.refusal)]
        }
    }

    /// The preview file couldn't be opened or decoded.
    mutating func openFailed(token: Int, _ failure: PreviewResolveFailure) -> [Effect] {
        guard session?.phase.token == token else { return [] }
        return end() + [.report(failure.refusal)]
    }

    /// The previewed track played to its end: end the preview and resume the main track.
    mutating func finished(token: Int) -> [Effect] {
        guard case .playing(_, let playing, _)? = session?.phase, playing == token else { return [] }
        return end()
    }

    /// ← / → while previewing (DEC-047). Returns whether the key was used.
    mutating func seek(by delta: TimeInterval) -> (handled: Bool, effects: [Effect]) {
        guard let current = session else { return (false, []) }
        if case .playing = current.phase { return (true, [.seekAudio(by: delta)]) }
        return (true, [])
    }

    /// Play/Pause (media key, toolbar, Playback menu, Dock) during a preview pauses or resumes
    /// the preview audio; the preview stays (IMP-W2C-01). Pausing also means the main track
    /// stays paused when the preview ends (headphones unplugged, S5).
    mutating func togglePause() -> [Effect] {
        guard var current = session, case .playing(let track, let token, let paused) = current.phase else { return [] }
        current.phase = .playing(track, token: token, isPaused: !paused)
        if !paused { current.main.wasPlaying = false }
        session = current
        return [paused ? .resumeAudio : .pauseAudio, .changed]
    }

    /// Return / double-click while previewing: play `track` for real (UC-KEY-06) — from the
    /// previewed position when it is the previewed track. The preview ends; main is replaced.
    mutating func handOver(_ track: Track) -> [Effect] {
        guard let current = session else { return [] }
        let samePlaying: Bool
        if case .playing(let previewed, _, _) = current.phase, previewed.id != nil, previewed.id == track.id {
            samePlaying = true
        } else {
            samePlaying = false
        }
        session = nil
        return [.handOver(track, fromPreviewPosition: samePlaying), .changed]
    }

    /// The owning list stopped being the visible place (another sidebar place, a pushed detail,
    /// the search pane) or went away: its preview ends, the main track resumes (S4).
    mutating func ownerGone(_ owner: PreviewOwner) -> [Effect] {
        guard session?.owner == owner else { return [] }
        return end()
    }

    /// Real playback started elsewhere (Play, Next, Previous, Stop, a queue row): the preview
    /// stops and the main state it saved is dropped.
    mutating func abandon() -> [Effect] {
        guard session != nil else { return [] }
        session = nil
        return [.stopAudio, .changed]
    }

    /// End the preview: stop it and give the main playback back as it was. `resumeMain: false`
    /// (the library disk went away) leaves the main track paused.
    mutating func end(resumeMain: Bool = true) -> [Effect] {
        guard let current = session else { return [] }
        session = nil
        var main = current.main
        if !resumeMain { main.wasPlaying = false }
        return [.stopAudio, .restoreMain(main), .changed]
    }
}

/// Why a preview couldn't start after the candidate looked fine (found at open time).
enum PreviewResolveFailure: Error, Equatable, Sendable {
    case notDownloaded
    case fileMissing
    case driveNotConnected(volumeName: String?)
    case unreadable
    /// A stream couldn't be resolved or fetched (`Couldn’t preview “‹title›” — ‹cause›`).
    case stream(title: String, cause: String)

    var refusal: PlaybackWords.PreviewRefusal {
        switch self {
        case .stream(let title, let cause): .streamFailed(title: title, cause: cause)
        case .notDownloaded: .notDownloaded
        case .fileMissing: .fileMissing
        case .driveNotConnected(let name): .driveNotConnected(volumeName: name)
        case .unreadable: .unreadable
        }
    }
}
