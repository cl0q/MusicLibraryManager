import Foundation

// MARK: - Sync profile state (UC-SIDE-07, §15.8, DEC-027) — pure

/// A running (or queued / paused / waiting) sync of one profile, as Activity shows it — the one
/// source of the numbers (UC-JOB-07).
struct SyncRunSnapshot: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case queued
        case running
        case paused
        /// The device was removed; the same operation waits for it (UC-JOB-10).
        case waitingForDevice
    }

    var operationID: UUID
    var phase: Phase
    var completed: Int
    var total: Int?
    /// `Converting to AAC: Overmono — So U Kno`.
    var currentItem: String?
    /// `Starts after “Sync “Car USB stick””` while queued.
    var waitText: String?

    /// From Activity's echo of the profile (only a `.sync` operation counts).
    static func from(_ echo: ActivityEcho?, progress: ActivityProgress? = nil) -> SyncRunSnapshot? {
        guard let echo, echo.kind == .sync else { return nil }
        let phase: Phase
        switch echo.state {
        case .running: phase = .running
        case .paused: phase = .paused
        case .queued:
            if case .drive? = echo.wait { phase = .waitingForDevice } else { phase = .queued }
        default: return nil
        }
        return SyncRunSnapshot(operationID: echo.operationID, phase: phase,
                               completed: progress?.completed ?? 0, total: progress?.total,
                               currentItem: progress?.currentItem, waitText: echo.waitText)
    }
}

/// Everything the words of one profile depend on. Built by `SyncViewModel`; no I/O here.
struct SyncProfileStateInput: Equatable, Sendable {
    var profileName: String
    /// `IPOD CLASSIC` (the volume) or the folder's name.
    var deviceName: String
    var destination: SyncDestination.Status
    var libraryDrive: LibraryDriveState
    /// The profile lists playlists or tracks.
    var hasContent: Bool
    /// The last computed plan (kept while the device is away).
    var plan: SyncPlanSummary?
    var planHasSufficientSpace: Bool = true
    var planComputedAt: Date?
    var isPlanUpdating = false
    var result: SyncProfileResult?
    /// Newest `sync_state` timestamp — the only "last synced" before v47 existed.
    var legacySyncedAt: Date?
    var run: SyncRunSnapshot?
    var now: Date
}

/// The words for one profile: sidebar second line, header, Sync Now, plan sentence, banner and
/// Last sync — computed in one place so the row, the page and the menus never disagree.
struct SyncProfileState: Equatable, Sendable {
    enum Page: Equatable, Sendable {
        case empty
        case notConnected
        case ready
        case queued
        case syncing
        case paused
        case interrupted
        case finishedWithFailures
        case libraryDriveAway
        case error
    }

    struct Banner: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case interrupted, libraryDriveAway }
        let kind: Kind
        /// Bold sentence.
        let title: String
        let detail: String?
    }

    let page: Page
    let sidebarText: String
    /// The thin bar under a syncing row.
    let sidebarProgress: Double?
    let isConnected: Bool
    /// `Connected` / `Not connected` / `Folder not found on IPOD` (§15.8: no quotes).
    let connectionText: String
    /// Facts after the connection word (`214 to add`, `last synced 2 hours ago`).
    let headerFacts: [String]
    /// `nil` = Sync Now can run.
    let syncNowDisabledReason: String?
    /// `Add 214 · Remove 12 · Skip 9 · 3.1 GB of 12 GB free`.
    let planSentence: String?
    /// `From 3 Oct 2026 — will be checked against the device when it is connected`.
    let planStatus: String?
    let banner: Banner?
    /// `Syncing 86 of 214` / `Paused · 86 of 214` / `Queued · Starts after …`.
    let runText: String?
    let runFraction: Double?
    /// The Last sync section's first line.
    let lastSyncLine: String
    /// Failures of the last run of this profile that still count.
    let failedCount: Int

    var canSyncNow: Bool { syncNowDisabledReason == nil }

    // MARK: Formatting (UC-COPY-09/10)

    static func relative(_ date: Date, now: Date) -> String {
        Date.AnchoredRelativeFormatStyle(anchor: date, presentation: .named, unitsStyle: .wide).format(now)
    }

    static func bytes(_ value: Int64) -> String {
        value.formatted(.byteCount(style: .file))
    }

    static func count(_ n: Int) -> String { n.formatted(.number) }

    /// `1 playlist to update` / `3 playlists to update` (IMP-105).
    static func playlistsText(_ n: Int) -> String {
        "\(count(n)) \(n == 1 ? "playlist" : "playlists") to update"
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    // MARK: Make

    static func make(_ input: SyncProfileStateInput) -> SyncProfileState {
        let device = "“\(input.deviceName)”"
        let result = input.result
        let isConnected = input.destination == .connected
        let driveAway = input.libraryDrive.isOffline
        let driveName = input.libraryDrive.volumeName.map { "“\($0)”" } ?? "the library drive"

        // Failures of the last finished run (they stay until fixed or the next run).
        let failedCount: Int = {
            guard let result, result.outcome == .completed || result.outcome == .cancelled else { return 0 }
            return result.failures.count
        }()
        let lastSyncedAt: Date? = {
            if let result, let ended = result.endedAt,
               result.outcome == .completed || result.outcome == .cancelled { return ended }
            return input.legacySyncedAt
        }()
        let staleInterruption = input.run == nil && (result?.outcome == .interrupted || result?.outcome == .running)
        let interruptedText: String? = {
            guard let result, input.run?.phase == .waitingForDevice || staleInterruption else { return nil }
            return "\(count(result.copiedCount)) of \(count(result.plannedCount)) copied"
        }()

        // Run words (UC-JOB-07: the Activity numbers).
        let progressText = input.run.flatMap { run in run.total.map { "\(count(run.completed)) of \(count($0))" } }
        let runFraction: Double? = input.run.flatMap { run in
            guard let total = run.total, total > 0 else { return nil }
            return min(1, Double(run.completed) / Double(total))
        }
        let runText: String? = {
            guard let run = input.run else { return nil }
            switch run.phase {
            case .running: return progressText.map { "Syncing \($0)" } ?? "Syncing…"
            case .paused: return progressText.map { "Paused · \($0)" } ?? "Paused"
            case .queued: return run.waitText.map { "Queued · \($0)" } ?? "Queued"
            case .waitingForDevice: return interruptedText.map { "Interrupted — \($0)" } ?? "Waiting for \(device)"
            }
        }()

        // Sidebar second line (UC-SIDE-07).
        let sidebarText: String = {
            if let run = input.run {
                if run.phase == .waitingForDevice, let interruptedText { return "Interrupted — \(interruptedText)" }
                return runText ?? "Syncing…"
            }
            if let interruptedText { return "Interrupted — \(interruptedText)" }
            switch input.destination {
            case .none, .notConnected: return "Not connected"
            case .folderNotFound: return "Folder not found on \(input.deviceName)"
            case .connected: break
            }
            if failedCount > 0, let lastSyncedAt {
                return "Synced \(relative(lastSyncedAt, now: input.now)) · \(count(failedCount)) failed"
            }
            if let plan = input.plan, plan.add > 0, input.hasContent { return "\(count(plan.add)) to add" }
            if let plan = input.plan, plan.playlistsToUpdate > 0, input.hasContent {
                return playlistsText(plan.playlistsToUpdate)
            }
            if let lastSyncedAt { return "Synced \(relative(lastSyncedAt, now: input.now))" }
            return "Connected"  // IMP-007
        }()

        // Header.
        let connectionText: String = {
            switch input.destination {
            case .connected: return "Connected"
            case .none, .notConnected: return "Not connected"
            case .folderNotFound: return "Folder not found on \(input.deviceName)"
            }
        }()
        var facts: [String] = []
        if isConnected, let plan = input.plan, plan.add > 0, input.hasContent, input.run == nil {
            facts.append("\(count(plan.add)) to add")
        }
        if isConnected, let plan = input.plan, plan.playlistsToUpdate > 0, input.hasContent, input.run == nil {
            facts.append(playlistsText(plan.playlistsToUpdate))
        }
        if !isConnected, let seen = result?.lastConnectedAt {
            facts.append("last connected \(day(seen))")
        } else if let lastSyncedAt {
            facts.append("last synced \(relative(lastSyncedAt, now: input.now))")
        } else if isConnected {
            facts.append("not synced yet")
        }

        // Plan.
        let neededAfterRemovals: (needed: Int64, free: Int64)? = input.plan.map { plan in
            (plan.addBytes, plan.freeBytes + (plan.cleanUp ? plan.removeBytes : 0))
        }
        let spaceSentence: String? = {
            guard let plan = input.plan, !input.planHasSufficientSpace, let space = neededAfterRemovals else { return nil }
            _ = plan
            // The figure includes the buffer the run keeps free, so it matches what the check used.
            return "Not enough space — \(bytes(space.needed + SyncService.spaceBuffer)) needed, \(bytes(space.free)) free after removals"
        }()
        let planSentence: String? = {
            if driveAway { return "Can’t sync — \(driveName) is not connected" }
            guard let plan = input.plan, input.hasContent else { return nil }
            let remove = plan.cleanUp ? "Remove \(count(plan.remove))" : "Remove 0 — Clean up is off"
            let space = spaceSentence ?? "\(bytes(plan.addBytes)) of \(bytes(plan.freeBytes)) free"
            let playlists = plan.playlistsToUpdate > 0 ? " · \(playlistsText(plan.playlistsToUpdate))" : ""
            return "Add \(count(plan.add)) · \(remove) · Skip \(count(plan.skip))\(playlists) · \(space)"
        }()
        let planStatus: String? = {
            guard input.plan != nil, input.hasContent else { return nil }
            if input.isPlanUpdating { return "Updating plan…" }
            if !isConnected, let at = input.planComputedAt ?? result?.lastConnectedAt {
                return "From \(day(at)) — will be checked against the device when it is connected"
            }
            if let at = input.planComputedAt { return "Up to date · computed \(relative(at, now: input.now))" }
            return nil
        }()

        // Sync Now (UC-COPY-13: the reason is written next to it and is its help).
        let syncNowDisabledReason: String? = {
            if input.run != nil { return "A sync of this profile is running." }
            if !input.hasContent {
                return "Nothing to sync yet — add playlists or tracks below, or drag them onto “\(input.profileName)” in the sidebar."
            }
            switch input.destination {
            case .none: return "Choose a destination with Change Destination…"
            case .notConnected: return "Connect \(device) to sync."
            case .folderNotFound: return "Folder not found on \(input.deviceName)"
            case .connected: break
            }
            if driveAway { return "Can’t sync — \(driveName) is not connected" }
            guard let plan = input.plan else { return "Updating plan…" }
            if let spaceSentence { return spaceSentence }
            if plan.add == 0 && (plan.remove == 0 || !plan.cleanUp) && plan.playlistsToUpdate == 0 {
                return "Everything in this profile is on \(device)."
            }
            return nil
        }()

        // Banner (UC-LAYOUT-02: one at a time).
        let banner: Banner? = {
            if let interruptedText {
                let live = input.run?.phase == .waitingForDevice
                return Banner(kind: .interrupted,
                              title: "\(device) was disconnected — \(interruptedText)",
                              detail: live
                                ? "The copied tracks are complete; the playlist files on the device were not updated yet."
                                : "Sync Now continues with the tracks that are not on the device yet.")
            }
            if driveAway {
                return Banner(kind: .libraryDriveAway,
                              title: "Can’t sync — \(driveName) is not connected.",
                              detail: "The music to copy is on \(driveName). Connect it and the sync can start; the plan below stays as it was.")
            }
            return nil
        }()

        // Last sync.
        let lastSyncLine: String = {
            if let run = input.run, run.phase != .waitingForDevice, let started = result?.startedAt {
                return "Running now — started \(started.formatted(date: .omitted, time: .shortened))"
            }
            guard let result, result.hasRun else {
                if let legacy = input.legacySyncedAt { return "Synced \(relative(legacy, now: input.now))" }
                return "Not synced yet."
            }
            switch result.outcome {
            case .none:
                return "Not synced yet."
            case .running, .interrupted:
                let when = result.lastInterruptedAt ?? result.startedAt ?? input.now
                return "Interrupted \(relative(when, now: input.now)) — \(count(result.copiedCount)) of \(count(result.plannedCount)) copied"
            case .completed, .cancelled:
                var parts = ["\(result.outcome == .cancelled ? "Cancelled" : "Synced") \(relative(result.endedAt ?? input.now, now: input.now))",
                             "\(count(result.copiedCount)) copied"]
                if result.removedCount > 0 { parts.append("\(count(result.removedCount)) removed") }
                if !result.failures.isEmpty { parts.append("\(count(result.failures.count)) failed") }
                if !result.skipped.isEmpty { parts.append("\(count(result.skipped.count)) skipped") }
                return parts.joined(separator: " · ")
            case .failed:
                let cause = result.failureCause ?? "the sync stopped"
                return "Couldn’t finish \(relative(result.endedAt ?? input.now, now: input.now)) — \(cause)"
            }
        }()

        // Page state (the nine states of `sync.html`).
        let page: Page = {
            if let run = input.run {
                switch run.phase {
                case .running: return .syncing
                case .paused: return .paused
                case .queued: return .queued
                case .waitingForDevice: return .interrupted
                }
            }
            if !input.hasContent { return .empty }
            if staleInterruption { return .interrupted }
            if !isConnected { return .notConnected }
            if driveAway { return .libraryDriveAway }
            if result?.outcome == .failed { return .error }
            if failedCount > 0 { return .finishedWithFailures }
            return .ready
        }()

        return SyncProfileState(
            page: page,
            sidebarText: sidebarText,
            sidebarProgress: input.run?.phase == .running || input.run?.phase == .paused ? runFraction : nil,
            isConnected: isConnected,
            connectionText: connectionText,
            headerFacts: facts,
            syncNowDisabledReason: syncNowDisabledReason,
            planSentence: planSentence,
            planStatus: planStatus,
            banner: banner,
            runText: runText,
            runFraction: runFraction,
            lastSyncLine: lastSyncLine,
            failedCount: failedCount
        )
    }
}
