import AVFoundation
import SwiftUI

/// Info ▸ Audio (P-INSPECTOR-AUDIO): this track's waveform (P-INSPECTOR-WAVEFORM — the
/// *inspected* track, not the player's), the analysis values with `Analyze`, and the five most
/// similar tracks (P-INSPECTOR-SIMILAR, merged). Several tracks: a summary (P-INSPECTOR.N09).
struct InspectorAudioTab: View {
    let tracks: [Track]

    var body: some View {
        Form {
            if tracks.count == 1, let track = tracks.first {
                InspectorSingleAudio(track: track)
            } else {
                InspectorMultipleAudio(tracks: tracks)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - One track

private struct InspectorSingleAudio: View {
    let track: Track

    @Environment(\.container) private var container
    @Environment(\.openSettings) private var openSettings
    @State private var fileURL: URL?
    @State private var hasSimilarityAnalysis = false
    @State private var similar: [Track] = []
    @State private var loadedTrackID: Int64?

    private var analysis: InspectorAnalysis { InspectorAnalysis.shared }

    var body: some View {
        let status = InspectorFileStatus.make(
            track: track,
            availability: track.availability(),
            offlineVolume: InspectorDrive.offlineVolume(container),
            libraryVolumeName: InspectorDrive.libraryVolumeName(container),
            sourceName: nil
        )
        Section {
            InspectorWaveform(track: track, fileURL: status.isFileReachable ? fileURL : nil, unavailableReason: waveformReason(status))
        }

        Section("Analysis") {
            if isAnalysed {
                LabeledContent("BPM") {
                    Text(track.bpm.flatMap { $0 > 0 ? String($0) : nil } ?? "—").monospacedDigit()
                }
                LabeledContent("Energy") { TrackMeter(level: track.energyBucket.flatMap { (1...5).contains($0) ? $0 : nil }) }
                LabeledContent("Danceability") { TrackMeter(level: track.danceability.map(DanceabilitySteps.scoreToLevel)) }
                LabeledContent("Loudness") {
                    Text(track.lufsI.map { "\($0.formatted(.number.precision(.fractionLength(1)))) LUFS" } ?? "—")
                        .monospacedDigit()
                        .help("Integrated loudness. Closer to 0 is louder.")
                }
                if track.lufsRange != nil || track.truePeak != nil {
                    DisclosureGroup("More") {
                        LabeledContent("Loudness range") {
                            Text(track.lufsRange.map { "\($0.formatted(.number.precision(.fractionLength(1)))) LU" } ?? "—").monospacedDigit()
                        }
                        LabeledContent("True peak") {
                            Text(track.truePeak.map { "\($0.formatted(.number.precision(.fractionLength(1)))) dBTP" } ?? "—").monospacedDigit()
                        }
                    }
                }
            } else {
                Text("Not analysed yet. Analysis measures tempo, energy, danceability and loudness and makes “Similar” work.")
                    .foregroundStyle(.secondary)
            }
            analyzeRow(status)
        }

        Section("Similar") {
            if !hasSimilarityAnalysis {
                Text("Analyze this track to find similar ones in your library.")
                    .foregroundStyle(.secondary)
            } else if similar.isEmpty {
                Text("No similar tracks in your library yet.")
                    .foregroundStyle(.secondary)
            } else {
                // Plain rows: no delete, no download here (PP-INSPECTOR-21). `Show All` → the
                // Similar view arrives with W3-DISC (DEC-030); until then it is left out.
                ForEach(similar, id: \.rowID) { match in
                    InspectorSimilarRow(track: match)
                }
            }
        }
        .task(id: TaskKey(trackID: track.id, analysing: analysis.isRunning(track.id ?? -1))) {
            await load()
        }
    }

    private struct TaskKey: Hashable {
        let trackID: Int64?
        let analysing: Bool
    }

    private var isAnalysed: Bool {
        track.bpm != nil || track.energyBucket != nil || track.danceability != nil || track.lufsI != nil
    }

    private func waveformReason(_ status: InspectorFileStatus) -> String? {
        if status.isFileReachable { return nil }
        if let offline = InspectorDrive.offlineVolume(container), track.availability().hasFile {
            return "The waveform needs the file. “\(offline.name)” is not connected."
        }
        switch track.availability() {
        case .fileMissing: return "The waveform needs the file. This file is missing."
        default: return "Download the track to see its waveform."
        }
    }

    @ViewBuilder
    private func analyzeRow(_ status: InspectorFileStatus) -> some View {
        let id = track.id ?? -1
        if let phase = analysis.phases[id] {
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text(phase).foregroundStyle(.secondary)
            }
        } else {
            if let problem = analysis.problems[id] {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    InspectorIssueLine(message: problem.text)
                    if problem == .toolMissing {
                        Text("Analysis needs ffmpeg. MLM looks in /opt/homebrew/bin, /usr/local/bin and ~/.local/bin.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Open Settings ▸ Sources") { openSettings(tab: .sources) }
                    }
                }
            }
            let reason = analyzeDisabledReason(status)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Button(isAnalysed ? "Analyze Again" : "Analyze") {
                    if let fileURL { analysis.analyze(track, fileURL: fileURL, container: container) }
                }
                .disabled(reason != nil)
                .help(reason ?? "Measures tempo, energy, danceability and loudness")
                if let reason {
                    Text(reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func analyzeDisabledReason(_ status: InspectorFileStatus) -> String? {
        if let offline = InspectorDrive.offlineVolume(container), track.availability().hasFile {
            return "Can’t analyze — “\(offline.name)” is not connected."
        }
        switch track.availability() {
        case .fileMissing: return "Can’t analyze — the file is missing."
        case .local: return fileURL == nil ? "Can’t analyze — the file isn’t where MLM expects it." : nil
        default: return "Download the track to analyze it."
        }
    }

    private func load() async {
        let trackChanged = loadedTrackID != track.id
        loadedTrackID = track.id
        if trackChanged {
            fileURL = nil
            similar = []
        }
        guard let id = track.id else { return }
        if track.availability() == .local, InspectorDrive.offlineVolume(container) == nil {
            fileURL = await TrackFileLocator.localURL(for: track, container: container)
        }
        guard let pool = container.databaseManager?.pool else { return }
        hasSimilarityAnalysis = (try? await InspectorQueries(database: pool).hasSimilarityAnalysis(trackID: id)) ?? false
        if hasSimilarityAnalysis, let repository = container.trackRepository {
            similar = ((try? await repository.fetchSimilarTracks(seedTrackId: id, limit: 5)) ?? []).map(\.track)
        } else {
            similar = []
        }
    }
}

/// One similar track: cover, title, artist · BPM. Ranked; no percentage (P-INSPECTOR-SIMILAR).
private struct InspectorSimilarRow: View {
    let track: Track

    var body: some View {
        HStack(spacing: Spacing.s) {
            Group {
                if track.availability().hasFile, let id = track.id {
                    TrackCoverView(trackId: id, size: .small, cornerRadius: 4)
                } else {
                    TrackPlaceholderArtwork()
                }
            }
            .frame(width: 24, height: 24)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(track.title).lineLimit(1)
                Text([TrackMetadataPresentation.artistDisplay(track.artist), track.bpm.flatMap { $0 > 0 ? "\($0) BPM" : nil }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Several tracks

private struct InspectorMultipleAudio: View {
    let tracks: [Track]

    var body: some View {
        let analysed = tracks.filter { $0.bpm != nil || $0.energyBucket != nil || $0.lufsI != nil }
        let bpms = tracks.compactMap { $0.bpm.flatMap { $0 > 0 ? $0 : nil } }
        let energies = Set(tracks.compactMap(\.energyBucket))
        Section("Analysis") {
            LabeledContent("Analysed") {
                Text("\(analysed.count.formatted(.number)) of \(tracks.count.formatted(.number))").monospacedDigit()
            }
            LabeledContent("BPM") {
                Text(bpms.isEmpty ? "—" : (bpms.min() == bpms.max() ? "\(bpms[0])" : "\(bpms.min() ?? 0)–\(bpms.max() ?? 0)"))
                    .monospacedDigit()
            }
            LabeledContent("Energy") {
                if energies.count > 1 {
                    Text("Mixed").foregroundStyle(.secondary)
                } else {
                    TrackMeter(level: energies.first)
                }
            }
            // W3-ACT: `Analyze ‹n› Tracks` as one Activity operation (P-INSPECTOR.N09) arrives with
            // the operation registry; Info shows no control until then.
        }
    }
}

// MARK: - Drive

/// The library's disk, read once per render from the window-level drive state (DEC-014).
@MainActor
enum InspectorDrive {
    /// Name and `/Volumes/…` path while the library's disk is not connected.
    static func offlineVolume(_ container: DependencyContainer) -> (name: String, path: String)? {
        let state = LibraryDriveState.current(container)
        guard state.isOffline, let name = state.volumeName, let path = container.mountObserver?.libraryVolumePath else { return nil }
        return (name, path)
    }

    /// `Lexxar` when the library folder is on a connected external disk; nil on this Mac.
    static func libraryVolumeName(_ container: DependencyContainer) -> String? {
        LibraryDriveState.current(container).volumeName
    }
}

// MARK: - Waveform (P-INSPECTOR-WAVEFORM)

/// The inspected track's waveform: cached peaks (the player's cache) or extracted once in the
/// background. The playhead shows only when this is the playing track; a click seeks it then.
/// Without a reachable file the reason is said in words (P-INSPECTOR-WAVEFORM.N01).
struct InspectorWaveform: View {
    let track: Track
    let fileURL: URL?
    let unavailableReason: String?

    @Environment(\.container) private var container
    @State private var peaks: [Float] = []
    @State private var isLoading = false
    @AppStorage("inspector.waveformZoom") private var zoom: Double = 1

    static let height: CGFloat = 64

    var body: some View {
        Group {
            if let unavailableReason {
                Text(unavailableReason)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, minHeight: Self.height)
            } else {
                InspectorPlayingWaveform(
                    track: track,
                    peaks: peaks,
                    isLoading: isLoading,
                    zoom: Binding(get: { CGFloat(zoom) }, set: { zoom = Double($0) })
                )
                .frame(height: Self.height)
            }
        }
        .task(id: fileURL) { await load() }
    }

    private func load() async {
        peaks = []
        guard let fileURL, let id = track.id else { return }
        isLoading = true
        defer { isLoading = false }
        let cacheDirectory = container.activeLibrary?.namespacedCacheDirectory(in: ActiveLibrary.defaultWaveformCacheRoot)
            ?? ActiveLibrary.defaultWaveformCacheRoot
        // The decode stops when the selection moves on (`.task(id:)` cancels this task).
        let decode = Task.detached(priority: .utility) {
            InspectorWaveformPeaks.load(fileURL: fileURL, trackID: id, cacheDirectory: cacheDirectory)
        }
        let loaded = await withTaskCancellationHandler { await decode.value } onCancel: { decode.cancel() }
        guard !Task.isCancelled else { return }
        peaks = loaded
    }
}

/// A leaf that reads playback progress, so ticks re-render only the waveform.
private struct InspectorPlayingWaveform: View {
    let track: Track
    let peaks: [Float]
    let isLoading: Bool
    @Binding var zoom: CGFloat

    @Environment(\.container) private var container

    var body: some View {
        let playback = container.playbackViewModel
        let isCurrent = playback?.currentTrack?.id != nil && playback?.currentTrack?.id == track.id
        WaveformView(
            data: peaks,
            progress: isCurrent ? (playback?.progress ?? 0) : 0,
            isLoading: isLoading,
            isScrollable: (track.duration ?? 0) >= 420,
            zoomLevel: $zoom,
            exponent: .constant(1),
            gain: .constant(1),
            waveformHeight: .constant(InspectorWaveform.height),
            needleTimeLabel: nil,
            onSeek: { fraction in
                // W2-C: a click on a track that isn't playing previews from there (DEC-010).
                if isCurrent { playback?.seekToProgress(fraction) }
            }
        )
        .accessibilityLabel("Waveform")
    }
}

/// Peaks for the waveform, shared with the player's per-library cache (`‹id›.bin`, Float32).
enum InspectorWaveformPeaks {
    static func load(fileURL: URL, trackID: Int64, cacheDirectory: URL) -> [Float] {
        let cacheURL = PlaybackViewModel.waveformCacheURL(in: cacheDirectory, trackID: trackID, fileURL: fileURL)
        if let data = try? Data(contentsOf: cacheURL), data.count >= MemoryLayout<Float>.size {
            var peaks = [Float](repeating: 0, count: data.count / MemoryLayout<Float>.size)
            _ = peaks.withUnsafeMutableBytes { data.copyBytes(to: $0) }
            return peaks
        }
        guard let file = try? AVAudioFile(forReading: fileURL), file.length > 0 else { return [] }
        let seconds = Double(file.length) / file.processingFormat.sampleRate
        let binCount = WaveformHelpers.adaptiveBinCount(duration: seconds)
        let chunkFrames: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else { return [] }
        let totalFrames = Int(file.length)
        let framesPerBin = max(totalFrames / binCount, 1)
        var peaks = [Float](repeating: 0, count: binCount)
        var frameIndex = 0
        while frameIndex < totalFrames {
            // Cancelled (another track selected): stop, and cache nothing half-read.
            if Task.isCancelled { return [] }
            guard (try? file.read(into: buffer, frameCount: chunkFrames)) != nil else { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let samples = buffer.floatChannelData?[0] else { break }
            for offset in 0..<count {
                let bin = min((frameIndex + offset) / framesPerBin, binCount - 1)
                let value = abs(samples[offset])
                if value > peaks[bin] { peaks[bin] = value }
            }
            frameIndex += count
        }
        if let maximum = peaks.max(), maximum > 0 {
            for index in peaks.indices { peaks[index] /= maximum }
        }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? peaks.withUnsafeBytes { Data($0) }.write(to: cacheURL)
        return peaks
    }
}
