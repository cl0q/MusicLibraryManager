import Foundation
import Observation

/// `Analyze` on Info ▸ Audio (P-INSPECTOR-AUDIO.E02): one button for all values, reusing the
/// existing single-track analyzers in order — loudness (energy), tempo and danceability, then
/// the similarity analysis. Runs keep going when the selection moves on and are shown again
/// when the track comes back (keyed by track id). Failures are said in words with the fix
/// (P-INSPECTOR-AUDIO.N02), never only in the log.
///
/// A typed BPM is kept: the analysis fills BPM only when the track has none
/// (P-INSPECTOR.N04; the old Danceability run overwrote it silently).
@MainActor
@Observable
final class InspectorAnalysis {
    static let shared = InspectorAnalysis()

    enum Problem: Error, Equatable, Sendable {
        /// ffmpeg isn't installed (Settings ▸ Sources shows the tools).
        case toolMissing
        /// The analysis failed for this file.
        case failed(String)

        var text: String {
            switch self {
            case .toolMissing: "Can’t analyze — ffmpeg not found"
            case .failed(let cause): "Couldn’t analyze this track — \(cause)"
            }
        }
    }

    /// Running analyses: track id → phase text (`Analyzing… loudness`).
    private(set) var phases: [Int64: String] = [:]
    /// The last failure per track (cleared by the next run).
    private(set) var problems: [Int64: Problem] = [:]

    func isRunning(_ trackID: Int64) -> Bool { phases[trackID] != nil }

    /// Analyze `track`, whose file is at `fileURL`.
    func analyze(_ track: Track, fileURL: URL, container: DependencyContainer = .shared) {
        guard let id = track.id, phases[id] == nil else { return }
        problems[id] = nil
        // W3-ACT: register this as an Activity operation (`Analyze “‹title›”`, cancellable
        // between phases, result persisted) and echo its phase here; until then the phase
        // below is the only progress.
        phases[id] = "Analyzing… loudness"
        Task {
            defer { phases[id] = nil }
            do {
                try await run(track, id: id, path: fileURL.path, container: container)
            } catch let problem as Problem {
                problems[id] = problem
            } catch {
                AppLogger.shared.error("Analysis of track \(id) failed: \(error)", source: "Analysis")
                problems[id] = .failed("the details are in the log")
            }
            TrackTagEdit.postTracksChanged([id])
        }
    }

    private func run(_ track: Track, id: Int64, path: String, container: DependencyContainer) async throws {
        guard let tracks = container.trackRepository else { return }
        let loudness = ReplayGainAnalyzer()
        guard loudness.isAvailable else { throw Problem.toolMissing }
        guard let gain = try await loudness.analyzeTrack(path: path) else {
            throw Problem.failed("ffmpeg couldn’t measure the loudness")
        }
        try await container.analysisRepository?.saveReplayGain(ReplayGain(
            trackId: id, trackGain: gain.trackGain, trackPeak: gain.trackPeak,
            albumGain: nil, albumPeak: nil, analyzedAt: ISO8601DateFormatter().string(from: Date())
        ))
        try await tracks.updateEnergyBucket(
            trackId: id, energyBucket: EnergyBucketer.bucket(lufs: gain.loudness),
            lufsI: gain.loudness, lufsRange: gain.lufsRange, truePeak: gain.trackPeak
        )

        phases[id] = "Analyzing… tempo and danceability"
        let dance = DanceabilityAnalyzer()
        guard dance.isAvailable else { throw Problem.toolMissing }
        if let result = try await dance.analyzeTrack(path: path) {
            try await tracks.updateDanceability(trackId: id, danceability: result.danceability, bpm: nil)
            // A BPM typed while this ran (or before) wins: filled only if still empty at write
            // time (S5). Analysis results never queue a file write.
            if let bpm = result.bpm, let pool = container.databaseManager?.pool {
                try await TrackTagRepository(database: pool).fillBPMIfEmpty(trackID: id, bpm: bpm)
            }
        }

        guard let duration = track.duration, duration > 0, let embedding = container.audioEmbeddingService,
              embedding.isAvailable else { return }
        phases[id] = "Analyzing… similarity"
        let drop = try await embedding.analyzeTrackDrop(at: path, totalDuration: Double(duration))
        let category = MixClassifier.classify(
            bpm: Double(track.bpm ?? 126), avgLufs: gain.loudness, lufsRange: gain.lufsRange,
            artist: track.artist, title: track.title
        )
        try await tracks.saveTrackEmbedding(
            trackId: id, embedding: drop.embedding, dropOffset: drop.offset,
            mixCategory: duration > 600 ? category.rawValue : nil
        )
    }
}
