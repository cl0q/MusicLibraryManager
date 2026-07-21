import SwiftUI

/// Maintenance actions view — batch operations for library health.
///
/// Provides buttons for: rescan metadata, fingerprint batch,
/// ReplayGain analysis, artwork fetch, deep scan duplicates,
/// reindex search, and orphan detection.
struct MaintenanceView: View {
    @Environment(\.container) private var container
    @State private var isRunning: String? = nil
    @State private var resultMessage: String? = nil
    @State private var selectedSource = "soundcloud"
    @State private var turboMode: Bool = false
    @State private var progressState: MaintenanceProgressTracker.ProgressState? = nil
    @State private var pathMigrationReport: OrganizedPathMigrationService.AuditReport? = nil
    @State private var showPathMigrationReport = false
    @State private var showPathMigrationConfirmation = false
    @State private var showPathRollbackConfirmation = false

    var body: some View {
        Form {
            Section("Performance") {
                HStack {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Turbo Mode")
                                .font(MLMFont.body)
                            Text("Use 80% of available cores for faster processing")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                        }
                    } icon: {
                        Image(systemName: "bolt.fill")
                            .frame(width: 20)
                    }
                    
                    Spacer()
                    
                    Toggle("Turbo", isOn: $turboMode)
                        .toggleStyle(.switch)
                }
            }
            
            Section("Transcode Cache") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speicherort für transkodierte Audiodateien")
                                    .font(MLMFont.body)
                                if let path = container.transcodeCache?.cacheDir.path {
                                    Text(path)
                                        .font(MLMFont.mono)
                                        .font(.caption)
                                        .foregroundColor(.mlmInkSecondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text("Standard-Pfad (intern)")
                                        .font(MLMFont.muted)
                                        .foregroundColor(.mlmInkMuted)
                                }
                            }
                        } icon: {
                            Image(systemName: "folder.badge.gearshape")
                                .frame(width: 20)
                        }
                        
                        Spacer()
                        
                        Button("Speicherort ändern...") {
                            chooseNewCacheFolder()
                        }
                        .disabled(isRunning != nil)
                    }
                    
                    Text("Hinweis: Wenn du einen neuen Pfad auswählst, verschiebt MLM all deine existierenden Cache-Dateien automatisch im Hintergrund dorthin und löscht die alten Dateien, um sofort Speicherplatz auf deiner internen SSD freizugeben.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                }
                .padding(.vertical, 4)
            }
            
            Section("Analysis") {
                maintenanceRow(
                    title: "Fingerprint All Tracks",
                    description: "Generate audio fingerprints for tracks missing them",
                    icon: "hand.point.up.braille",
                    action: "fingerprint"
                ) {
                    await runFingerprint()
                }

                maintenanceRow(
                    title: "ReplayGain Analysis",
                    description: "Analyze loudness (LUFS) and compute energy buckets",
                    icon: "waveform",
                    action: "replaygain"
                ) {
                    await runReplayGain()
                }

                maintenanceRow(
                    title: "Danceability Analysis",
                    description: "Analyze rhythmic beat regularity and compute danceability scores",
                    icon: "sparkles",
                    action: "danceability"
                ) {
                    await runDanceability()
                }

                maintenanceRow(
                    title: "Groove Analysis (Smart Suggestions)",
                    description: "Generate CoreML acoustic embeddings for smart song suggestions",
                    icon: "music.note.list",
                    action: "groove"
                ) {
                    await runGrooveAnalysis()
                }

                maintenanceRow(
                    title: "Refresh embedded artwork",
                    description: "Extract embedded artwork from audio files (ffmpeg, no network)",
                    icon: "waveform.circle.fill",
                    action: "artwork-embedded"
                ) {
                    await runArtworkEmbedded()
                }

                maintenanceRow(
                    title: "Fetch from MusicBrainz",
                    description: "Download missing album art from MusicBrainz Cover Art Archive (rate-limited)",
                    icon: "globe",
                    action: "artwork-musicbrainz"
                ) {
                    await runArtworkMusicBrainz()
                }
            }

            Section("Duplicates") {
                maintenanceRow(
                    title: "Deep Scan",
                    description: "Compare all fingerprints to find duplicate tracks",
                    icon: "doc.on.doc",
                    action: "deepscan"
                ) {
                    await runDeepScan()
                }
            }

            Section("Library") {
                maintenanceRow(
                    title: "Rescan Metadata",
                    description: "Re-read audio tags from all local files",
                    icon: "arrow.clockwise",
                    action: "rescan"
                ) {
                    await runRescanMetadata()
                }

                pathMigrationControls
            }

            Section("Source Playlists") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recreate or link a synchronized liked playlist for a specific source.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)

                    HStack {
                        Picker("Source Type", selection: $selectedSource) {
                            Text("SoundCloud").tag("soundcloud")
                            // Future proofing for other sources can be added here
                        }
                        .frame(maxWidth: 220)

                        Spacer()

                        if isRunning == "create-liked-playlist" {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Create / Link Playlist") {
                                Task {
                                    await runCreateLikedPlaylist()
                                }
                            }
                            .disabled(isRunning != nil)
                        }
                    }
                }
            }

            if let result = resultMessage {
                Section {
                    Text(result)
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .confirmationDialog(
            "Organized paths jetzt aktualisieren?",
            isPresented: $showPathMigrationConfirmation,
            titleVisibility: .visible
        ) {
            Button("Bestätigen und anwenden", role: .destructive) {
                Task { await applyPathMigration() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Beende vorher alle Downloads und schließe die ältere Tauri-App. Nur die in der Vorschau eindeutig bestätigten organized_path-Werte werden geändert. Vorher werden SQLite-Backup und JSON-Manifest außerhalb der Audio-Library erstellt.")
        }
        .confirmationDialog(
            "Letzte Pfad-Migration zurückrollen?",
            isPresented: $showPathRollbackConfirmation,
            titleVisibility: .visible
        ) {
            Button("Rollback bestätigen", role: .destructive) {
                Task { await rollbackPathMigration() }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Die organized_path-Werte aus dem neuesten angewendeten Manifest werden wiederhergestellt. Vor dem Rollback wird ein weiteres SQLite-Backup erstellt.")
        }
    }

    @ViewBuilder
    private var pathMigrationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Organized-Path-Migration")
                            .font(MLMFont.body)
                        Text("Nur lesen → Vorschau → Backup/Manifest → bestätigte DB-Transaktion")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                    }
                } icon: {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .frame(width: 20)
                }

                Spacer()

                if isRunning == "path-audit" {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Vorschau erstellen") {
                        Task { await runPathMigrationAudit() }
                    }
                    .disabled(isRunning != nil)
                }
            }

            if let report = pathMigrationReport {
                Text(
                    "\(report.inspectedCount) geprüft · \(report.alreadyValidCount) intakt · " +
                    "\(report.eligibleCount) eindeutig · \(report.unresolvedCount) ungeklärt · " +
                    "\(report.diskFileCount) Audiodateien inventarisiert"
                )
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)

                DisclosureGroup("Kandidatenbericht", isExpanded: $showPathMigrationReport) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(report.rows.filter { $0.status != .alreadyValid }) { row in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text("#\(row.trackID) · \(row.artist) — \(row.title)")
                                            .font(MLMFont.muted)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(row.status == .eligible ? "EINDEUTIG" : "OFFEN")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundColor(row.status == .eligible ? .green : .orange)
                                    }
                                    Text("Vorher: \(row.beforeOrganizedPath)")
                                        .font(MLMFont.mono)
                                        .foregroundColor(.mlmInkMuted)
                                        .textSelection(.enabled)
                                    if let selected = row.selectedRelativePath {
                                        Text("Danach: \(selected)")
                                            .font(MLMFont.mono)
                                            .foregroundColor(.mlmInkSecondary)
                                            .textSelection(.enabled)
                                    }
                                    Text(row.note)
                                        .font(.caption)
                                        .foregroundColor(.mlmInkMuted)
                                    ForEach(row.candidates) { candidate in
                                        Text(
                                            "• \(candidate.relativePath) " +
                                            "[\(candidate.reasons.map(\.rawValue).joined(separator: ", "))]"
                                        )
                                        .font(.caption.monospaced())
                                        .foregroundColor(.mlmInkMuted)
                                        .textSelection(.enabled)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 360)
                }

                HStack {
                    Button("\(report.eligibleCount) eindeutige Änderungen anwenden") {
                        showPathMigrationConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(report.eligibleCount == 0 || isRunning != nil)

                    if isRunning == "path-apply" {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Button("Letzte Migration zurückrollen…") {
                showPathRollbackConfirmation = true
            }
            .disabled(isRunning != nil)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func maintenanceRow(
        title: String,
        description: String,
        icon: String,
        action: String,
        task: @escaping () async -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(MLMFont.body)
                        Text(description)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                    }
                } icon: {
                    Image(systemName: icon)
                        .frame(width: 20)
                }

                Spacer()

                if isRunning == action {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Run") {
                        progressState = nil
                        Task { await task() }
                    }
                    .disabled(isRunning != nil)
                }
            }
            
            if isRunning == action, let progress = progressState {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(
                        value: min(Double(progress.current), Double(progress.total)),
                        total: Double(max(1, progress.total))
                    )
                    .progressViewStyle(.linear)
                    .tint(.mlmAccent)
                    
                    HStack(spacing: 8) {
                        if !progress.currentTrackTitle.isEmpty {
                            Text("Processing: \(progress.currentTrackArtist) - \(progress.currentTrackTitle)")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                                .lineLimit(1)
                        } else {
                            Text("Processing...")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                        }
                        
                        Spacer()
                        
                        Text("\(progress.current) / \(progress.total) (\(Int(progress.percent))%)")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                    }
                }
                .padding(.top, 4)
                .transition(.opacity.combined(with: .slide))
            }
        }
    }

    // MARK: - Actions

    private func runFingerprint() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "fingerprint"
        resultMessage = nil
        progressState = nil

        let service = FingerprintService()
        guard service.isAvailable else {
            resultMessage = "fpcalc not found. Install via: brew install chromaprint"
            isRunning = nil
            return
        }

        let tracks = (try? await trackRepo.fetchUnfingerprintedTracks()) ?? []
        let libraryRoot = try? await container.configRepository?.getLibraryRoot()
        let (processed, failed, _) = await service.batchFingerprint(
            tracks: tracks,
            repository: analysisRepo,
            libraryRoot: libraryRoot,
            turboMode: turboMode
        ) { state in
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.progressState = state
                }
            }
        }

        resultMessage = "Fingerprint: \(processed) processed, \(failed) failed (Turbo: \(turboMode ? "ON" : "OFF"))"
        progressState = nil
        isRunning = nil
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    private func runReplayGain() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "replaygain"
        resultMessage = nil
        progressState = nil

        let analyzer = ReplayGainAnalyzer()
        guard analyzer.isAvailable else {
            resultMessage = "ffmpeg not found. Install via: brew install ffmpeg"
            isRunning = nil
            return
        }

        let tracks = (try? await trackRepo.fetchUnanalyzedTracks()) ?? []
        let libraryRoot = try? await container.configRepository?.getLibraryRoot()
        let (analyzed, failed, _) = await analyzer.batchAnalyze(
            tracks: tracks,
            repository: analysisRepo,
            trackRepository: trackRepo,
            libraryRoot: libraryRoot,
            turboMode: turboMode
        ) { state in
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.progressState = state
                }
            }
        }

        resultMessage = "ReplayGain: \(analyzed) analyzed, \(failed) failed (Turbo: \(turboMode ? "ON" : "OFF"))"
        progressState = nil
        isRunning = nil
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
     }

    private func runDanceability() async {
        guard let trackRepo = container.trackRepository else { return }

        isRunning = "danceability"
        resultMessage = nil
        progressState = nil

        let analyzer = DanceabilityAnalyzer()
        guard analyzer.isAvailable else {
            resultMessage = "ffmpeg not found. Install via: brew install ffmpeg"
            isRunning = nil
            return
        }

        let tracks = (try? await trackRepo.fetchTracksWithoutDanceability()) ?? []
        let libraryRoot = try? await container.configRepository?.getLibraryRoot()
        let (analyzed, failed, _) = await analyzer.batchAnalyze(
            tracks: tracks,
            trackRepository: trackRepo,
            libraryRoot: libraryRoot,
            turboMode: turboMode
        ) { state in
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.progressState = state
                }
            }
        }

        resultMessage = "Danceability: \(analyzed) analyzed, \(failed) failed (Turbo: \(turboMode ? "ON" : "OFF"))"
        progressState = nil
        isRunning = nil
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    private func runGrooveAnalysis() async {
        guard let trackRepo = container.trackRepository,
              let analyzer = container.grooveBatchAnalyzer else { return }

        isRunning = "groove"
        resultMessage = nil
        progressState = nil

        guard analyzer.isAvailable else {
            resultMessage = "CoreML preprocessor or model not available. Ensure ffmpeg is installed."
            isRunning = nil
            return
        }

        let tracks = (try? await trackRepo.fetchTracksWithoutGrooveEmbedding()) ?? []
        let libraryRoot = try? await container.configRepository?.getLibraryRoot()
        let (analyzed, failed, _) = await analyzer.batchAnalyze(
            tracks: tracks,
            trackRepository: trackRepo,
            libraryRoot: libraryRoot,
            turboMode: turboMode
        ) { state in
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.progressState = state
                }
            }
        }

        resultMessage = "Groove embeddings: \(analyzed) analyzed, \(failed) failed (Turbo: \(turboMode ? "ON" : "OFF"))"
        progressState = nil
        isRunning = nil
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    /// Backfill embedded artwork via ArtworkBackfillService (ffmpeg, no network, D-16).
    private func runArtworkEmbedded() async {
        guard let service = container.artworkBackfillService else {
            AppLogger.shared.warn("MaintenanceView: artworkBackfillService not available",
                                  source: "MaintenanceView")
            resultMessage = "Artwork backfill service not available"
            return
        }

        isRunning = "artwork-embedded"
        resultMessage = nil
        progressState = nil

        await service.refreshMissing(turboMode: turboMode) { state in
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.progressState = state
                }
            }
        }

        resultMessage = "Embedded artwork: refresh complete"
        progressState = nil
        isRunning = nil
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    /// Fetch artwork from MusicBrainz for tracks without embedded art (network, rate-limited, D-16).
    ///
    /// ArtworkService is instantiated inline — it is not exposed on DependencyContainer.
    /// This mirrors the pattern from the former runArtwork() method.
    private func runArtworkMusicBrainz() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "artwork-musicbrainz"
        resultMessage = nil
        progressState = nil

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.mlm.artwork_cache")
        let service = ArtworkService(cacheDir: cacheDir)

        // SCDL-08: use the provider-eligibility query so NULL-path sentinel rows
        // (written by the embedded auto-backfill when ffmpeg found no art) stay
        // eligible for MusicBrainz/provider lookup. The embedded auto-backfill
        // (ArtworkBackfillService) intentionally stays on fetchTracksWithoutArtwork().
        let tracks = (try? await trackRepo.fetchTracksEligibleForProviderArtwork()) ?? []
        let libraryRoot = try? await container.configRepository?.getLibraryRoot()
        let result = await service.batchFetchArtwork(
            tracks: tracks,
            repository: analysisRepo,
            libraryRoot: libraryRoot,
            turboMode: turboMode
        ) { state in
            Task { @MainActor in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    self.progressState = state
                }
            }
        }

        resultMessage = "Artwork: \(result.fetched) fetched, \(result.alreadyCached) cached, \(result.notFound) not found (Turbo: \(turboMode ? "ON" : "OFF"))"
        progressState = nil
        isRunning = nil
        NotificationCenter.default.post(name: .libraryDidImport, object: nil)
    }

    private func makePathMigrationService() async throws -> OrganizedPathMigrationService {
        guard let databaseManager = container.databaseManager,
              let configRepository = container.configRepository,
              let root = try await configRepository.getLibraryRoot(),
              !root.isEmpty else {
            throw OrganizedPathMigrationService.MigrationError.libraryRootMissing
        }
        return OrganizedPathMigrationService(
            database: databaseManager.pool,
            databasePath: databaseManager.databasePath,
            libraryRoot: URL(fileURLWithPath: root, isDirectory: true)
        )
    }

    private func runPathMigrationAudit() async {
        isRunning = "path-audit"
        resultMessage = nil
        do {
            let service = try await makePathMigrationService()
            let report = try await service.audit()
            pathMigrationReport = report
            showPathMigrationReport = report.unresolvedCount > 0
            resultMessage = "Pfad-Audit: \(report.eligibleCount) eindeutige Änderungen bereit; \(report.unresolvedCount) bleiben unangetastet."
        } catch {
            pathMigrationReport = nil
            resultMessage = "Pfad-Audit fehlgeschlagen: \(error.localizedDescription)"
        }
        isRunning = nil
    }

    private func applyPathMigration() async {
        guard let report = pathMigrationReport else { return }
        guard container.downloadViewModel?.isDownloading != true,
              !PerformanceQueueService.shared.isDownloadActive else {
            resultMessage = "Pfad-Migration nicht gestartet: Bitte zuerst alle Downloads beenden."
            return
        }
        isRunning = "path-apply"
        resultMessage = nil
        do {
            let service = try await makePathMigrationService()
            let result = try await service.apply(report)
            pathMigrationReport = nil
            showPathMigrationReport = false
            resultMessage = "Pfad-Migration: \(result.updatedCount) organized_path-Werte aktualisiert. Manifest: \(result.manifestURL.path) · Backup: \(result.backupURL.path)"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
        } catch {
            resultMessage = "Pfad-Migration abgebrochen: \(error.localizedDescription)"
        }
        isRunning = nil
    }

    private func rollbackPathMigration() async {
        isRunning = "path-rollback"
        resultMessage = nil
        do {
            let service = try await makePathMigrationService()
            let result = try await service.rollbackMostRecent()
            pathMigrationReport = nil
            showPathMigrationReport = false
            let warning = result.manifestFinalizationWarning.map { " Warnung: \($0)" } ?? ""
            resultMessage = "Rollback: \(result.restoredCount) organized_path-Werte wiederhergestellt. Manifest: \(result.manifestURL.path) · Backup: \(result.rollbackBackupURL.path)\(warning)"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
        } catch {
            resultMessage = "Rollback abgebrochen: \(error.localizedDescription)"
        }
        isRunning = nil
    }

    private func runRescanMetadata() async {
        guard let trackRepo = container.trackRepository,
              let configRepo = container.configRepository else { return }

        isRunning = "rescan"
        resultMessage = nil
        progressState = nil

        let service = LibraryRepairService(
            trackRepository: trackRepo,
            configRepository: configRepo
        )

        do {
            let (succeeded, failed) = try await service.rescanMetadata(
                turboMode: turboMode
            ) { state in
                Task { @MainActor in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        self.progressState = state
                    }
                }
            }
            resultMessage = "Metadata Rescan abgeschlossen: \(succeeded) aktualisiert · \(failed) fehlgeschlagen"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
        } catch {
            resultMessage = "Metadata Rescan fehlgeschlagen: \(error.localizedDescription)"
        }

        progressState = nil
        isRunning = nil
    }

    private func runDeepScan() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "deepscan"
        resultMessage = nil
        progressState = nil

        let service = DeepScanService(
            trackRepository: trackRepo,
            analysisRepository: analysisRepo
        )

        do {
            let result = try await service.deepScan(turboMode: turboMode) { state in
                Task { @MainActor in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        self.progressState = state
                    }
                }
            }
            resultMessage = "Deep scan: \(result.pairsCompared) compared, \(result.duplicatesFound) dups, \(result.conflictsFlagged) conflicts (Turbo: \(turboMode ? "ON" : "OFF"))"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            NotificationCenter.default.post(name: .reviewQueueDidChange, object: nil)
        } catch {
            resultMessage = "Deep scan failed: \(error.localizedDescription)"
        }

        progressState = nil
        isRunning = nil
    }

    private func runCreateLikedPlaylist() async {
        guard let sourceRepo = container.sourceRepository,
              let playlistRepo = container.playlistRepository else { return }

        isRunning = "create-liked-playlist"
        resultMessage = nil

        do {
            let sourceName = selectedSource
            // Ensure the source exists in the DB
            let source = try await sourceRepo.upsert(name: sourceName, userId: "default")

            // Re-create / link the liked playlist
            let playlistName: String
            switch sourceName {
            case "soundcloud":
                playlistName = "Liked from SoundCloud"
            default:
                playlistName = "Liked from \(sourceName.capitalized)"
            }

            let playlist = try await playlistRepo.findOrCreateLikedPlaylist(
                name: playlistName,
                sourceId: source.id!,
                externalId: nil,
                legacyNameMatches: [sourceName, "liked"]
            )

            // Post notification that playlists changed
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil
            )

            resultMessage = "Successfully created or linked playlist '\(playlist.name)'"
        } catch {
            resultMessage = "Failed to create/link playlist: \(error.localizedDescription)"
        }

        isRunning = nil
    }

    private func chooseNewCacheFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Speicherort für Transcode-Cache wählen"
        panel.prompt = "Ordner wählen"
        
        if panel.runModal() == .OK, let url = panel.url {
            container.relocateTranscodeCache(to: url.path)
        }
    }
}
