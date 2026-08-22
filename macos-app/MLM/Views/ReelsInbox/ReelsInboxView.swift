import SwiftUI
import AVKit
import AVFoundation
import ShazamKit
import Vision

struct KeyframeData: Identifiable, Hashable {
    let id = UUID()
    let offset: TimeInterval
    let image: NSImage
    var recognizedTexts: [String] = []
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(offset)
    }
    
    static func == (lhs: KeyframeData, rhs: KeyframeData) -> Bool {
        return lhs.id == rhs.id && lhs.offset == rhs.offset
    }
}

struct OcrSongCandidate: Hashable, Identifiable {
    let id = UUID()
    let artist: String
    let title: String
    
    var displayString: String {
        return "\(artist) - \(title)"
    }
}

struct ImportedReel: Identifiable, Hashable {
    let id: UUID
    let fileURL: URL
    var title: String
    var artist: String
    
    // Shazam matching results
    var matchedTitle: String? = nil
    var matchedArtist: String? = nil
    var matchOffset: TimeInterval? = nil
    var matchFailed: Bool = false
    
    // OCR results
    var recognizedTexts: [String]? = nil
    var keyframes: [KeyframeData]? = nil
    var isOcrRunning: Bool = false
}

struct ReelsInboxView: View {
    @Environment(\.container) private var container
    
    @State private var importedReels: [ImportedReel] = []
    @State private var selectedReel: ImportedReel? = nil
    @State private var avPlayer = AVPlayer()
    
    // Form fields
    @State private var artistInput: String = ""
    @State private var titleInput: String = ""
    
    // Search state
    @State private var isSearching = false
    @State private var searchResults: UnifiedSearchResults? = nil
    @State private var playlists: [Playlist] = []
    @State private var previewLoadingTrackId: String? = nil
    
    // Expandability & Match state
    @State private var matchingReelId: UUID? = nil
    
    // Drag and drop state
    @State private var isDraggingOver = false
    
    // Active search task to support cancellation and prevent overlapping/rate-limits
    @State private var searchTask: Task<Void, Never>? = nil
    
    // For visual keyframe preview sheet/modal
    @State private var expandedKeyframe: KeyframeData? = nil
    
    // Custom manual search query input
    @State private var customSearchQuery: String = ""
    
    var body: some View {
        HSplitView {
            // Left Panel: Reels list
            leftSidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 350)
                .frame(maxHeight: .infinity)
                .background(Color.mlmSurface)
            
            // Right Panel: Player & Search results
            mainContent
                .frame(minWidth: 500, idealWidth: 700)
                .frame(maxHeight: .infinity)
                .background(Color.mlmBase)
        }
        .onDrop(of: ["public.file-url"], isTargeted: $isDraggingOver) { providers in
            handleDrop(providers: providers)
        }
        .task {
            await loadImportedReels()
            await loadPlaylists()
        }
        .sheet(item: $expandedKeyframe) { kf in
            ExpandedKeyframeView(
                keyframe: kf,
                allTexts: selectedReel?.recognizedTexts ?? []
            ) { artist in
                artistInput = artist
                updateSelectedReelMetadata()
            } onApplyTitle: { title in
                titleInput = title
                updateSelectedReelMetadata()
            } onApplyBoth: { both in
                if let selected = selectedReel {
                    applySmartMetadata(both, for: selected)
                }
            }
        }
    }
    
    // MARK: - Left Sidebar: Reels List
    private var leftSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Reels Inbox")
                    .font(MLMFont.pageTitle)
                    .foregroundColor(.mlmInk)
                
                Spacer()
                
                Button(action: selectFolder) {
                    Label("Import", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .help("Select folder containing reels")
            }
            .padding()
            
            Divider()
            
            if importedReels.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "play.rectangle.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(.mlmInkMuted)
                    
                    Text("No Reels Imported")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInk)
                    
                    Text("Drag and drop .mp4 or .mov files here, or click Import to load a folder.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    
                    Button("Select Folder") {
                        selectFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(isDraggingOver ? Color.mlmAccent.opacity(0.1) : Color.clear)
            } else {
                List(selection: $selectedReel) {
                    ForEach(importedReels) { reel in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Image(systemName: "video.fill")
                                    .foregroundColor(.mlmInkSecondary)
                                    .frame(width: 32, height: 32)
                                    .background(Color.mlmRaised)
                                    .cornerRadius(6)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reel.fileURL.lastPathComponent)
                                        .font(MLMFont.bodyBold)
                                        .lineLimit(1)
                                        .foregroundColor(.mlmInk)
                                    
                                    if !reel.artist.isEmpty || !reel.title.isEmpty {
                                        Text("\(reel.artist) - \(reel.title)")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkSecondary)
                                            .lineLimit(1)
                                    } else {
                                        Text("Not parsed")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkMuted)
                                    }
                                }
                                
                                Spacer()
                                
                                if matchingReelId == reel.id {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedReel = reel
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(reel)
                    }
                    .onDelete(perform: deleteReels)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedReel) { _, newValue in
                    if let reel = newValue {
                        loadReel(reel)
                    }
                }
            }
        }
    }
    
    // MARK: - Main Content Area
    private var mainContent: some View {
        ScrollView {
            VStack(spacing: 24) {
                if let reel = selectedReel {
                    // Video player & Metadata input side-by-side
                    HStack(alignment: .top, spacing: 20) {
                        // Premium video player container
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Reel Preview")
                                .font(MLMFont.sectionLabel)
                                .foregroundColor(.mlmInkMuted)
                            
                            VideoPlayer(player: avPlayer)
                                .frame(height: 240)
                                .cornerRadius(12)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.mlmEdge, lineWidth: 1)
                                )
                                .shadow(radius: 8)
                        }
                        .frame(width: 180)
                        
                        // Form fields
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Music Identification")
                                .font(MLMFont.sectionLabel)
                                .foregroundColor(.mlmInkMuted)
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Search and download")
                                    .font(MLMFont.bodyBold)
                                    .foregroundColor(.mlmInk)
                                
                                HStack {
                                    TextField("Artist, title, or another search term", text: $customSearchQuery, onCommit: triggerSearch)
                                        .textFieldStyle(.roundedBorder)
                                        .font(MLMFont.body)
                                    
                                    Button(action: triggerSearch) {
                                        Image(systemName: "magnifyingglass.fill")
                                            .foregroundColor(.mlmAccent)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.bottom, 4)
                            
                            Divider()
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Artist")
                                    .font(MLMFont.muted)
                                    .foregroundColor(.mlmInkSecondary)
                                TextField("e.g. Drake", text: $artistInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(MLMFont.body)
                                    .onChange(of: artistInput) { _, _ in
                                        updateSelectedReelMetadata()
                                    }
                            }
                            
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Song Title")
                                    .font(MLMFont.muted)
                                    .foregroundColor(.mlmInkSecondary)
                                TextField("e.g. Hotline Bling", text: $titleInput)
                                    .textFieldStyle(.roundedBorder)
                                    .font(MLMFont.body)
                                    .onChange(of: titleInput) { _, _ in
                                        updateSelectedReelMetadata()
                                    }
                            }
                            
                            Button(action: triggerSearch) {
                                HStack {
                                    if isSearching {
                                        ProgressView()
                                            .controlSize(.small)
                                            .padding(.trailing, 4)
                                    } else {
                                        Image(systemName: "magnifyingglass.circle.fill")
                                    }
                                    Text("Search & download")
                                        .font(MLMFont.bodyBold)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(artistInput.isEmpty && titleInput.isEmpty)
                            .padding(.top, 8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding()
                    .background(Color.mlmSurface)
                    .cornerRadius(16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                    )
                    .padding(.horizontal)
                    
                    ocrAnalysisSection(for: reel)
                        .padding(.horizontal)
                    
                    // Unified Search Section
                    unifiedSearchPanel
                } else {
                    // Empty state for Main Content
                    VStack(spacing: 16) {
                        Image(systemName: "play.rectangle.on.rectangle.fill")
                            .font(.system(size: 64))
                            .foregroundColor(.mlmInkMuted)
                        
                        Text("Select a Reel")
                            .font(MLMFont.pageTitle)
                            .foregroundColor(.mlmInk)
                        
                        Text("Choose an imported Instagram Reel from the sidebar to identify and download its music.")
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInkSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.top, 100)
                }
            }
            .padding(.vertical)
        }
    }
    
    // MARK: - Unified Search Results Panel
    private var unifiedSearchPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Unified Search Results")
                    .font(MLMFont.sectionHeader)
                    .foregroundColor(.mlmInk)
                
                Spacer()
                
                if isSearching {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal)
            
            if searchResults == nil {
                VStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 32))
                        .foregroundColor(.mlmInkMuted)
                    
                    Text(isSearching ? "Searching sources..." : "No results yet")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .background(Color.mlmSurface)
                .cornerRadius(12)
                .padding(.horizontal)
            } else {
                VStack(spacing: 20) {
                    // 1. DABmusic Section
                    if let dabTracks = searchResults?.dabTracks, !dabTracks.isEmpty {
                        sourceSection(
                            title: "DABmusic",
                            icon: "opticaldisc.fill",
                            color: .blue,
                            tracks: dabTracks,
                            rowView: { track in
                                searchResultRow(
                                    id: "dab-\(track.id)",
                                    title: track.title,
                                    artist: track.artist,
                                    duration: track.duration.map { TimeInterval($0) },
                                    onPreview: { await resolveAndPlayDab(track) },
                                    onDownload: { await downloadDabTrack(track) },
                                    onAddToPlaylist: { playlist in await addDabToPlaylist(playlist, track: track) }
                                )
                            }
                        )
                    }
                    
                    // 2. Qobuz Section
                    if let squidTracks = searchResults?.squidTracks, !squidTracks.isEmpty {
                        sourceSection(
                            title: "Qobuz",
                            icon: "music.note",
                            color: .cyan,
                            tracks: squidTracks,
                            rowView: { track in
                                searchResultRow(
                                    id: "qobuz-\(track.id)",
                                    title: track.title,
                                    artist: track.artist,
                                    duration: track.durationSec.map { TimeInterval($0) },
                                    onPreview: { await resolveAndPlaySquid(track) },
                                    onDownload: { await downloadSquidTrack(track) },
                                    onAddToPlaylist: { playlist in await addSquidToPlaylist(playlist, track: track) }
                                )
                            }
                        )
                    }
                    
                    // 3. SoundCloud Section
                    if let scTracks = searchResults?.soundCloudTracks, !scTracks.isEmpty {
                        sourceSection(
                            title: "SoundCloud",
                            icon: "cloud.fill",
                            color: Color.mlmBrandSoundCloud,
                            tracks: scTracks,
                            rowView: { track in
                                searchResultRow(
                                    id: "soundcloud-\(track.id)",
                                    title: track.title,
                                    artist: track.user?.username ?? "Unknown",
                                    duration: track.duration.map { TimeInterval($0) / 1000.0 },
                                    onPreview: { await resolveAndPlaySoundCloud(track) },
                                    onDownload: { await downloadSoundCloudTrack(track) },
                                    onAddToPlaylist: { playlist in await addSoundCloudToPlaylist(playlist, track: track) }
                                )
                            }
                        )
                    }
                    
                    // 4. YouTube Section
                    if let ytTracks = searchResults?.youtubeTracks, !ytTracks.isEmpty {
                        sourceSection(
                            title: "YouTube",
                            icon: "play.rectangle.fill",
                            color: .mlmBrandYouTube,
                            tracks: ytTracks,
                            rowView: { track in
                                searchResultRow(
                                    id: "youtube-\(track.id)",
                                    title: track.title,
                                    artist: track.uploader ?? "Unknown",
                                    duration: track.duration,
                                    onPreview: { await resolveAndPlayYouTube(track) },
                                    onDownload: { await downloadYouTubeTrack(track) },
                                    onAddToPlaylist: { playlist in await addYouTubeToPlaylist(playlist, track: track) }
                                )
                            }
                        )
                    }
                }
            }
        }
    }
    
    // MARK: - Section & Row Builder Helpers
    @ViewBuilder
    private func sourceSection<T, V: View>(
        title: String,
        icon: String,
        color: Color,
        tracks: [T],
        rowView: @escaping (T) -> V
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(color)
                Text(title)
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInk)
                Spacer()
            }
            .padding(.horizontal, 8)
            
            VStack(spacing: 0) {
                ForEach(0..<tracks.count, id: \.self) { idx in
                    rowView(tracks[idx])
                    
                    if idx < tracks.count - 1 {
                        Divider()
                            .padding(.horizontal, 8)
                    }
                }
            }
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
            )
        }
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func searchResultRow(
        id: String,
        title: String,
        artist: String,
        duration: TimeInterval?,
        onPreview: @escaping () async -> Void,
        onDownload: @escaping () async -> Void,
        onAddToPlaylist: @escaping (Playlist) async -> Void
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                    .lineLimit(1)
                
                Text(artist)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            if let dur = duration {
                Text(formatDuration(dur))
                    .font(MLMFont.dataSmall)
                    .foregroundColor(.mlmInkMuted)
            }
            
            HStack(spacing: 8) {
                // Preview / Listen Action
                Button(action: {
                    Task {
                        await onPreview()
                    }
                }) {
                    if previewLoadingTrackId == id {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 24, height: 24)
                    } else {
                        Image(systemName: isCurrentlyPlaying(title: title, artist: artist) ? "stop.circle.fill" : "play.circle.fill")
                            .font(.title3)
                    }
                }
                .buttonStyle(.plain)
                .help("Preview / Listen to track")
                
                // Download Action
                Button(action: {
                    Task {
                        await onDownload()
                    }
                }) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("High priority download")
                
                // Add to Playlist Menu
                Menu {
                    ForEach(playlists) { playlist in
                        Button(playlist.name) {
                            Task {
                                await onAddToPlaylist(playlist)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title3)
                }
                .menuStyle(.borderlessButton)
                .help("Add to playlist")
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.mlmSurface)
    }
    
    // MARK: - Actions & Handlers
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            loadReels(from: url)
        }
    }
    
    private func loadReels(from folderURL: URL) {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: folderURL, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            let videoFiles = contents.filter { url in
                let ext = url.pathExtension.lowercased()
                return ext == "mp4" || ext == "mov"
            }
            for file in videoFiles {
                if !importedReels.contains(where: { $0.fileURL == file }) {
                    let filename = file.deletingPathExtension().lastPathComponent
                    let parsed = parseArtistTitle(from: filename)
                    let reel = ImportedReel(id: UUID(), fileURL: file, title: parsed.title, artist: parsed.artist)
                    importedReels.append(reel)
                    Task { await saveReel(reel) }
                }
            }
        } catch {
            AppLogger.shared.log("Failed to load Reels: \(error.localizedDescription)", level: .error, source: "ReelsInbox")
        }
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, error in
                guard let data = data,
                      let path = String(data: data, encoding: .utf8),
                      let url = URL(string: path) else { return }
                
                DispatchQueue.main.async {
                    let ext = url.pathExtension.lowercased()
                    if ext == "mp4" || ext == "mov" {
                        if !importedReels.contains(where: { $0.fileURL == url }) {
                            let filename = url.deletingPathExtension().lastPathComponent
                            let parsed = parseArtistTitle(from: filename)
                            let reel = ImportedReel(id: UUID(), fileURL: url, title: parsed.title, artist: parsed.artist)
                            importedReels.append(reel)
                            Task { await saveReel(reel) }
                        }
                    } else {
                        var isDir: ObjCBool = false
                        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                            loadReels(from: url)
                        }
                    }
                }
            }
        }
        return true
    }
    
    private func loadReel(_ reel: ImportedReel) {
        avPlayer.pause()
        searchTask?.cancel()
        
        let playerItem = AVPlayerItem(url: reel.fileURL)
        avPlayer.replaceCurrentItem(with: playerItem)
        
        artistInput = reel.artist
        titleInput = reel.title
        customSearchQuery = "\(reel.artist) \(reel.title)".trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = nil
        
        // If we already have a parsed artist or title, search immediately!
        if !artistInput.isEmpty || !titleInput.isEmpty {
            triggerSearch()
        } else {
            // Otherwise, let's run Shazam automatically in the background!
            identifyReelMusic(reel)
        }
        
        runOcrTextExtraction(for: reel)
    }
    
    private func updateSelectedReelMetadata() {
        guard let selected = selectedReel,
              let index = importedReels.firstIndex(where: { $0.id == selected.id }) else { return }
        
        importedReels[index].artist = artistInput
        importedReels[index].title = titleInput
        
        selectedReel = importedReels[index]
        let reel = importedReels[index]
        Task { await saveReel(reel) }
        
        customSearchQuery = "\(artistInput) \(titleInput)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func deleteReels(at offsets: IndexSet) {
        let reels = offsets.map { importedReels[$0] }
        importedReels.remove(atOffsets: offsets)
        selectedReel = nil
        avPlayer.pause()
        avPlayer.replaceCurrentItem(with: nil)
        Task {
            for reel in reels {
                try? await container.reelRepository?.delete(id: reel.id.uuidString)
            }
        }
    }
    
    private func triggerSearch() {
        searchTask?.cancel()
        
        let query = customSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = nil
            isSearching = false
            return
        }
        
        isSearching = true
        searchResults = nil
        
        AppLogger.shared.info("Reels Search: Triggering unified search for query: '\(query)' (Artist: '\(artistInput)', Title: '\(titleInput)')", source: "ReelsSearch")
        
        searchTask = Task {
            if let searchService = container.unifiedSearchService {
                let results = await searchService.search(query: query)
                if !Task.isCancelled {
                    await MainActor.run {
                        self.searchResults = results
                        self.isSearching = false
                        
                        let dabCount = results.dabTracks.count
                        let squidCount = results.squidTracks.count
                        let scCount = results.soundCloudTracks.count
                        let ytCount = results.youtubeTracks.count
                        
                        AppLogger.shared.info("Reels Search Complete for query '\(query)': DAB: \(dabCount) matches, Qobuz: \(squidCount) matches, SoundCloud: \(scCount) matches, YouTube: \(ytCount) matches", source: "ReelsSearch")
                        
                        for track in results.dabTracks.prefix(3) {
                            AppLogger.shared.debug("  [DAB] Match: \(track.artist) - \(track.title) (ID: \(track.id))", source: "ReelsSearch")
                        }
                        for track in results.squidTracks.prefix(3) {
                            AppLogger.shared.debug("  [Qobuz] Match: \(track.artist) - \(track.title) (ID: \(track.id))", source: "ReelsSearch")
                        }
                        for track in results.soundCloudTracks.prefix(3) {
                            AppLogger.shared.debug("  [SoundCloud] Match: \(track.user?.username ?? "Unknown") - \(track.title) (ID: \(track.id))", source: "ReelsSearch")
                        }
                        for track in results.youtubeTracks.prefix(3) {
                            AppLogger.shared.debug("  [YouTube] Match: \(track.uploader ?? "Unknown") - \(track.title) (VideoID: \(track.id))", source: "ReelsSearch")
                        }
                    }
                }
            } else {
                if !Task.isCancelled {
                    await MainActor.run {
                        self.isSearching = false
                    }
                }
            }
        }
    }
    
    // MARK: - Streaming Resolution & Preview Actions
    private func playPreviewTrack(resolvedURL: URL, title: String, artist: String, duration: TimeInterval?) async {
        do {
            let (tempURL, _) = try await URLSession.shared.download(from: resolvedURL)
            let ext = resolvedURL.pathExtension.isEmpty ? "mp3" : resolvedURL.pathExtension
            let stableURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            
            try? FileManager.default.removeItem(at: stableURL)
            try FileManager.default.moveItem(at: tempURL, to: stableURL)
            
            let previewTrack = Track(
                id: nil,
                artist: artist,
                albumArtist: artist,
                album: "Search Previews",
                title: title,
                genre: "Preview",
                year: nil,
                bitrate: 128,
                duration: duration.map { Int($0) },
                format: ext,
                originalPath: stableURL.path,
                organizedPath: nil,
                isDuplicate: 0,
                dateAdded: ISO8601DateFormatter().string(from: Date()),
                downloadStatus: "local"
            )
            
            await MainActor.run {
                if let playbackVM = container.playbackViewModel {
                    Task {
                        await playbackVM.playFile(at: stableURL, track: previewTrack)
                    }
                }
            }
        } catch {
            AppLogger.shared.log("Failed to download or play preview: \(error.localizedDescription)", level: .error, source: "Preview")
        }
    }
    
    private func resolveAndPlayDab(_ track: DabTrack) async {
        avPlayer.pause()
        if isCurrentlyPlaying(title: track.title, artist: track.artist) {
            container.playbackViewModel?.stop()
            return
        }
        
        let id = "dab-\(track.id)"
        previewLoadingTrackId = id
        
        if let searchService = container.unifiedSearchService,
           let url = await searchService.resolvePreviewURL(forDab: track) {
            previewLoadingTrackId = nil
            await playPreviewTrack(resolvedURL: url, title: track.title, artist: track.artist, duration: track.duration.map { TimeInterval($0) })
        } else {
            previewLoadingTrackId = nil
        }
    }
    
    private func resolveAndPlaySquid(_ track: SquidWtfClient.SquidTrack) async {
        avPlayer.pause()
        if isCurrentlyPlaying(title: track.title, artist: track.artist) {
            container.playbackViewModel?.stop()
            return
        }
        
        let id = "qobuz-\(track.id)"
        previewLoadingTrackId = id
        
        if let searchService = container.unifiedSearchService,
           let url = await searchService.resolvePreviewURL(forSquid: track) {
            previewLoadingTrackId = nil
            await playPreviewTrack(resolvedURL: url, title: track.title, artist: track.artist, duration: track.durationSec.map { TimeInterval($0) })
        } else {
            previewLoadingTrackId = nil
        }
    }
    
    private func resolveAndPlaySoundCloud(_ track: SoundCloudTrack) async {
        avPlayer.pause()
        if isCurrentlyPlaying(title: track.title, artist: track.user?.username ?? "Unknown") {
            container.playbackViewModel?.stop()
            return
        }
        
        let id = "soundcloud-\(track.id)"
        previewLoadingTrackId = id
        
        if let searchService = container.unifiedSearchService,
           let url = await searchService.resolvePreviewURL(forSoundCloud: track) {
            previewLoadingTrackId = nil
            let artist = track.user?.username ?? "Unknown"
            await playPreviewTrack(resolvedURL: url, title: track.title, artist: artist, duration: track.duration.map { TimeInterval(Double($0) / 1000.0) })
        } else {
            previewLoadingTrackId = nil
        }
    }
    
    private func resolveAndPlayYouTube(_ track: YouTubeTrack) async {
        avPlayer.pause()
        if isCurrentlyPlaying(title: track.title, artist: track.uploader ?? "Unknown") {
            container.playbackViewModel?.stop()
            return
        }
        
        let id = "youtube-\(track.id)"
        previewLoadingTrackId = id
        
        if let searchService = container.unifiedSearchService,
           let url = await searchService.resolvePreviewURL(forYouTube: track) {
            previewLoadingTrackId = nil
            let artist = track.uploader ?? "Unknown"
            await playPreviewTrack(resolvedURL: url, title: track.title, artist: artist, duration: track.duration)
        } else {
            previewLoadingTrackId = nil
        }
    }
    
    // MARK: - Queue Download & DB Sync Actions
    private func dbInsertRemoteTrack(title: String, artist: String, format: String, duration: TimeInterval?, originalPath: String) async -> Track? {
        guard let trackRepo = container.trackRepository else { return nil }
        
        // Check if exact track already exists to reuse
        if let existing = try? await trackRepo.search(query: "\(artist) \(title)"),
           let match = existing.first(where: { $0.title.lowercased() == title.lowercased() && $0.artist.lowercased() == artist.lowercased() }) {
            return match
        }
        
        let newTrack = Track(
            id: nil,
            artist: artist,
            albumArtist: artist,
            album: "Reels",
            title: title,
            genre: nil,
            year: nil,
            bitrate: nil,
            duration: duration.map { Int($0) },
            format: format,
            originalPath: originalPath,
            organizedPath: nil,
            isDuplicate: 0,
            dateAdded: ISO8601DateFormatter().string(from: Date()),
            downloadStatus: nil
        )
        
        return try? await trackRepo.insert(newTrack)
    }
    
    private func downloadDabTrack(_ track: DabTrack) async {
        let streamURL = try? await container.unifiedSearchService?.dabClient.getStreamURL(trackId: track.id)
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: track.artist,
            format: "dab",
            duration: track.duration.map { TimeInterval($0) },
            originalPath: streamURL ?? ""
        ) {
            PerformanceQueueService.shared.enqueueDownload(track: dbTrack)
        }
    }
    
    private func downloadSquidTrack(_ track: SquidWtfClient.SquidTrack) async {
        let streamURL = try? await container.unifiedSearchService?.squidClient.getStreamURL(trackId: track.id)
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: track.artist,
            format: "qobuz",
            duration: track.durationSec.map { TimeInterval($0) },
            originalPath: streamURL?.absoluteString ?? ""
        ) {
            PerformanceQueueService.shared.enqueueDownload(track: dbTrack)
        }
    }
    
    private func downloadSoundCloudTrack(_ track: SoundCloudTrack) async {
        let artist = track.user?.username ?? "Unknown"
        let origPath = track.permalinkUrl ?? "soundcloud://\(track.id)"
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: artist,
            format: "soundcloud",
            duration: track.duration.map { TimeInterval(Double($0) / 1000.0) },
            originalPath: origPath
        ) {
            PerformanceQueueService.shared.enqueueDownload(track: dbTrack)
        }
    }
    
    private func downloadYouTubeTrack(_ track: YouTubeTrack) async {
        let artist = track.uploader ?? "Unknown"
        let origPath = track.watchUrl
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: artist,
            format: "youtube",
            duration: track.duration,
            originalPath: origPath
        ) {
            PerformanceQueueService.shared.enqueueDownload(track: dbTrack)
        }
    }
    
    // MARK: - Playlist Addition Actions
    private func addDabToPlaylist(_ playlist: Playlist, track: DabTrack) async {
        let streamURL = try? await container.unifiedSearchService?.dabClient.getStreamURL(trackId: track.id)
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: track.artist,
            format: "dab",
            duration: track.duration.map { TimeInterval($0) },
            originalPath: streamURL ?? ""
        ) {
            await insertTrackToPlaylist(playlist, track: dbTrack)
        }
    }
    
    private func addSquidToPlaylist(_ playlist: Playlist, track: SquidWtfClient.SquidTrack) async {
        let streamURL = try? await container.unifiedSearchService?.squidClient.getStreamURL(trackId: track.id)
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: track.artist,
            format: "qobuz",
            duration: track.durationSec.map { TimeInterval($0) },
            originalPath: streamURL?.absoluteString ?? ""
        ) {
            await insertTrackToPlaylist(playlist, track: dbTrack)
        }
    }
    
    private func addSoundCloudToPlaylist(_ playlist: Playlist, track: SoundCloudTrack) async {
        let artist = track.user?.username ?? "Unknown"
        let origPath = track.permalinkUrl ?? "soundcloud://\(track.id)"
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: artist,
            format: "soundcloud",
            duration: track.duration.map { TimeInterval(Double($0) / 1000.0) },
            originalPath: origPath
        ) {
            await insertTrackToPlaylist(playlist, track: dbTrack)
        }
    }
    
    private func addYouTubeToPlaylist(_ playlist: Playlist, track: YouTubeTrack) async {
        let artist = track.uploader ?? "Unknown"
        let origPath = track.watchUrl
        if let dbTrack = await dbInsertRemoteTrack(
            title: track.title,
            artist: artist,
            format: "youtube",
            duration: track.duration,
            originalPath: origPath
        ) {
            await insertTrackToPlaylist(playlist, track: dbTrack)
        }
    }
    
    private func insertTrackToPlaylist(_ playlist: Playlist, track: Track) async {
        guard let playlistId = playlist.id,
              let playlistRepo = container.playlistRepository,
              let finalTrackId = track.id else { return }
        
        let position = String(format: "%06d", 999000)
        try? await playlistRepo.addTracks(
            playlistId: playlistId,
            trackIds: [finalTrackId],
            startPosition: position
        )
        
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistId": playlistId]
        )
    }
    
    private func loadPlaylists() async {
        if let repo = container.playlistRepository {
            if let list = try? await repo.fetchAll() {
                await MainActor.run {
                    self.playlists = list
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private func parseArtistTitle(from text: String) -> (artist: String, title: String) {
        let delimiters = [" - ", " – ", " — ", " • ", "•", " | ", "|", " : ", ":", "-"]
        for delimiter in delimiters {
            let parts = text.components(separatedBy: delimiter)
            if parts.count >= 2 {
                let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                if !artist.isEmpty && !title.isEmpty {
                    return (artist: artist, title: title)
                }
            }
        }
        return (artist: "", title: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let mins = Int(duration) / 60
        let secs = Int(duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }
    
    private func isCurrentlyPlaying(title: String, artist: String) -> Bool {
        guard let playbackVM = container.playbackViewModel,
              playbackVM.isPlaying,
              let track = playbackVM.currentTrack else { return false }
        
        return track.title == title && track.artist == artist
    }
    
    // MARK: - Shazam / Audio Recognition Expandable Details
    // MARK: - Video Previews & OCR Interaction Details
    @ViewBuilder
    private func ocrAnalysisSection(for reel: ImportedReel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header Row with title & Shazam button side-by-side
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Video analysis and text recognition (OCR)")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInk)
                    Text("Select a keyframe to seek, or use recognized text to search.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                }
                
                Spacer()
                
                // Shazam button
                if matchingReelId == reel.id {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Identifying with Shazam…")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.mlmRaised)
                    .cornerRadius(8)
                } else {
                    Button(action: {
                        identifyReelMusic(reel)
                    }) {
                        Label("Per Audio erkennen (Shazam)", systemImage: "shazam.logo.fill")
                            .font(MLMFont.bodyBold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
            .padding(.bottom, 4)
            
            // 1. Shazam Results (if matched)
            if let matchedTitle = reel.matchedTitle, let matchedArtist = reel.matchedArtist {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .foregroundColor(.green)
                        .font(.title2)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Shazam match")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                        Text("\(matchedArtist) - \(matchedTitle)")
                            .font(MLMFont.bodyBold)
                            .foregroundColor(.green)
                    }
                    
                    Spacer()
                    
                    Button("Use match") {
                        applyMatchedMetadata(reel)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)
                }
                .padding()
                .background(Color.green.opacity(0.08))
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
            } else if reel.matchFailed {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Shazam could not identify this track. Try the on-screen text instead.")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.orange.opacity(0.08))
                .cornerRadius(8)
            }
            
            // 2. Keyframe Carousel / Grid
            VStack(alignment: .leading, spacing: 8) {
                Text("Video keyframes")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkMuted)
                
                if reel.isOcrRunning {
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading keyframes and reading on-screen text…")
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInkSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 90)
                    .background(Color.mlmSurface)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                    )
                } else if let keyframes = reel.keyframes, !keyframes.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(keyframes) { kf in
                                OCRKeyframeThumbnailView(keyframe: kf, onExpand: {
                                    expandedKeyframe = kf
                                }, onSeek: {
                                    seekPlayer(to: kf.offset)
                                })
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } else {
                    Button(action: {
                        runOcrTextExtraction(for: reel)
                    }) {
                        Label("Load keyframes and run OCR", systemImage: "sparkles")
                            .font(MLMFont.bodyBold)
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            // 3. OCR Text Pills / Suggestions
            if let recognizedTexts = reel.recognizedTexts, !recognizedTexts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Recognized text")
                        .font(MLMFont.sectionLabel)
                        .foregroundColor(.mlmInkMuted)
                    
                    // Smart Candidates List
                    let candidates = findAllOcrCandidates(in: recognizedTexts)
                    if !candidates.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Recognized songs and titles")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.mlmInkMuted)
                            
                            ForEach(candidates) { candidate in
                                Button(action: {
                                    setArtist(candidate.artist, for: reel)
                                    setTitle(candidate.title, for: reel)
                                    triggerSearch()
                                }) {
                                    HStack(spacing: 8) {
                                        Image(systemName: "sparkles")
                                            .foregroundColor(.green)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("\(candidate.artist) - \(candidate.title)")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundColor(.mlmInk)
                                            Text("Select to use this song and search")
                                                .font(.system(size: 9))
                                                .foregroundColor(.mlmInkSecondary)
                                                .opacity(0.8)
                                        }
                                        Spacer()
                                        Image(systemName: "magnifyingglass.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(.mlmAccent)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.mlmRaised)
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 6)
                    }
                    
                    Text("Recognized text fragments")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.mlmInkMuted)
                        .padding(.top, 4)
                    
                    // Wrapping Grid of pills
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 280), spacing: 8)], spacing: 8) {
                        ForEach(recognizedTexts.prefix(8), id: \.self) { text in
                            HStack(spacing: 4) {
                                Text(text)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.mlmInk)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.leading, 8)
                                
                                Spacer(minLength: 4)
                                
                                Menu {
                                    Button("Artist") {
                                        setArtist(text, for: reel)
                                    }
                                    Button("Title") {
                                        setTitle(text, for: reel)
                                    }
                                    Button("Use both as \"Artist - Title\"") {
                                        applySmartMetadata(text, for: reel)
                                    }
                                    Button("Kopieren") {
                                        copyToClipboard(text)
                                    }
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.mlmInkSecondary)
                                        .font(.system(size: 12))
                                        .padding(.trailing, 6)
                                }
                                .menuStyle(.borderlessButton)
                                .frame(width: 24, height: 24)
                            }
                            .frame(height: 32)
                            .background(Color.mlmSurface)
                            .cornerRadius(6)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding()
                .background(Color.mlmSurface)
                .cornerRadius(12)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                )
            }
        }
        .padding()
        .background(Color.mlmSurface.opacity(0.4))
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
        )
    }
    
    private func setArtist(_ text: String, for reel: ImportedReel) {
        guard let index = importedReels.firstIndex(where: { $0.id == reel.id }) else { return }
        importedReels[index].artist = text
        let updated = importedReels[index]
        Task { await saveReel(updated) }
        if selectedReel?.id == reel.id {
            artistInput = text
            selectedReel = importedReels[index]
        }
    }
    
    private func setTitle(_ text: String, for reel: ImportedReel) {
        guard let index = importedReels.firstIndex(where: { $0.id == reel.id }) else { return }
        importedReels[index].title = text
        let updated = importedReels[index]
        Task { await saveReel(updated) }
        if selectedReel?.id == reel.id {
            titleInput = text
            selectedReel = importedReels[index]
        }
    }
    
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
    
    private func findBestOcrCandidate(in texts: [String]) -> (artist: String, title: String)? {
        let delimiters = [" - ", " – ", " — ", " • ", "•", " | ", "|", " : ", ":"]
        var candidates: [(artist: String, title: String, score: Int)] = []
        
        for text in texts {
            let cleanedText = Self.cleanOcrText(text)
            guard cleanedText.count >= 4 else { continue }
            if Self.isInstagramUiNoise(cleanedText) { continue }
            
            for delimiter in delimiters {
                let parts = cleanedText.components(separatedBy: delimiter)
                if parts.count >= 2 {
                    let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !artist.isEmpty && !title.isEmpty && artist.count > 1 && title.count > 1 {
                        var score = 100
                        if cleanedText.lowercased().contains("original") {
                            score -= 20
                        }
                        candidates.append((artist: artist, title: title, score: score))
                        break
                    }
                }
            }
        }
        
        candidates.sort {
            if $0.score == $1.score {
                return ($0.artist.count + $0.title.count) > ($1.artist.count + $1.title.count)
            }
            return $0.score > $1.score
        }
        
        if let best = candidates.first {
            return (artist: best.artist, title: best.title)
        }
        return nil
    }
    
    private nonisolated static func cleanOcrText(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "🎵", with: "")
        cleaned = cleaned.replacingOccurrences(of: "🎶", with: "")
        cleaned = cleaned.replacingOccurrences(of: "👤", with: "")
        cleaned = cleaned.replacingOccurrences(of: "▶️", with: "")
        
        let noiseSuffixes = [
            " (Original Audio)", " (Originalton)", " (Original Sound)", " (Original-Audio)",
            " Original Audio", " Originalton", " Original Sound", " Original-Audio"
        ]
        for suffix in noiseSuffixes {
            cleaned = cleaned.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }
        
        if cleaned.lowercased().hasPrefix("originalton von ") {
            cleaned = String(cleaned.dropFirst("originalton von ".count))
        }
        
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private nonisolated static func isInstagramUiNoise(_ text: String) -> Bool {
        let lower = text.lowercased()
        let noiseKeywords = [
            "gefällt mir", "kommentieren", "teilen", "beitrag", "instagram", "reels", 
            "folgen", "abonnieren", "aufrufe", "views", "vor 1 tag", "vor 2 tagen", 
            "originalton", "original audio", "original sound", "original-audio", 
            "tonspur", "soundtrack", "audio hinzufügen", "sound hinzufügen",
            "nachricht", "profil", "entdecken", "suche", "suchbegriff"
        ]
        for keyword in noiseKeywords {
            if lower == keyword || lower.contains(keyword) {
                return true
            }
        }
        
        if lower.hasPrefix("@") {
            return true
        }
        
        if lower.range(of: "^[0-9:\\s,.]+$", options: .regularExpression) != nil {
            return true
        }
        
        return false
    }
    
    private func findSmartOcrCandidate(in texts: [String]) -> String? {
        if let best = findBestOcrCandidate(in: texts) {
            return "\(best.artist) - \(best.title)"
        }
        return nil
    }
    
    private func findAllOcrCandidates(in texts: [String]) -> [OcrSongCandidate] {
        let delimiters = [" - ", " – ", " — ", " • ", "•", " | ", "|", " : ", ":"]
        var candidates: [(artist: String, title: String, score: Int)] = []
        var seen = Set<String>()
        
        for text in texts {
            let cleanedText = Self.cleanOcrText(text)
            guard cleanedText.count >= 4 else { continue }
            if Self.isInstagramUiNoise(cleanedText) { continue }
            
            for delimiter in delimiters {
                let parts = cleanedText.components(separatedBy: delimiter)
                if parts.count >= 2 {
                    let artist = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if !artist.isEmpty && !title.isEmpty && artist.count > 1 && title.count > 1 {
                        let key = "\(artist.lowercased()) - \(title.lowercased())"
                        if !seen.contains(key) {
                            seen.insert(key)
                            var score = 100
                            if cleanedText.lowercased().contains("original") {
                                score -= 20
                            }
                            candidates.append((artist: artist, title: title, score: score))
                            break
                        }
                    }
                }
            }
        }
        
        candidates.sort {
            if $0.score == $1.score {
                return ($0.artist.count + $0.title.count) > ($1.artist.count + $1.title.count)
            }
            return $0.score > $1.score
        }
        
        return candidates.map { OcrSongCandidate(artist: $0.artist, title: $0.title) }
    }
    
    private func applySmartMetadata(_ candidate: String, for reel: ImportedReel) {
        let parsed = parseArtistTitle(from: candidate)
        if !parsed.artist.isEmpty && !parsed.title.isEmpty {
            setArtist(parsed.artist, for: reel)
            setTitle(parsed.title, for: reel)
            triggerSearch()
        }
    }
    
    private func seekPlayer(to offset: TimeInterval) {
        let time = CMTime(seconds: offset, preferredTimescale: 600)
        avPlayer.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        avPlayer.play()
    }
    
    private func applyMatchedMetadata(_ reel: ImportedReel) {
        guard let index = importedReels.firstIndex(where: { $0.id == reel.id }) else { return }
        let artist = reel.matchedArtist ?? ""
        let title = reel.matchedTitle ?? ""
        
        importedReels[index].artist = artist
        importedReels[index].title = title
        let updated = importedReels[index]
        Task { await saveReel(updated) }
        
        if selectedReel?.id == reel.id {
            artistInput = artist
            titleInput = title
            selectedReel = importedReels[index]
            triggerSearch()
        }
    }
    
    private func identifyReelMusic(_ reel: ImportedReel) {
        guard let index = importedReels.firstIndex(where: { $0.id == reel.id }) else { return }
        
        importedReels[index].matchFailed = false
        matchingReelId = reel.id
        
        let fileURL = reel.fileURL
        
        Task.detached(priority: .userInitiated) { [index] in
            let isAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            
            let asset = AVURLAsset(url: fileURL)
            
            guard let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first else {
                await MainActor.run {
                    self.matchingReelId = nil
                    self.importedReels[index].matchFailed = true
                }
                return
            }
            
            guard let reader = try? AVAssetReader(asset: asset) else {
                await MainActor.run {
                    self.matchingReelId = nil
                    self.importedReels[index].matchFailed = true
                }
                return
            }
            
            let outputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1
            ]
            
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
            reader.add(output)
            
            guard reader.startReading() else {
                await MainActor.run {
                    self.matchingReelId = nil
                    self.importedReels[index].matchFailed = true
                }
                return
            }
            
            let delegate = ReelMatchDelegate()
            let session = SHSession()
            session.delegate = delegate
            
            let audioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100.0, channels: 1, interleaved: false)!
            
            var totalSamples: Int64 = 0
            let maxSamplesToRead = Int64(44100.0 * 12.0)
            
            while reader.status == .reading, totalSamples < maxSamplesToRead {
                guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
                let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
                
                if let pcmBuffer = Self.audioPCMBuffer(from: sampleBuffer, format: audioFormat, numSamples: numSamples) {
                    let audioTime = AVAudioTime(sampleTime: totalSamples, atRate: 44100.0)
                    session.matchStreamingBuffer(pcmBuffer, at: audioTime)
                    totalSamples += Int64(numSamples)
                }
            }
            
            reader.cancelReading()
            
            _ = delegate.wait(timeout: .now() + 4.0)
            
            let finalDidMatch = delegate.didMatch
            let finalTitle = delegate.matchedTitle
            let finalArtist = delegate.matchedArtist
            let finalOffset = delegate.matchOffset
            
            await MainActor.run {
                self.matchingReelId = nil
                if finalDidMatch {
                    self.importedReels[index].matchedTitle = finalTitle
                    self.importedReels[index].matchedArtist = finalArtist
                    self.importedReels[index].matchOffset = finalOffset
                    self.importedReels[index].matchFailed = false
                    
                    if self.selectedReel?.id == reel.id {
                        self.artistInput = finalArtist ?? ""
                        self.titleInput = finalTitle ?? ""
                        self.updateSelectedReelMetadata()
                        self.triggerSearch()
                    }
                } else {
                    self.importedReels[index].matchFailed = true
                    if self.selectedReel?.id == reel.id {
                        self.selectedReel = self.importedReels[index]
                    }
                }
            }
        }
    }
    
    private func runOcrTextExtraction(for reel: ImportedReel) {
        guard let index = importedReels.firstIndex(where: { $0.id == reel.id }) else { return }
        
        // Skip if already running or if we already have OCR results and keyframes
        guard !importedReels[index].isOcrRunning else { return }
        if importedReels[index].recognizedTexts != nil && importedReels[index].keyframes != nil {
            return
        }
        
        importedReels[index].isOcrRunning = true
        if selectedReel?.id == reel.id {
            selectedReel = importedReels[index]
        }
        let fileURL = reel.fileURL
        
        Task.detached(priority: .userInitiated) { [index] in
            let isAccessing = fileURL.startAccessingSecurityScopedResource()
            defer {
                if isAccessing {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }
            
            let asset = AVURLAsset(url: fileURL)
            
            // 1. Get video duration
            guard let durationTime = try? await asset.load(.duration) else {
                await MainActor.run {
                    self.importedReels[index].isOcrRunning = false
                    if self.selectedReel?.id == reel.id {
                        self.selectedReel = self.importedReels[index]
                    }
                }
                return
            }
            let duration = CMTimeGetSeconds(durationTime)
            guard duration > 0 else {
                await MainActor.run {
                    self.importedReels[index].isOcrRunning = false
                    if self.selectedReel?.id == reel.id {
                        self.selectedReel = self.importedReels[index]
                    }
                }
                return
            }
            
            // 2. Generate 10 keyframes evenly spaced (spaced at 5%, 15%, 25%, 35%, 45%, 55%, 65%, 75%, 85%, 95% of duration)
            let percentages = [0.05, 0.15, 0.25, 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.95]
            let offsets = percentages.map { duration * $0 }
            
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            
            var generatedKeyframes: [KeyframeData] = []
            var extractedTexts: Set<String> = []
            
            for offset in offsets {
                let time = CMTime(seconds: offset, preferredTimescale: 600)
                do {
                    let (cgImage, _) = try await generator.image(at: time)
                    let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                    
                    // Run OCR on this CGImage
                    let texts = await self.performOcr(on: cgImage)
                    var frameTexts: [String] = []
                    for text in texts {
                        let cleaned = Self.cleanOcrText(text)
                        if cleaned.count > 1 && !Self.isInstagramUiNoise(cleaned) {
                            extractedTexts.insert(cleaned)
                            if !frameTexts.contains(cleaned) {
                                frameTexts.append(cleaned)
                            }
                        }
                    }
                    
                    let keyframe = KeyframeData(offset: offset, image: nsImage, recognizedTexts: frameTexts)
                    generatedKeyframes.append(keyframe)
                } catch {
                    AppLogger.shared.log("OCR frame extraction failed at \(offset)s: \(error.localizedDescription)", level: .warning, source: "ReelsOCR")
                }
            }
            
            // Sort extracted text so we have a reliable order
            let finalTexts = Array(extractedTexts).sorted { $0.count > $1.count }
            let finalKeyframes = generatedKeyframes
            
            AppLogger.shared.info("OCR Extraction Complete: Parsed \(finalTexts.count) unique prominent strings from Reel '\(reel.fileURL.lastPathComponent)': \(finalTexts)", source: "ReelsOCR")
            
            await MainActor.run {
                self.importedReels[index].keyframes = finalKeyframes
                self.importedReels[index].recognizedTexts = finalTexts
                self.importedReels[index].isOcrRunning = false
                
                if self.selectedReel?.id == reel.id {
                    self.selectedReel = self.importedReels[index]
                    
                    let ocrCandidates = self.findAllOcrCandidates(in: finalTexts)
                    AppLogger.shared.info("OCR Song Candidates extracted: \(ocrCandidates.map { "\($0.artist) - \($0.title)" })", source: "ReelsOCR")
                    
                    // Smart parsing: if we find any text matching our music rules, let's pre-populate the input fields!
                    // We only do this if the current input fields are empty.
                    if self.artistInput.isEmpty && self.titleInput.isEmpty {
                        if let bestCandidate = self.findBestOcrCandidate(in: finalTexts) {
                            AppLogger.shared.info("OCR Smart Auto-Query: Pre-populating metadata with candidate '\(bestCandidate.artist) - \(bestCandidate.title)' and triggering unified search.", source: "ReelsOCR")
                            self.artistInput = bestCandidate.artist
                            self.titleInput = bestCandidate.title
                            self.updateSelectedReelMetadata()
                            self.triggerSearch()
                        }
                    }
                }
            }
        }
    }
    
    private func performOcr(on cgImage: CGImage) async -> [String] {
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    AppLogger.shared.debug("OCR: No text observations found in frame.", source: "ReelsOCR")
                    continuation.resume(returning: [])
                    return
                }
                
                AppLogger.shared.debug("OCR: Found \(observations.count) raw text observations.", source: "ReelsOCR")
                
                struct OcrBlock {
                    let text: String
                    let box: CGRect
                }
                
                var blocks: [OcrBlock] = []
                for obs in observations {
                    let candidates = obs.topCandidates(3)
                    if let primary = candidates.first?.string {
                        let size = obs.boundingBox.size
                        
                        // Smart Prominence Filter: Keep only big text blocks that stand out,
                        // and discard tiny background watermarks, timelines, and UI details.
                        let isProminent = (size.height >= 0.02) || (size.height >= 0.016 && size.width >= 0.08)
                        
                        AppLogger.shared.debug("OCR BoundingBox: \"\(primary)\" [x: \(String(format: "%.4f", obs.boundingBox.origin.x)), y: \(String(format: "%.4f", obs.boundingBox.origin.y)), w: \(String(format: "%.4f", size.width)), h: \(String(format: "%.4f", size.height))] - Prominent: \(isProminent)", source: "ReelsOCR")
                        
                        if isProminent {
                            blocks.append(OcrBlock(text: primary, box: obs.boundingBox))
                        }
                    }
                }
                
                var results = Set<String>()
                for block in blocks {
                    results.insert(block.text)
                }
                
                // Smart geometric Y-stacking proximity merger for stacked titles/artists
                for i in 0..<blocks.count {
                    for j in 0..<blocks.count {
                        if i == j { continue }
                        let blockA = blocks[i]
                        let blockB = blocks[j]
                        
                        let yDist = blockA.box.origin.y - blockB.box.origin.y
                        let isVerticallyClose = yDist > 0.005 && yDist < 0.08
                        
                        if isVerticallyClose {
                            let centerA = blockA.box.origin.x + blockA.box.size.width / 2
                            let centerB = blockB.box.origin.x + blockB.box.size.width / 2
                            let centerDist = abs(centerA - centerB)
                            
                            let minXA = blockA.box.origin.x
                            let maxXA = blockA.box.origin.x + blockA.box.size.width
                            let minXB = blockB.box.origin.x
                            let maxXB = blockB.box.origin.x + blockB.box.size.width
                            
                            let hasXOverlap = !(maxXA < minXB || maxXB < minXA)
                            let isHorizontallyAligned = centerDist < 0.15 || hasXOverlap
                            
                            if isHorizontallyAligned {
                                AppLogger.shared.info("OCR Y-Stacking: Merging stacked text lines: \"\(blockA.text)\" and \"\(blockB.text)\"", source: "ReelsOCR")
                                results.insert("\(blockA.text) - \(blockB.text)")
                                results.insert("\(blockB.text) - \(blockA.text)")
                            }
                        }
                    }
                }
                
                AppLogger.shared.debug("OCR: Extracted \(results.count) cleaned/prominent strings.", source: "ReelsOCR")
                continuation.resume(returning: Array(results))
            }
            
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["de-DE", "en-US", "fr-FR", "es-ES", "it-IT"]
            
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.shared.error("OCR Request failed: \(error.localizedDescription)", source: "ReelsOCR")
                continuation.resume(returning: [])
            }
        }
    }
    
    private nonisolated static func audioPCMBuffer(from sampleBuffer: CMSampleBuffer, format: AVAudioFormat, numSamples: Int) -> AVAudioPCMBuffer? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else { return nil }
        buffer.frameLength = AVAudioFrameCount(numSamples)
        
        let floatBuffer = buffer.floatChannelData![0]
        var length = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>? = nil
        
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &length,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        
        guard status == noErr, let dataPointer = dataPointer else { return nil }
        
        dataPointer.withMemoryRebound(to: Float.self, capacity: numSamples) { srcPtr in
            floatBuffer.initialize(from: srcPtr, count: numSamples)
        }
        
        return buffer
    }
    
    private func loadImportedReels() async {
        guard let repository = container.reelRepository else { return }
        let records = (try? await repository.fetchAll()) ?? []
        importedReels = records.compactMap { record in
            guard let id = UUID(uuidString: record.id) else { return nil }
            return ImportedReel(
                id: id,
                fileURL: URL(fileURLWithPath: record.filePath),
                title: record.title,
                artist: record.artist
            )
        }
    }

    private func saveReel(_ reel: ImportedReel) async {
        guard let repository = container.reelRepository else { return }
        let now = Date()
        let existing = (try? await repository.fetchAll())?.first { $0.id == reel.id.uuidString }
        let record = ImportedReelRecord(
            id: reel.id.uuidString,
            filePath: reel.fileURL.path,
            title: reel.title,
            artist: reel.artist,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now
        )
        try? await repository.save(record)
    }
}

// MARK: - ShazamKit Match Session Delegate
class ReelMatchDelegate: NSObject, SHSessionDelegate, @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    
    private(set) var matchedTitle: String? = nil
    private(set) var matchedArtist: String? = nil
    private(set) var matchOffset: TimeInterval? = nil
    private(set) var didMatch = false
    private(set) var error: Error? = nil
    
    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        return semaphore.wait(timeout: timeout)
    }
    
    func session(_ session: SHSession, didFind match: SHMatch) {
        if let matchedItem = match.mediaItems.first {
            matchedTitle = matchedItem.title
            matchedArtist = matchedItem.artist
            matchOffset = matchedItem.matchOffset
            didMatch = true
        }
        semaphore.signal()
    }
    
    func session(_ session: SHSession, didNotFindMatchFor signature: SHSignature, error: Error?) {
        self.error = error
        semaphore.signal()
    }
}

// MARK: - Reel Video Frame Thumbnail View
struct ReelFramePreviewView: View {
    let fileURL: URL
    let offset: TimeInterval
    
    @State private var image: NSImage? = nil
    @State private var isLoading = false
    
    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 120)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.mlmEdge, lineWidth: 1)
                    )
            } else if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(height: 120)
            } else {
                Color.mlmRaised
                    .frame(height: 120)
                    .cornerRadius(6)
                    .overlay(
                        Label("No preview", systemImage: "photo")
                            .font(.system(size: 10))
                            .foregroundColor(.mlmInkMuted)
                    )
            }
        }
        .task {
            await generateFrame()
        }
    }
    
    private func generateFrame() async {
        isLoading = true
        let isAccessing = fileURL.startAccessingSecurityScopedResource()
        defer {
            if isAccessing {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }
        
        let asset = AVURLAsset(url: fileURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        
        let time = CMTime(seconds: offset, preferredTimescale: 600)
        
        do {
            let (cgImage, _) = try await generator.image(at: time)
            let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            await MainActor.run {
                self.image = nsImage
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
            }
        }
    }
}

// MARK: - OCR Keyframe Thumbnail Card
struct OCRKeyframeThumbnailView: View {
    let keyframe: KeyframeData
    let onExpand: () -> Void
    let onSeek: () -> Void
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: keyframe.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 100, height: 75)
                    .cornerRadius(6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.mlmEdge, lineWidth: 1)
                    )
                
                // Seek Button overlay
                Button(action: onSeek) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Seek to this point")
            }
            
            Text(String(format: "%.1fs", keyframe.offset))
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.mlmInkSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onExpand()
        }
        .help("Click to enlarge this frame and select text")
    }
}

// MARK: - Expanded Keyframe Full Screen Overlay / View
struct ExpandedKeyframeView: View {
    @Environment(\.dismiss) private var dismiss
    let keyframe: KeyframeData
    let allTexts: [String]
    let onApplyArtist: (String) -> Void
    let onApplyTitle: (String) -> Void
    let onApplyBoth: (String) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(String(format: "Keyframe detail (offset: %.1fs)", keyframe.offset))
                    .font(.headline)
                    .foregroundColor(.mlmInk)
                Spacer()
                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding()
            .background(Color.mlmSurface)
            
            Divider()
            
            // Content
            HSplitView {
                // Left side: Big image preview
                VStack(spacing: 8) {
                    Image(nsImage: keyframe.image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cornerRadius(8)
                        .shadow(radius: 4)
                        .padding()
                }
                .frame(minWidth: 350, idealWidth: 500)
                .background(Color.black.opacity(0.05))
                
                // Right side: OCR text options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Text recognized in this frame")
                        .font(MLMFont.sectionLabel)
                        .foregroundColor(.mlmInk)
                    
                    let frameTexts = keyframe.recognizedTexts
                    if frameTexts.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "text.badge.xmark")
                                .font(.system(size: 24))
                                .foregroundColor(.mlmInkMuted)
                            Text("No text was recognized in this frame.")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkSecondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(frameTexts, id: \.self) { text in
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(text)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundColor(.mlmInk)
                                            .multilineTextAlignment(.leading)
                                            .textSelection(.enabled)
                                            .padding(8)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.mlmRaised)
                                            .cornerRadius(6)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
                                            )
                                        
                                        HStack(spacing: 8) {
                                            Button(action: {
                                                onApplyArtist(text)
                                                dismiss()
                                            }) {
                                                Label("Artist", systemImage: "person.fill")
                                                    .font(.system(size: 10))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            
                                            Button(action: {
                                                onApplyTitle(text)
                                                dismiss()
                                            }) {
                                                Label("Title", systemImage: "music.note")
                                                    .font(.system(size: 10))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                            
                                            Button(action: {
                                                onApplyBoth(text)
                                                dismiss()
                                            }) {
                                                Label("Use both", systemImage: "sparkles")
                                                    .font(.system(size: 10, weight: .bold))
                                            }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)
                                            .tint(.green)
                                        }
                                        .padding(.leading, 4)
                                    }
                                }
                            }
                            .padding(.trailing, 8)
                        }
                    }
                }
                .padding()
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 400)
                .frame(maxHeight: .infinity)
                .background(Color.mlmSurface)
            }
        }
        .frame(minWidth: 700, idealWidth: 850, minHeight: 480, idealHeight: 560)
        .background(Color.mlmBase)
    }
}
