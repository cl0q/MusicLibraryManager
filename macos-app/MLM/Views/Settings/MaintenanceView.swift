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

    var body: some View {
        Form {
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
                    title: "Fetch Artwork",
                    description: "Download missing album art from MusicBrainz",
                    icon: "photo",
                    action: "artwork"
                ) {
                    await runArtwork()
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
                    Task { await task() }
                }
                .disabled(isRunning != nil)
            }
        }
    }

    // MARK: - Actions

    private func runFingerprint() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "fingerprint"
        resultMessage = nil

        let service = FingerprintService()
        guard service.isAvailable else {
            resultMessage = "fpcalc not found. Install via: brew install chromaprint"
            isRunning = nil
            return
        }

        let tracks = (try? await trackRepo.fetchUnfingerprintedTracks()) ?? []
        let result = await service.batchFingerprint(
            tracks: tracks,
            repository: analysisRepo
        )

        resultMessage = "Fingerprint: \(result.processed) processed, \(result.failed) failed"
        isRunning = nil
    }

    private func runReplayGain() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "replaygain"
        resultMessage = nil

        let analyzer = ReplayGainAnalyzer()
        guard analyzer.isAvailable else {
            resultMessage = "ffmpeg not found. Install via: brew install ffmpeg"
            isRunning = nil
            return
        }

        let tracks = (try? await trackRepo.fetchUnanalyzedTracks()) ?? []
        let result = await analyzer.batchAnalyze(
            tracks: tracks,
            repository: analysisRepo,
            trackRepository: trackRepo
        )

        resultMessage = "ReplayGain: \(result.analyzed) analyzed, \(result.failed) failed"
        isRunning = nil
    }

    private func runArtwork() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "artwork"
        resultMessage = nil

        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.mlm.artwork_cache")
        let service = ArtworkService(cacheDir: cacheDir)

        let tracks = (try? await trackRepo.fetchTracksWithoutArtwork()) ?? []
        let result = await service.batchFetchArtwork(
            tracks: tracks,
            repository: analysisRepo
        )

        resultMessage = "Artwork: \(result.fetched) fetched, \(result.alreadyCached) cached, \(result.notFound) not found"
        isRunning = nil
    }

    private func runDeepScan() async {
        guard let trackRepo = container.trackRepository,
              let analysisRepo = container.analysisRepository else { return }

        isRunning = "deepscan"
        resultMessage = nil

        let service = DeepScanService(
            trackRepository: trackRepo,
            analysisRepository: analysisRepo
        )

        do {
            let result = try await service.deepScan()
            resultMessage = "Deep scan: \(result.pairsCompared) compared, \(result.duplicatesFound) dups, \(result.conflictsFlagged) conflicts"
        } catch {
            resultMessage = "Deep scan failed: \(error.localizedDescription)"
        }

        isRunning = nil
    }
}
