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
                    // TODO: Implement via ImportService
                    resultMessage = "Metadata rescan not yet implemented"
                }

                maintenanceRow(
                    title: "Stale Pfade reparieren",
                    description: "Findet verwaiste Pfade im organized_path, repariert sie aus original_path oder sucht nach umbenannten Ordnern auf der Festplatte",
                    icon: "wrench.and.screwdriver",
                    action: "repair-paths"
                ) {
                    await runRepairStalePaths()
                }
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

        let tracks = (try? await trackRepo.fetchTracksWithoutArtwork()) ?? []
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

    /// Repair tracks whose organized_path no longer resolves to a file
    /// on disk (Task 4 — stale path remediation).
    private func runRepairStalePaths() async {
        guard let trackRepo = container.trackRepository,
              let configRepo = container.configRepository else { return }

        isRunning = "repair-paths"
        resultMessage = nil

        let service = LibraryRepairService(
            trackRepository: trackRepo,
            configRepository: configRepo
        )

        do {
            let r = try await service.repairStaleOrganizedPaths()
            resultMessage = "Stale Pfade: \(r.inspected) geprüft · \(r.alreadyValid) intakt · \(r.repaired) repariert · \(r.demotedToRemote) → remote · \(r.unrepairable) nicht reparierbar"
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
        } catch {
            resultMessage = "Repair fehlgeschlagen: \(error.localizedDescription)"
        }

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
}
