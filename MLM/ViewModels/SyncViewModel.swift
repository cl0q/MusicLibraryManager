import AppKit
import SwiftUI

/// Content of one profile, for its page (Content section).
struct SyncProfileContent: Equatable {
    struct PlaylistItem: Identifiable, Equatable {
        let playlist: Playlist
        let trackCount: Int
        /// Tracks of the playlist that can't be copied because they aren't downloaded (N05).
        let notDownloaded: Int
        var id: Int64 { playlist.id ?? 0 }
    }

    var playlists: [PlaylistItem] = []
    var tracks: [Track] = []
}

/// One profile's plan as the app keeps it (cached per profile; kept while the device is away).
struct SyncPlanEntry {
    var preview: SyncService.PreviewResult?
    var computedAt: Date?
    var isUpdating = false
    /// `120 of 214` while updating.
    var progress: (done: Int, total: Int)?
    var error: String?
}

/// Sync profiles, per profile: content, plan, destination, last result and running sync
/// (W3-SYNC, DEC-027). Nothing here depends on which profile is open — every profile has its
/// own state (fixes PP-SYNC-02 and the selection-dependent rows of V-SYNC).
///
/// - Plans of **all** profiles are computed one at a time off the main actor (cached per profile;
///   recomputed 1 s after a content or option change, at once on mount / unmount and after a
///   sync; never for a destination that isn't there). A slow plan shows in Activity (quiet).
/// - Sync Now, Pause / Resume / Cancel act on the profile's Activity operation — the toolbar,
///   the popover and the page share one source of truth (UC-JOB-07).
@Observable
final class SyncViewModel {
    // MARK: State

    private(set) var profiles: [SyncProfile] = []
    private(set) var results: [Int64: SyncProfileResult] = [:]
    /// Newest `sync_state` timestamp per profile (the only "last synced" before v47).
    private(set) var legacySyncedAt: [Int64: Date] = [:]
    private(set) var plans: [Int64: SyncPlanEntry] = [:]
    private(set) var destinations: [Int64: SyncDestination.Status] = [:]
    private(set) var contentCounts: [Int64: Int] = [:]
    /// Free / total bytes of connected destinations (read on mount events, never while drawing).
    private(set) var capacities: [Int64: (free: Int64, total: Int64)] = [:]
    /// The connected destination is a Rockbox player (`.rockbox` at the volume root).
    private(set) var isRockbox: [Int64: Bool] = [:]
    /// Sheets and the delete alert, shared by the sidebar rows and the profile pages.
    let presenter = SyncPresenter()
    private(set) var contents: [Int64: SyncProfileContent] = [:]
    private(set) var isLoading = false
    /// A create in the New Sync Profile sheet failed (shown in the sheet, UC-SHEET-18).
    private(set) var errorMessage: String?
    /// Profiles whose options changed during their running sync (`Applies to the next sync`).
    private(set) var optionsChangedWhileSyncing: Set<Int64> = []

    /// Any sync runs now (blocks a transcode-cache move).
    var isSyncing: Bool { syncService.isRunning }

    // MARK: Dependencies

    private let syncRepository: SyncRepository
    let syncService: SyncService
    let resultRepository: SyncProfileResultRepository
    private var ingestService: PlaylistIngestService?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    @ObservationIgnored private let workspaceCenter: NotificationCenter
    @ObservationIgnored var libraryDrive: @MainActor () -> LibraryDriveState = { LibraryDriveState.current(.shared) }
    /// `/Volumes/<name>` of the drive that holds the library (never offered for Eject).
    @ObservationIgnored var libraryVolumePath: @MainActor () -> String? = { DependencyContainer.shared.mountObserver?.libraryVolumePath }
    @ObservationIgnored var statusBar: @MainActor () -> StatusBarCenter? = { ShellWindowModels.main.statusBar }
    @ObservationIgnored var edits: @MainActor () -> ShellEdits = {
        ShellEdits(dependencies: .live(.shared), undo: .main, window: .main)
    }
    @ObservationIgnored var playlistRepository: @MainActor () -> PlaylistRepository? = { DependencyContainer.shared.playlistRepository }
    @ObservationIgnored var destinationStatus: (String) -> SyncDestination.Status = { SyncDestination.status(for: $0) }
    /// Debounce of plan recomputes after an edit (1 s) and after downloads / file checks.
    @ObservationIgnored var editDebounce: Duration = .seconds(1)
    @ObservationIgnored var backgroundDebounce: Duration = .seconds(5)

    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var planDebounces: [Int64: Task<Void, Never>] = [:]
    @ObservationIgnored private var planQueue: [(id: Int64, force: Bool)] = []
    @ObservationIgnored private var planWorker: Task<Void, Never>?
    @ObservationIgnored private var currentPlanTask: (id: Int64, task: Task<SyncService.PreviewResult, Error>)?
    @ObservationIgnored private var runs: [Int64: Task<Void, Never>] = [:]

    init(syncRepository: SyncRepository, syncService: SyncService, ingestService: PlaylistIngestService? = nil,
         resultRepository: SyncProfileResultRepository? = nil,
         notificationCenter: NotificationCenter = .default,
         workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.syncRepository = syncRepository
        self.syncService = syncService
        self.ingestService = ingestService
        let results = resultRepository ?? SyncProfileResultRepository(database: syncRepository.databaseWriter)
        self.resultRepository = results
        self.notificationCenter = notificationCenter
        self.workspaceCenter = workspaceCenter
        syncService.results = results
    }

    deinit {
        for observer in observers {
            notificationCenter.removeObserver(observer)
            workspaceCenter.removeObserver(observer)
        }
    }

    /// Set the ingest service after initialization (WP4 wiring).
    func setIngestService(_ service: PlaylistIngestService?) {
        self.ingestService = service
    }

    /// The service behind Read Playlist Changes from Device (`nil` until the library is open).
    func deviceChangeService() -> DevicePlaylistChangeService? {
        guard let ingestService else { return nil }
        let database = syncRepository.databaseWriter
        return DevicePlaylistChangeService(ingest: ingestService, tracks: TrackRepository(database: database),
                                           playlists: PlaylistRepository(database: database), database: database)
    }

    // MARK: - Loading

    /// Loads profiles, results and content counts; the first call also starts watching for
    /// changes and computes every profile's plan.
    @MainActor
    func loadProfiles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            profiles = try await syncRepository.fetchAll()
            let timestamps = try await syncRepository.fetchLastSyncTimestamps()
            legacySyncedAt = Dictionary(uniqueKeysWithValues: timestamps.compactMap { id, timestamp in
                Self.sqliteDateFormatter.date(from: timestamp).map { (id, $0) }
            })
            results = (try? await resultRepository.fetchAll()) ?? results
            contentCounts = (try? await syncRepository.fetchContentCounts()) ?? contentCounts
        } catch {
            AppLogger.shared.error("sync profiles load failed: \(error)", source: "sync")
        }
        let known = Set(profiles.compactMap(\.id))
        plans = plans.filter { known.contains($0.key) }
        contents = contents.filter { known.contains($0.key) }
        let firstLoad = observers.isEmpty
        refreshDestinations()
        if firstLoad {
            startObserving()
            for id in profiles.compactMap(\.id) { schedulePlan(id, after: .zero) }
        }
    }

    @MainActor
    func reloadResults() async {
        results = (try? await resultRepository.fetchAll()) ?? results
    }

    /// Checks every destination (on load and on mount / unmount — never while drawing rows).
    @MainActor
    @discardableResult
    func refreshDestinations() -> Set<Int64> {
        var changed = Set<Int64>()
        for profile in profiles {
            guard let id = profile.id else { continue }
            let status = destinationStatus(profile.outputFolder)
            if destinations[id] != status { changed.insert(id) }
            destinations[id] = status
            if status == .connected {
                capacities[id] = SyncDestination.capacity(of: profile.outputFolder)
                isRockbox[id] = SyncDestination.volumePath(for: profile.outputFolder).map {
                    FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".rockbox"))
                } ?? false
            } else {
                capacities[id] = nil
            }
        }
        return changed
    }

    @MainActor
    func loadContent(_ profileID: Int64) async {
        do {
            let playlists = try await syncRepository.fetchProfilePlaylists(profileId: profileID)
            let tracks = try await syncRepository.fetchProfileTracks(profileId: profileID)
            let summaries = (try? await playlistRepository()?.fetchSummaries()) ?? [:]
            contents[profileID] = SyncProfileContent(
                playlists: playlists.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { playlist in
                    let summary = playlist.id.flatMap { summaries[$0] }
                    return .init(playlist: playlist, trackCount: summary?.totalTracks ?? 0,
                                 notDownloaded: (summary?.notDownloadedTracks ?? 0) + (summary?.failedTracks ?? 0))
                },
                tracks: tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            )
            contentCounts[profileID] = playlists.count + tracks.count
                + ((try? await syncRepository.fetchProfileRules(profileId: profileID).count) ?? 0)
        } catch {
            AppLogger.shared.error("loadContent failed: \(error)", source: "sync")
        }
    }

    // MARK: - State (UC-SIDE-07, §15.8)

    @MainActor
    func profile(_ id: Int64) -> SyncProfile? {
        profiles.first { $0.id == id }
    }

    /// The running / queued / paused / waiting sync of the profile, from Activity.
    @MainActor
    func run(for profile: SyncProfile) -> SyncRunSnapshot? {
        guard let id = profile.id else { return nil }
        let echo = ActivityCenter.shared.echo(for: .syncProfile(id, name: profile.name))
        let progress = echo.flatMap { ActivityCenter.shared.operation(id: $0.operationID)?.progress }
        return SyncRunSnapshot.from(echo, progress: progress)
    }

    @MainActor
    func stateInput(for profile: SyncProfile, now: Date = Date()) -> SyncProfileStateInput {
        let id = profile.id ?? -1
        let plan = plans[id]
        return SyncProfileStateInput(
            profileName: profile.name,
            deviceName: SyncDestination.deviceName(for: profile.outputFolder),
            destination: destinations[id] ?? .notConnected,
            libraryDrive: libraryDrive(),
            hasContent: (contentCounts[id] ?? 0) > 0,
            plan: plan?.preview?.summary,
            planHasSufficientSpace: plan?.preview?.hasSufficientSpace ?? true,
            planComputedAt: plan?.computedAt,
            isPlanUpdating: plan?.isUpdating ?? false,
            result: results[id],
            legacySyncedAt: legacySyncedAt[id],
            run: run(for: profile),
            now: now
        )
    }

    @MainActor
    func state(for profile: SyncProfile, now: Date = Date()) -> SyncProfileState {
        SyncProfileState.make(stateInput(for: profile, now: now))
    }

    // MARK: - Plans

    /// Recompute the profile's plan after `delay` (an edit: 1 s); a newer request replaces it.
    @MainActor
    func schedulePlan(_ profileID: Int64, after delay: Duration, force: Bool = false) {
        planDebounces[profileID]?.cancel()
        planDebounces[profileID] = Task { @MainActor [weak self] in
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            self?.enqueuePlan(profileID, force: force)
        }
    }

    /// ⌘R / Recompute Plan: at once, ignoring the cached plan.
    @MainActor
    func recomputePlan(_ profileID: Int64) {
        refreshDestinations()
        schedulePlan(profileID, after: .zero, force: true)
    }

    /// Stops an update of the profile's plan; the previous numbers stay.
    @MainActor
    func cancelPlanUpdate(_ profileID: Int64) {
        planDebounces[profileID]?.cancel()
        planQueue.removeAll { $0.id == profileID }
        if currentPlanTask?.id == profileID { currentPlanTask?.task.cancel() }
        plans[profileID, default: SyncPlanEntry()].isUpdating = false
        plans[profileID]?.progress = nil
    }

    @MainActor
    private func enqueuePlan(_ profileID: Int64, force: Bool) {
        if let index = planQueue.firstIndex(where: { $0.id == profileID }) {
            planQueue[index].force = planQueue[index].force || force
        } else {
            planQueue.append((profileID, force))
        }
        guard planWorker == nil else { return }
        planWorker = Task { @MainActor [weak self] in
            while let self, !self.planQueue.isEmpty {
                let next = self.planQueue.removeFirst()
                await self.computePlan(next.id, force: next.force)
            }
            self?.planWorker = nil
        }
    }

    /// One plan, off the main actor (`SyncService.previewSync` is nonisolated). Not for a
    /// destination that isn't there, and not while the profile syncs.
    @MainActor
    private func computePlan(_ profileID: Int64, force: Bool) async {
        guard let profile = profile(profileID) else { return }
        let status = destinationStatus(profile.outputFolder)
        destinations[profileID] = status
        guard status == .connected, syncService.runningProfileId != profileID else {
            plans[profileID, default: SyncPlanEntry()].isUpdating = false
            return
        }
        if force { syncService.invalidatePreview(profileId: profileID) }
        plans[profileID, default: SyncPlanEntry()].isUpdating = true
        plans[profileID]?.error = nil
        // Quiet and graceful (UC-JOB-01): visible in Activity only when slower than ~2 s.
        let job = ActivityCenter.shared.begin(
            .deviceScan, title: "Update the plan of “\(profile.name)”", itemNoun: .file,
            automatic: true, graceful: true, quiet: true, persists: false)
        let service = syncService
        let task = Task.detached(priority: .utility) { [weak self] () -> SyncService.PreviewResult in
            try await service.previewSync(profileId: profileID, forceRefresh: force) { done, total in
                job.update(completed: done, total: total)
                Task { @MainActor [weak self] in self?.plans[profileID]?.progress = (done, total) }
            }
        }
        currentPlanTask = (profileID, task)
        PerformanceQueueService.shared.setExternalSyncPreviewActive(true)
        defer {
            PerformanceQueueService.shared.setExternalSyncPreviewActive(false)
            currentPlanTask = nil
        }
        do {
            let preview = try await task.value
            plans[profileID] = SyncPlanEntry(preview: preview, computedAt: syncService.cachedPreview(profileId: profileID)?.computedAt ?? Date())
            job.finish()
            capacities[profileID] = SyncDestination.capacity(of: profile.outputFolder)
            let now = Date()
            try? await resultRepository.recordConnected(profileID: profileID, at: now)
            results[profileID, default: SyncProfileResult(profileID: profileID)].lastConnectedAt = now
        } catch is CancellationError {
            job.discard()
            plans[profileID, default: SyncPlanEntry()].isUpdating = false
            plans[profileID]?.progress = nil
        } catch {
            job.discard()
            AppLogger.shared.error("sync plan failed for \(profile.name): \(error)", source: "Sync")
            plans[profileID, default: SyncPlanEntry()].isUpdating = false
            plans[profileID]?.progress = nil
            plans[profileID]?.error = "Couldn’t read “\(SyncDestination.deviceName(for: profile.outputFolder))” — the device stopped answering."
        }
    }

    // MARK: - Watching (content, options, mounts, downloads)

    @MainActor
    private func startObserving() {
        func observe(_ name: Notification.Name, on center: NotificationCenter, _ handle: @escaping @MainActor (Notification) -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                MainActor.assumeIsolated { handle(note) }
            })
        }
        observe(.syncProfileDidChange, on: notificationCenter) { [weak self] note in
            guard let self else { return }
            let id = (note.userInfo?["profileId"] as? Int64) ?? (note.userInfo?["profileId"] as? NSNumber)?.int64Value
            Task { @MainActor in
                await self.loadProfiles()
                let ids = id.map { [$0] } ?? self.profiles.compactMap(\.id)
                for id in ids {
                    if self.contents[id] != nil { await self.loadContent(id) }
                    self.schedulePlan(id, after: self.editDebounce)
                }
            }
        }
        observe(.playlistDidChange, on: notificationCenter) { [weak self] note in
            guard let self, note.userInfo?["coverRevalidation"] == nil,
                  (note.userInfo?["origin"] as? String) != "coverService" else { return }
            Task { @MainActor in
                for id in self.profiles.compactMap(\.id) {
                    if self.contents[id] != nil { await self.loadContent(id) }
                    self.schedulePlan(id, after: self.editDebounce)
                }
            }
        }
        for name in [Notification.Name.trackAvailabilityDidChange, .downloadDidComplete, .libraryFilesDidChange] {
            observe(name, on: notificationCenter) { [weak self] _ in
                guard let self else { return }
                for id in self.profiles.compactMap(\.id) { self.schedulePlan(id, after: self.backgroundDebounce) }
            }
        }
        for name in [Notification.Name.libraryDriveDidMount, .libraryDriveDidUnmount] {
            observe(name, on: notificationCenter) { [weak self] _ in
                guard let self else { return }
                for id in self.profiles.compactMap(\.id) { self.schedulePlan(id, after: .zero) }
            }
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observe(name, on: workspaceCenter) { [weak self] _ in
                guard let self else { return }
                for id in self.refreshDestinations() where self.destinations[id] == .connected {
                    self.schedulePlan(id, after: .zero)
                }
            }
        }
    }

    /// The profile row or content changed elsewhere (rename, drop, undo): reload and re-plan.
    @MainActor
    func profileDidChange(_ profileID: Int64) async {
        await loadProfiles()
        if contents[profileID] != nil { await loadContent(profileID) }
        schedulePlan(profileID, after: editDebounce)
    }

    // MARK: - Create, delete, options

    /// Creates a profile with the preset's options and, from a selection, its first tracks.
    @MainActor
    func createProfile(name: String, outputFolder: String, preset: SyncDevicePreset,
                       trackIDs: [Int64] = []) async -> SyncProfile? {
        errorMessage = nil
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if profiles.contains(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            errorMessage = "A sync profile with this name already exists."
            return nil
        }
        do {
            let profile = try await syncRepository.create(name: trimmed, outputFolder: outputFolder)
            guard let id = profile.id else { return nil }
            let options = preset.options
            try await syncRepository.updateSettings(
                profileId: id, generateM3U8: options.playlistFiles, transcodeMode: options.transcodeMode,
                fat32SafePaths: true, cleanupRemovedFiles: true, playlistFormat: options.playlistFormat,
                artworkMode: options.artworkMode)
            for trackID in trackIDs { try await syncRepository.addTrack(profileId: id, trackId: trackID) }
            await loadProfiles()
            schedulePlan(id, after: .zero)
            notificationCenter.post(name: .syncProfileDidChange, object: nil, userInfo: ["profileId": id])
            return self.profile(id)
        } catch {
            errorMessage = error.localizedDescription.contains("UNIQUE")
                ? "A sync profile with this name already exists."
                : "Couldn’t create the sync profile — \(error.localizedDescription)"
            return nil
        }
    }

    @MainActor
    func clearError() {
        errorMessage = nil
    }

    /// A-SYNC-DELETEPROFILE (confirmed): cancels its running sync first. Nothing on the device
    /// or in the library is touched.
    @MainActor
    func deleteProfile(_ profile: SyncProfile) async {
        guard let id = profile.id else { return }
        if let run = run(for: profile) { ActivityCenter.shared.cancel(run.operationID) }
        if syncService.runningProfileId == id { syncService.cancelSync() }
        // The run may still be writing `sync_state` rows and its result: delete only after it ended.
        await runs[id]?.value
        cancelPlanUpdate(id)
        do {
            try await syncRepository.delete(id: id)
            profiles.removeAll { $0.id == id }
            plans[id] = nil
            results[id] = nil
            contents[id] = nil
            destinations[id] = nil
            syncService.invalidatePreview(profileId: id)
            statusBar()?.post("Deleted the sync profile “\(profile.name)”")
            notificationCenter.post(name: .syncProfileDidChange, object: nil)
        } catch {
            statusBar()?.post(UndoFailure.sentence("Couldn’t delete “\(profile.name)”", error))
        }
    }

    /// Options save at once; the plan recomputes after 1 s (V-SYNC-DETAIL.E07).
    @MainActor
    func updateOptions(_ profileID: Int64, generateM3U8: Bool? = nil, transcodeMode: String? = nil,
                       fat32SafePaths: Bool? = nil, cleanupRemovedFiles: Bool? = nil,
                       playlistFormat: String? = nil, normalizeLoudness: Bool? = nil, artworkMode: String? = nil) async {
        do {
            try await syncRepository.updateSettings(
                profileId: profileID, generateM3U8: generateM3U8, transcodeMode: transcodeMode,
                fat32SafePaths: fat32SafePaths, cleanupRemovedFiles: cleanupRemovedFiles,
                playlistFormat: playlistFormat, normalizeLoudness: normalizeLoudness, artworkMode: artworkMode)
            if syncService.runningProfileId == profileID { optionsChangedWhileSyncing.insert(profileID) }
            await loadProfiles()
            schedulePlan(profileID, after: editDebounce)
        } catch {
            statusBar()?.post(UndoFailure.sentence("Couldn’t change the option", error))
        }
    }

    /// Reset to Device Defaults (the preset the destination suggests).
    @MainActor
    func applyPreset(_ preset: SyncDevicePreset, to profileID: Int64) async {
        let options = preset.options
        await updateOptions(profileID, generateM3U8: options.playlistFiles, transcodeMode: options.transcodeMode,
                            cleanupRemovedFiles: true, playlistFormat: options.playlistFormat,
                            artworkMode: options.artworkMode)
    }

    /// S-SYNC-DESTINATION: the plan is computed again for the new destination; nothing is
    /// deleted on the old one.
    @MainActor
    func changeDestination(_ profileID: Int64, to path: String) async {
        guard let profile = profile(profileID), path != profile.outputFolder else { return }
        do {
            try await syncRepository.updateSettings(profileId: profileID, outputFolder: path)
            syncService.invalidatePreview(profileId: profileID)
            plans[profileID] = nil
            await loadProfiles()
            schedulePlan(profileID, after: .zero)
            statusBar()?.post("Changed the destination of “\(profile.name)” to “\(SyncDestination.deviceName(for: path))”")
        } catch {
            statusBar()?.post(UndoFailure.sentence("Couldn’t change the destination", error))
        }
    }

    @MainActor
    func setBackgroundProcessing(_ level: SyncTurboLevel) {
        syncService.setSyncTurboLevel(level)
    }

    // MARK: - Content (undoable through ShellEdits, nothing navigates)

    @MainActor
    func addTracks(_ trackIDs: [Int64], to profile: SyncProfile) async {
        guard let id = profile.id else { return }
        await edits().addTracks(trackIDs, toSyncProfile: id, name: profile.name)
    }

    @MainActor
    func addPlaylists(_ playlistIDs: [Int64], to profile: SyncProfile) async {
        guard let id = profile.id else { return }
        await edits().addPlaylists(playlistIDs, toSyncProfile: id, name: profile.name)
    }

    @MainActor
    func removePlaylists(_ playlistIDs: Set<Int64>, from profile: SyncProfile) async {
        guard let id = profile.id else { return }
        let names = Dictionary((contents[id]?.playlists ?? []).map { ($0.id, $0.playlist.name) }, uniquingKeysWith: { a, _ in a })
        await edits().removePlaylists(Array(playlistIDs), fromSyncProfile: id, name: profile.name, playlistNames: names)
    }

    @MainActor
    func removeTracks(_ trackIDs: Set<Int64>, from profile: SyncProfile) async {
        guard let id = profile.id else { return }
        let names = Dictionary((contents[id]?.tracks ?? []).compactMap { track in track.id.map { ($0, track.title) } },
                               uniquingKeysWith: { a, _ in a })
        await edits().removeTracks(Array(trackIDs), fromSyncProfile: id, name: profile.name, trackNames: names)
    }

    // MARK: - Sync Now, Retry Failed, Pause / Resume / Cancel

    /// Sync Now: one Activity operation; the status bar marks the end with `Eject “‹device›”`.
    @MainActor
    func syncNow(_ profile: SyncProfile) {
        start(profile, onlyTrackIDs: nil)
    }

    /// Retry Failed: only this profile's failed tracks, into this profile's destination (PP-SYNC-02).
    @MainActor
    func retryFailed(_ profile: SyncProfile, trackIDs: Set<Int64>? = nil) {
        guard let id = profile.id else { return }
        let failed = Set(results[id]?.failures.map(\.trackID) ?? [])
        let ids = trackIDs.map { $0.intersection(failed) } ?? failed
        guard !ids.isEmpty else { return }
        statusBar()?.post("Retrying \(StatusBarText.tracks(ids.count)) on “\(profile.name)” — playlist files are rewritten afterwards")
        start(profile, onlyTrackIDs: ids)
    }

    @MainActor
    private func start(_ profile: SyncProfile, onlyTrackIDs: Set<Int64>?) {
        guard let id = profile.id, runs[id] == nil else { return }
        optionsChangedWhileSyncing.remove(id)
        let service = syncService
        let deviceName = SyncDestination.deviceName(for: profile.outputFolder)
        runs[id] = Task { @MainActor [weak self] in
            var message: String?
            var ejectable = false
            do {
                let result = try await service.executeSync(profileId: id, onlyTrackIDs: onlyTrackIDs)
                ejectable = self?.canEjectVolume(of: profile) ?? false
                message = Self.endMessage(result, retry: onlyTrackIDs != nil)
            } catch let error as SyncError {
                if case .insufficientSpace = error {
                    message = "Couldn’t start the sync — not enough space on “\(deviceName)”"
                }
            } catch let error as SyncRunError {
                message = "Couldn’t start the sync — \(error.plainCause)"
            } catch {
                message = UndoFailure.sentence("The sync of “\(profile.name)” stopped", error)
            }
            guard let self else { return }
            self.runs[id] = nil
            self.optionsChangedWhileSyncing.remove(id)
            await self.loadProfiles()
            self.refreshDestinations()
            self.schedulePlan(id, after: .zero)
            if let message {
                var actions: [StatusAction] = []
                if ejectable && !self.isAnotherSyncOnVolume(of: profile) {
                    actions.append(StatusAction("Eject “\(deviceName)”") { [weak self] in
                        Task { await self?.eject(profile) }
                    })
                }
                self.statusBar()?.post(message, actions: actions)
            }
        }
    }

    /// Waits until the profile's sync (started here) has ended and its result is loaded.
    @MainActor
    func waitForRun(_ profileID: Int64) async {
        await runs[profileID]?.value
    }

    /// Waits until no plan is being computed or queued.
    @MainActor
    func waitForPlans() async {
        for task in planDebounces.values { await task.value }
        while let worker = planWorker { await worker.value }
    }

    /// `Sync finished — 214 copied · 9 failed · 9 skipped` / `Sync cancelled — 86 copied`.
    static func endMessage(_ result: SyncService.SyncResult, retry: Bool) -> String {
        var parts = ["\(result.syncedCount.formatted(.number)) copied"]
        if result.removedCount > 0 { parts.append("\(result.removedCount.formatted(.number)) removed") }
        if result.failedCount > 0 { parts.append("\(result.failedCount.formatted(.number)) failed") }
        if result.skippedCount > 0 { parts.append("\(result.skippedCount.formatted(.number)) skipped") }
        let head = result.wasCancelled ? "Sync cancelled" : (retry ? "Retry finished" : "Sync finished")
        return "\(head) — \(parts.joined(separator: " · "))"
    }

    @MainActor
    func pause(_ profile: SyncProfile) {
        if let run = run(for: profile) { ActivityCenter.shared.pause(run.operationID) }
    }

    @MainActor
    func resume(_ profile: SyncProfile) {
        if let run = run(for: profile) { ActivityCenter.shared.resume(run.operationID) }
    }

    @MainActor
    func cancel(_ profile: SyncProfile) {
        if let run = run(for: profile) { ActivityCenter.shared.cancel(run.operationID) }
    }

    /// `Show in Activity`: the Activity window with this profile's last operation selected.
    @MainActor
    func showInActivity(_ profile: SyncProfile) {
        let id = run(for: profile)?.operationID ?? profile.id.flatMap { results[$0]?.operationID }
        ActivityRouter.shared.selectedOperationID = id
        ActivityRouter.shared.requestWindow(tab: .operations)
    }

    // MARK: - Eject (§10 Q13)

    @MainActor
    private func isAnotherSyncOnVolume(of profile: SyncProfile) -> Bool {
        guard let volume = SyncDestination.volumePath(for: profile.outputFolder) else { return false }
        return profiles.contains { other in
            other.id != profile.id && SyncDestination.volumePath(for: other.outputFolder) == volume && run(for: other) != nil
        }
    }

    /// Why `Eject` can't run now; `nil` = it can.
    @MainActor
    func ejectRefusal(_ profile: SyncProfile) -> String? {
        guard let volume = SyncDestination.volumePath(for: profile.outputFolder) else { return "Not a removable disk." }
        let deviceName = SyncDestination.deviceName(for: profile.outputFolder)
        if volume == libraryVolumePath() { return "Can’t eject — “\(deviceName)” holds the library" }
        let busy = profiles.contains { other in
            SyncDestination.volumePath(for: other.outputFolder) == volume && run(for: other) != nil
        }
        return busy ? "“\(deviceName)” can’t be ejected while it syncs." : nil
    }

    @MainActor
    func canEject(_ profile: SyncProfile) -> Bool {
        guard let id = profile.id, destinations[id] == .connected || destinations[id] == .folderNotFound else { return false }
        return canEjectVolume(of: profile)
    }

    @MainActor
    private func canEjectVolume(of profile: SyncProfile) -> Bool {
        SyncDestination.isEjectable(profile.outputFolder, libraryVolumePath: libraryVolumePath())
    }

    @MainActor
    func eject(_ profile: SyncProfile) async {
        let deviceName = SyncDestination.deviceName(for: profile.outputFolder)
        if let refusal = ejectRefusal(profile) {
            statusBar()?.post(refusal.hasPrefix("Can’t eject") ? refusal : "Couldn’t eject — \(refusal)")
            return
        }
        guard let volume = SyncDestination.volumePath(for: profile.outputFolder) else { return }
        do {
            try await SyncDestination.eject(volumePath: volume)
            refreshDestinations()
            statusBar()?.post("“\(deviceName)” can be removed safely")
        } catch {
            AppLogger.shared.warn("Eject of \(volume) failed: \(error.localizedDescription)", source: "Sync")
            statusBar()?.post("Couldn’t eject — “\(deviceName)” is in use", actions: [
                StatusAction("Try Again") { [weak self] in Task { await self?.eject(profile) } }
            ])
        }
    }

    // MARK: - Helpers

    private static let sqliteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()
}

// MARK: - Device presets (S-SYNC-NEWPROFILE.N01)

/// What a new profile starts with. Every option can be changed later on the profile.
enum SyncDevicePreset: String, CaseIterable, Identifiable, Sendable {
    case rockbox
    case doppi
    case ios
    case plainFolder

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rockbox: "Rockbox player"
        case .doppi: "Phone app (Doppi)"
        case .ios: "MLM for iOS"
        case .plainFolder: "Plain folder"
        }
    }

    struct Options: Equatable {
        let playlistFiles: Bool
        let transcodeMode: String
        let playlistFormat: String
        let artworkMode: String
    }

    var options: Options {
        switch self {
        case .rockbox: Options(playlistFiles: true, transcodeMode: TranscodeMode.aac248.rawValue,
                               playlistFormat: PlaylistFormat.rockbox.rawValue, artworkMode: ArtworkMode.resize250.rawValue)
        case .doppi: Options(playlistFiles: true, transcodeMode: TranscodeMode.aac248.rawValue,
                             playlistFormat: PlaylistFormat.doppi.rawValue, artworkMode: ArtworkMode.keepOriginal.rawValue)
        case .ios: Options(playlistFiles: true, transcodeMode: TranscodeMode.aac248.rawValue,
                           playlistFormat: PlaylistFormat.ios.rawValue, artworkMode: ArtworkMode.keepOriginal.rawValue)
        case .plainFolder: Options(playlistFiles: false, transcodeMode: TranscodeMode.keepOriginals.rawValue,
                                   playlistFormat: PlaylistFormat.rockbox.rawValue, artworkMode: ArtworkMode.keepOriginal.rawValue)
        }
    }

    /// `AAC 248 kbps · artwork 250 px · playlist files (.m3u8) · clean up on`.
    var summary: String {
        let o = options
        var parts = [o.transcodeMode == TranscodeMode.keepOriginals.rawValue ? "files as they are" : "AAC 248 kbps"]
        if o.artworkMode == ArtworkMode.resize250.rawValue { parts.append("artwork 250 px") }
        if o.playlistFiles { parts.append(o.playlistFormat == PlaylistFormat.doppi.rawValue ? "playlist files (.m3u)" : "playlist files (.m3u8)") }
        parts.append("clean up on")
        return parts.joined(separator: " · ")
    }

    /// The preset matching a profile's options (`Reset to Device Defaults`), if any.
    static func matching(_ profile: SyncProfile) -> SyncDevicePreset? {
        allCases.first { preset in
            let o = preset.options
            return o.playlistFiles == profile.generateM3U8 && o.transcodeMode == profile.transcodeMode
                && o.playlistFormat == profile.playlistFormat && o.artworkMode == profile.artworkMode
        }
    }
}
