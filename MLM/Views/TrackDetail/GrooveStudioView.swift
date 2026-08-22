import SwiftUI
import GRDB
import Foundation
import AppKit

/// Screen navigation state inside the Groove Studio workspace.
enum StudioScreen: Hashable {
    case grid
    case detail(genre: String)
    case merger
    case exporter
}

/// The new Groove Studio view — a premium, full-size workspace for labeling, cleaning, and exporting track genres for CreateML.
struct GrooveStudioView: View {
    @Environment(\.container) private var container
    
    @State private var selectedScreen: StudioScreen = .grid
    
    private var selectedGenre: String? {
        get {
            if case .detail(let genre) = selectedScreen {
                return genre
            }
            return nil
        }
        set {
            if let newGenre = newValue {
                selectedScreen = .detail(genre: newGenre)
            } else {
                selectedScreen = .grid
            }
        }
    }
    
    // MARK: - Library State
    @State private var uniqueGenres: [(genre: String, count: Int)] = []
    @State private var genreTracks: [Track] = []
    @State private var suggestions: [(track: Track, score: Float, bestMatchOffset: Double)] = []
    
    // MARK: - Loading States
    @State private var isLoadingGenres = false
    @State private var isLoadingTracks = false
    @State private var isLoadingSuggestions = false
    @State private var saveMessage: String? = nil
    @State private var saveMessageTimer: Timer? = nil
    
    // MARK: - Active Reference Song
    @State private var referenceTrack: Track? = nil
    
    // MARK: - Controls State
    @State private var temperature: Double = 0.3
    @State private var suggestionLimit: Int = 10
    @State private var onlyUntaggedSuggestions: Bool = false
    
    // MARK: - Thumbs / Pending Edits
    struct PendingEdit: Hashable {
        let trackId: Int64
        let title: String
        let artist: String
        let genre: String
        let mixCategory: String?
    }
    @State private var pendingEdits: [Int64: PendingEdit] = [:]
    @State private var feedbackMap: [Int64: Int] = [:] // Session thumbs ratings to display
    
    // MARK: - Independent Dual Players
    @State private var leftPlayer = PreviewPlayerManager()  // Suggestion player
    @State private var rightPlayer = PreviewPlayerManager() // Reference & Preview player
    
    // MARK: - Waveform Visualization State
    @State private var zoomLevel: CGFloat = 1.0
    @State private var exponent: Float = 1.5
    @State private var gain: Float = 1.0
    @State private var leftWaveformHeight: CGFloat = 36.0
    @State private var rightWaveformHeight: CGFloat = 36.0
    
    // MARK: - Playlists & Sync Profiles for ContextMenu
    @State private var availablePlaylists: [Playlist] = []
    @State private var availableSyncProfiles: [SyncProfile] = []
    
    // MARK: - Genre Merger State
    @State private var selectedForMerge: Set<String> = []
    @State private var targetGenreName: String = ""
    @State private var mergerMessage: String? = nil
    @State private var mergerError: String? = nil
    @State private var selectedPreviewGenre: String? = nil
    @State private var mergerPreviewTracks: [Track] = []
    @State private var isLoadingPreviewTracks = false
    @State private var selectedMergerTrackIDs: Set<Int64> = []
    
    private struct PreviewTrackRow: Identifiable {
        let id: Int64
        let track: Track
    }
    
    @State private var previewTracksSortOrder: [KeyPathComparator<PreviewTrackRow>] = [
        KeyPathComparator(\.track.title, order: .forward)
    ]
    
    private var sortedPreviewTracks: [PreviewTrackRow] {
        mergerPreviewTracks
            .compactMap { t in t.id.map { PreviewTrackRow(id: $0, track: t) } }
            .sorted(using: previewTracksSortOrder)
    }
    
    private func isNowPlaying(_ track: Track) -> Bool {
        guard let playbackVM = container.playbackViewModel,
              let currentTrack = playbackVM.currentTrack,
              let currentID = currentTrack.id,
              let trackID = track.id else {
            return false
        }
        return currentID == trackID && playbackVM.isPlaying
    }
    
    // MARK: - CreateML Exporter State
    @State private var exportFolderURL: URL? = nil
    @State private var isExporting = false
    @State private var exportProgress: Double = 0.0
    @State private var exportProgressText: String = ""
    @State private var exportCancelRequested = false
    @State private var exportTask: Task<Void, Never>? = nil
    @State private var showExcludedGenres = false
    
    private let transcodeService = TranscodeService()
    
    // MARK: - Body
    var body: some View {
        VStack(spacing: 0) {
            switch selectedScreen {
            case .grid:
                genreSelectionGrid
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .trailing)))
            case .detail(let genre):
                genreDetailPanel(genre: genre)
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .merger:
                genreMergerPanel
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            case .exporter:
                createMLExporterPanel
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .move(edge: .leading)))
            }
        }
        .background(Color.mlmBase)
        .task {
            await loadUniqueGenres()
            await loadPlaylistsAndSyncProfiles()
        }
        .onDisappear {
            leftPlayer.stop()
            rightPlayer.stop()
        }
    }
    
    // MARK: - Genre Selection Grid
    
    private var genreSelectionGrid: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Genre Workshop")
                        .font(MLMFont.heroTitle)
                        .foregroundColor(.mlmInk)
                    Text("Pick a genre to review suggestions and clean up your tags.")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                }
                Spacer()
                
                // Consolidation & Export Actions
                HStack(spacing: 12) {
                    Button {
                        selectedForMerge = []
                        targetGenreName = ""
                        mergerMessage = nil
                        mergerError = nil
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedScreen = .merger
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.grid.3x3.fill")
                            Text("Consolidate genres")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.mlmAccent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.mlmSurface)
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Consolidate inconsistent genres in your library")
                    
                    Button {
                        exportFolderURL = nil
                        isExporting = false
                        exportProgress = 0.0
                        exportProgressText = ""
                        exportCancelRequested = false
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedScreen = .exporter
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                            Text("Export training set (CreateML)")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.mlmAccent)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .help("Export a flat training set for CreateML")
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            
            Divider()
                .background(Color.mlmEdge)
            
            if isLoadingGenres {
                VStack {
                    Spacer()
                    ProgressView("Loading genres...")
                        .controlSize(.large)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if uniqueGenres.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "waveform.badge.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.mlmInkMuted)
                    Text("No genres in your library yet")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInkSecondary)
                    Text("Tag some tracks to use the workshop.")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let columns = [
                        GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)
                    ]
                    
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(uniqueGenres, id: \.genre) { item in
                            Button {
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    selectedScreen = .detail(genre: item.genre)
                                }
                                Task {
                                    await loadTracksForGenre(item.genre)
                                }
                            } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    HStack {
                                        Image(systemName: "music.note")
                                            .font(.title3)
                                            .foregroundColor(.white)
                                            .padding(10)
                                            .background(
                                                Circle()
                                                    .fill(
                                                        LinearGradient(
                                                            colors: [Color.mlmAccent, Color.mlmActive],
                                                            startPoint: .topLeading,
                                                            endPoint: .bottomTrailing
                                                        )
                                                    )
                                            )
                                        Spacer()
                                        
                                        Text("\(item.count)")
                                            .font(MLMFont.mono)
                                            .font(.caption)
                                            .foregroundColor(.mlmInkSecondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.mlmBase)
                                            .cornerRadius(6)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.genre)
                                            .font(MLMFont.sectionHeader)
                                            .foregroundColor(.mlmInk)
                                            .lineLimit(1)
                                        
                                        Text(item.count == 1 ? "1 Song" : "\(item.count) Songs")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkSecondary)
                                    }
                                }
                                .padding(16)
                                .background(Color.mlmSurface)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                                )
                                .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 2)
                            }
                            .buttonStyle(.plain)
                            .springLoadableHover {}
                        }
                    }
                    .padding(24)
                }
            }
        }
    }
    
    // MARK: - Genre Detail Panel
    
    private func genreDetailPanel(genre: String) -> some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 16) {
                Button {
                    // Stop players
                    leftPlayer.stop()
                    rightPlayer.stop()
                    // Clear state
                    referenceTrack = nil
                    suggestions = []
                    pendingEdits = [:]
                    feedbackMap = [:]
                    withAnimation(.easeInOut(duration: 0.25)) {
                        selectedScreen = .grid
                    }
                    Task {
                        await loadUniqueGenres()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Genres")
                    }
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.mlmSurface)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                
                Text(genre)
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)
                
                if !pendingEdits.isEmpty {
                    Button {
                        Task { await savePendingEdits() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.circle.fill")
                            Text("Save (\(pendingEdits.count))")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.purple)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
                
                if let msg = saveMessage {
                    Text(msg)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmSuccess)
                        .transition(.opacity)
                }
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.mlmSurface)
            
            Divider()
                .background(Color.mlmEdge)
            
            // Dual Waveforms Panel
            dualWaveformsHeader
            
            Divider()
                .background(Color.mlmEdge)
            
            // Main Content Area (Two Columns)
            HStack(spacing: 0) {
                // Left Column: Suggestions
                leftSuggestionsColumn(genre: genre)
                
                Divider()
                    .background(Color.mlmEdge)
                
                // Right Column: Known Tracks
                rightKnownTracksColumn
            }
            .frame(maxHeight: .infinity)
        }
    }
    
    // MARK: - Dual Waveforms
    
    private var dualWaveformsHeader: some View {
        HStack(spacing: 24) {
            // Left Player (Suggestions) Waveform
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(
                        leftPlayer.currentTrack != nil ? "Suggestion player" : "Preview player",
                        systemImage: "waveform.circle.fill"
                    )
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(leftPlayer.currentTrack != nil ? .mlmAccent : .mlmInkSecondary)
                    
                    Spacer()
                    
                    if let track = leftPlayer.currentTrack {
                        Text("\(track.title) · \(track.artist)")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                            .lineLimit(1)
                    } else {
                        Text("Ready for preview…")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                    }
                }
                
                HStack(spacing: 8) {
                    Button {
                        leftPlayer.togglePlayPause()
                    } label: {
                        Image(systemName: leftPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.mlmAccent)
                    }
                    .buttonStyle(.plain)
                    .disabled(leftPlayer.currentTrack == nil)
                    
                    WaveformView(
                        data: leftPlayer.waveformData,
                        progress: leftPlayer.progress,
                        isLoading: leftPlayer.isLoadingWaveform,
                        zoomLevel: $zoomLevel,
                        exponent: $exponent,
                        gain: $gain,
                        waveformHeight: $leftWaveformHeight
                    ) { fraction in
                        leftPlayer.seekToProgress(fraction)
                    }
                    .frame(height: 24)
                    .background(Color.mlmRaised)
                    .cornerRadius(4)
                    
                    Text(leftPlayer.currentTrack != nil ? "\(leftPlayer.formattedPosition) / \(leftPlayer.formattedDuration)" : "0:00")
                        .font(MLMFont.dataSmall)
                        .foregroundColor(.mlmInkSecondary)
                        .frame(width: 66, alignment: .trailing)
                }
            }
            .padding(12)
            .background(Color.mlmSurface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(leftPlayer.currentTrack != nil ? Color.mlmAccent.opacity(0.3) : Color.mlmEdgeSubtle, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
            
            // Right Player (Reference & Previews) Waveform
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label(
                        rightPlayer.currentTrack?.id == referenceTrack?.id && referenceTrack != nil ? "Reference player" : "Preview player",
                        systemImage: "waveform.circle.fill"
                    )
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(rightPlayer.currentTrack != nil ? .mlmActive : .mlmInkSecondary)
                    
                    Spacer()
                    
                    if let track = rightPlayer.currentTrack {
                        Text("\(track.title) · \(track.artist)")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                            .lineLimit(1)
                    } else {
                        Text("Ready for preview…")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                    }
                }
                
                HStack(spacing: 8) {
                    Button {
                        rightPlayer.togglePlayPause()
                    } label: {
                        Image(systemName: rightPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.mlmActive)
                    }
                    .buttonStyle(.plain)
                    .disabled(rightPlayer.currentTrack == nil)
                    
                    WaveformView(
                        data: rightPlayer.waveformData,
                        progress: rightPlayer.progress,
                        isLoading: rightPlayer.isLoadingWaveform,
                        zoomLevel: $zoomLevel,
                        exponent: $exponent,
                        gain: $gain,
                        waveformHeight: $rightWaveformHeight
                    ) { fraction in
                        rightPlayer.seekToProgress(fraction)
                    }
                    .frame(height: 24)
                    .background(Color.mlmRaised)
                    .cornerRadius(4)
                    
                    Text(rightPlayer.currentTrack != nil ? "\(rightPlayer.formattedPosition) / \(rightPlayer.formattedDuration)" : "0:00")
                        .font(MLMFont.dataSmall)
                        .foregroundColor(.mlmInkSecondary)
                        .frame(width: 66, alignment: .trailing)
                }
            }
            .padding(12)
            .background(Color.mlmSurface)
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(rightPlayer.currentTrack != nil ? Color.mlmActive.opacity(0.3) : Color.mlmEdgeSubtle, lineWidth: 1)
            )
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
    
    // MARK: - Left Spalte: Suggestions Column
    
    private func leftSuggestionsColumn(genre: String) -> some View {
        VStack(spacing: 0) {
            // Column Title & Settings
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Suggestions", systemImage: "sparkles")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInk)
                    Spacer()
                }
                
                if referenceTrack != nil {
                    // Temperature, Count & Untagged Options
                    VStack(spacing: 8) {
                        HStack(spacing: 12) {
                            Text("Temperature:")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                                .frame(width: 76, alignment: .leading)
                            
                            Slider(value: $temperature, in: 0.0...1.0, step: 0.1)
                                .labelsHidden()
                                .onChange(of: temperature) { _, _ in
                                    triggerSuggestionsReload()
                                }
                            
                            Text(String(format: "%.1f", temperature))
                                .font(MLMFont.mono)
                                .font(.caption)
                                .foregroundColor(.mlmInkSecondary)
                                .frame(width: 24, alignment: .trailing)
                        }
                        
                        HStack {
                            Text("Suggestions:")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                                .frame(width: 76, alignment: .leading)
                            
                            Picker("Limit", selection: $suggestionLimit) {
                                Text("10 tracks").tag(10)
                                Text("20 tracks").tag(20)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .onChange(of: suggestionLimit) { _, _ in
                                triggerSuggestionsReload()
                            }
                        }
                        
                        Toggle("Suggest untagged tracks only", isOn: $onlyUntaggedSuggestions)
                            .font(MLMFont.muted)
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .onChange(of: onlyUntaggedSuggestions) { _, _ in
                                triggerSuggestionsReload()
                            }
                    }
                    .padding(10)
                    .background(Color.mlmRaised)
                    .cornerRadius(8)
                }
            }
            .padding(16)
            
            Divider()
                .background(Color.mlmEdge)
            
            // List of Suggestions
            if referenceTrack == nil {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .font(.system(size: 36))
                        .foregroundColor(.mlmInkMuted)
                    Text("Choose a reference track")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInkSecondary)
                    Text("Double-click a track on the right to load suggestions.")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if isLoadingSuggestions {
                VStack {
                    Spacer()
                    ProgressView("Finding suggestions…")
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if suggestions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundColor(.mlmInkMuted)
                    Text("No suggestions found")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInkSecondary)
                    Text("Adjust the temperature or remove filters.")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(suggestions, id: \.track.id) { item in
                            let track = item.track
                            let scorePercent = Int(item.score * 100)
                            
                            VStack(spacing: 0) {
                                HStack(spacing: 8) {
                                    // Play icon if playing
                                    Button {
                                        Task {
                                            let libRoot = (try? await container.configRepository?.getLibraryRoot()) ?? ""
                                            await leftPlayer.playTrack(track, libraryRoot: libRoot, mainPlayback: container.playbackViewModel)
                                        }
                                    } label: {
                                        ZStack {
                                            TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                                                .frame(width: 24, height: 24)
                                            
                                            if leftPlayer.currentTrack?.id == track.id {
                                                Color.black.opacity(0.4)
                                                    .cornerRadius(4)
                                                Image(systemName: leftPlayer.isPlaying ? "pause.fill" : "play.fill")
                                                    .font(.system(size: 9, weight: .bold))
                                                    .foregroundColor(.white)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(MLMFont.bodyBold)
                                            .foregroundColor(.mlmInk)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkSecondary)
                                            .lineLimit(1)
                                    }
                                    
                                    Spacer()
                                    
                                    // Render Purple Proposed Tags if pending thumbs up
                                    if pendingEdits[track.id!] != nil {
                                        HStack(spacing: 4) {
                                            Text(genre)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundColor(.purple)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 2)
                                                .background(
                                                    RoundedRectangle(cornerRadius: 4)
                                                        .stroke(Color.purple, lineWidth: 1)
                                                )
                                            
                                        }
                                    } else {
                                        // Score % badge
                                        Text("\(scorePercent)% Match")
                                            .font(MLMFont.mono)
                                            .font(.caption2)
                                            .foregroundColor(scorePercent > 80 ? .mlmSuccess : (scorePercent > 60 ? .mlmWarning : .mlmInkSecondary))
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.mlmRaised)
                                            .cornerRadius(4)
                                    }
                                    
                                    // Thumbs Rating Action Buttons
                                    HStack(spacing: 6) {
                                        Button {
                                            toggleThumbsUp(track: track)
                                        } label: {
                                            Image(systemName: pendingEdits[track.id!] != nil ? "hand.thumbsup.fill" : "hand.thumbsup")
                                                .foregroundColor(pendingEdits[track.id!] != nil ? .purple : .mlmInkSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Mark this genre for saving")
                                        
                                        Button {
                                            registerThumbsDown(track: track)
                                        } label: {
                                            Image(systemName: feedbackMap[track.id!] == -1 ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                                .foregroundColor(feedbackMap[track.id!] == -1 ? .mlmError : .mlmInkSecondary)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Exclude this track from suggestions")
                                    }
                                    .font(.system(size: 13))
                                    .padding(.leading, 8)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) {
                                    Task {
                                        let libRoot = (try? await container.configRepository?.getLibraryRoot()) ?? ""
                                        await leftPlayer.playTrack(track, libraryRoot: libRoot, mainPlayback: container.playbackViewModel)
                                    }
                                }
                                .contextMenu {
                                    TrackContextMenu(
                                        selectedTrackIDs: Set([track.id!]),
                                        tracks: [track],
                                        availablePlaylists: availablePlaylists,
                                        availableSyncProfiles: availableSyncProfiles,
                                        addToSyncProfile: { profile in
                                            Task {
                                                container.syncViewModel?.selectedProfile = profile
                                                await container.syncViewModel?.addTracks([track.id!])
                                            }
                                        }
                                    )
                                }
                                .background(leftPlayer.currentTrack?.id == track.id ? Color.mlmRaised : Color.clear)
                                
                                Divider()
                                    .background(Color.mlmEdgeSubtle)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Right Spalte: Known Tracks Column
    
    private var rightKnownTracksColumn: some View {
        VStack(spacing: 0) {
            // Column Title
            HStack {
                Label("Tracks in \(selectedGenre ?? "")", systemImage: "music.note.list")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)
                Spacer()
            }
            .padding(16)
            
            Divider()
                .background(Color.mlmEdge)
            
            // Reference song card slot at the top
            VStack(spacing: 0) {
                if let ref = referenceTrack {
                    HStack(spacing: 12) {
                        TrackCoverView(trackId: ref.id ?? 0, size: .small, cornerRadius: 6)
                            .frame(width: 32, height: 32)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Reference track")
                                .font(MLMFont.sectionLabel)
                                .foregroundColor(.purple)
                            
                            Text(ref.title)
                                .font(MLMFont.bodyBold)
                                .foregroundColor(.mlmInk)
                                .lineLimit(1)
                            
                            Text(ref.artist)
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                                .lineLimit(1)
                        }
                        
                        Spacer()
                        
                        Button {
                            ejectReferenceSong()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title3)
                                .foregroundColor(.mlmInkSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Remove reference track")
                        .springLoadableHover {}
                    }
                    .padding(12)
                    .background(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.08), Color.mlmActive.opacity(0.04)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.purple.opacity(0.2), lineWidth: 1.5)
                    )
                    .padding(12)
                } else {
                    HStack {
                        Spacer()
                        VStack(spacing: 4) {
                            Image(systemName: "waveform.circle")
                                .font(.title2)
                                .foregroundColor(.mlmInkMuted)
                            Text("No reference selected")
                                .font(MLMFont.sectionLabel)
                                .foregroundColor(.mlmInkSecondary)
                            Text("Double-click a track below to generate suggestions")
                                .font(.system(size: 10))
                                .foregroundColor(.mlmInkMuted)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(Color.mlmRaised)
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            .foregroundColor(Color.mlmEdge)
                    )
                    .padding(12)
                }
            }
            
            Divider()
                .background(Color.mlmEdge)
            
            // List of other tracks of the genre
            if isLoadingTracks {
                VStack {
                    Spacer()
                    ProgressView("Loading genre tracks...")
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if genreTracks.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "music.note")
                        .font(.system(size: 32))
                        .foregroundColor(.mlmInkMuted)
                    Text("No known tracks available")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInkSecondary)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(genreTracks, id: \.id) { track in
                            // Filter out if currently shown as the active reference track at the top
                            if track.id != referenceTrack?.id {
                                VStack(spacing: 0) {
                                    HStack(spacing: 12) {
                                        Button {
                                            Task {
                                                let libRoot = (try? await container.configRepository?.getLibraryRoot()) ?? ""
                                                await rightPlayer.playTrack(track, libraryRoot: libRoot, mainPlayback: container.playbackViewModel)
                                            }
                                        } label: {
                                            ZStack {
                                                TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                                                    .frame(width: 24, height: 24)
                                                
                                                if rightPlayer.currentTrack?.id == track.id {
                                                    Color.black.opacity(0.4)
                                                        .cornerRadius(4)
                                                    Image(systemName: rightPlayer.isPlaying ? "pause.fill" : "play.fill")
                                                        .font(.system(size: 9, weight: .bold))
                                                        .foregroundColor(.white)
                                                }
                                            }
                                        }
                                        .buttonStyle(.plain)
                                        
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(track.title)
                                                .font(MLMFont.bodyBold)
                                                .foregroundColor(.mlmInk)
                                                .lineLimit(1)
                                            Text(track.artist)
                                                .font(MLMFont.muted)
                                                .foregroundColor(.mlmInkSecondary)
                                                .lineLimit(1)
                                        }
                                        
                                        Spacer()
                                        
                                        Text(track.album)
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkMuted)
                                            .lineLimit(1)
                                            .frame(maxWidth: 140, alignment: .trailing)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                    .onTapGesture(count: 2) {
                                        if referenceTrack == nil {
                                            selectReferenceSong(track)
                                        } else {
                                            // Play as temporary comparison preview on right player
                                            Task {
                                                let libRoot = (try? await container.configRepository?.getLibraryRoot()) ?? ""
                                                await rightPlayer.playTrack(track, libraryRoot: libRoot, mainPlayback: container.playbackViewModel)
                                            }
                                        }
                                    }
                                    .contextMenu {
                                        TrackContextMenu(
                                            selectedTrackIDs: Set([track.id!]),
                                            tracks: [track],
                                            availablePlaylists: availablePlaylists,
                                            availableSyncProfiles: availableSyncProfiles,
                                            addToSyncProfile: { profile in
                                                Task {
                                                    container.syncViewModel?.selectedProfile = profile
                                                    await container.syncViewModel?.addTracks([track.id!])
                                                }
                                            }
                                        )
                                    }
                                    .background(rightPlayer.currentTrack?.id == track.id ? Color.mlmRaised : Color.clear)
                                    
                                    Divider()
                                        .background(Color.mlmEdgeSubtle)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Genre Merger View Panel
    
    private var genreMergerPanel: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 16) {
                Button {
                    rightPlayer.stop()
                    selectedPreviewGenre = nil
                    mergerPreviewTracks = []
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedScreen = .grid
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                    Text("Back")
                    }
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.mlmSurface)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                
                Text("Consolidate genres")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.mlmSurface)
            
            Divider()
                .background(Color.mlmEdge)
            
            VStack(alignment: .leading, spacing: 0) {
                // Top controls section (Intro text, Selection columns)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Select alternate spellings or duplicate genres and merge them into one canonical genre. Tracks update immediately in the database.")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                        .padding(.horizontal, 4)
                    
                    if let msg = mergerMessage {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                            Text(msg)
                        }
                        .foregroundColor(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.mlmSuccess)
                        .cornerRadius(8)
                    }
                    
                    if let err = mergerError {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(err)
                        }
                        .foregroundColor(.white)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.mlmError)
                        .cornerRadius(8)
                    }
                    
                    HStack(spacing: 24) {
                        // Left: Genre List Checklist
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SELECT (\(selectedForMerge.count) selected)")
                                .font(MLMFont.sectionLabel)
                                .foregroundColor(.mlmInkSecondary)
                            
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(uniqueGenres, id: \.genre) { item in
                                        let isPreviewSelected = selectedPreviewGenre == item.genre
                                        HStack(spacing: 0) {
                                            // Checkbox toggle Button
                                            Button {
                                                if selectedForMerge.contains(item.genre) {
                                                    selectedForMerge.remove(item.genre)
                                                } else {
                                                    selectedForMerge.insert(item.genre)
                                                    if targetGenreName.isEmpty {
                                                        targetGenreName = item.genre
                                                    }
                                                }
                                            } label: {
                                                Image(systemName: selectedForMerge.contains(item.genre) ? "checkmark.square.fill" : "square")
                                                    .foregroundColor(selectedForMerge.contains(item.genre) ? .mlmAccent : .mlmInkSecondary)
                                                    .font(.title3)
                                                    .padding(.leading, 12)
                                                    .padding(.trailing, 4)
                                                    .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                            
                                            // Row Button (sets selectedPreviewGenre)
                                            Button {
                                                selectedPreviewGenre = item.genre
                                                Task {
                                                    await loadMergerPreviewTracks(genre: item.genre)
                                                }
                                            } label: {
                                                HStack {
                                                    Text(item.genre)
                                                        .font(MLMFont.bodyBold)
                                                        .foregroundColor(.mlmInk)
                                                    
                                                    Spacer()
                                                    
                                                    Text("\(item.count) Songs")
                                                        .font(MLMFont.muted)
                                                        .foregroundColor(isPreviewSelected ? .mlmAccent : .mlmInkMuted)
                                                }
                                                .padding(.vertical, 8)
                                                .padding(.trailing, 12)
                                                .padding(.leading, 8)
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .background(isPreviewSelected ? Color.mlmAccent.opacity(0.08) : Color.clear)
                                        
                                        Divider()
                                            .background(Color.mlmEdgeSubtle)
                                    }
                                }
                            }
                            .frame(height: 200) // Keep the genre checklist relatively short so the song list has space!
                            .background(Color.mlmSurface)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.mlmEdge, lineWidth: 1)
                            )
                        }
                        .frame(maxWidth: .infinity)
                        
                        // Right: Target Input & Action
                        VStack(alignment: .leading, spacing: 12) {
                            Text("MERGE")
                                .font(MLMFont.sectionLabel)
                                .foregroundColor(.mlmInkSecondary)
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Neuer kanonischer Genre-Name:")
                                    .font(MLMFont.bodyBold)
                                    .foregroundColor(.mlmInk)
                                
                                TextField("z.B. Hip Hop & Rap", text: $targetGenreName)
                                    .textFieldStyle(.roundedBorder)
                                    .font(MLMFont.body)
                                    .frame(maxWidth: .infinity)
                            }
                            .padding(14)
                            .background(Color.mlmSurface)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.mlmEdge, lineWidth: 1)
                            )
                            
                            Button {
                                Task { await executeMergeGenres() }
                            } label: {
                                HStack {
                                    Image(systemName: "circle.grid.3x3.fill")
                                    Text("Merge selected genres")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .background(selectedForMerge.count < 2 || targetGenreName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Color.gray : Color.mlmAccent)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(selectedForMerge.count < 2 || targetGenreName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 200) // Keep right frame aligned
                    }
                }
                .padding(20)
                
                Divider()
                    .background(Color.mlmEdge)
                
                // Bottom section: Song list for preview
                VStack(spacing: 0) {
                    if let genre = selectedPreviewGenre {
                        HStack {
                            Text("Tracks in \"\(genre)\" (showing \(mergerPreviewTracks.count) of 50)")
                                .font(MLMFont.sectionHeader)
                                .foregroundColor(.mlmInk)
                            
                            Spacer()
                            
                            Text("Double-click to preview")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.mlmSurface)
                        
                        Divider()
                            .background(Color.mlmEdge)
                        
                        if isLoadingPreviewTracks {
                            VStack {
                                Spacer()
                                ProgressView("Loading tracks…")
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.mlmBase)
                        } else if mergerPreviewTracks.isEmpty {
                            VStack {
                                Spacer()
                                Text("No tracks found in this genre.")
                                    .font(MLMFont.body)
                                    .foregroundColor(.mlmInkMuted)
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.mlmBase)
                        } else {
                            Table(selection: $selectedMergerTrackIDs, sortOrder: $previewTracksSortOrder) {
                                TableColumn("Title", value: \.track.title) { row in
                                    let track = row.track
                                    HStack(spacing: 8) {
                                        TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                                            .frame(width: 18, height: 18)
                                        
                                        if isNowPlaying(track) {
                                            Image(systemName: "speaker.wave.2.fill")
                                                .imageScale(.small)
                                                .foregroundStyle(Color.accentColor)
                                                .symbolEffect(.variableColor, isActive: true)
                                        }
                                        
                                        Text(track.title).lineLimit(1)
                                    }
                                }
                                .width(min: 160, ideal: 260)
                                
                                TableColumn("Artist", value: \.track.artist) { row in
                                    Text(row.track.artist).lineLimit(1)
                                }
                                .width(min: 100, ideal: 180)
                                
                                TableColumn("Album", value: \.track.album) { row in
                                    Text(row.track.album).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .width(min: 100, ideal: 180)
                                
                                TableColumn("Time", value: \.track.durationSortKey) { row in
                                    Text(row.track.formattedDuration)
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .width(54)
                                
                                TableColumn("Format", value: \.track.format) { row in
                                    Text(row.track.format.uppercased())
                                        .foregroundStyle(.secondary)
                                }
                                .width(60)
                            } rows: {
                                ForEach(sortedPreviewTracks) { row in
                                    TableRow(row)
                                }
                            }
                            .contextMenu(forSelectionType: Int64.self) { selectedIDs in
                                TrackContextMenu(
                                    selectedTrackIDs: selectedIDs,
                                    tracks: mergerPreviewTracks,
                                    availablePlaylists: availablePlaylists,
                                    availableSyncProfiles: availableSyncProfiles,
                                    addToSyncProfile: { profile in
                                        Task {
                                            container.syncViewModel?.selectedProfile = profile
                                            await container.syncViewModel?.addTracks(Array(selectedIDs))
                                        }
                                    }
                                )
                            } primaryAction: { selectedIDs in
                                if let trackID = selectedIDs.first,
                                   let track = mergerPreviewTracks.first(where: { $0.id == trackID }) {
                                    if let playbackVM = container.playbackViewModel {
                                        Task {
                                            await playbackVM.playTrack(track)
                                        }
                                    }
                                }
                            }
                            .background(Color.mlmBase)
                        }
                    } else {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundColor(.mlmInkMuted)
                            Text("Choose a genre from the list")
                                .font(MLMFont.sectionHeader)
                                .foregroundColor(.mlmInkSecondary)
                            Text("Select a genre above to review up to 50 tracks before merging.")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 40)
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.mlmBase)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
    
    // MARK: - CreateML Exporter View Panel
    
    private var createMLExporterPanel: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 16) {
                Button {
                    cancelExport()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedScreen = .grid
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Back")
                    }
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmAccent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.mlmSurface)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isExporting)
                
                Text("Export CreateML training set")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)
                
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.mlmSurface)
            
            Divider()
                .background(Color.mlmEdge)
            
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Export tracks with genres into a flat folder structure. FFmpeg converts each track to **AAC 248 kbps (.m4a)**, ready to load into **Apple Create ML** for training a SoundClassifier model.")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                        .padding(.horizontal, 4)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        let eligibleGenres = uniqueGenres.filter { $0.count >= 50 }
                        let eligibleTracksCount = eligibleGenres.reduce(0) { $0 + $1.count }
                        let excludedGenres = uniqueGenres.filter { $0.count < 50 }
                        let excludedTracksCount = excludedGenres.reduce(0) { $0 + $1.count }
                        
                        // Summary of items with dual-cards for Eligible and Excluded sets
                        HStack(alignment: .top, spacing: 16) {
                            // Primary Export Card (>= 10 tracks)
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.green)
                                        .font(.system(size: 14, weight: .bold))
                                    Text("READY FOR EXPORT (≥ 50 tracks)")
                                        .font(MLMFont.sectionLabel)
                                        .foregroundColor(.mlmInkSecondary)
                                }
                                
                                HStack(spacing: 24) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Tracks:")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkSecondary)
                                        Text("\(eligibleTracksCount)")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(.mlmInk)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Genres:")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkSecondary)
                                        Text("\(eligibleGenres.count)")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(.mlmInk)
                                    }
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.mlmSurface)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.mlmEdge, lineWidth: 1)
                            )
                            
                            // Excluded Card (< 10 tracks)
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .foregroundColor(.orange)
                                        .font(.system(size: 14, weight: .bold))
                                    Text("EXCLUDED (< 50 tracks)")
                                        .font(MLMFont.sectionLabel)
                                        .foregroundColor(.mlmInkSecondary)
                                }
                                
                                HStack(spacing: 24) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Tracks:")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkSecondary)
                                        Text("\(excludedTracksCount)")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(.mlmInkMuted)
                                    }
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Genres:")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkSecondary)
                                        Text("\(excludedGenres.count)")
                                            .font(.system(size: 22, weight: .bold))
                                            .foregroundColor(.mlmInkMuted)
                                    }
                                }
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.mlmSurface)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.mlmEdge, lineWidth: 1)
                            )
                        }
                        
                        // Format Badge
                        HStack(spacing: 12) {
                            Text("Target format:")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                            Text("AAC 248kbps (.m4a)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(.purple)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.purple.opacity(0.1))
                                .cornerRadius(4)
                            
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        
                        // Detailed information of Excluded Genres
                        if !excludedGenres.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        showExcludedGenres.toggle()
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: showExcludedGenres ? "chevron.down" : "chevron.right")
                                            .font(.system(size: 10, weight: .bold))
                                        Text("Show excluded genres (\(excludedGenres.count))")
                                            .font(MLMFont.bodyBold)
                                        Spacer()
                                    }
                                    .foregroundColor(.mlmInkSecondary)
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                                
                                if showExcludedGenres {
                                    Text("These genres have fewer than 50 tracks and are excluded from training. Use Consolidate genres to merge them.")
                                        .font(MLMFont.muted)
                                        .foregroundColor(.mlmInkSecondary)
                                        .padding(.bottom, 4)
                                    
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 8) {
                                            ForEach(excludedGenres, id: \.genre) { item in
                                                HStack(spacing: 6) {
                                                    Text(item.genre)
                                                        .font(MLMFont.body)
                                                        .foregroundColor(.mlmInk)
                                                    Text("\(item.count)")
                                                        .font(MLMFont.muted)
                                                        .foregroundColor(.white)
                                                        .padding(.horizontal, 6)
                                                        .padding(.vertical, 2)
                                                        .background(Color.orange)
                                                        .clipShape(Capsule())
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 6)
                                                .background(Color.mlmSurface)
                                                .cornerRadius(6)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 6)
                                                        .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                                                )
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                            .padding(16)
                            .background(Color.mlmSurface.opacity(0.5))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                            )
                        }
                        
                        // Select folder card
                        VStack(alignment: .leading, spacing: 12) {
                            Text("TRAINING SET DESTINATION:")
                                .font(MLMFont.sectionLabel)
                                .foregroundColor(.mlmInkSecondary)
                            
                            HStack(spacing: 12) {
                                Button {
                                    chooseExportFolder()
                                } label: {
                                    HStack {
                                        Image(systemName: "folder.badge.plus")
                                        Text("Choose destination…")
                                    }
                                    .font(MLMFont.bodyBold)
                                    .foregroundColor(.mlmAccent)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.mlmBase)
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.mlmEdge, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                                .disabled(isExporting)
                                
                                if let url = exportFolderURL {
                                    Text(url.path)
                                        .font(MLMFont.mono)
                                        .font(.caption)
                                        .foregroundColor(.mlmInk)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text("No folder selected")
                                        .font(MLMFont.body)
                                        .foregroundColor(.mlmInkMuted)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color.mlmSurface)
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.mlmEdge, lineWidth: 1)
                        )
                        
                        // Exporter Progress / Button
                        if isExporting {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(exportProgressText)
                                    .font(MLMFont.bodyBold)
                                    .foregroundColor(.mlmInk)
                                
                                ProgressView(value: exportProgress, total: 1.0)
                                    .progressViewStyle(.linear)
                                
                                Button {
                                    cancelExport()
                                } label: {
                                    HStack {
                                        Image(systemName: "xmark.circle")
                                        Text("Cancel export")
                                    }
                                    .font(MLMFont.bodyBold)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.mlmError)
                                    .cornerRadius(6)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(16)
                            .background(Color.mlmSurface)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.mlmEdge, lineWidth: 1)
                            )
                        } else {
                            Button {
                                startCreateMLExport()
                            } label: {
                                HStack {
                                    Image(systemName: "play.fill")
                                    Text("Start export")
                                }
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 12)
                                .background(exportFolderURL == nil ? Color.gray : Color.mlmAccent)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                            .disabled(exportFolderURL == nil)
                        }
                    }
                }
                .padding(24)
            }
        }
    }
    
    // MARK: - Actions & Logic
    
    private func loadUniqueGenres() async {
        guard let trackRepo = container.trackRepository else { return }
        isLoadingGenres = true
        do {
            let list = try await trackRepo.fetchUniqueGenres()
            await MainActor.run {
                self.uniqueGenres = list
                self.isLoadingGenres = false
            }
        } catch {
            print("Failed to load unique genres: \(error)")
            await MainActor.run {
                self.isLoadingGenres = false
            }
        }
    }
    
    private func loadPlaylistsAndSyncProfiles() async {
        availablePlaylists = (try? await container.playlistRepository?.fetchAll()) ?? []
        if let syncVM = container.syncViewModel {
            if syncVM.profiles.isEmpty {
                await syncVM.loadProfiles()
            }
            availableSyncProfiles = syncVM.profiles
        }
    }
    private func loadMergerPreviewTracks(genre: String) async {
        guard let trackRepo = container.trackRepository else { return }
        await MainActor.run {
            self.isLoadingPreviewTracks = true
        }
        do {
            let list = try await trackRepo.fetchTracks(genre: genre)
            let trimmedList = Array(list.prefix(50))
            await MainActor.run {
                self.mergerPreviewTracks = trimmedList
                self.isLoadingPreviewTracks = false
            }
        } catch {
            print("Failed to load preview tracks for genre \(genre): \(error)")
            await MainActor.run {
                self.isLoadingPreviewTracks = false
            }
        }
    }
    
    private func loadTracksForGenre(_ genre: String) async {
        guard let trackRepo = container.trackRepository else { return }
        isLoadingTracks = true
        do {
            let list = try await trackRepo.fetchTracks(genre: genre)
            await MainActor.run {
                self.genreTracks = list
                self.isLoadingTracks = false
            }
        } catch {
            print("Failed to load tracks for genre \(genre): \(error)")
            await MainActor.run {
                self.isLoadingTracks = false
            }
        }
    }
    
    private func selectReferenceSong(_ track: Track) {
        referenceTrack = track
        // Automatically start playing reference on right player
        Task {
            let libRoot = (try? await container.configRepository?.getLibraryRoot()) ?? ""
            await rightPlayer.playTrack(track, libraryRoot: libRoot, mainPlayback: container.playbackViewModel)
            await loadSuggestions(for: track)
        }
    }
    
    private func ejectReferenceSong() {
        referenceTrack = nil
        rightPlayer.stop()
        suggestions = []
    }
    
    private func triggerSuggestionsReload() {
        guard let ref = referenceTrack else { return }
        Task {
            await loadSuggestions(for: ref)
        }
    }
    
    private func loadSuggestions(for seedTrack: Track) async {
        guard let trackRepo = container.trackRepository, let seedId = seedTrack.id else { return }
        isLoadingSuggestions = true
        do {
            // Load similar tracks from repository with temperature variance
            let rawList = try await trackRepo.fetchSimilarTracks(
                seedTrackId: seedId,
                limit: suggestionLimit + 40, // Fetch a larger buffer to filter correctly
                temperature: temperature
            )
            
            // Filter list in Swift:
            // 1. Exclude tracks that already have the selected genre (since they appear on the right)
            // 2. If 'onlyUntaggedSuggestions' is checked, exclude tracks that have any non-blank genre
            var filtered = rawList.filter { item in
                let track = item.track
                
                // Exclude active genre
                if let trackGenre = track.genre, !trackGenre.isEmpty {
                    if trackGenre.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) ==
                       selectedGenre?.lowercased().trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) {
                        return false
                    }
                    
                    // Exclude any genre if only untagged requested
                    if onlyUntaggedSuggestions {
                        return false
                    }
                }
                
                return true
            }
            
            // Take requested limit (10 or 20)
            filtered = Array(filtered.prefix(suggestionLimit))
            
            // Fetch similarity feedback to display thumbs state correctly
            let feedbackRows = (try? await trackRepo.fetchSimilarityFeedback(seedTrackId: seedId)) ?? []
            let feedMap = Dictionary(uniqueKeysWithValues: feedbackRows.map { ($0.targetTrackId, $0.feedbackValue) })
            
            await MainActor.run {
                self.suggestions = filtered
                self.feedbackMap = feedMap
                self.isLoadingSuggestions = false
            }
        } catch {
            print("Failed to load suggestions: \(error)")
            await MainActor.run {
                self.isLoadingSuggestions = false
            }
        }
    }
    
    // MARK: - Thumbs Interactions
    
    private func toggleThumbsUp(track: Track) {
        guard let trackId = track.id, let genre = selectedGenre else { return }
        
        if pendingEdits[trackId] != nil {
            // Remove pending
            pendingEdits.removeValue(forKey: trackId)
        } else {
            // Add to pending
            pendingEdits[trackId] = PendingEdit(
                trackId: trackId,
                title: track.title,
                artist: track.artist,
                genre: genre,
                mixCategory: nil
            )
        }
    }
    
    private func registerThumbsDown(track: Track) {
        guard let seedId = referenceTrack?.id, let targetId = track.id, let trackRepo = container.trackRepository else { return }
        
        // Remove from pending thumbs up if exists
        pendingEdits.removeValue(forKey: targetId)
        
        Task {
            do {
                // Save negative similarity feedback immediately in DB (excludes it from candidate list)
                try await trackRepo.saveSimilarityFeedback(seedTrackId: seedId, targetTrackId: targetId, feedbackValue: -1)
                
                await MainActor.run {
                    feedbackMap[targetId] = -1
                    
                    // Snappy UI: remove the track from recommendations instantly with animation
                    withAnimation(.easeInOut(duration: 0.2)) {
                        suggestions.removeAll(where: { $0.track.id == targetId })
                    }
                }
                
                // Fetch next replacement track to keep limit satisfied (10 or 20)
                if let ref = referenceTrack {
                    await loadSuggestions(for: ref)
                }
            } catch {
                print("Failed to save negative feedback: \(error)")
            }
        }
    }
    
    // MARK: - Save Batch
    
    private func savePendingEdits() async {
        guard let trackRepo = container.trackRepository, !pendingEdits.isEmpty else { return }
        
        let editsToProcess = Array(pendingEdits.values)
        let count = editsToProcess.count
        
        do {
            for edit in editsToProcess {
                // 1. Update track genre in the tracks table
                if var track = try await trackRepo.fetchTrack(id: edit.trackId) {
                    track.genre = edit.genre
                    try await trackRepo.update(track)
                }
                
                // 2. Update mix category in track_embeddings table
                try await trackRepo.updateMixCategory(trackId: edit.trackId, mixCategory: edit.mixCategory)
                
                // 3. Register positive similarity feedback
                if let seedId = referenceTrack?.id {
                    try await trackRepo.saveSimilarityFeedback(seedTrackId: seedId, targetTrackId: edit.trackId, feedbackValue: 1)
                }
            }
            
            // Post notification to let all libraries reload tags in lists
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            
            await MainActor.run {
                pendingEdits = [:]
                saveMessage = "\(count) track\(count == 1 ? "" : "s") tagged and saved."
                
                // Reset save success message after 4 seconds
                saveMessageTimer?.invalidate()
                saveMessageTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { _ in
                    saveMessage = nil
                }
            }
            
            // Refresh right and left lists to show the newly tagged songs on the right column!
            if let genre = selectedGenre {
                await loadTracksForGenre(genre)
            }
            if let ref = referenceTrack {
                await loadSuggestions(for: ref)
            }
            
        } catch {
            print("Failed to save pending edits: \(error)")
            await MainActor.run {
                saveMessage = "Could not save changes."
            }
        }
    }
    
    // MARK: - Genre Merger Execution
    
    private func executeMergeGenres() async {
        guard let trackRepo = container.trackRepository, !selectedForMerge.isEmpty else { return }
        let targetClean = targetGenreName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetClean.isEmpty else {
            mergerError = "The target genre name cannot be empty."
            return
        }
        
        isLoadingGenres = true
        mergerMessage = nil
        mergerError = nil
        
        do {
            // Execute Database Merge
            try await trackRepo.mergeGenres(sources: Array(selectedForMerge), target: targetClean)
            
            // Post notification to refresh library lists
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)
            
            // Reload unique genres
            let list = try await trackRepo.fetchUniqueGenres()
            
            await MainActor.run {
                self.uniqueGenres = list
                self.selectedForMerge = []
                self.targetGenreName = ""
                self.isLoadingGenres = false
                self.mergerMessage = "Genres merged into '\(targetClean)'."
            }
        } catch {
            print("Failed to merge genres: \(error)")
            await MainActor.run {
                self.isLoadingGenres = false
                self.mergerError = "Could not merge genres: \(error.localizedDescription)"
            }
        }
    }
    
    // MARK: - CreateML Exporter Execution
    
    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Choose a destination folder for the CreateML training set"
        panel.prompt = "Choose folder"
        if panel.runModal() == .OK, let url = panel.url {
            self.exportFolderURL = url
        }
    }
    
    private func startCreateMLExport() {
        let container = self.container
        guard let destURL = exportFolderURL, let trackRepo = container.trackRepository else { return }
        
        let transcodeCache = container.transcodeCache
        let configRepository = container.configRepository
        let backgroundProcessing = container.syncViewModel?.syncService.syncTurboLevel ?? .standard
        
        isExporting = true
        exportProgress = 0.0
        exportProgressText = "Loading tracks from the library..."
        exportCancelRequested = false
        
        exportTask = Task { [transcodeCache, configRepository, backgroundProcessing] in
            let activityVM = container.activityViewModel
            var operationId: UUID? = nil
            
            do {
                // 1. Fetch all tracks with genre
                let allTracks = try await trackRepo.fetchTracksWithGenre()
                
                // Group tracks by genre to construct a frequency map
                var genreCounts: [String: Int] = [:]
                for track in allTracks {
                    if let genre = track.genre?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !genre.isEmpty {
                        genreCounts[genre, default: 0] += 1
                    }
                }
                
                // Filter to keep only tracks belonging to genres with at least 50 songs
                let tracks = allTracks.filter { track in
                    guard let genre = track.genre?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !genre.isEmpty else {
                        return false
                    }
                    return (genreCounts[genre] ?? 0) >= 50
                }
                let total = tracks.count
                
                if total == 0 {
                    await MainActor.run {
                        self.isExporting = false
                        self.exportProgressText = "No tracks with genres found. At least 50 tracks per genre are required."
                    }
                    return
                }
                
                // Start background operation
                operationId = activityVM?.startOperation(
                    type: .createMLExport,
                    title: "CreateML Export: \(destURL.lastPathComponent)",
                    detail: "Starting export of \(total) tracks..."
                )
                AppLogger.shared.info("CreateML: Starting export of \(total) tracks to \(destURL.lastPathComponent)", source: "CreateML")
                
                // 2. Loop and transcode/copy concurrently
                let workerCount = backgroundProcessing.workerCount()
                let limiter = ConcurrencyLimiter(maxConcurrency: workerCount)
                
                await withTaskGroup(of: Void.self) { group in
                    for track in tracks {
                        group.addTask {
                            guard !Task.isCancelled else { return }
                            
                            await limiter.run {
                                guard !Task.isCancelled else { return }
                                
                                guard let genre = track.genre?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines), !genre.isEmpty else {
                                    return
                                }
                                
                                let cleanGenre = GrooveStudioView.sanitizeFilename(genre)
                                let genreDir = destURL.appendingPathComponent(cleanGenre)
                                
                                // Create genre directory
                                do {
                                    try FileManager.default.createDirectory(at: genreDir, withIntermediateDirectories: true)
                                } catch {
                                    AppLogger.shared.error("CreateML: Could not create genre folder '\(cleanGenre)': \(error.localizedDescription)", source: "CreateML")
                                    return
                                }
                                
                                // Resolve source path on disk
                                guard let sourceURL = await self.resolveLocalURL(for: track) else {
                                    AppLogger.shared.warn("CreateML: Source file missing for track: \(track.artist) - \(track.title)", source: "CreateML")
                                    return
                                }
                                
                                // Name output file flat: [Artist] - [Title].m4a
                                let cleanArtist = GrooveStudioView.sanitizeFilename(track.artist)
                                let cleanTitle = GrooveStudioView.sanitizeFilename(track.title)
                                let outputName = "\(cleanArtist) - \(cleanTitle).m4a"
                                let targetFile = genreDir.appendingPathComponent(outputName)
                                
                                // 1. Attempt to use transcode cache to ensure cached and then copy
                                var transcodeSuccess = false
                                if let transcodeCache {
                                    do {
                                        let libraryRoot = try? await configRepository?.getLibraryRoot()
                                        if let cachedURL = try await transcodeCache.ensureCached(track: track, bitrateKbps: 248, libraryRoot: libraryRoot) {
                                            // Attempt hardlink first (same volume, instant, 0 byte copy), fallback to copy if cross-volume
                                            try? FileManager.default.removeItem(at: targetFile)
                                            do {
                                                try FileManager.default.linkItem(at: cachedURL, to: targetFile)
                                                transcodeSuccess = true
                                                AppLogger.shared.debug("CreateML: Created hard link from transcode cache: \(track.artist) - \(track.title)", source: "CreateML")
                                            } catch {
                                                try FileManager.default.copyItem(at: cachedURL, to: targetFile)
                                                transcodeSuccess = true
                                                AppLogger.shared.debug("CreateML: Copied track from transcode cache: \(track.artist) - \(track.title)", source: "CreateML")
                                            }
                                        }
                                    } catch {
                                        AppLogger.shared.warn("CreateML: Cache or copy error for \(track.artist) - \(track.title): \(error.localizedDescription)", source: "CreateML")
                                    }
                                }
                                
                                // 2. Fallback to direct transcode if cache is unavailable or failed
                                if !transcodeSuccess {
                                    do {
                                        let result = try await self.transcodeService.transcode(
                                            input: sourceURL,
                                            outputDir: genreDir,
                                            outputName: outputName,
                                            bitrateKbps: 248
                                        )
                                        
                                        switch result {
                                        case .transcoded:
                                            AppLogger.shared.debug("CreateML: Transcoded track directly: \(track.artist) - \(track.title)", source: "CreateML")
                                            break
                                        case .skipped:
                                            if !FileManager.default.fileExists(atPath: targetFile.path) {
                                                try? FileManager.default.copyItem(at: sourceURL, to: targetFile)
                                                AppLogger.shared.debug("CreateML: Copied track directly: \(track.artist) - \(track.title)", source: "CreateML")
                                            }
                                        case .failed:
                                            if !FileManager.default.fileExists(atPath: targetFile.path) {
                                                try? FileManager.default.copyItem(at: sourceURL, to: targetFile)
                                                AppLogger.shared.warn("CreateML: Transcode failed; copied fallback for: \(track.artist) - \(track.title)", source: "CreateML")
                                            }
                                        }
                                    } catch {
                                        // Fallback copy on any error
                                        if !FileManager.default.fileExists(atPath: targetFile.path) {
                                            try? FileManager.default.copyItem(at: sourceURL, to: targetFile)
                                            AppLogger.shared.warn("CreateML: Transcode failed; copied fallback for: \(track.artist) - \(track.title): \(error.localizedDescription)", source: "CreateML")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    var completedCount = 0
                    for await _ in group {
                        completedCount += 1
                        let currentProgress = Double(completedCount) / Double(total)
                        let text = "[\(completedCount)/\(total)] Exporting tracks (\(Int(currentProgress * 100))%)..."
                        
                        await MainActor.run {
                            self.exportProgress = currentProgress
                            self.exportProgressText = text
                        }
                        
                        // Update background operation
                        if let opId = operationId {
                            activityVM?.updateProgress(id: opId, progress: currentProgress, detail: "[\(completedCount)/\(total)] tracks exported...")
                        }
                    }
                }
                
                await MainActor.run {
                    self.isExporting = false
                    if exportCancelRequested {
                        self.exportProgressText = "Export cancelled."
                        self.exportProgress = 0.0
                        if let opId = operationId {
                            activityVM?.failOperation(id: opId, error: "Cancelled by user")
                        }
                        AppLogger.shared.info("CreateML: Export cancelled.", source: "CreateML")
                    } else {
                        self.exportProgressText = "Exported \(total) tracks into genre folders."
                        self.exportProgress = 1.0
                        if let opId = operationId {
                            activityVM?.completeOperation(id: opId, detail: "\(total) tracks exported")
                        }
                        AppLogger.shared.info("CreateML: Export complete. \(total) tracks exported to '\(destURL.lastPathComponent)'.", source: "CreateML")
                    }
                }
                
            } catch {
                AppLogger.shared.error("CreateML: Export failed: \(error.localizedDescription)", source: "CreateML")
                if let opId = operationId {
                    activityVM?.failOperation(id: opId, error: error.localizedDescription)
                }
                await MainActor.run {
                    self.isExporting = false
                    self.exportProgressText = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }
    
    private func cancelExport() {
        exportCancelRequested = true
        exportTask?.cancel()
        exportTask = nil
    }
    
    // MARK: - Helpers
    
    private func resolveLocalURL(for track: Track) async -> URL? {
        let root = (try? await container.configRepository?.getLibraryRoot()) ?? nil
        if let root, let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        // Fallback: original_path
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }
    
    nonisolated private static func sanitizeFilename(_ input: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "\\/:*?\"<>|")
        return input.components(separatedBy: invalidCharacters).joined(separator: "_")
    }
}
