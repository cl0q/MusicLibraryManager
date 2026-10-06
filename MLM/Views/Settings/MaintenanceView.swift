import SwiftUI

/// Settings ▸ Maintenance (ST-MAINT, F-22, DEC-044): jobs as rows — what each is for, how much
/// of the library it covers (SQL), when it last ran with its own result (Activity's history),
/// `Run`. A running or queued job is an Activity operation; its row is only the echo, with the
/// same words and numbers (UC-JOB-07). No shared result line (ST-MAINT.E18 removed), no
/// one-job-at-a-time lock: jobs queue. `Cancel` appears only where it really cancels.
///
/// The work lives in `MaintenanceJobs` (also started from Library ▸ Maintenance ▸).
struct MaintenanceView: View {
    @Environment(\.container) private var container
    @State private var backgroundProcessing: SyncTurboLevel = .standard
    @State private var confirmsApply = false
    @State private var confirmsRollback = false
    @State private var confirmsCacheClear = false
    @State private var choosesCacheFolder = false
    /// Why the cache can't be cleared or moved (review B1), or the last refusal.
    @State private var cacheRefusal: String?
    @State private var cacheProblem: String?
    @State private var cacheSummary: (files: Int, bytes: Int64)?
    @State private var cacheReach: LocationReach = .notSet

    private var jobs: MaintenanceJobs { .shared }
    private var runner: MaintenanceJobRunner { jobs.runner }
    private var tools: DownloadToolsModel { .shared }
    private var drive: LibraryDriveState { LibraryDriveState.current(container) }

    var body: some View {
        Form {
            if drive.isOffline, let name = drive.volumeName {
                Section {
                    Label("“\(name)” is not connected. Maintenance that reads audio files can’t run until it is.",
                          systemImage: "externaldrive.badge.xmark")
                }
            }
            backgroundSection
            Section("Analysis") {
                jobRow(MaintenanceJob.fingerprint, "Fingerprint all tracks", "Finds duplicates by sound.")
                jobRow(MaintenanceJob.replayGain, "ReplayGain analysis", "Loudness for Normalize loudness and the Energy column.")
                jobRow(MaintenanceJob.danceability, "Danceability analysis", "Beat regularity for the Dance column.")
                jobRow(MaintenanceJob.similarity, "Similarity analysis", "On-device analysis for Similar and for genre suggestions.")
            }
            Section("Artwork and tags") {
                jobRow(MaintenanceJob.artworkEmbedded, "Refresh embedded artwork", "Reads cover art from the audio files. No network.")
                jobRow(MaintenanceJob.artworkMusicBrainz, "Fetch artwork from MusicBrainz", "Downloads missing album covers. Slow on purpose (rate-limited).")
                jobRow(MaintenanceJob.rereadTags, "Reread tags from files", "Use after editing tags in another app.")
                jobRow(MaintenanceJob.clearSourceNames, "Clear source names from Album",
                       "Empties the Album field where it holds SoundCloud, YouTube or another source name. Where the tracks came from stays recorded.")
            }
            duplicatesSection
            transcodeCacheSection
            OrganizedPathsSection(confirmsApply: $confirmsApply, confirmsRollback: $confirmsRollback, drive: drive)
        }
        .formStyle(.grouped)
        .task(id: container.isInitialized) {
            backgroundProcessing = container.syncViewModel?.syncService.syncTurboLevel
                ?? UserDefaults.standard.string(forKey: "sync_turbo_level").flatMap(SyncTurboLevel.init(rawValue:))
                ?? .standard
            await jobs.refreshCoverage()
            await refreshCache()
            await tools.check()
        }
        .onChange(of: ActivityCenter.shared.finishedCount) { _, _ in
            Task {
                await jobs.refreshCoverage()
                // Only a cache operation or a sync changes the cache (not every finished job).
                if let last = ActivityCenter.shared.finishedOperations.first,
                   [.transcodeCacheMove, .sync].contains(last.kind) {
                    await refreshCache()
                }
            }
        }
        .alert("Update organized paths?", isPresented: $confirmsApply) {
            Button("Apply \(jobs.pathReport?.eligibleCount.formatted() ?? "0") Changes", role: .destructive) {
                jobs.start(MaintenanceJob.pathApply)
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(applyMessage)
        }
        .alert("Roll back last path migration?", isPresented: $confirmsRollback) {
            Button("Roll Back", role: .destructive) { jobs.start(MaintenanceJob.pathRollback) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(rollbackMessage)
        }
        .alert(MaintenanceJobs.rereadTitle(tracks: jobs.coverage?.tracksWithFile ?? 0),
               isPresented: Binding(get: { jobs.rereadConfirmationRequested },
                                    set: { jobs.rereadConfirmationRequested = $0 })) {
            Button("Reread Tags", role: .destructive) { jobs.start(MaintenanceJob.rereadTags) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(MaintenanceJobs.rereadMessage)
        }
        .alert(SourceAlbumCleanup.alertTitle(jobs.coverage?.sourceNamedAlbums ?? 0),
               isPresented: Binding(get: { jobs.clearSourceNamesConfirmationRequested },
                                    set: { jobs.clearSourceNamesConfirmationRequested = $0 })) {
            Button(SourceAlbumCleanup.alertButton(jobs.coverage?.sourceNamedAlbums ?? 0)) { jobs.start(MaintenanceJob.clearSourceNames) }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(SourceAlbumCleanup.alertMessage)
        }
        .alert("Clear the transcode cache?", isPresented: $confirmsCacheClear) {
            Button("Clear Cache", role: .destructive) {
                Task {
                    cacheProblem = await jobs.clearTranscodeCache()
                    await refreshCache()
                }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(cacheClearMessage)
        }
        .folderPanel(isPresented: $choosesCacheFolder, message: "Choose a folder for the transcode cache.",
                     directory: container.transcodeCache?.cacheDir) { url in
            Task { cacheProblem = await jobs.relocateTranscodeCache(to: url) }
        }
    }

    // MARK: Background processing

    private var backgroundSection: some View {
        Section("Background processing") {
            Picker(selection: $backgroundProcessing) {
                ForEach(SyncTurboLevel.allCases) { Text($0.displayName).tag($0) }
            } label: {
                Text("How hard background work may push this Mac")
                Text("Conservative keeps the Mac responsive · Fast uses all cores, fans may spin up. Applies to the next run.")
            }
            .pickerStyle(.segmented)
            .onChange(of: backgroundProcessing) { _, level in
                if let syncViewModel = container.syncViewModel {
                    syncViewModel.setBackgroundProcessing(level)
                } else {
                    UserDefaults.standard.set(level.rawValue, forKey: "sync_turbo_level")
                }
            }
        }
    }

    // MARK: Job rows (ST-MAINT.E13)

    private func jobRow(_ action: String, _ title: String, _ purpose: String) -> some View {
        let echo = runner.echo(for: action)
        let automatic = action == MaintenanceJob.artworkEmbedded && echo == nil
            ? jobs.automaticArtworkOperation.flatMap(MaintenanceJobRunner.echo) : nil
        let toolMissing = action == MaintenanceJob.fingerprint && tools.isMissing(.fpcalc)
        let blocked = jobs.blockedReason(action, drive: drive, toolMissing: toolMissing)
        return LabeledContent {
            if echo != nil {
                if runner.canCancel(action) {
                    Button("Cancel") { runner.cancel(action) }
                }
            } else {
                Button("Run") {
                    // Rereading replaces database values: it asks first (review S2).
                    if action == MaintenanceJob.rereadTags {
                        jobs.rereadConfirmationRequested = true
                    } else if action == MaintenanceJob.clearSourceNames {
                        jobs.clearSourceNamesConfirmationRequested = true
                    } else {
                        jobs.start(action)
                    }
                }
                    .disabled(blocked != nil)
                    .help(blocked ?? "")
            }
        } label: {
            SettingsRowLabel(title) {
                Text(purpose)
                if let echo {
                    JobEchoView(echo: echo)
                } else if let automatic {
                    // The automatic backfill runs: say so instead of a refresh that didn't happen.
                    JobEchoView(echo: MaintenanceJobRunner.Echo(text: "Artwork is being read for new tracks — \(automatic.text)",
                                                                fraction: automatic.fraction, isQueued: false))
                } else {
                    HStack(spacing: 4) {
                        Text(idleLine(action))
                        if toolMissing {
                            Text("·")
                            SettingsState(text: "fpcalc not found", systemImage: "exclamationmark.triangle", tone: .problem)
                            Text("·")
                            Button("Open Sources ▸ Download tools") { SettingsRouter.shared.select(.sources) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
    }

    /// `9,412 of 12,935 analysed · last run 28 Sep 2026 — 3,204 analysed · 12 failed`.
    private func idleLine(_ action: String) -> String {
        [jobs.coverage?.text(for: action), runner.lastRun(of: action)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: Duplicates and the liked playlist

    private var duplicatesSection: some View {
        Section("Duplicates and linked playlists") {
            LabeledContent {
                Button("Open Review") {
                    MainWindowPresenter.shared.show()
                    NotificationCenter.default.post(name: .showReview, object: nil)
                }
            } label: {
                SettingsRowLabel("Find duplicates and conflicts") {
                    Text("Runs in Review, where progress, decisions and Undo stay together.")
                }
            }
            LabeledContent {
                Button("Recreate") { jobs.start(MaintenanceJob.recreateLikedPlaylist) }
                    .disabled(runner.isActive(MaintenanceJob.recreateLikedPlaylist))
            } label: {
                SettingsRowLabel("Recreate the “\(MaintenanceJobs.likedPlaylistName)” playlist") {
                    Text("Creates it again, or links the existing one, if it was deleted.")
                }
            }
        }
    }

    // MARK: Transcode cache

    private var transcodeCacheSection: some View {
        Section {
            let blocked = container.transcodeCacheMoveBlockedReason ?? cacheRefusal
            let needsDrive = cacheReach.isReachable ? nil : cacheReach.text
            LabeledContent {
                HStack {
                    Button("Change…") { choosesCacheFolder = true }
                        .disabled(blocked != nil || needsDrive != nil)
                        .help(blocked ?? needsDrive ?? "")
                    Button("Clear Cache…", role: .destructive) { confirmsCacheClear = true }
                        .disabled(blocked != nil || needsDrive != nil || (cacheSummary?.files ?? 0) == 0)
                        .help(blocked ?? needsDrive ?? "")
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if let dir = container.transcodeCache?.cacheDir { SettingsPath(dir) }
                    Group {
                        if !cacheReach.isReachable, cacheReach != .notSet {
                            SettingsState(reach: cacheReach)
                        } else if let cacheSummary {
                            Text("\(DataLocationsViewModel.countText(cacheSummary.files, singular: "file", plural: "files")) · \(DataLocationsViewModel.formatBytes(cacheSummary.bytes))")
                        }
                        if let refusal = cacheProblem ?? cacheRefusal {
                            SettingsState(text: refusal, systemImage: "exclamationmark.triangle", tone: .error)
                        }
                        if let echo = ActivityCenter.shared.activeOperations.first(where: { $0.kind == .transcodeCacheMove })
                            .flatMap(MaintenanceJobRunner.echo) {
                            JobEchoView(echo: echo)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Transcode cache")
        } footer: {
            Text("Transcoded copies made for syncing. Changing the location moves the existing files in the background (shown in Activity) and removes the old copies.")
        }
    }

    private func refreshCache() async {
        guard let dir = container.transcodeCache?.cacheDir else {
            cacheSummary = nil
            cacheReach = .notSet
            return
        }
        cacheReach = await Task.detached {
            LocationReach.of(dir, isVolumeMounted: DataLocationsViewModel.isVolumeMounted,
                             exists: { FileManager.default.fileExists(atPath: $0.path) })
        }.value
        cacheSummary = cacheReach.isReachable ? await Task.detached { MaintenanceJobs.cacheSummary(dir) }.value : nil
        cacheRefusal = cacheReach.isReachable ? await jobs.cacheRefusal(for: dir) : nil
    }

    /// A-SET-CACHECLEAR: `2,140 transcoded copies (18.2 GB) will be deleted. …`
    private var cacheClearMessage: String {
        let count = cacheSummary?.files ?? 0
        let size = DataLocationsViewModel.formatBytes(cacheSummary?.bytes ?? 0)
        let copies = count == 1 ? "1 transcoded copy" : "\(count.formatted()) transcoded copies"
        return "\(copies) (\(size)) will be deleted — only files MLM made in this cache folder. Your music files are not touched. The next sync creates the copies it needs again, which takes time."
    }

    // MARK: Path alerts

    /// A-SET-PATHAPPLY: the count and the safety net in plain words.
    private var applyMessage: String {
        let fixable = jobs.pathReport?.eligibleCount ?? 0
        let unclear = jobs.pathReport?.unresolvedCount ?? 0
        return "\(fixable.formatted()) track locations confirmed in the preview will be updated; the \(unclear.formatted()) unclear entries stay as they are. MLM backs up the library first and records every change so it can be rolled back. No files are moved."
    }

    /// A-SET-PATHROLLBACK: names the migration that will be undone.
    private var rollbackMessage: String {
        guard let last = jobs.lastMigration else { return "There is no migration to roll back." }
        return "The \(last.changeCount.formatted()) organized paths changed on \(last.appliedAt.formatted(date: .abbreviated, time: .omitted)) will be restored. MLM backs up the library again before the rollback. No files are moved."
    }
}

// MARK: - Organized paths (ST-MAINT.E16)

/// Preview → confirm → roll back; read only until applied. Results stay on this block.
private struct OrganizedPathsSection: View {
    @Binding var confirmsApply: Bool
    @Binding var confirmsRollback: Bool
    let drive: LibraryDriveState

    private var jobs: MaintenanceJobs { .shared }
    private var runner: MaintenanceJobRunner { jobs.runner }

    /// Rows shown in the preview before `…n more`.
    private static let previewRows = 20

    var body: some View {
        Section("Organized paths") {
            let auditBlocked = jobs.blockedReason(MaintenanceJob.pathAudit, drive: drive)
            let busy = [MaintenanceJob.pathAudit, MaintenanceJob.pathApply, MaintenanceJob.pathRollback]
                .contains(where: runner.isActive)
            LabeledContent {
                HStack {
                    Button("Preview Changes") { jobs.start(MaintenanceJob.pathAudit) }
                        .disabled(auditBlocked != nil || busy)
                        .help(auditBlocked ?? "")
                    Button("Roll Back Last Migration…") { confirmsRollback = true }
                        .disabled(jobs.lastMigration == nil || busy)
                        .help(jobs.lastMigration == nil ? "There is no migration to roll back." : "")
                }
            } label: {
                SettingsRowLabel("Repair track locations that no longer match the files") {
                    Text("Read only until you apply. MLM backs up first and can roll the last migration back.")
                    statusLine
                }
            }
            if let report = jobs.pathReport, !busy {
                LabeledContent {
                    if let reason = jobs.pathApplyBlockedReason() {
                        SettingsState(text: reason, systemImage: "exclamationmark.triangle", tone: .problem)
                    } else {
                        Button("Apply \(report.eligibleCount.formatted()) Changes…") { confirmsApply = true }
                            .disabled(report.eligibleCount == 0)
                            .keyboardShortcut(.defaultAction)
                    }
                } label: {
                    DisclosureGroup("Changes (\(report.eligibleCount.formatted()) can be fixed, \(report.unresolvedCount.formatted()) unclear)") {
                        changes(report)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let active = [MaintenanceJob.pathAudit, MaintenanceJob.pathApply, MaintenanceJob.pathRollback]
            .lazy.compactMap { runner.echo(for: $0) }.first
        if let active {
            JobEchoView(echo: active)
        } else if let problem = jobs.pathProblem {
            SettingsState(text: "Couldn’t preview — \(problem)", systemImage: "exclamationmark.triangle", tone: .error)
        } else if let report = jobs.pathReport {
            Text("\(report.inspectedCount.formatted()) reviewed · \(report.alreadyValidCount.formatted()) already valid · \(report.eligibleCount.formatted()) can be fixed · \(report.unresolvedCount.formatted()) unclear · \(report.diskFileCount.formatted()) audio files found")
        } else if let result = jobs.pathResult {
            Text(result)
        } else if let last = jobs.lastMigration {
            Text("Last migration \(last.appliedAt.formatted(date: .abbreviated, time: .omitted)) — \(last.changeCount.formatted()) organized paths updated")
        }
    }

    private func changes(_ report: OrganizedPathMigrationService.AuditReport) -> some View {
        let rows = report.rows.filter { $0.status != .alreadyValid }
        return VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(rows.prefix(Self.previewRows)) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(row.artist) — \(row.title) · \(row.status == .eligible ? "can be fixed" : "unclear")")
                        .fontWeight(.medium)
                    SettingsPath("Before  \(row.beforeOrganizedPath)")
                    if let after = row.selectedRelativePath {
                        SettingsPath("After   \(after)")
                    }
                    Text(Self.note(for: row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
            }
            if rows.count > Self.previewRows {
                let fixable = rows.dropFirst(Self.previewRows).filter { $0.status == .eligible }.count
                let unclear = rows.count - Self.previewRows - fixable
                Text("…\(fixable.formatted()) more can be fixed, \(unclear.formatted()) more unclear")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, Spacing.xs)
    }

    /// The reason in plain words (no internal reason codes, ST-MAINT.E16).
    static func note(for row: OrganizedPathMigrationService.AuditRow) -> String {
        switch row.status {
        case .eligible:
            return "The same file was found in exactly one place."
        case .unresolved:
            if row.candidates.count > 1 {
                return "\(row.candidates.count) files could be this track: \(row.candidates.prefix(2).map(\.relativePath).joined(separator: " and ")). Left unchanged."
            }
            return "No matching file was found. Left unchanged."
        case .alreadyValid:
            return ""
        }
    }
}
