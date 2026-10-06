import Foundation

// MARK: - Kind (the job-kind map of `activity.html` W-ACTIVITY.N01)

/// Every kind of background work MLM does (inventory §10.1, DEC-044). One case per row of
/// the job-kind map; the raw value is persisted (`activity_operations.kind`), so cases are
/// only ever added.
enum ActivityKind: String, Codable, CaseIterable, Sendable {
    /// A playlist or track download batch (also `Import “‹playlist›”`, a retry batch).
    case download
    /// A recommendation downloaded from Similar / Discover.
    case recommendationDownload
    /// A track found in a reel, downloaded through the same queue.
    case reelsDownload
    /// Folder import or library-folder scan (`Scan “‹folder›”`).
    case folderScan
    /// The standing automatic analysis of new tracks (`Analyse new tracks`).
    case analysisQueue
    /// A Settings ▸ Maintenance analysis run (fingerprint, ReplayGain, danceability, similarity).
    case maintenanceAnalysis
    /// Artwork backfill (automatic) and artwork fetch (manual).
    case artwork
    case createMLExport
    /// Sync + transcoding — one operation per sync.
    case sync
    case transcodeCacheMove
    /// Read playlist changes from a device / apply them.
    case deviceScan
    case backup
    case restore
    /// Organised-path migration and its rollback.
    case pathMigration
    case libraryAdoption
    case storageSize
    /// Refresh from a source (likes / account playlists) — one per source.
    case sourceRefresh
    /// Refresh one linked playlist from its source.
    case playlistRefresh
    case duplicateScan
    /// Review ▸ Albums: `Look Up Albums` over the tracks without an album (W4-3, IMP-083).
    case albumLookup
    /// The file check of persisted availability (W2-A).
    case fileCheck
    /// Writing tag changes into the files (W2-E).
    case tagWrite
    /// Info ▸ Analyze for the selected tracks.
    case trackAnalysis
    /// A kind this build doesn't know (a row written by a newer MLM) — shown generically.
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = ActivityKind(rawValue: raw) ?? .other
    }

    /// The Kind column word (`activity.html` K map).
    var label: String {
        switch self {
        case .download, .recommendationDownload, .reelsDownload: "Download"
        case .folderScan: "Scan"
        case .analysisQueue, .maintenanceAnalysis, .trackAnalysis: "Analysis"
        case .artwork: "Artwork"
        case .createMLExport: "Export"
        case .sync: "Sync"
        case .transcodeCacheMove, .pathMigration, .libraryAdoption, .storageSize, .fileCheck: "Library"
        case .deviceScan: "Device"
        case .backup, .restore: "Backup"
        case .sourceRefresh, .playlistRefresh: "Refresh"
        case .duplicateScan, .albumLookup: "Review"
        case .tagWrite: "Tags"
        case .other: "Other"
        }
    }

    /// SF Symbol of the Kind column.
    var systemImage: String {
        switch self {
        case .download, .recommendationDownload, .reelsDownload: "arrow.down.circle"
        case .folderScan: "folder"
        case .analysisQueue, .maintenanceAnalysis, .trackAnalysis: "waveform"
        case .artwork: "photo"
        case .createMLExport: "square.and.arrow.up"
        case .sync: "arrow.triangle.2.circlepath"
        case .transcodeCacheMove, .pathMigration, .libraryAdoption, .storageSize, .fileCheck: "internaldrive"
        case .deviceScan: "externaldrive"
        case .backup, .restore: "clock.arrow.circlepath"
        case .sourceRefresh, .playlistRefresh: "arrow.clockwise"
        case .duplicateScan: "checklist"
        case .albumLookup: "square.stack"
        case .tagWrite: "pencil"
        case .other: "gearshape"
        }
    }

    /// The `-ing` verb of the toolbar item and the inline echo (`Downloading 12 of 44`).
    var activeVerb: String {
        switch self {
        case .download, .recommendationDownload, .reelsDownload: "Downloading"
        case .folderScan: "Scanning"
        case .analysisQueue, .maintenanceAnalysis, .trackAnalysis: "Analysing"
        case .artwork: "Fetching artwork"
        case .createMLExport: "Exporting"
        case .sync: "Syncing"
        case .transcodeCacheMove: "Moving"
        case .deviceScan: "Reading"
        case .backup: "Backing up"
        case .restore: "Restoring"
        case .pathMigration: "Moving files"
        case .libraryAdoption: "Setting up"
        case .storageSize: "Calculating"
        case .sourceRefresh, .playlistRefresh: "Refreshing"
        case .duplicateScan: "Comparing"
        case .albumLookup: "Looking up albums"
        case .fileCheck: "Checking files"
        case .tagWrite: "Writing tags"
        case .other: "Working"
        }
    }

    /// The word of the status-bar start/end messages (UC-JOB-08): `Download started — 44 tracks`.
    var messageName: String {
        switch self {
        case .download, .recommendationDownload, .reelsDownload: "Download"
        case .folderScan: "Import"
        case .analysisQueue, .maintenanceAnalysis, .trackAnalysis: "Analysis"
        case .artwork: "Artwork"
        case .createMLExport: "Export"
        case .sync: "Sync"
        case .transcodeCacheMove: "Cache move"
        case .deviceScan: "Device scan"
        case .backup: "Backup"
        case .restore: "Restore"
        case .pathMigration: "File move"
        case .libraryAdoption: "Library setup"
        case .storageSize: "Size calculation"
        case .sourceRefresh, .playlistRefresh: "Refresh"
        case .duplicateScan: "Duplicate scan"
        case .albumLookup: "Album lookup"
        case .fileCheck: "File check"
        case .tagWrite: "Tag writing"
        case .other: "Operation"
        }
    }

    /// Kinds whose finished results may be announced by a system notification (UC-JOB-12:
    /// import, sync and backup results/failures).
    var mayNotify: Bool {
        switch self {
        case .download, .folderScan, .sync, .backup, .restore: true
        default: false
        }
    }
}

// MARK: - Subject (typed link)

/// What an operation is for — a typed link the popover and window open on click (UC-PRIM-13).
/// A subject that no longer exists keeps its name and becomes plain text (`isMissing`).
struct ActivitySubject: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case none
        case playlist
        case syncProfile
        /// Tracks shown in All Tracks.
        case tracks
        case allTracks
        case folder
        case settings
        case review
        case discover
        case reels
        case genres
        case libraryFile
    }

    var kind: Kind
    /// Row id for playlist / sync profile.
    var id: Int64?
    /// Display name (`Warm-up`, `iPod Classic`, a folder name, a settings tab title).
    var name: String?
    /// Kind-specific detail: a `SettingsTab` raw value, a folder path.
    var detail: String?
    var trackIDs: [Int64]
    /// The thing no longer exists (deleted playlist, removed profile): the link is plain text.
    var isMissing: Bool

    init(kind: Kind, id: Int64? = nil, name: String? = nil, detail: String? = nil,
         trackIDs: [Int64] = [], isMissing: Bool = false) {
        self.kind = kind
        self.id = id
        self.name = name
        self.detail = detail
        self.trackIDs = trackIDs
        self.isMissing = isMissing
    }

    static let none = ActivitySubject(kind: .none)
    static func playlist(_ id: Int64, name: String) -> ActivitySubject { .init(kind: .playlist, id: id, name: name) }
    static func syncProfile(_ id: Int64, name: String) -> ActivitySubject { .init(kind: .syncProfile, id: id, name: name) }
    static func tracks(_ ids: [Int64]) -> ActivitySubject { .init(kind: .tracks, trackIDs: ids) }
    static let allTracks = ActivitySubject(kind: .allTracks, name: "All Tracks")
    static func folder(_ url: URL) -> ActivitySubject {
        .init(kind: .folder, name: url.lastPathComponent, detail: url.path)
    }
    static func settings(_ tab: SettingsTab) -> ActivitySubject {
        .init(kind: .settings, name: tab.title, detail: tab.rawValue)
    }
    static let review = ActivitySubject(kind: .review, name: "Review")
    static let discover = ActivitySubject(kind: .discover, name: "Discover")
    static let reels = ActivitySubject(kind: .reels, name: "Reels")
    static let genres = ActivitySubject(kind: .genres, name: "Genres")
    static let libraryFile = ActivitySubject(kind: .libraryFile, name: "Library file")

    var settingsTab: SettingsTab? { kind == .settings ? detail.flatMap(SettingsTab.init(rawValue:)) : nil }

    /// Whether the subject can be opened.
    var isLinkable: Bool { kind != .none && !isMissing }

    /// The label of `Show ‹Subject›` (CM-OPS-ROW): `Show Playlist`, `Show Sync Profile`,
    /// `Show in All Tracks`, `Show Maintenance`.
    var showLabel: String? {
        guard isLinkable else { return nil }
        switch kind {
        case .none: return nil
        case .playlist: return "Show Playlist"
        case .syncProfile: return "Show Sync Profile"
        case .tracks, .allTracks: return "Show in All Tracks"
        case .folder: return "Show in Folders"
        case .settings: return "Show \(name ?? "Settings")"
        case .review: return "Show Review"
        case .discover: return "Show Discover"
        case .reels: return "Show Reels"
        case .genres: return "Show Genres"
        case .libraryFile: return "Show Library File in Finder"
        }
    }

    /// Short label of the subject link in the Operation column (`Playlist`, `Sync profile`,
    /// `Settings ▸ Maintenance`).
    var linkLabel: String? {
        switch kind {
        case .none: return nil
        case .playlist: return name.map { "“\($0)”" } ?? "Playlist"
        case .syncProfile: return name.map { "“\($0)”" } ?? "Sync profile"
        case .tracks: return trackIDs.count == 1 ? "1 track" : "\(trackIDs.count.formatted(.number)) tracks"
        case .allTracks: return "All Tracks"
        case .folder: return name.map { "“\($0)”" } ?? "Folder"
        case .settings: return "Settings ▸ \(name ?? "General")"
        case .review: return "Review"
        case .discover: return "Discover"
        case .reels: return "Discover ▸ Reels"
        case .genres: return "Genres"
        case .libraryFile: return "Library file"
        }
    }
}

// MARK: - State (UC §15.6 — exactly six words)

enum ActivityState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed
    case cancelled

    /// The verbatim State-column word (UC-STATE §15.6).
    var word: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .paused: "Paused"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var systemImage: String {
        switch self {
        case .queued: "clock"
        case .running: "circle.dotted"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .failed: "xmark.octagon"
        case .cancelled: "xmark.circle"
        }
    }

    /// Running includes Queued and Paused (P-ACTIVITY-OPS.E02).
    var isActive: Bool { self == .queued || self == .running || self == .paused }
    var isTerminal: Bool { !isActive }
}

/// Why a Queued or Paused operation doesn't move — said in words in the Progress column.
enum ActivityWait: Codable, Hashable, Sendable {
    /// Waiting for an earlier operation of the same kind (`Starts after “Liked on SoundCloud”`);
    /// `after` is already formatted (a quoted subject name or a title).
    case turn(after: String)
    /// Work that needs the library drive waits while it is away (UC-JOB-10).
    case drive(volumeName: String)
    /// The analysis queue pauses itself while downloads or sync plans run.
    case suspendedWhileDownloads
    /// Paused by the user.
    case user
    case other(String)

    var sentence: String {
        switch self {
        case .turn(let after): "Starts after \(after)"
        case .drive(let volume): "Waiting for “\(volume)”"
        case .suspendedWhileDownloads: "Waiting — paused while downloads run"
        case .user: "Paused"
        case .other(let text): text
        }
    }
}

// MARK: - Progress

/// Determinate (`n of m` + the current item) or indeterminate progress.
struct ActivityProgress: Codable, Equatable, Sendable {
    /// Items finished so far.
    var completed: Int
    /// Items in total, `nil` when not countable.
    var total: Int?
    /// Fraction of the item in flight (0…1), for a smoother ring.
    var currentFraction: Double
    /// The item in flight (`Arpo — Live at Dekmantel 2024`), or the step (`Reading tags`).
    var currentItem: String?
    /// Extra facts after the item (`1 failed so far`, `about 6 min left`).
    var detail: String?
    /// Waiting items for a standing queue (`212 waiting`).
    var waiting: Int?

    init(completed: Int = 0, total: Int? = nil, currentFraction: Double = 0,
         currentItem: String? = nil, detail: String? = nil, waiting: Int? = nil) {
        self.completed = completed
        self.total = total
        self.currentFraction = currentFraction
        self.currentItem = currentItem
        self.detail = detail
        self.waiting = waiting
    }

    static let indeterminate = ActivityProgress()

    var isDeterminate: Bool { (total ?? 0) > 0 }

    /// 0…1 for the ring, `nil` when indeterminate.
    var fraction: Double? {
        guard let total, total > 0 else { return nil }
        let value = (Double(min(completed, total)) + min(max(currentFraction, 0), 1)) / Double(total)
        return min(max(value, 0), 1)
    }

    /// The `n` of `n of m` while running: the item in flight (1-based), capped at the total.
    var position: Int {
        guard let total, total > 0 else { return completed }
        return min(completed + (completed < total ? 1 : 0), total)
    }
}

// MARK: - Result

/// One outcome count of a result sentence (`35 downloaded`, `9 failed`, `2 skipped`).
struct ActivityCount: Codable, Equatable, Hashable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case done, failed, skipped
        init(from decoder: Decoder) throws {
            self = Outcome(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .done
        }
    }
    var outcome: Outcome
    var count: Int
    /// Past participle or noun phrase after the number (`downloaded`, `imported`, `synced`).
    var word: String

    init(_ outcome: Outcome, _ count: Int, _ word: String) {
        self.outcome = outcome
        self.count = count
        self.word = word
    }

    var text: String { "\(count.formatted(.number)) \(word)" }
}

/// The one action that fixes a failure group (UC-JOB-11).
enum ActivityFix: Codable, Hashable, Sendable {
    case openSettings(String)
    /// Sign-in expired — Reconnect opens Settings ▸ Sources.
    case reconnect(source: String?)
    /// Retry the group's items (`Retry All`).
    case retry
    /// Nothing helps but another source; offer `Show Tracks`.
    case showTracks
    /// Waits for the drive; no button (it resumes by itself).
    case waitForDrive
    case runAgain

    var buttonTitle: String? {
        switch self {
        case .openSettings(let tab): "Open Settings ▸ \(SettingsTab(rawValue: tab)?.title ?? "General")"
        case .reconnect: "Reconnect"
        case .retry: "Retry All"
        case .showTracks: "Show Tracks"
        case .waitForDrive: nil
        case .runAgain: "Run Again"
        }
    }
}

/// Failures of one cause, with the fix (UC-JOB-11): `9 downloads failed — sign-in expired
/// (SoundCloud) · Reconnect`.
struct ActivityFailureGroup: Codable, Equatable, Hashable, Sendable {
    /// The cause in plain words (from `DownloadFailureReasonText` for downloads).
    var cause: String
    var count: Int
    var fix: ActivityFix?
    /// **Failed downloads only**: tracks whose `tracks.download_failure` the registry checks
    /// live (`ActivityFailureSource`) — what `Retry All` and `Show Tracks` act on and what the
    /// toolbar's `‹n› failed` counts. Other failures (sync, analysis) leave it empty and count
    /// by `count`; their tracks are in `ActivityResult.items`.
    var trackIDs: [Int64]
    /// Whether retrying can help (sign-in expired yes after Reconnect; removed / DRM no).
    var isRetryable: Bool
    /// A remark under the group (`Retrying won’t help. Try another source …`).
    var note: String?
    /// Downloads: the source policy of the batch that failed
    /// (`DownloadOrchestrator.PreferredSource.storageKey`); a retry uses the same one. `nil` (or a
    /// group restored from before this field) = `auto`, the full fallback chain.
    var sourcePin: String?

    init(cause: String, count: Int, fix: ActivityFix? = nil, trackIDs: [Int64] = [],
         isRetryable: Bool = true, note: String? = nil, sourcePin: String? = nil) {
        self.cause = cause
        self.count = count
        self.fix = fix
        self.trackIDs = trackIDs
        self.isRetryable = isRetryable
        self.note = note
        self.sourcePin = sourcePin
    }

    private enum CodingKeys: String, CodingKey { case cause, count, fix, trackIDs, isRetryable, note, sourcePin }

    /// Lenient (S9): an unknown fix decodes as none; the failed track ids are always kept.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cause = (try? c.decode(String.self, forKey: .cause)) ?? "Reason unknown"
        trackIDs = (try? c.decode([Int64].self, forKey: .trackIDs)) ?? []
        count = (try? c.decode(Int.self, forKey: .count)) ?? trackIDs.count
        fix = try? c.decodeIfPresent(ActivityFix.self, forKey: .fix)
        isRetryable = (try? c.decode(Bool.self, forKey: .isRetryable)) ?? true
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        sourcePin = try? c.decodeIfPresent(String.self, forKey: .sourcePin)
    }
}

/// Decodes an array element by element, skipping elements this build can't read.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var result: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                result.append(element)
            } else {
                _ = try? container.decode(SkipElement.self)
            }
        }
        elements = result
    }

    private struct SkipElement: Decodable {}
}

/// Per-item outcome of an operation (per-track rows of a batch, P-ACTIVITY-OPS.E14).
struct ActivityItemOutcome: Codable, Equatable, Hashable, Sendable {
    /// Track-glossary words: `Downloaded`, `Download failed`, `Skipped — already downloaded`, …
    var word: String
    var title: String
    var trackID: Int64?
    /// Plain reason / remark (`Sign-in expired (SoundCloud)`, `FLAC from DAB`).
    var reason: String?
    var isFailure: Bool

    init(word: String, title: String, trackID: Int64? = nil, reason: String? = nil, isFailure: Bool = false) {
        self.word = word
        self.title = title
        self.trackID = trackID
        self.reason = reason
        self.isFailure = isFailure
    }
}

/// What an operation achieved — counts by outcome plus failures grouped by cause. Persisted
/// as JSON (`activity_operations.result`) and kept across relaunch (UC-JOB-02).
struct ActivityResult: Codable, Equatable, Sendable {
    var counts: [ActivityCount]
    var failureGroups: [ActivityFailureGroup]
    /// A result sentence when counts don't say it (`Moved 2,114 files · 3.2 GB`,
    /// `Library folder 412 GB · library file 96 MB`).
    var summary: String?
    /// The plain cause of a Failed operation (`Destination “Lexxar” was not connected`).
    var failureCause: String?
    /// Per-item outcomes (capped at `ActivityResult.maxItems`).
    var items: [ActivityItemOutcome]

    static let maxItems = 2_000

    private enum CodingKeys: String, CodingKey { case counts, failureGroups, summary, failureCause, items }

    /// Lenient (S9): unreadable elements are skipped, never the whole result.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        counts = (try? c.decode(LossyArray<ActivityCount>.self, forKey: .counts))?.elements ?? []
        failureGroups = (try? c.decode(LossyArray<ActivityFailureGroup>.self, forKey: .failureGroups))?.elements ?? []
        summary = try? c.decodeIfPresent(String.self, forKey: .summary)
        failureCause = try? c.decodeIfPresent(String.self, forKey: .failureCause)
        items = (try? c.decode(LossyArray<ActivityItemOutcome>.self, forKey: .items))?.elements ?? []
    }

    init(counts: [ActivityCount] = [], failureGroups: [ActivityFailureGroup] = [],
         summary: String? = nil, failureCause: String? = nil, items: [ActivityItemOutcome] = []) {
        self.counts = counts
        self.failureGroups = failureGroups
        self.summary = summary
        self.failureCause = failureCause
        self.items = Array(items.prefix(Self.maxItems))
    }

    static let empty = ActivityResult()

    /// `35 downloaded · 9 failed` (Activity), counts with zero left out except a lone zero.
    var sentence: String {
        var parts = counts.filter { $0.count > 0 }.map(\.text)
        if parts.isEmpty, let first = counts.first { parts = [first.text] }
        if let summary { parts.insert(summary, at: 0) }
        return parts.joined(separator: " · ")
    }

    /// `35 downloaded, 9 failed` (status bar, UC-STATUS-05 — `·` is reserved for buttons).
    var statusSentence: String {
        var parts = counts.filter { $0.count > 0 }.map(\.text)
        if parts.isEmpty, let first = counts.first { parts = [first.text] }
        if let summary { parts.insert(summary, at: 0) }
        return parts.joined(separator: ", ")
    }

    var failedCount: Int {
        counts.filter { $0.outcome == .failed }.reduce(0) { $0 + $1.count }
    }

    /// Every track id named by a failure group.
    var failedTrackIDs: [Int64] { failureGroups.flatMap(\.trackIDs) }
}

// MARK: - Controls (honest only, UC-JOB-03)

/// The controls a job declares. Only what really works: a job that can't stop declares no
/// cancel and gets no Cancel button.
struct ActivityControls: Sendable {
    /// How a cancel is worded — the truth about when it stops.
    enum CancelStyle: String, Sendable {
        case immediately
        case afterThisTrack
        case afterThisFile

        var title: String {
            switch self {
            case .immediately: "Cancel"
            case .afterThisTrack: "Cancel After This Track"
            case .afterThisFile: "Cancel After This File"
            }
        }
    }

    var cancelStyle: CancelStyle
    var cancel: (@Sendable () -> Void)?
    var pause: (@Sendable () -> Void)?
    var resume: (@Sendable () -> Void)?
    /// `Clear Waiting…` of a standing queue (A-OPS-CLEARQUEUE).
    var clearWaiting: (@Sendable () -> Void)?
    /// Retry the given failed track ids (with the failed batch's own source policy).
    var retry: (@Sendable ([Int64]) -> Void)?
    /// `Run Again` for a finished / cancelled / failed operation (this session only).
    var runAgain: (@Sendable () -> Void)?

    init(cancelStyle: CancelStyle = .immediately,
         cancel: (@Sendable () -> Void)? = nil,
         pause: (@Sendable () -> Void)? = nil,
         resume: (@Sendable () -> Void)? = nil,
         clearWaiting: (@Sendable () -> Void)? = nil,
         retry: (@Sendable ([Int64]) -> Void)? = nil,
         runAgain: (@Sendable () -> Void)? = nil) {
        self.cancelStyle = cancelStyle
        self.cancel = cancel
        self.pause = pause
        self.resume = resume
        self.clearWaiting = clearWaiting
        self.retry = retry
        self.runAgain = runAgain
    }

    static let none = ActivityControls()

    var canCancel: Bool { cancel != nil }
    var canPause: Bool { pause != nil && resume != nil }
}

// MARK: - Operation

/// One operation as the center keeps it.
struct ActivityOperation: Identifiable, Sendable {
    let id: UUID
    let kind: ActivityKind
    var title: String
    var subject: ActivitySubject
    var state: ActivityState
    var wait: ActivityWait?
    var progress: ActivityProgress
    var result: ActivityResult?
    let startedAt: Date
    var endedAt: Date?
    /// Started by MLM, not by the user (`Automatic`, UC-JOB-01).
    let isAutomatic: Bool
    /// The open library at start; `nil` = app-level (adoption, open, backups before a library).
    let libraryID: String?
    /// Ended with failures (or failed) and not dismissed — it is in Needs attention.
    var needsAttention: Bool
    var dismissedAt: Date?
    /// Noun for counts (`track`/`tracks`, `file`/`files`) in start messages.
    var itemNoun: ActivityNoun
    /// Name of the start/end status-bar message (`Download`, `Import`).
    var messageName: String
    /// Controls live only while MLM runs.
    var controls: ActivityControls
    /// Restored from the history (no controls, no job behind it).
    var isFromHistory: Bool

    var duration: TimeInterval? { endedAt.map { $0.timeIntervalSince(startedAt) } }
}

/// A countable noun with its plural (`1 track`, `44 tracks`) — UC-COPY-09.
struct ActivityNoun: Codable, Hashable, Sendable {
    var singular: String
    var plural: String

    static let track = ActivityNoun(singular: "track", plural: "tracks")
    static let file = ActivityNoun(singular: "file", plural: "files")
    static let item = ActivityNoun(singular: "item", plural: "items")
    static let playlist = ActivityNoun(singular: "playlist", plural: "playlists")
    static let analysis = ActivityNoun(singular: "analysis", plural: "analyses")
    static let tagChange = ActivityNoun(singular: "tag change", plural: "tag changes")

    func counted(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? singular : plural)"
    }
}

// MARK: - Result helpers of other areas

extension ActivityResult {
    /// `12,935 tracks · 48 MB` — a backup's result (P-ACTIVITY-OPS.N10).
    static func backup(_ info: BackupInfo) -> ActivityResult {
        var parts: [String] = []
        if let tracks = info.trackCount { parts.append(ActivityNoun.track.counted(tracks)) }
        if let bytes = info.databaseSizeBytes { parts.append(bytes.formatted(.byteCount(style: .file))) }
        return ActivityResult(summary: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }
}
