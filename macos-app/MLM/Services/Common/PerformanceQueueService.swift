import Foundation
import Observation
import os
import GRDB

/// Type of job handled by the PerformanceQueueService.
enum PerformanceJobType: Sendable, Codable, Equatable {
    case download
    case analysis
}

/// A job in the PerformanceQueueService.
struct PerformanceJob: Sendable, Identifiable, Equatable {
    let id: UUID
    let type: PerformanceJobType
    let track: Track
    
    init(id: UUID = UUID(), type: PerformanceJobType, track: Track) {
        self.id = id
        self.type = type
        self.track = track
    }
}

/// Thread-safe concurrent priority queue service that coordinates downloads and track analyses.
///
/// Ensures high-priority download jobs run immediately and analysis jobs (loudness, fingerprint,
/// and CoreML groove embedding) cooperative yield CPU/network resource when downloads are active.
@Observable
@MainActor
final class PerformanceQueueService: Sendable {
    
    /// Global shared instance of the queue service.
    static let shared = PerformanceQueueService()
    
    // MARK: - UI Observable State
    
    /// Count of pending high-priority download jobs.
    private(set) var pendingDownloadsCount: Int = 0
    
    /// Count of pending low-priority analysis jobs.
    private(set) var pendingAnalysesCount: Int = 0
    
    /// User-facing description of the active job, if any.
    private(set) var activeJobDescription: String? = nil
    
    /// Whether any download (internal or external) is currently active.
    private(set) var isDownloadActive: Bool = false
    
    // MARK: - Core Execution Actor
    
    private let actor: PerformanceQueueActor
    
    private init() {
        self.actor = PerformanceQueueActor()
        
        // Connect the actor to report state updates back to this MainActor class
        Task {
            await actor.setService(self)
        }
    }
    
    // MARK: - Public API
    
    /// Enqueue a download job (high priority).
    /// Download jobs jump to the front of the queue, right before analysis jobs.
    nonisolated func enqueueDownload(track: Track) {
        Task {
            await actor.enqueue(track: track, type: .download)
        }
    }
    
    /// Enqueue a download by creating a remote track entry and then enqueuing it in the priority queue.
    nonisolated func enqueueDownload(
        title: String,
        artist: String,
        source: String,
        streamURL: String?,
        externalId: String
    ) {
        Task {
            guard let trackRepository = DependencyContainer.shared.trackRepository else { return }
            
            let originalPath = streamURL ?? "soundcloud://\(externalId)"
            let track = Track(
                artist: artist,
                albumArtist: artist,
                album: "Downloads",
                title: title,
                format: source.lowercased(),
                originalPath: originalPath
            )
            
            do {
                let inserted = try await trackRepository.insert(track)
                await actor.enqueue(track: inserted, type: .download)
            } catch {
                AppLogger.shared.log(
                    "PerformanceQueue: Failed to insert remote track: \(error.localizedDescription)",
                    level: .error,
                    source: "PerformanceQueue"
                )
            }
        }
    }
    
    /// Enqueue an analysis job (low priority).
    /// Analysis jobs are appended at the end of the queue.
    func enqueueAnalysis(track: Track) {
        Task {
            await actor.enqueue(track: track, type: .analysis)
        }
    }
    
    /// Notify the queue service whether a download is running externally (e.g. via DownloadViewModel).
    /// While active, no new analysis jobs start, and running analyses cooperatively suspend.
    func setExternalDownloadActive(_ active: Bool) {
        Task {
            await actor.setExternalDownloadActive(active)
        }
    }
    
    /// Clear the entire pending queue.
    func clearQueue() {
        Task {
            await actor.clearQueue()
        }
    }
    
    // MARK: - MainActor State Synchronization
    
    @MainActor
    fileprivate func updateState(
        pendingDownloads: Int,
        pendingAnalyses: Int,
        activeJobDesc: String?,
        downloadActive: Bool
    ) {
        self.pendingDownloadsCount = pendingDownloads
        self.pendingAnalysesCount = pendingAnalyses
        self.activeJobDescription = activeJobDesc
        self.isDownloadActive = downloadActive
    }
}

// MARK: - PerformanceQueueActor

/// Background actor responsible for safe, concurrent, serialized execution of queue jobs.
actor PerformanceQueueActor {
    private weak var service: PerformanceQueueService?
    
    private var queue: [PerformanceJob] = []
    private var activeJob: PerformanceJob? = nil
    private var isExternalDownloadActive = false
    private var activeDownloadsCount = 0
    private var isWorkerRunning = false
    
    // Shared analyzers
    private let replayGainAnalyzer = ReplayGainAnalyzer()
    private let fingerprintService = FingerprintService()
    
    func setService(_ service: PerformanceQueueService) {
        self.service = service
    }
    
    func setExternalDownloadActive(_ active: Bool) async {
        self.isExternalDownloadActive = active
        await updateServiceState()
        if !active {
            triggerWorker()
        }
    }
    
    func enqueue(track: Track, type: PerformanceJobType) async {
        let job = PerformanceJob(type: type, track: track)
        
        if type == .download {
            // Jump to the front of the queue, after existing download jobs, but before analysis jobs
            if let firstAnalysisIndex = queue.firstIndex(where: { $0.type == .analysis }) {
                queue.insert(job, at: firstAnalysisIndex)
            } else {
                queue.append(job)
            }
        } else {
            // Prevent redundant duplicates in the queue for analysis jobs
            if queue.contains(where: { $0.track.id == track.id && $0.type == .analysis }) {
                return
            }
            queue.append(job)
        }
        
        await updateServiceState()
        triggerWorker()
    }
    
    func clearQueue() async {
        queue.removeAll()
        await updateServiceState()
    }
    
    // MARK: - Worker Engine
    
    private func triggerWorker() {
        guard !isWorkerRunning else { return }
        isWorkerRunning = true
        Task {
            await runWorkerLoop()
        }
    }
    
    private func runWorkerLoop() async {
        while true {
            guard let nextJob = await getNextJob() else {
                break
            }
            
            activeJob = nextJob
            if nextJob.type == .download {
                activeDownloadsCount += 1
            }
            await updateServiceState()
            
            do {
                try await executeJob(nextJob)
            } catch {
                AppLogger.shared.log(
                    "PerformanceQueue: Job \(nextJob.id) failed with error: \(error.localizedDescription)",
                    level: .error,
                    source: "PerformanceQueue"
                )
            }
            
            if nextJob.type == .download {
                activeDownloadsCount = max(0, activeDownloadsCount - 1)
            }
            activeJob = nil
            await updateServiceState()
        }
        
        isWorkerRunning = false
    }
    
    private func getNextJob() async -> PerformanceJob? {
        let dlActive = isExternalDownloadActive || activeDownloadsCount > 0
        
        if dlActive {
            // If download is active, only return a high-priority download job (never start analysis)
            if let index = queue.firstIndex(where: { $0.type == .download }) {
                return queue.remove(at: index)
            }
            return nil
        } else {
            // Otherwise, pull from the front of the queue
            if !queue.isEmpty {
                return queue.removeFirst()
            }
            return nil
        }
    }
    
    private var isDownloadActive: Bool {
        isExternalDownloadActive || activeDownloadsCount > 0 || queue.contains(where: { $0.type == .download })
    }
    
    private func updateServiceState() async {
        let downloads = queue.filter({ $0.type == .download }).count
        let analyses = queue.filter({ $0.type == .analysis }).count
        
        let activeDesc: String?
        if let activeJob = activeJob {
            let typeStr = activeJob.type == .download ? "Downloading" : "Analyzing"
            activeDesc = "\(typeStr): \(activeJob.track.artist) - \(activeJob.track.title)"
        } else {
            activeDesc = nil
        }
        
        let dlActive = isDownloadActive
        
        await service?.updateState(
            pendingDownloads: downloads,
            pendingAnalyses: analyses,
            activeJobDesc: activeDesc,
            downloadActive: dlActive
        )
    }
    
    // MARK: - Job Execution
    
    private func executeJob(_ job: PerformanceJob) async throws {
        let track = job.track
        guard let trackId = track.id else { return }
        
        guard let trackRepository = DependencyContainer.shared.trackRepository,
              let analysisRepository = DependencyContainer.shared.analysisRepository,
              let configRepository = DependencyContainer.shared.configRepository else {
            AppLogger.shared.log("PerformanceQueue: Repositories not yet ready. Postponing job.", level: .warning, source: "PerformanceQueue")
            return
        }
        
        switch job.type {
        case .download:
            AppLogger.shared.info("PerformanceQueue: Running high-priority download for \(track.artist) - \(track.title)", source: "PerformanceQueue")
            guard let downloadVM = DependencyContainer.shared.downloadViewModel else {
                AppLogger.shared.log("PerformanceQueue: DownloadViewModel not ready.", level: .warning, source: "PerformanceQueue")
                return
            }
            // Execute the single download via DownloadViewModel
            await downloadVM.downloadTracks([track])
            
        case .analysis:
            AppLogger.shared.info("PerformanceQueue: Running low-priority analysis pipeline for \(track.artist) - \(track.title)", source: "PerformanceQueue")
            
            // Cooperatively check if a download is active and suspend if needed
            try await checkSuspensionPoints()
            
            // 1. Resolve file path
            let libraryRoot = try? await configRepository.getLibraryRoot()
            let resolvedPath: String?
            
            if let organized = track.organizedPath {
                let path: String
                if let root = libraryRoot, !root.isEmpty {
                    path = URL(fileURLWithPath: root).appendingPathComponent(organized).path
                } else {
                    path = organized
                }
                if FileManager.default.fileExists(atPath: path) {
                    resolvedPath = path
                } else if FileManager.default.fileExists(atPath: track.originalPath) {
                    resolvedPath = track.originalPath
                } else {
                    resolvedPath = nil
                }
            } else {
                resolvedPath = track.isLocal && FileManager.default.fileExists(atPath: track.originalPath) ? track.originalPath : nil
            }
            
            guard let filePath = resolvedPath else {
                AppLogger.shared.log("PerformanceQueue: Analysis skipped for \(track.title) — file not found.", level: .warning, source: "PerformanceQueue")
                return
            }
            
            // --- Step A: ReplayGain Analysis ---
            if replayGainAnalyzer.isAvailable {
                do {
                    AppLogger.shared.debug("PerformanceQueue [A/3]: Calculating ReplayGain LUFS for \(track.title)", source: "PerformanceQueue")
                    if let gain = try await replayGainAnalyzer.analyzeTrack(path: filePath) {
                        let rg = ReplayGain(
                            trackId: trackId,
                            trackGain: gain.trackGain,
                            trackPeak: gain.trackPeak,
                            albumGain: nil,
                            albumPeak: nil,
                            analyzedAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try await analysisRepository.saveReplayGain(rg)
                        
                        let bucket = EnergyBucketer.bucket(lufs: gain.loudness)
                        try await trackRepository.updateEnergyBucket(
                            trackId: trackId,
                            energyBucket: bucket,
                            lufsI: gain.loudness,
                            lufsRange: gain.lufsRange,
                            truePeak: gain.trackPeak
                        )
                        AppLogger.shared.debug("PerformanceQueue [A/3]: Saved ReplayGain for \(track.title) (LUFS: \(gain.loudness))", source: "PerformanceQueue")
                    }
                } catch {
                    AppLogger.shared.log("PerformanceQueue [A/3]: ReplayGain failed for \(track.title) — \(error.localizedDescription)", level: .warning, source: "PerformanceQueue")
                }
            }
            
            // Check suspension points before the next heavy step
            try await checkSuspensionPoints()
            
            // --- Step B: Chromaprint Fingerprinting ---
            if fingerprintService.isAvailable {
                do {
                    AppLogger.shared.debug("PerformanceQueue [B/3]: Generating Chromaprint for \(track.title)", source: "PerformanceQueue")
                    if let result = try await fingerprintService.generateFingerprint(path: filePath) {
                        let fingerprint = Fingerprint(
                            trackId: trackId,
                            fingerprint: result.fingerprint,
                            durationSeconds: result.duration,
                            acoustid: nil,
                            musicbrainzRecordingId: nil,
                            fingerprintedAt: ISO8601DateFormatter().string(from: Date())
                        )
                        try await analysisRepository.saveFingerprint(fingerprint)
                        AppLogger.shared.debug("PerformanceQueue [B/3]: Saved fingerprint for \(track.title)", source: "PerformanceQueue")
                    }
                } catch {
                    AppLogger.shared.log("PerformanceQueue [B/3]: Fingerprinting failed for \(track.title) — \(error.localizedDescription)", level: .warning, source: "PerformanceQueue")
                }
            }
            
            // Check suspension points before the final CoreML step
            try await checkSuspensionPoints()
            
            // --- Step C: CoreML Groove Embedding ---
            if let embeddingService = DependencyContainer.shared.audioEmbeddingService, embeddingService.isAvailable {
                do {
                    AppLogger.shared.debug("PerformanceQueue [C/3]: Extracting CoreML Groove Embedding for \(track.title)", source: "PerformanceQueue")
                    let totalDuration = Double(track.duration ?? 0)
                    let res = try await embeddingService.analyzeTrackDrop(at: filePath, totalDuration: totalDuration)
                    
                    let mixCat = MixClassifier.classify(
                        bpm: 126.0,
                        avgLufs: track.lufsI ?? -14.0,
                        lufsRange: track.lufsRange ?? 5.0,
                        artist: track.artist,
                        title: track.title
                    )
                    let mixCatString = (track.duration ?? 0) > 600 ? mixCat.rawValue : nil
                    
                    try await trackRepository.saveTrackEmbedding(
                        trackId: trackId,
                        embedding: res.embedding,
                        dropOffset: res.offset,
                        mixCategory: mixCatString
                    )
                    AppLogger.shared.debug("PerformanceQueue [C/3]: Saved Groove Embedding for \(track.title)", source: "PerformanceQueue")
                } catch {
                    AppLogger.shared.log("PerformanceQueue [C/3]: Groove Embedding failed for \(track.title) — \(error.localizedDescription)", level: .warning, source: "PerformanceQueue")
                }
            }
            
            AppLogger.shared.info("PerformanceQueue: Finished analysis pipeline for \(track.artist) - \(track.title)", source: "PerformanceQueue")
        }
    }
    
    /// Cooperative suspension point.
    /// Sleeps and yields execution to give full network and CPU bandwidth to high-priority downloads.
    private func checkSuspensionPoints() async throws {
        while isDownloadActive {
            // Cooperative yield and wait 500ms before checking again
            try await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled {
                throw CancellationError()
            }
        }
    }
}
