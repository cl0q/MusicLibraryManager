import SwiftUI
import GRDB
import Foundation

/// Helper manager for completely independent suggested track previews
@Observable
final class PreviewPlayerManager {
    private let player = AudioPlayer()
    private(set) var currentTrack: Track? = nil
    private(set) var isPlaying = false
    private(set) var currentPosition: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    private(set) var waveformData: [Float] = []
    private(set) var isLoadingWaveform = false
    
    private var positionTimer: Timer?
    private var waveformTask: Task<Void, Never>?
    
    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentPosition / duration
    }
    
    var formattedPosition: String {
        formatTime(currentPosition)
    }
    
    var formattedDuration: String {
        formatTime(duration)
    }
    
    deinit {
        positionTimer?.invalidate()
    }
    
    @MainActor
    func playTrack(_ track: Track, libraryRoot: String, mainPlayback: PlaybackViewModel?) async {
        stop()
        isLoadingWaveform = true
        
        // Pause the main app playback first so they don't overlap, without disrupting its selection/position
        mainPlayback?.pause()
        
        let path: String
        if let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: libraryRoot).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) {
                path = url.path
            } else {
                path = track.originalPath
            }
        } else {
            path = track.originalPath
        }
        
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            AppLogger.shared.log("Preview: File not found \(fileURL.path)", level: .error, source: "PreviewPlayer")
            isLoadingWaveform = false
            return
        }
        
        do {
            try player.loadFile(at: fileURL)
            currentTrack = track
            duration = player.duration
            currentPosition = 0
            
            try player.play()
            isPlaying = true
            
            // Start polling timer
            startPositionTimer()
            
            // Extract waveform
            let binCount = WaveformHelpers.adaptiveBinCount(duration: duration)
            waveformTask = Task.detached(priority: .utility) { [weak self] in
                guard let self else { return }
                let data = (try? await MainActor.run { try self.player.extractWaveformData(binCount: binCount) }) ?? []
                await MainActor.run {
                    self.waveformData = data
                    self.isLoadingWaveform = false
                }
            }
            
            // Boost and seek Straight to the Drop if available
            if let dbPool = DependencyContainer.shared.databaseManager?.pool,
               let trackId = track.id {
                let dropOffset = try? await dbPool.read { db in
                    try Double.fetchOne(db, sql: "SELECT drop_offset FROM track_embeddings WHERE track_id = ? LIMIT 1", arguments: [trackId])
                }
                if let drop = dropOffset, drop > 0 {
                    try? player.seek(to: drop)
                    currentPosition = player.currentPosition
                }
            }
        } catch {
            AppLogger.shared.log("Preview playback failed: \(error.localizedDescription)", level: .error, source: "PreviewPlayer")
            isLoadingWaveform = false
        }
    }
    
    @MainActor
    func togglePlayPause() {
        do {
            try player.togglePlayPause()
            isPlaying = player.state == .playing
            if isPlaying {
                startPositionTimer()
            } else {
                stopPositionTimer()
            }
        } catch {}
    }
    
    @MainActor
    func seekToProgress(_ fraction: Double) {
        let position = fraction * duration
        do {
            try player.seek(to: position)
            currentPosition = player.currentPosition
        } catch {}
    }
    
    @MainActor
    func stop() {
        player.stop()
        isPlaying = false
        currentPosition = 0
        currentTrack = nil
        waveformData = []
        stopPositionTimer()
        waveformTask?.cancel()
    }
    
    @MainActor
    private func startPositionTimer() {
        stopPositionTimer()
        positionTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentPosition = self.player.currentPosition
                
                // Natural end detection
                if self.player.state == .stopped && self.isPlaying {
                    self.stop()
                }
            }
        }
    }
    
    @MainActor
    private func stopPositionTimer() {
        positionTimer?.invalidate()
        positionTimer = nil
    }
    
    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Groove — A premium, comprehensive workspace sheet for exploring track similarities and discovering new music.
struct GrooveView: View {
    let seedTrack: Track

    @Environment(\.dismiss) private var dismiss
    @Environment(\.container) private var container

    // MARK: - State properties
    @State private var localGrooves: [(track: Track, score: Float, bestMatchOffset: Double)] = []
    @State private var swarmRecommendations: [SwarmRecommendation] = []
    
    @State private var selectedSwarmSource: SwarmRecommendationService.SwarmSource = .soundcloud
    
    @State private var isLoadingLocal = false
    @State private var isLoadingSwarm = false
    @State private var swarmError: String? = nil
    
    // Quick add lists
    @State private var playlists: [Playlist] = []
    @State private var syncProfiles: [SyncProfile] = []
    
    // Remote swarm pagination limit
    @State private var swarmLimit: Int = 10
    
    // Cache to check if recommended tracks are already local or in discovery log
    @State private var localStatusCache: [String: Track] = [:]
    @State private var discoveryLogStatus: [Int64: String] = [:] // trackId -> status
    @State private var localFeedbackMap: [Int64: Int] = [:] // trackId -> feedbackValue
    @State private var trackPendingDeletion: Track?
    @State private var showingDeleteConfirmation = false
    
    // Independent preview player manager instance
    @State private var previewPlayer = PreviewPlayerManager()
    
    // Scrubber / Waveform properties for Inline Waveforms
    @State private var zoomLevel: CGFloat = 1.0
    @State private var exponent: Float = 1.5
    @State private var gain: Float = 1.0
    @State private var waveformHeight: CGFloat = 32.0

    // Fetch view models from dependency container
    private var playbackVM: PlaybackViewModel? {
        container.playbackViewModel
    }
    
    private var downloadVM: DownloadViewModel? {
        container.downloadViewModel
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerBar
            
            Divider()
                .background(Color.mlmEdge)
            
            // Main workspace content (split view)
            HSplitView {
                // Left Panel: Local Groove suggestions
                localGroovesSection
                    .frame(minWidth: 440, maxWidth: .infinity)
                
                // Right Panel: Remote Discovery recommendations
                swarmDiscoverySection
                    .frame(minWidth: 440, maxWidth: .infinity)
            }
            .background(Color.mlmBase)
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Color.mlmBase)
        .task {
            await loadLocalGrooves()
            await loadSwarmRecommendations()
            await loadActionsData()
        }
        .onDisappear {
            previewPlayer.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task {
                await refreshLocalStatuses()
            }
        }
        .alert("Delete file?", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {
                trackPendingDeletion = nil
            }
            Button("Delete", role: .destructive) {
                guard let track = trackPendingDeletion else { return }
                trackPendingDeletion = nil
                Task { await handleRejectDiscovery(track: track) }
            }
        } message: {
            Text("Delete this file from disk?")
        }
    }

    // MARK: - Subviews

    private var headerBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.mlmAccent)
                        .font(.title3)
                    Text("Similar tracks")
                        .font(MLMFont.title3)
                        .foregroundColor(.mlmInk)
                }
                
                // Seed info subtitle
                HStack(spacing: 6) {
                    Text("Similar to")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                    Text("'\(seedTrack.title)'")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInkSecondary)
                    Text("by")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                    Text(seedTrack.artist)
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInkSecondary)
                }
            }
            
            Spacer()
            
            Button {
                previewPlayer.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.mlmInkSecondary.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Close similar tracks")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.mlmSurface)
    }

    // MARK: - Local Groove Row Builder (Reusable for left & right downloaded tracks)

    private func localTrackRow(
        track: Track,
        isPlaying: Bool,
        matchScore: Float? = nil,
        isSwarmSuggestion: Bool = false,
        swarmSource: String? = nil
    ) -> some View {
        let status = discoveryLogStatus[track.id ?? 0]
        
        return VStack(spacing: 10) {
            HStack(spacing: 12) {
                // Artwork & Play Indicator cover overlay
                ZStack {
                    TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 6)
                        .frame(width: 36, height: 36)
                    
                    if isPlaying {
                        Color.black.opacity(0.4)
                            .frame(width: 36, height: 36)
                            .cornerRadius(6)
                        
                        Image(systemName: previewPlayer.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if isPlaying {
                        previewPlayer.togglePlayPause()
                    } else {
                        playTrackPreview(track)
                    }
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                        .lineLimit(1)
                    
                    Text(track.artist)
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                        .lineLimit(1)
                }
                
                Spacer()
                
                // Match score Badge or Source Badge
                if let score = matchScore {
                    Text("\(Int(score * 100))% Match")
                        .font(MLMFont.badge)
                        .foregroundColor(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule()
                                .fill(score > 0.85 ? Color.mlmSuccess : (score > 0.70 ? Color.mlmWarning : Color.mlmInkMuted))
                        )
                } else if let src = swarmSource {
                    let badgeText = src.lowercased() == "soundcloud" ? "SoundCloud" : src.capitalized
                    Text(badgeText)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            Capsule()
                                .fill(src.lowercased() == "soundcloud" ? Color.orange : Color.red)
                        )
                }
                
                // Playlist quick-add menu
                playlistMenu(for: track)
                
                // Sync profile quick-add menu
                syncProfileMenu(for: track)
                
                // Thumbs Up (Approve / Boost feedback loop)
                Button {
                    Task {
                        if isSwarmSuggestion {
                            await handleApproveDiscovery(track: track, source: swarmSource ?? "soundcloud")
                        } else {
                            await handleLocalThumbsUp(targetId: track.id!)
                        }
                    }
                } label: {
                    let isApproved = isSwarmSuggestion ? (status == "approved") : (localFeedbackMap[track.id!] == 1)
                    Image(systemName: isApproved ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .foregroundColor(isApproved ? Color.green : Color.mlmInkSecondary)
                }
                .buttonStyle(.plain)
                .help(isSwarmSuggestion ? "Add to library" : "Mark as a good match")
                
                // Thumbs Down (Reject / Purge / Hide feedback loop)
                Button {
                    if isSwarmSuggestion {
                        trackPendingDeletion = track
                        showingDeleteConfirmation = true
                    } else {
                        Task {
                            await handleLocalThumbsDown(targetId: track.id!)
                        }
                    }
                } label: {
                    Image(systemName: "hand.thumbsdown.fill")
                        .foregroundColor(.mlmError.opacity(0.8))
                }
                .buttonStyle(.plain)
                .help(isSwarmSuggestion ? "Delete" : "Mark as a poor match and hide")
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                playTrackPreview(track)
            }
            
            // Inline Player waveforms (Independent Preview Player!)
            if isPlaying {
                inlinePreviewDeck
                    .transition(.opacity)
            }
        }
        .padding(12)
        .background(Color.mlmSurface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPlaying ? Color.mlmAccent.opacity(0.5) : Color.mlmEdge.opacity(0.2), lineWidth: isPlaying ? 1.5 : 1)
        )
    }

    // MARK: - Left Panel (Local suggestions)
    
    private var localGroovesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Local matches", systemImage: "music.note.house")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)
                
                Spacer()
                
                if isLoadingLocal {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await loadLocalGrooves() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.mlmInkSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            
            Divider()
                .background(Color.mlmEdge)
            
            if localGrooves.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 40))
                        .foregroundColor(.mlmInkMuted)
                    Text("No local matches yet")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInkSecondary)
                    Text("Analyze more tracks in your library to find similar music.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(localGrooves, id: \.track.id) { row in
                            let isPlaying = previewPlayer.currentTrack?.id == row.track.id
                            localTrackRow(track: row.track, isPlaying: isPlaying, matchScore: row.score)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }
    
    // MARK: - Right Panel (Global swarm recommendations)
    
    private var swarmDiscoverySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Label("Recommendations", systemImage: "globe.europe.africa.fill")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)
                
                Spacer()
                
                Picker("Recommendation source", selection: $selectedSwarmSource) {
                    Text("SoundCloud").tag(SwarmRecommendationService.SwarmSource.soundcloud)
                    Text("Last.fm").tag(SwarmRecommendationService.SwarmSource.lastfm)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
                .onChange(of: selectedSwarmSource) { _ in
                    swarmLimit = 10
                    Task { await loadSwarmRecommendations() }
                }
                
                if isLoadingSwarm {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task { await loadSwarmRecommendations() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundColor(.mlmInkSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            
            Divider()
                .background(Color.mlmEdge)
            
            if let errorMsg = swarmError {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                        .foregroundColor(.mlmError)
                    Text("Could not load recommendations")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                    Text(errorMsg)
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if swarmRecommendations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundColor(.mlmInkMuted)
                    Text(isLoadingSwarm ? "Searching recommendations…" : "No recommendations found")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInkSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(swarmRecommendations, id: \.self) { rec in
                            let key = rec.scDownloadUrl ?? "\(rec.artist) - \(rec.title)"
                            let localTrack = localStatusCache[key]
                            let isLocal = localTrack != nil
                            let dlStatus = downloadVM?.discoveryStatuses[key]
                            let isPlaying = isLocal && previewPlayer.currentTrack?.id == localTrack?.id
                            
                            VStack(spacing: 10) {
                                if isLocal, let trackObj = localTrack {
                                    // REWORKED! Instantly morphs into the exact same local track row layout as the left panel!
                                    localTrackRow(
                                        track: trackObj,
                                        isPlaying: isPlaying,
                                        isSwarmSuggestion: true,
                                        swarmSource: rec.source
                                    )
                                } else {
                                    // Remote (Not Downloaded yet) row state
                                    HStack(spacing: 12) {
                                        Image(systemName: rec.source.lowercased() == "soundcloud" ? "cloud.fill" : "music.note")
                                            .font(.system(size: 14))
                                            .foregroundColor(.mlmInkMuted)
                                            .frame(width: 36, height: 36)
                                            .background(Color.mlmRaised)
                                            .cornerRadius(6)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(rec.title)
                                                .font(MLMFont.bodyBold)
                                                .foregroundColor(.mlmInk)
                                                .lineLimit(1)
                                            
                                            Text(rec.artist)
                                                .font(MLMFont.body)
                                                .foregroundColor(.mlmInkSecondary)
                                                .lineLimit(1)
                                        }
                                        
                                        Spacer()
                                        
                                        // SoundCloud smaller, camel-case badge
                                        let sourceBadge = rec.source.lowercased() == "soundcloud" ? "SoundCloud" : rec.source.capitalized
                                        Text(sourceBadge)
                                            .font(.system(size: 8, weight: .bold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(
                                                Capsule()
                                                    .fill(rec.source.lowercased() == "soundcloud" ? Color.orange : Color.red)
                                            )
                                        
                                        if let dlStatus = dlStatus {
                                            // Downloading status badges
                                            switch dlStatus {
                                            case .queued:
                                                Text("Queued…")
                                                    .font(MLMFont.muted)
                                                    .foregroundColor(.mlmInkSecondary)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.mlmRaised)
                                                    .cornerRadius(4)
                                            case .downloading:
                                                HStack(spacing: 6) {
                                                    ProgressView()
                                                        .controlSize(.small)
                                                    Text("Downloading…")
                                                        .font(MLMFont.muted)
                                                        .foregroundColor(.mlmAccent)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.mlmRaised)
                                                .cornerRadius(4)
                                            case .downloaded:
                                                Text("Downloaded")
                                                    .font(MLMFont.muted)
                                                    .foregroundColor(.mlmSuccess)
                                            case .failed:
                                                Button {
                                                    triggerDownload(rec)
                                                } label: {
                                                    Label("Retry", systemImage: "arrow.clockwise")
                                                        .font(.system(size: 10, weight: .bold))
                                                        .foregroundColor(.white)
                                                        .padding(.horizontal, 8)
                                                        .padding(.vertical, 4)
                                                        .background(Color.mlmError)
                                                        .cornerRadius(4)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        } else {
                                            // Remote trigger download button
                                            Button {
                                                triggerDownload(rec)
                                            } label: {
                                                Label("Download", systemImage: "arrow.down.circle")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundColor(.white)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.mlmAccent)
                                                    .cornerRadius(4)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(12)
                                    .background(Color.mlmSurface)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.mlmEdge.opacity(0.2), lineWidth: 1)
                                    )
                                }
                            }
                        }
                        
                        // "Load More Suggestions" button at the bottom of the list
                        loadMoreButton
                            .padding(.top, 8)
                    }
                    .padding(16)
                }
            }
        }
    }

    // MARK: - Inline Waveform Preview Deck
    
    private var inlinePreviewDeck: some View {
        HStack(spacing: 12) {
            // Play/Pause button
            Button {
                previewPlayer.togglePlayPause()
            } label: {
                Image(systemName: previewPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.mlmAccent)
            }
            .buttonStyle(.plain)
            
            // Inline Waveform
            VStack(spacing: 3) {
                WaveformView(
                    data: previewPlayer.waveformData,
                    progress: previewPlayer.progress,
                    isLoading: previewPlayer.isLoadingWaveform,
                    zoomLevel: $zoomLevel,
                    exponent: $exponent,
                    gain: $gain,
                    waveformHeight: $waveformHeight
                ) { fraction in
                    previewPlayer.seekToProgress(fraction)
                }
                .frame(height: 24)
                .background(Color.mlmBase)
                .cornerRadius(4)
                
                // Progress time text
                HStack {
                    Text(previewPlayer.formattedPosition)
                        .font(MLMFont.mono)
                        .font(.system(size: 8))
                        .foregroundColor(.mlmInkSecondary)
                        .monospacedDigit()
                    Spacer()
                    Text(previewPlayer.formattedDuration)
                        .font(MLMFont.mono)
                        .font(.system(size: 8))
                        .foregroundColor(.mlmInkMuted)
                        .monospacedDigit()
                }
            }
            
            // Stop button
            Button {
                previewPlayer.stop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 10))
                    .foregroundColor(.mlmInkMuted)
                    .padding(6)
                    .background(Color.mlmBase)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color.mlmRaised)
        .cornerRadius(6)
    }

    // MARK: - Helper Interaction Components

    private func playlistMenu(for track: Track) -> some View {
        Menu {
            if playlists.isEmpty {
                Text("No playlists found")
            } else {
                ForEach(playlists) { pl in
                    Button(pl.name) {
                        addToPlaylist(pl, track: track)
                    }
                }
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 12))
                .foregroundColor(.mlmAccent)
        }
        .menuStyle(.button)
        .help("Add to playlist")
    }

    private func syncProfileMenu(for track: Track) -> some View {
        Menu {
            if syncProfiles.isEmpty {
                Text("No sync profiles found")
            } else {
                ForEach(syncProfiles) { sp in
                    Button(sp.name) {
                        addToSyncProfile(sp, track: track)
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath.circle")
                .font(.system(size: 12))
                .foregroundColor(.mlmActive)
        }
        .menuStyle(.button)
        .help("Add to sync profile")
    }

    private var loadMoreButton: some View {
        Button {
            Task { await loadMoreRecommendations() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.circle")
                Text("Load more")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.mlmAccent)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions & Loading Loops

    private func loadLocalGrooves() async {
        guard let trackRepo = container.trackRepository, let id = seedTrack.id else { return }
        isLoadingLocal = true
        do {
            let list = try await trackRepo.fetchSimilarTracks(seedTrackId: id, limit: 12)
            
            // Load similarity feedback maps to check approved/active states reactively
            let feedbackRows = (try? await trackRepo.fetchSimilarityFeedback(seedTrackId: id)) ?? []
            let map = Dictionary(uniqueKeysWithValues: feedbackRows.map { ($0.targetTrackId, $0.feedbackValue) })
            
            await MainActor.run {
                self.localGrooves = list
                self.localFeedbackMap = map
                self.isLoadingLocal = false
            }
        } catch {
            AppLogger.shared.error("GrooveStudio: Failed to load local grooves: \(error.localizedDescription)", source: "GrooveStudio")
            isLoadingLocal = false
        }
    }
    
    private func loadSwarmRecommendations() async {
        guard let swarmService = container.swarmRecommendationService else { return }
        isLoadingSwarm = true
        swarmError = nil
        do {
            let list = try await swarmService.fetchRecommendations(for: seedTrack, source: selectedSwarmSource, limit: swarmLimit)
            await MainActor.run {
                self.swarmRecommendations = list
                self.isLoadingSwarm = false
            }
            await refreshLocalStatuses()
        } catch {
            await MainActor.run {
                self.swarmError = error.localizedDescription
                self.isLoadingSwarm = false
            }
        }
    }

    private func loadMoreRecommendations() async {
        guard let swarmService = container.swarmRecommendationService else { return }
        isLoadingSwarm = true
        swarmLimit += 10
        do {
            let newList = try await swarmService.fetchRecommendations(for: seedTrack, source: selectedSwarmSource, limit: swarmLimit)
            
            // Physically extend the list, filtering out any existing duplicates
            var currentKeys = Set(swarmRecommendations.map { $0.scDownloadUrl ?? "\($0.artist) - \($0.title)" })
            var extended: [SwarmRecommendation] = swarmRecommendations
            for rec in newList {
                let key = rec.scDownloadUrl ?? "\(rec.artist) - \(rec.title)"
                if !currentKeys.contains(key) {
                    extended.append(rec)
                    currentKeys.insert(key)
                }
            }
            
            await MainActor.run {
                self.swarmRecommendations = extended
                self.isLoadingSwarm = false
            }
            await refreshLocalStatuses()
        } catch {
            await MainActor.run {
                self.swarmError = error.localizedDescription
                self.isLoadingSwarm = false
            }
        }
    }
    
    private func refreshLocalStatuses() async {
        guard let trackRepo = container.trackRepository else { return }
        var statusMap: [String: Track] = [:]
        var logMap: [Int64: String] = [:]
        
        // Resolve tracks by querying discovery neighbors for this seed
        let dbDiscoveredTracks = (try? await trackRepo.fetchDiscoveryTracksForSeed(seedTrackId: seedTrack.id ?? 0)) ?? []
        
        for rec in swarmRecommendations {
            let key = rec.scDownloadUrl ?? "\(rec.artist) - \(rec.title)"
            
            // 1. Resolve SoundCloud track from the database discovery logs of this seed
            if let matchingTrack = dbDiscoveredTracks.first(where: {
                let tTitle = $0.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let rTitle = rec.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                return tTitle == rTitle || tTitle.contains(rTitle) || rTitle.contains(tTitle)
            }) {
                statusMap[key] = matchingTrack
                if let trackId = matchingTrack.id {
                    let status = await fetchDiscoveryStatusDirect(trackId: trackId)
                    logMap[trackId] = status
                }
                continue
            }
            
            // 2. Fallback SoundCloud permalink checks
            if rec.source.lowercased() == "soundcloud", let sourceId = rec.sourceId {
                if let existing = try? await trackRepo.fetchTrackBySoundCloudPath(externalId: sourceId, permalink: rec.scDownloadUrl) {
                     statusMap[key] = existing
                     if let trackId = existing.id {
                         let status = await fetchDiscoveryStatusDirect(trackId: trackId)
                         logMap[trackId] = status
                     }
                     continue
                }
            }
            
            // 3. Fallback exact artist/title checks
            if let existing = try? await trackRepo.fetchTrackByArtistAndTitle(artist: rec.artist, title: rec.title) {
                statusMap[key] = existing
                if let trackId = existing.id {
                    let status = await fetchDiscoveryStatusDirect(trackId: trackId)
                    logMap[trackId] = status
                }
            }
        }
        
        await MainActor.run {
            self.localStatusCache = statusMap
            self.discoveryLogStatus = logMap
        }
    }
    
    private func fetchDiscoveryStatusDirect(trackId: Int64) async -> String {
        guard let db = container.databaseManager?.pool else { return "none" }
        let status = try? await db.read { dbConn -> String? in
            try String.fetchOne(dbConn, sql: "SELECT status FROM track_discovery_log WHERE discovered_track_id = ? LIMIT 1", arguments: [trackId])
        }
        return status ?? "none"
    }
    
    private func triggerDownload(_ rec: SwarmRecommendation) {
        guard let downloadVM = downloadVM else { return }
        downloadVM.downloadDiscoveryTrack(
            artist: rec.artist,
            title: rec.title,
            soundcloudURL: rec.scDownloadUrl,
            source: rec.source,
            seedTrack: seedTrack
        )
    }
    
    private func playTrackPreview(_ track: Track) {
        Task {
            await previewPlayer.playTrack(track, libraryRoot: downloadVM?.libraryRoot ?? "", mainPlayback: playbackVM)
        }
    }

    private func loadActionsData() async {
        if let playlistRepo = container.playlistRepository {
            playlists = (try? await playlistRepo.fetchAll()) ?? []
        }
        if let syncRepo = container.syncRepository {
            syncProfiles = (try? await syncRepo.fetchAll()) ?? []
        }
    }

    private func addToPlaylist(_ playlist: Playlist, track: Track) {
        guard let playlistId = playlist.id,
              let playlistRepo = container.playlistRepository,
              let trackId = track.id else { return }

        let position = String(format: "%06d", 999000)
        Task {
            try? await playlistRepo.addTracks(
                playlistId: playlistId,
                trackIds: [trackId],
                startPosition: position
            )
            NotificationCenter.default.post(
                name: .playlistDidChange,
                object: nil,
                userInfo: ["playlistId": playlistId]
            )
            AppLogger.shared.info("GrooveStudio: Added '\(track.title)' to playlist '\(playlist.name)'.", source: "GrooveStudio")
        }
    }

    private func addToSyncProfile(_ profile: SyncProfile, track: Track) {
        guard let profileId = profile.id,
              let syncRepo = container.syncRepository,
              let trackId = track.id else { return }

        Task {
            try? await syncRepo.addTrack(profileId: profileId, trackId: trackId)
            NotificationCenter.default.post(
                name: .syncProfileDidChange,
                object: nil,
                userInfo: ["profileId": profileId]
            )
            AppLogger.shared.info("GrooveStudio: Added '\(track.title)' to sync profile '\(profile.name)'.", source: "GrooveStudio")
        }
    }
    
    // MARK: - Thumbs Up & Thumbs Down Review Loop Triggers
    
    private func handleApproveDiscovery(track: Track, source: String) async {
        guard let reviewService = container.discoveryReviewService else { return }
        do {
            try await reviewService.accept(track: track, seedTrackID: seedTrack.id, source: source)
            await refreshLocalStatuses()
            await loadLocalGrooves()
        } catch {
            AppLogger.shared.error("GrooveStudio: Failed to approve track: \(error.localizedDescription)", source: "GrooveStudio")
        }
    }
    
    private func handleRejectDiscovery(track: Track) async {
        guard let reviewService = container.discoveryReviewService,
              let trackId = track.id else { return }
        
        do {
            // Stop previewing first if we are purging this track
            if previewPlayer.currentTrack?.id == trackId {
                previewPlayer.stop()
            }
            
            try await reviewService.delete(track: track)
            await refreshLocalStatuses()
            await loadLocalGrooves()
        } catch {
            AppLogger.shared.error("GrooveStudio: Failed to reject track: \(error.localizedDescription)", source: "GrooveStudio")
        }
    }

    private func handleLocalThumbsUp(targetId: Int64) async {
        guard let trackRepo = container.trackRepository,
              let seedId = seedTrack.id else { return }
        
        do {
            // Give local track +1 feedback to improve compose similarity score weight
            try await trackRepo.saveSimilarityFeedback(seedTrackId: seedId, targetTrackId: targetId, feedbackValue: 1)
            
            // Apply the existing similarity feedback adjustment.
            try await trackRepo.applyVectorGravity(seedTrackId: seedId, targetTrackId: targetId, pullRate: 0.05)
            
            AppLogger.shared.info("Similar: Applied positive feedback to local track \(targetId).", source: "Similar")
            
            await loadLocalGrooves()
        } catch {
            AppLogger.shared.error("GrooveStudio: Failed to register positive local feedback: \(error.localizedDescription)", source: "GrooveStudio")
        }
    }
    
    private func handleLocalThumbsDown(targetId: Int64) async {
        guard let trackRepo = container.trackRepository,
              let seedId = seedTrack.id else { return }
        
        do {
            // Give local track -1 feedback to exclude it from future similarity results
            try await trackRepo.saveSimilarityFeedback(seedTrackId: seedId, targetTrackId: targetId, feedbackValue: -1)
            
            AppLogger.shared.info("GrooveStudio: Applied negative feedback to track \(targetId) (hidden from similarity results).", source: "GrooveStudio")
            
            await loadLocalGrooves()
        } catch {
            AppLogger.shared.error("GrooveStudio: Failed to register negative local feedback: \(error.localizedDescription)", source: "GrooveStudio")
        }
    }
    
    // MARK: - Time Helper
    
    private func formatOffsetTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let totalSeconds = Int(seconds)
        let m = totalSeconds / 60
        let s = totalSeconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
