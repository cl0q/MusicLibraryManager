import SwiftUI

/// Redesigned metadata panel showing detailed track information with clean tabs.
///
/// Organized into three tabs:
/// - **General**: Primary tags with click-to-edit inline support (Title, Artist, Album Artist, Album, Genre, Year).
/// - **Audio & Analysis**: Audio analytical values and manual trigger controls.
/// - **File & System**: Format badge, bitrate, dates, and full paths with Copy and Reveal in Finder.
struct MetadataPanel: View {
    let track: Track

    @Binding var zoomLevel: CGFloat
    @Binding var exponent: Float
    @Binding var gain: Float
    @Binding var waveformHeight: CGFloat

    @Environment(\.container) private var container

    // MARK: - Navigation Tabs
    @State private var selectedTab: Tab = .general

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case audio = "Audio"
        case file = "File"
        case similar = "Groove"

        var id: String { self.rawValue }

        var icon: String {
            switch self {
            case .general: return "pencil.and.outline"
            case .audio: return "waveform"
            case .file: return "doc"
            case .similar: return "sparkles"
            }
        }
    }

    // MARK: - Inline Editing State
    enum EditableField: Hashable {
        case title, artist, albumArtist, album, genre, year
    }

    @State private var editingField: EditableField?
    @State private var editValue: String = ""
    @FocusState private var focusedField: EditableField?

    // MARK: - Analysis Trigger State
    @State private var isAnalyzingReplayGain = false
    @State private var isAnalyzingDanceability = false

    // MARK: - Actions Data
    @State private var playlists: [Playlist] = []
    @State private var syncProfiles: [SyncProfile] = []

    // MARK: - Suggestions State Variables
    @State private var similarTracks: [(track: Track, score: Float, bestMatchOffset: Double)] = []
    @State private var hasEmbedding = false
    @State private var isAnalyzing = false
    @State private var isLoadingSimilar = false
    @State private var showingGroove = false

    var body: some View {
        VStack(spacing: 0) {
            // Premium custom tab bar
            HStack(spacing: 0) {
                ForEach(Tab.allCases) { tab in
                    Button {
                        withAnimation(.interactiveSpring(response: 0.25, dampingFraction: 0.75)) {
                            selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: .medium))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundColor(selectedTab == tab ? .white : .mlmInkSecondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(selectedTab == tab ? Color.mlmAccent : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.mlmRaised)
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Divider()
                .background(Color.mlmEdge)

            // Scrollable Tab Content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case .general:
                        generalTabContent
                    case .audio:
                        audioTabContent
                    case .file:
                        fileTabContent
                    case .similar:
                        similarTabContent
                    }
                }
                .padding(12)
            }

            // Persistent Quick-Add Action Footer
            Divider()
                .background(Color.mlmEdge)

            quickAddActionFooter
                .padding(12)
                .background(Color.mlmRaised)
        }
        .task {
            await loadActionsData()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await loadActionsData() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { _ in
            Task { await loadActionsData() }
        }
        .onAppear {
            checkEmbeddingStatus()
        }
        .onChange(of: track) { _ in
            similarTracks = []
            hasEmbedding = false
            checkEmbeddingStatus()
        }
        .onChange(of: selectedTab) { _, newTab in
            if newTab == .similar {
                showingGroove = true
            }
        }
        .onChange(of: showingGroove) { _, isPresented in
            if !isPresented && selectedTab == .similar {
                selectedTab = .general
            }
        }
    }

    // MARK: - General Tab Content (Editable Tags)

    private var generalTabContent: some View {
        VStack(spacing: 10) {
            editableRow(label: "Titel", value: track.title, field: .title)
            editableRow(label: "Interpret", value: track.artist, field: .artist)
            editableRow(label: "Album-Interpret", value: track.albumArtist, field: .albumArtist)
            editableRow(label: "Album", value: track.album, field: .album)
            editableRow(label: "Genre", value: track.genre ?? "", field: .genre, placeholder: "Kein Genre")
            editableRow(label: "Jahr", value: track.year.map { "\($0)" } ?? "", field: .year, placeholder: "Kein Jahr")
        }
    }

    private func editableRow(
        label: String,
        value: String,
        field: EditableField,
        placeholder: String = ""
    ) -> some View {
        EditableRowView(
            label: label,
            value: value,
            placeholder: placeholder,
            field: field,
            editingField: $editingField,
            editValue: $editValue,
            focusedField: $focusedField,
            onSave: {
                await saveField(field, value: editValue)
            }
        )
    }

    private func saveField(_ field: EditableField, value: String) async {
        guard let trackRepository = container.trackRepository else { return }
        var updatedTrack = track

        switch field {
        case .title:
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            updatedTrack.title = cleaned
        case .artist:
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            updatedTrack.artist = cleaned
        case .albumArtist:
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            updatedTrack.albumArtist = cleaned.isEmpty ? updatedTrack.artist : cleaned
        case .album:
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            updatedTrack.album = cleaned
        case .genre:
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            updatedTrack.genre = cleaned.isEmpty ? nil : cleaned
        case .year:
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty {
                updatedTrack.year = nil
            } else if let parsedYear = Int(cleaned) {
                updatedTrack.year = parsedYear
            } else {
                return // Ignore invalid year inputs
            }
        }

        do {
            try await trackRepository.update(updatedTrack)
            NotificationCenter.default.post(name: .libraryDidImport, object: nil)

            await MainActor.run {
                withAnimation(.easeOut(duration: 0.15)) {
                    editingField = nil
                }
            }
        } catch {
            print("Failed to save track metadata: \(error)")
        }
    }

    // MARK: - Audio & Analysis Tab Content

    private var audioTabContent: some View {
        VStack(spacing: 12) {
            // Analysis values Card
            VStack(spacing: 8) {
                analysisRow("LUFS (Integrated)", value: track.lufsI.map { String(format: "%.1f LUFS", $0) } ?? "—")
                analysisRow("Loudness Range", value: track.lufsRange.map { String(format: "%.1f LU", $0) } ?? "—")
                analysisRow("True Peak", value: track.truePeak.map { String(format: "%.1f dBTP", $0) } ?? "—")
                analysisRow("Tempo (BPM)", value: track.bpm.map { "\($0) BPM" } ?? "—")

                Divider()
                    .background(Color.mlmEdge.opacity(0.4))
                    .padding(.vertical, 4)

                // Energy row
                HStack(spacing: 12) {
                    Text("Energy")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .frame(width: 110, alignment: .leading)
                    EnergyBars(level: track.energyBucket)
                    if let bucket = track.energyBucket {
                        Text("\(bucket)/5")
                            .font(MLMFont.dataSmall)
                            .foregroundColor(.mlmInkMuted)
                    }
                    Spacer()
                }

                // Danceability row
                HStack(spacing: 12) {
                    Text("Danceability")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .frame(width: 110, alignment: .leading)
                    DanceabilitySteps(score: track.danceability)
                    if let d = track.danceability {
                        Text(String(format: "%.0f%%", d * 100))
                            .font(MLMFont.dataSmall)
                            .foregroundColor(.mlmInkMuted)
                    }
                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mlmSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.mlmEdge.opacity(0.15), lineWidth: 1)
                    )
            )

            // Manual Analysis Trigger Card
            VStack(alignment: .leading, spacing: 10) {
                Label("Analyse manuell starten", systemImage: "bolt.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.mlmInk)

                Divider()
                    .background(Color.mlmEdge.opacity(0.4))

                HStack(spacing: 12) {
                    // ReplayGain Trigger
                    Button {
                        analyzeReplayGainNow()
                    } label: {
                        HStack {
                            if isAnalyzingReplayGain {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "waveform.path")
                            }
                            Text("Loudness (LUFS)")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAnalyzingReplayGain || isAnalyzingDanceability || track.isRemote)
                    .help("ReplayGain Lautstärkeanalyse für diesen Song ausführen")

                    // Danceability Trigger
                    Button {
                        analyzeDanceabilityNow()
                    } label: {
                        HStack {
                            if isAnalyzingDanceability {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "figure.dance")
                            }
                            Text("Danceability")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAnalyzingReplayGain || isAnalyzingDanceability || track.isRemote)
                    .help("Rhythmische Tanzbarkeit für diesen Song berechnen")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mlmSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.mlmEdge.opacity(0.15), lineWidth: 1)
                    )
            )

            // Waveform Options Card
            VStack(alignment: .leading, spacing: 12) {
                Label("Waveform-Optionen", systemImage: "slider.horizontal.3")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.mlmInk)

                Divider()
                    .background(Color.mlmEdge.opacity(0.4))

                // Contrast / Sensitivity Slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Empfindlichkeit (Kontrast)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.mlmInkSecondary)
                        Spacer()
                        Text(String(format: "%.1fx", exponent))
                            .font(MLMFont.dataSmall)
                            .foregroundColor(.mlmInkMuted)
                    }
                    Slider(value: $exponent, in: 0.5...3.0, step: 0.1)
                        .controlSize(.small)
                }

                // Gain Slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Verstärkung (Gain)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.mlmInkSecondary)
                        Spacer()
                        Text(String(format: "%.1fx", gain))
                            .font(MLMFont.dataSmall)
                            .foregroundColor(.mlmInkMuted)
                    }
                    Slider(value: $gain, in: 0.5...2.5, step: 0.1)
                        .controlSize(.small)
                }

                // Height Slider
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bereichs-Höhe")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.mlmInkSecondary)
                        Spacer()
                        Text("\(Int(waveformHeight)) pt")
                            .font(MLMFont.dataSmall)
                            .foregroundColor(.mlmInkMuted)
                    }
                    Slider(value: $waveformHeight, in: 60...250, step: 5)
                        .controlSize(.small)
                }

                Divider()
                    .background(Color.mlmEdge.opacity(0.4))

                Button("Zurücksetzen") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        zoomLevel = 1.0
                        exponent = 1.5
                        gain = 1.0
                        waveformHeight = 80.0
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mlmSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.mlmEdge.opacity(0.15), lineWidth: 1)
                    )
            )
        }
    }

    private func analysisRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
            Spacer()
        }
    }

    // MARK: - File & System Tab Content

    private var fileTabContent: some View {
        VStack(spacing: 12) {
            // Path card: Original Path
            pathCard(label: "Original-Pfad", path: track.originalPath)

            // Path card: Organized Path (if exists)
            if let organized = track.organizedPath, !organized.isEmpty {
                pathCard(label: "Organisierter Pfad", path: organized)
            }

            // General File Info Card
            VStack(spacing: 8) {
                fileRow("Format", value: track.format.uppercased())
                fileRow("Bitrate", value: track.bitrate.map { "\($0) kbps" } ?? "—")
                fileRow("Dauer", value: track.formattedDuration)
                fileRow("Hinzugefügt am", value: Self.formatLocalDateTime(track.dateAdded))
                fileRow("Status", value: track.isLocal ? "Lokal" : "Remote")

                if let status = track.downloadStatus {
                    fileRow("Download am", value: Self.formatLocalDateTime(status))
                }

                fileRow("Duplikat", value: track.isDuplicate == 1 ? "Ja" : "Nein")

                if let albumId = track.albumId {
                    fileRow("Album ID", value: "\(albumId)")
                }

                if let variantOf = track.variantOf {
                    fileRow("Variante von", value: "Track #\(variantOf)")
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.mlmSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.mlmEdge.opacity(0.15), lineWidth: 1)
                    )
            )
        }
    }

    private func fileRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
            Spacer()
        }
    }

    private func pathCard(label: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.mlmInkMuted)
                    .tracking(1.0)

                Spacer()

                HStack(spacing: 8) {
                    // Copy path
                    Button {
                        copyPath(for: path)
                    } label: {
                        Label("Kopieren", systemImage: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Pfad in die Zwischenablage kopieren")

                    // Reveal in Finder (Only available if track is local)
                    if track.isLocal {
                        Button {
                            revealInFinder(for: track)
                        } label: {
                            Label("Zeigen", systemImage: "macwindow.and.cursorarrow")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Datei im Finder anzeigen")
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                Text(path)
                    .font(MLMFont.dataSmall)
                    .foregroundColor(.mlmInk)
                    .padding(6)
                    .background(Color.mlmBase.opacity(0.4))
                    .cornerRadius(4)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.mlmSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.mlmEdge.opacity(0.15), lineWidth: 1)
                )
        )
    }

    // MARK: - File Quick Actions

    private func copyPath(for path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private func revealInFinder(for track: Track) {
        Task {
            if let url = await resolveLocalURL(for: track) {
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else {
                // Absolute path fallback
                let raw = track.originalPath
                if raw.hasPrefix("/") {
                    let expanded = (raw as NSString).expandingTildeInPath
                    let url = URL(fileURLWithPath: expanded)
                    await MainActor.run {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
            }
        }
    }

    private func resolveLocalURL(for track: Track) async -> URL? {
        let root = (try? await container.configRepository?.getLibraryRoot()) ?? nil
        if let root, let organized = track.organizedPath, !organized.isEmpty {
            let url = URL(fileURLWithPath: root).appendingPathComponent(organized)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        let raw = track.originalPath
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            let expanded = (raw as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: expanded) {
                return URL(fileURLWithPath: expanded)
            }
        }
        return nil
    }

    // MARK: - Manual Analysis Functions

    private func analyzeReplayGainNow() {
        isAnalyzingReplayGain = true
        Task {
            defer { isAnalyzingReplayGain = false }
            guard let url = await resolveLocalURL(for: track) else { return }
            let analyzer = ReplayGainAnalyzer()
            guard analyzer.isAvailable else { return }

            do {
                if let result = try await analyzer.analyzeTrack(path: url.path),
                   let trackId = track.id,
                   let analysisRepo = container.analysisRepository,
                   let trackRepo = container.trackRepository {

                    // Save ReplayGain
                    let rg = ReplayGain(
                        trackId: trackId,
                        trackGain: result.trackGain,
                        trackPeak: result.trackPeak,
                        albumGain: nil,
                        albumPeak: nil,
                        analyzedAt: ISO8601DateFormatter().string(from: Date())
                    )
                    try await analysisRepo.saveReplayGain(rg)

                    // Compute and save energy bucket
                    let bucket = EnergyBucketer.bucket(lufs: result.loudness)
                    try await trackRepo.updateEnergyBucket(
                        trackId: trackId,
                        energyBucket: bucket,
                        lufsI: result.loudness,
                        lufsRange: result.lufsRange,
                        truePeak: result.trackPeak
                    )

                    NotificationCenter.default.post(name: .libraryDidImport, object: nil)
                }
            } catch {
                print("Failed single ReplayGain analysis: \(error)")
            }
        }
    }

    private func analyzeDanceabilityNow() {
        isAnalyzingDanceability = true
        Task {
            defer { isAnalyzingDanceability = false }
            guard let url = await resolveLocalURL(for: track) else { return }
            let analyzer = DanceabilityAnalyzer()
            guard analyzer.isAvailable else { return }

            do {
                if let danceability = try await analyzer.analyzeTrack(path: url.path),
                   let trackId = track.id,
                   let trackRepo = container.trackRepository {

                    try await trackRepo.updateDanceability(trackId: trackId, danceability: danceability)
                    NotificationCenter.default.post(name: .libraryDidImport, object: nil)
                }
            } catch {
                print("Failed single Danceability analysis: \(error)")
            }
        }
    }

    // MARK: - Persistent Quick-Add Action Footer

    private var quickAddActionFooter: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                // Playlist Menu Button
                Menu {
                    if playlists.isEmpty {
                        Text("Keine Playlists gefunden")
                    } else {
                        ForEach(playlists) { playlist in
                            Button(playlist.name) {
                                addToPlaylist(playlist)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "plus.rectangle.on.folder")
                            .font(.system(size: 11, weight: .bold))
                        Text("Zu Playlist...")
                            .font(.system(size: 11, weight: .bold))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .background(Color.mlmAccent)
                    .cornerRadius(6)
                }
                .menuStyle(.button)
                .help("Diesen Song zu einer Playlist hinzufügen")

                // Sync Profile Menu Button
                Menu {
                    if syncProfiles.isEmpty {
                        Text("Keine Profile gefunden")
                    } else {
                        ForEach(syncProfiles) { profile in
                            Button(profile.name) {
                                addToSyncProfile(profile)
                            }
                        }
                    }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .bold))
                        Text("Zu Sync...")
                            .font(.system(size: 11, weight: .bold))
                        Spacer()
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .background(Color.mlmActive)
                    .cornerRadius(6)
                }
                .menuStyle(.button)
                .help("Diesen Song zu einem Sync-Profil hinzufügen")
            }
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

    private func addToPlaylist(_ playlist: Playlist) {
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
        }
    }

    private func addToSyncProfile(_ profile: SyncProfile) {
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
        }
    }

    // MARK: - Date Formatting

    static func formatLocalDateTime(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: iso) {
            return Self.localFormatter.string(from: date)
        }
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: iso) {
            return Self.localFormatter.string(from: date)
        }
        return iso
    }

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = .current
        f.locale = .current
        return f
    }()

    // MARK: - Groove Similarity Tab Content

    private var similarTabContent: some View {
        VStack(spacing: 12) {
            if isAnalyzing {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                    
                    Text("Analysiere Audio-Drop-Struktur...")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                    
                    Text("ffmpeg decodiert Audio bei 16kHz mono, und CoreML YAMNet extrahiert dichte rhythmische Feature-Vektoren.")
                        .font(MLMFont.dataSmall)
                        .foregroundColor(.mlmInkMuted)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else if !hasEmbedding {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 32))
                        .foregroundColor(.mlmAccent)
                    
                    Text("Keine Groove-Analyse vorhanden")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInk)
                    
                    Text("Analysiere diesen Track, um klanglich und rhythmisch ähnliche Grooves aus deiner Library zu finden.")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    Button {
                        runEmbeddingAnalysis()
                    } label: {
                        HStack {
                            Image(systemName: "wand.and.stars")
                            Text("Groove-Analyse starten")
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.mlmSurface)
                )
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "sparkles.rectangle.stack.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.mlmAccent)
                        .padding(.top, 12)
                    
                    Text("Groove Studio 🚀")
                        .font(MLMFont.sectionHeader)
                        .foregroundColor(.mlmInk)
                    
                    Text("Dieses Lied hat eine aktive Groove-Analyse. Öffne Groove, um:")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Klanglich & rhythmisch ähnliche Tracks finden", systemImage: "music.note.list")
                        Label("SoundCloud & Last.fm Swarm-Empfehlungen laden", systemImage: "globe")
                        Label("Preview-Deck mit eigener Timeline nutzen", systemImage: "play.circle")
                        Label("Tracks downloaden & Vector Gravity trainieren", systemImage: "arrow.down.circle")
                    }
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkSecondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(Color.mlmRaised)
                    .cornerRadius(8)
                    
                    Button {
                        showingGroove = true
                    } label: {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Groove öffnen")
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.mlmAccent)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.mlmSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    LinearGradient(
                                        colors: [Color.mlmAccent.opacity(0.6), Color.mlmActive.opacity(0.3)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.5
                                )
                        )
                )
                .sheet(isPresented: $showingGroove) {
                    GrooveView(seedTrack: track)
                        .environment(\.container, container)
                }
            }
        }
    }

    private func checkEmbeddingStatus() {
        guard let db = container.databaseManager?.pool, let trackId = track.id else { return }
        Task {
            let exists = (try? await db.read { dbConn in
                try TrackEmbedding.exists(dbConn, key: trackId)
            }) ?? false
            
            await MainActor.run {
                self.hasEmbedding = exists
            }
        }
    }

    private func runEmbeddingAnalysis() {
        guard let embeddingService = container.audioEmbeddingService,
              let repo = container.trackRepository,
              let trackId = track.id,
              let duration = track.duration else { return }
        
        isAnalyzing = true
        Task {
            do {
                let resolvedPath: String
                if let organized = track.organizedPath {
                    let root = (try? await container.configRepository?.getLibraryRoot()) ?? ""
                    resolvedPath = root.isEmpty ? organized : URL(fileURLWithPath: root).appendingPathComponent(organized).path
                } else {
                    resolvedPath = track.originalPath
                }
                
                let res = try await embeddingService.analyzeTrackDrop(at: resolvedPath, totalDuration: Double(duration))
                
                let mixCat = MixClassifier.classify(
                    bpm: 126.0,
                    avgLufs: track.lufsI ?? -14.0,
                    lufsRange: track.lufsRange ?? 5.0,
                    artist: track.artist,
                    title: track.title
                )
                let mixCatString = track.duration ?? 0 > 600 ? mixCat.rawValue : nil
                
                try await repo.saveTrackEmbedding(
                    trackId: trackId,
                    embedding: res.embedding,
                    dropOffset: res.offset,
                    mixCategory: mixCatString
                )
                
                await MainActor.run {
                    self.hasEmbedding = true
                    self.isAnalyzing = false
                }
            } catch {
                AppLogger.shared.log("Groove analysis failed: \(error)", level: .error, source: "Suggestions")
                await MainActor.run {
                    self.isAnalyzing = false
                }
            }
        }
    }
}

// MARK: - Helper Views for Editable Metadata Row

struct EditableRowView: View {
    let label: String
    let value: String
    let placeholder: String
    let field: MetadataPanel.EditableField

    @Binding var editingField: MetadataPanel.EditableField?
    @Binding var editValue: String
    @FocusState.Binding var focusedField: MetadataPanel.EditableField?

    let onSave: () async -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.mlmInkMuted)
                .tracking(1.0)

            if editingField == field {
                HStack(spacing: 8) {
                    TextField("", text: $editValue)
                        .textFieldStyle(.plain)
                        .font(MLMFont.body)
                        .focused($focusedField, equals: field)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.mlmAccent, lineWidth: 1.5)
                                .background(Color.mlmBase)
                        )
                        .onSubmit {
                            Task {
                                await onSave()
                            }
                        }
                        .onExitCommand {
                            editingField = nil
                        }

                    Button {
                        Task {
                            await onSave()
                        }
                    } label: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.mlmSuccess)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)

                    Button {
                        editingField = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.mlmError)
                            .font(.system(size: 16))
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            } else {
                HStack {
                    let displayVal = value.isEmpty ? placeholder : value
                    Text(displayVal.isEmpty ? "—" : displayVal)
                        .font(MLMFont.bodyBold)
                        .foregroundColor(value.isEmpty ? .mlmInkMuted : .mlmInk)
                        .lineLimit(2)

                    Spacer()

                    if isHovered {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.mlmAccent)
                            .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    editValue = value
                    editingField = field
                    focusedField = field
                }
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        isHovered = hovering
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isHovered && editingField != field ? Color.mlmRaised : Color.mlmSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.mlmEdge.opacity(0.15), lineWidth: 1)
                )
        )
    }
}
