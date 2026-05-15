# Phase 37: Album-Art-Pipeline durchziehen — Pattern Map

**Mapped:** 2026-05-15
**Files analyzed:** 14 (3 new services, 1 new view, 5 modified files, 5 test files)
**Analogs found:** 11 / 14 (78% match rate; 3 no-analog files follow framework-standard patterns)

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `ArtworkBackfillService.swift` (NEW) | service | background-async-queue | `PlaylistCoverService.swift` | exact — Phase 36 twin |
| `TrackArtworkCache.swift` (NEW) | utility | memory-cache | `NSCache<NSNumber, NSImage>` stdlib | exact — stdlib pattern |
| `TrackCoverView.swift` (NEW) | component | request-response | SwiftUI Image + fallback patterns | partial — no exact analog |
| `ArtworkService.swift` (MODIFY) | service | subprocess | existing file (make extractEmbeddedArtwork static) | self-analog |
| `ArtworkExtractor.swift` (MODIFY) | adapter | subprocess | `ArtworkExtractor.swift` existing (thin wrapper) | self-analog |
| `Notifications.swift` (MODIFY) | config | pub-sub | existing Notifications.swift | self-analog |
| `DependencyContainer.swift` (MODIFY) | config | dependency-injection | existing Container (PlaylistCoverService init pattern line 122-133) | self-analog |
| `LibraryTable.swift` (MODIFY) | component | display | existing file (Title column inline cover) | self-analog |
| `TrackDetailView.swift` (MODIFY) | component | display | existing file (header cover) | self-analog |
| `PlayerBar.swift` (MODIFY) | component | display | existing file (coverThumbnail property) | self-analog |
| `MaintenanceView.swift` (MODIFY) | component | request-response | existing file (button split) | self-analog |
| `ArtworkBackfillServiceTests.swift` (NEW) | test | unit-async | `PlaylistCoverServiceTests` pattern | partial — no exact test file found |
| `TrackCoverViewTests.swift` (NEW) | test | snapshot | SwiftUI view snapshot test pattern | partial — no exact analog |
| `TrackArtworkCacheTests.swift` (NEW) | test | unit | `NSCache` stdlib behavior test | partial — stdlib coverage |

---

## Pattern Assignments

### `ArtworkBackfillService.swift` (service, background-async-queue)

**Closest Analog:** `macos-app/MLM/Services/Playlists/PlaylistCoverService.swift` (Phase 36, lines 26-88)

**Match Quality:** EXACT — This is the direct Phase 36 twin. ArtworkBackfillService replicates the entire @MainActor @Observable lifecycle, notification observer, and async TaskGroup pattern.

#### Imports Pattern (lines 1–5 of PlaylistCoverService)
```swift
import AppKit
import AVFoundation
import Foundation
import GRDB
```

**Adaptation for Phase 37:** Replace AVFoundation with no import needed (ffmpeg via ArtworkService instead); keep AppKit, Foundation, GRDB.

#### Class Declaration and Dependencies (lines 26–55)
```swift
@MainActor
@Observable
final class PlaylistCoverService {
    private let database: any DatabaseWriter
    private let playlistRepository: PlaylistRepository
    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository
    private var inFlight: Set<Int64> = []
    private var observerToken: NSObjectProtocol?

    init(
        database: any DatabaseWriter,
        playlistRepository: PlaylistRepository,
        trackRepository: TrackRepository,
        configRepository: ConfigRepository
    ) {
        self.database = database
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
        self.configRepository = configRepository
        startObserving()
    }
}
```

**Adaptation for Phase 37:**
- Keep @MainActor, @Observable, inFlight coalescing pattern
- Dependencies: database, trackRepository, analysisRepository (not playlistRepository, configRepository)
- observerToken cleanup pattern remains identical (deinit, MainActor.assumeIsolated)
- startObserving() hooks `.libraryDidImport` instead of `.playlistDidChange`
- userInfo origin guard: `["origin": "artworkBackfill"]` (optional; lower re-entry risk than Phase 36)

#### Notification Observer Setup (lines 67–87)
```swift
private func startObserving() {
    observerToken = NotificationCenter.default.addObserver(
        forName: .playlistDidChange,
        object: nil,
        queue: .main
    ) { [weak self] note in
        if (note.userInfo?["origin"] as? String) == "coverService" { return }
        let userInfo = note.userInfo
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let pid = userInfo?["playlistId"] as? Int64 {
                await self.regenerateCover(playlistId: pid)
            }
        }
    }
}
```

**Adaptation for Phase 37:**
- Listen for `.libraryDidImport` instead of `.playlistDidChange`
- No userInfo["playlistId"] target (backfill is library-wide or missing-only)
- Call `await self.backfillMissing()` or `await self.refreshAll()` based on planner's granularity choice (D-16, Claude's Discretion)

#### Async Work Pattern with TaskGroup (implied by Phase 36, detailed in RESEARCH.md)
**Source:** RESEARCH.md code example Pattern 1 (lines 149–225) — ArtworkBackfillService blueprint

```swift
private func backfillMissing() async {
    let tracks = try? await trackRepository.fetchTracksWithoutArtwork()
    guard let tracks else { return }
    
    let total = tracks.count
    var processed = 0
    
    // Chunk into batches for TaskGroup
    let chunks = tracks.chunked(into: 25)
    
    await withTaskGroup(of: Void.self, maxConcurrentTasks: 4) { group in
        for chunk in chunks {
            for track in chunk {
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.extractForTrack(track)
                    processed += 1
                }
            }
        }
    }
}

private func extractForTrack(_ track: Track) async {
    let trackPath = URL(fileURLWithPath: track.organizedPath ?? "")
    guard let data = await ArtworkService.extractEmbeddedArtwork(from: trackPath) else {
        return
    }
    do {
        try await ArtworkService.shared.saveResized(data: data, trackId: track.id ?? 0)
        try await analysisRepository.saveArtwork(...)
        NotificationCenter.default.post(
            name: .trackArtworkDidChange,
            object: nil,
            userInfo: ["trackId": track.id ?? 0, "artworkPath": "..."]
        )
    } catch {
        AppLogger.warn("Artwork backfill failed: \(error)")
    }
}
```

**Adaptations:**
- D-02: maxConcurrentTasks: 4 (established from CONTEXT decision)
- D-03: Post per-track `.trackArtworkDidChange` notification with userInfo schema (trackId, artworkPath)
- D-06: Call `ArtworkService.extractEmbeddedArtwork(from:)` as static method (to be made public in ArtworkService refactor)
- D-07: Silent return nil on ffmpeg missing; log via `AppLogger.warn` once per session

#### Error Handling Pattern (PlaylistCoverService lines 167–174)
```swift
} catch {
    AppLogger.shared.error(
        "Cover regeneration failed for playlist \(playlistId): \(error)",
        source: "PlaylistCover"
    )
}
```

**Adaptation for Phase 37:** Keep structure; log source as "ArtworkBackfill", message includes trackId.

---

### `TrackArtworkCache.swift` (utility, memory-cache)

**Closest Analog:** Foundation `NSCache<K, V>` stdlib pattern + Phase 36 pattern hints (RESEARCH.md lines 283–312)

**Match Quality:** EXACT — NSCache is purpose-built for this pattern; no existing project analog needed.

#### Class Definition and Initialization (RESEARCH.md Pattern 3 lines 284–292)
```swift
final class TrackArtworkCache: @unchecked Sendable {
    static let shared = TrackArtworkCache()
    
    private let cache = NSCache<NSNumber, NSImage>()
    
    init() {
        cache.countLimit = 200  // Max 200 images in memory
    }
```

**Concrete implementation:**
- Singleton pattern: `static let shared = TrackArtworkCache()`
- @unchecked Sendable to satisfy actor isolation (NSCache is thread-safe internally)
- countLimit = 200 (from D-09 decision; tunable per planner's profiling)
- Cache key: `NSNumber(value: trackId * 10000 + Int64(size.rawValue))` or simpler scheme depending on ArtworkService.ArtworkSize definition

#### Core Methods (RESEARCH.md Pattern 3 lines 294–310)
```swift
func image(forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) -> NSImage? {
    let key = NSNumber(value: trackId * 10000 + Int64(size.rawValue))
    return cache.object(forKey: key)
}

func setImage(_ image: NSImage, forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) {
    let key = NSNumber(value: trackId * 10000 + Int64(size.rawValue))
    cache.setObject(image, forKey: key)
}

func invalidate(forTrackId trackId: Int64) {
    // Remove all sizes for this track
    for size in [ArtworkService.ArtworkSize.small, .large] {
        let key = NSNumber(value: trackId * 10000 + Int64(size.rawValue))
        cache.removeObject(forKey: key)
    }
}
```

**No imports needed beyond Foundation; no dependencies.**

---

### `TrackCoverView.swift` (component, request-response)

**Closest Analogs:** 
1. SwiftUI Image + RoundedRectangle pattern (existing in PlayerBar.swift lines 69–78, TrackDetailView fallback patterns)
2. Notification observation pattern (LibraryTable, other views using `.onReceive(NotificationCenter.default.publisher(for:))`)
3. File-existence + async-load pattern (PlaylistCoverService URL resolution lines 239–253)

**Match Quality:** PARTIAL — No single analog view exists; pattern is synthesized from SwiftUI stdlib + existing codebase patterns.

#### View Structure and State (RESEARCH.md code example lines 502–537)
```swift
struct TrackCoverView: View {
    let trackId: Int64
    let size: ArtworkService.ArtworkSize
    var cornerRadius: CGFloat = 6
    
    @State private var image: NSImage?
    @State private var isLoading = false
    @Environment(\.container) private var container
    
    var body: some View {
        ZStack {
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else if isLoading {
                ProgressView()
                    .frame(width: sizePoints, height: sizePoints)
            } else {
                fallbackGradient
            }
        }
        .frame(width: sizePoints, height: sizePoints)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .onReceive(NotificationCenter.default.publisher(for: .trackArtworkDidChange)) { note in
            if (note.userInfo?["trackId"] as? Int64) == trackId {
                image = nil
                isLoading = true
                loadImage()
            }
        }
        .task {
            await loadImage()
        }
    }
}
```

**Adaptations:**
- @Environment(\.container) pattern copied from LibraryTable.swift line 10
- @State image: NSImage? — loads from TrackArtworkCache or disk
- Notification observation: `.trackArtworkDidChange` (new notification, defined in Notifications.swift by Phase 37)
- Size calculation via sizePoints computed property (18pt for .small, 128pt for .large per D-12)

#### File-Existence Check + Self-Healing (RESEARCH.md code lines 539–569, also D-14 in CONTEXT.md)
```swift
private func loadImage() async {
    isLoading = true
    defer { isLoading = false }
    
    // 1. Check cache first
    if let cached = TrackArtworkCache.shared.image(forTrackId: trackId, size: size) {
        image = cached
        return
    }
    
    // 2. Get artwork path from DB
    guard let artworkPath = try? await container.analysisRepository?.fetchArtwork(trackId: trackId)?.artworkPath else {
        return
    }
    
    // 3. Check file existence (D-14 self-healing)
    let fileURL = URL(fileURLWithPath: artworkPath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        if let service = container.artworkBackfillService {
            await service.refreshSingleTrack(trackId: trackId)
        }
        return
    }
    
    // 4. Load and cache
    if let nsImage = NSImage(contentsOfFile: fileURL.path) {
        TrackArtworkCache.shared.setImage(nsImage, forTrackId: trackId, size: size)
        image = nsImage
    }
}
```

**Adaptations:**
- D-14: File-existence check before attempting NSImage load
- D-14: Trigger single-track refresh via `ArtworkBackfillService.refreshSingleTrack(trackId:)` if file missing but DB row exists
- AnalysisRepository pattern copied from PlaylistCoverService.swift lines 100–110 (async fetch pattern)

#### Fallback Gradient Rendering (RESEARCH.md code lines 578–590, D-11 in CONTEXT.md)
```swift
private var fallbackGradient: some View {
    RoundedRectangle(cornerRadius: cornerRadius)
        .fill(LinearGradient(
            gradient: Gradient(colors: [.mlmBase, .mlmRaised]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        ))
        .overlay(
            Image(systemName: "music.note")
                .foregroundStyle(.mlmInkMuted)
                .font(.system(size: sizePoints / 2))
        )
}

private var sizePoints: CGFloat {
    switch size {
    case .small: return 40   // PlayerBar
    case .large: return 128  // TrackDetailView
    }
}
```

**Source:** Solar palette colors (mlmBase, mlmRaised, mlmInkMuted) copied from Phase 36 colors.swift; music.note icon from SF Symbols (iOS/macOS stdlib).

---

### `ArtworkService.swift` (MODIFY — make extractEmbeddedArtwork static + public)

**Current Analog:** File itself (macos-app/MLM/Services/Analysis/ArtworkService.swift lines 119–150)

**Match Quality:** SELF-ANALOG — Extract the existing private instance method and convert to static.

#### Current Private Method (lines 119–150)
```swift
private func extractEmbeddedArtwork(from path: String) -> Data? {
    guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else { return nil }

    let tmpOutput = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".jpg")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: ffmpeg)
    process.arguments = [
        "-i", path,
        "-an", "-vcodec", "mjpeg", "-vframes", "1",
        "-y", tmpOutput.path
    ]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0,
           FileManager.default.fileExists(atPath: tmpOutput.path) {
            let data = try Data(contentsOf: tmpOutput)
            try? FileManager.default.removeItem(at: tmpOutput)
            return data.isEmpty ? nil : data
        }
    } catch {}

    try? FileManager.default.removeItem(at: tmpOutput)
    return nil
}
```

#### Phase 37 Refactor (D-05 API change)
**Change to:**
```swift
static func extractEmbeddedArtwork(from url: URL) async -> Data? {
    return await Task.detached(priority: .default) { () -> Data? in
        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else {
            AppLogger.warn("ffmpeg not found — artwork extraction disabled")
            return nil
        }
        
        let tmpOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".jpg")
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-i", url.path,
            "-an", "-vcodec", "mjpeg", "-vframes", "1",
            "-y", tmpOutput.path
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0,
               FileManager.default.fileExists(atPath: tmpOutput.path) {
                let data = try Data(contentsOf: tmpOutput)
                try? FileManager.default.removeItem(at: tmpOutput)
                return data.isEmpty ? nil : data
            }
        } catch {
            AppLogger.error("ffmpeg extraction failed: \(error)")
        }
        
        try? FileManager.default.removeItem(at: tmpOutput)
        return nil
    }.value
}
```

**Key changes (D-05, D-06, D-07):**
- Signature: `static func extractEmbeddedArtwork(from url: URL) async -> Data?`
- Parameter: URL instead of String path (safer, matches SwiftUI conventions)
- Wrap in Task.detached to avoid blocking @MainActor callers
- D-07: Silent return nil on ffmpeg missing; log once via AppLogger.warn
- No Result enum, no internal size handling (caller decides)

#### Existing Callers to Update
**batchFetchArtwork (line 82):** Change from:
```swift
if let embeddedData = extractEmbeddedArtwork(from: filePath) {
```
To:
```swift
let trackURL = URL(fileURLWithPath: filePath)
if let embeddedData = await Self.extractEmbeddedArtwork(from: trackURL) {
```

---

### `ArtworkExtractor.swift` (MODIFY — become thin wrapper)

**Current Analog:** File itself (lines 16–29); Phase 36 AVFoundation pattern

**Match Quality:** SELF-ANALOG — Rewrite body to call ArtworkService.extractEmbeddedArtwork instead of AVFoundation.

#### Current Implementation (lines 16–29)
```swift
enum ArtworkExtractor {
    static func extract(audioURL: URL) async -> Data? {
        let asset = AVURLAsset(url: audioURL)
        guard let isPlayable = try? await asset.load(.isPlayable), isPlayable else {
            return nil
        }
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        let artworkItems = AVMetadataItem.metadataItems(
            from: items,
            filteredByIdentifier: .commonIdentifierArtwork
        )
        guard let item = artworkItems.first else { return nil }
        return try? await item.load(.dataValue)
    }
}
```

#### Phase 37 Refactor
**Change to (D-05 wrapper):**
```swift
enum ArtworkExtractor {
    /// Thin wrapper: delegates to ArtworkService.extractEmbeddedArtwork (ffmpeg-based).
    /// Maintains signature for compatibility with PlaylistCoverService:112 caller.
    static func extract(audioURL: URL) async -> Data? {
        return await ArtworkService.extractEmbeddedArtwork(from: audioURL)
    }
}
```

**Rationale:**
- PlaylistCoverService.regenerateCover (line 112) calls `await ArtworkExtractor.extract(audioURL:)` — preserve signature
- Signature: `async -> Data?` unchanged
- Caller (PlaylistCoverService) receives same Data or nil, passes to NSImage(data:) without modification
- No AVFoundation import needed; remove if unused elsewhere

---

### `Notifications.swift` (MODIFY — add .trackArtworkDidChange)

**Current Analog:** File itself (macos-app/MLM/Utilities/Notifications.swift lines 1–77)

**Match Quality:** SELF-ANALOG — Add new notification to existing extension.

#### Existing Pattern (lines 19–26 example)
```swift
static let libraryDidImport = Notification.Name("MLMLibraryDidImport")

static let libraryDidDeleteTracks = Notification.Name("MLMLibraryDidDeleteTracks")

static let libraryRootDidChange = Notification.Name("MLMLibraryRootDidChange")
```

#### Phase 37 Addition (D-03 notification definition)
**Add after playlistDidChange (after line 47):**
```swift
/// Posted when track artwork is extracted and cached (per-track granularity).
///
/// Fired by ArtworkBackfillService after successful extraction + DB save.
/// Views (TrackCoverView, LibraryTable, etc.) observe and invalidate cache for the affected track.
/// - `userInfo["trackId"]`: `Int64` — track ID whose artwork was updated
/// - `userInfo["artworkPath"]`: `String` — path to the cached artwork file (1200px version)
static let trackArtworkDidChange = Notification.Name("MLMTrackArtworkDidChange")
```

**Location:** After `.playlistDidChange` definition (around line 47) in the Playlists section, or in a new "Artwork" section.

---

### `DependencyContainer.swift` (MODIFY — wire ArtworkBackfillService)

**Closest Analog:** File itself (macos-app/MLM/App/DependencyContainer.swift lines 122–133 PlaylistCoverService init pattern)

**Match Quality:** EXACT — Copy the PlaylistCoverService initialization pattern exactly.

#### Existing PlaylistCoverService Pattern (lines 36–38, 118–133)
```swift
// Line 36–38 property declaration
private(set) var playlistCoverService: PlaylistCoverService?

// Lines 122–133 initialization in initialize() method
if let plRepo = self.playlistRepository,
   let trRepo = self.trackRepository,
   let cfRepo = self.configRepository {
    self.playlistCoverService = await MainActor.run {
        PlaylistCoverService(
            database: dbPool,
            playlistRepository: plRepo,
            trackRepository: trRepo,
            configRepository: cfRepo
        )
    }
}
```

#### Phase 37 Adaptation (add ArtworkBackfillService)

**1. Add property (after line 38):**
```swift
/// Artwork extraction orchestrator (Phase 37). Observes `.libraryDidImport`
/// and runs background backfill with TaskGroup(maxConcurrentTasks: 4).
private(set) var artworkBackfillService: ArtworkBackfillService?
```

**2. Add initialization (after PlaylistCoverService block, around line 133):**
```swift
// Phase 37 — Artwork backfill orchestrator. Observes `.libraryDidImport`
// and extracts embedded artwork for imported tracks in background queue.
if let trRepo = self.trackRepository,
   let aRepo = self.analysisRepository {
    self.artworkBackfillService = await MainActor.run {
        ArtworkBackfillService(
            database: dbPool,
            trackRepository: trRepo,
            analysisRepository: aRepo
        )
    }
}
```

**Note:** ArtworkBackfillService dependencies are database, trackRepository, analysisRepository (not playlistRepository or configRepository).

---

### `LibraryTable.swift` (MODIFY — inject TrackCoverView in Title column)

**Closest Analog:** File itself (macos-app/MLM/Views/Library/LibraryTable.swift lines 54–67 Title column definition)

**Match Quality:** SELF-ANALOG — Modify existing Title column TableColumn closure.

#### Current Title Column (lines 55–67)
```swift
TableColumn("Title", value: \.track.title) { row in
    let track = row.track
    HStack(spacing: 6) {
        if isNowPlaying(track) {
            Image(systemName: "speaker.wave.2.fill")
                .imageScale(.small)
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.variableColor, isActive: true)
        }
        Text(track.title).lineLimit(1)
    }
}
.width(min: 140, ideal: 260)
```

#### Phase 37 Refactor (D-13 inline cover)
```swift
TableColumn("Title", value: \.track.title) { row in
    let track = row.track
    HStack(spacing: 8) {
        // New: Inline cover thumbnail (18pt)
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
.width(min: 160, ideal: 280)  // Slightly increased to accommodate cover
```

**Changes:**
- Add TrackCoverView as first element in HStack (D-13)
- size: .small (18pt thumbnail per D-12)
- cornerRadius: 4 (compact for table context per UI-SPEC)
- spacing: 8 (md token per UI-SPEC)
- Increase min/ideal widths slightly to breathe (min: 140 → 160, ideal: 260 → 280)
- @Environment(\.container) is already available at LibraryTable level (line 10)

---

### `TrackDetailView.swift` (MODIFY — replace header placeholder with TrackCoverView)

**Closest Analog:** File itself (implied from CONTEXT.md line 111 reference to existing header section with RoundedRectangle + music.note)

**Match Quality:** SELF-ANALOG — Replace existing fallback placeholder with TrackCoverView component.

#### Current Pattern (inferred from CONTEXT.md reference)
The existing header has a RoundedRectangle(cornerRadius:) with LinearGradient fallback + music.note icon. This is being replaced.

#### Phase 37 Implementation (D-10, D-12)
**Replace the existing RoundedRectangle placeholder with:**
```swift
TrackCoverView(
    trackId: track.id ?? 0, 
    size: .large, 
    cornerRadius: 6
)
.frame(width: 56, height: 56)  // D-12 baseline; may grow to 128pt per ROADMAP
```

**Integration context:** The TrackDetailView header section layout (VStack or HStack containing title, artist, format badge, play button, etc.) remains unchanged; the cover is simply a child view within the existing layout.

**Note:** Fallback rendering (Solar gradient + music.note) is built into TrackCoverView itself, so no separate placeholder code is needed.

---

### `PlayerBar.swift` (MODIFY — replace coverThumbnail property with TrackCoverView)

**Closest Analog:** File itself (macos-app/MLM/Views/Player/PlayerBar.swift lines 69–78 coverThumbnail property)

**Match Quality:** SELF-ANALOG — Replace property body entirely.

#### Current Implementation (lines 69–78)
```swift
private var coverThumbnail: some View {
    RoundedRectangle(cornerRadius: 5, style: .continuous)
        .fill(Color(nsColor: .controlColor))
        .overlay {
            Image(systemName: "music.note")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(width: 40, height: 40)
}
```

#### Phase 37 Refactor (D-10, D-12)
```swift
private var coverThumbnail: some View {
    TrackCoverView(
        trackId: viewModel.currentTrack?.id ?? 0,
        size: .small,
        cornerRadius: 5
    )
    .frame(width: 40, height: 40)
}
```

**Changes:**
- trackId: Pull from viewModel.currentTrack?.id (existing viewModel already provides current track)
- size: .small (40pt per D-12)
- cornerRadius: 5 (matches existing value)
- .frame(width: 40, height: 40) maintains bounds
- Fallback gradient + music.note built into TrackCoverView

---

### `MaintenanceView.swift` (MODIFY — split Artwork buttons per D-16)

**Closest Analog:** File itself (referenced in CONTEXT.md line 106 as location of current `runArtwork()` method at line 170–195)

**Match Quality:** SELF-ANALOG — Refactor button layout and handler methods.

#### Current Pattern (inferred)
Single button labeled "Fetch Artwork" or similar, wired to a `runArtwork()` method that calls ArtworkService.batchFetchArtwork.

#### Phase 37 Split (D-16 decision)
**Replace single button with two:**

```swift
// Button 1: Refresh embedded artwork (ffmpeg-based backfill)
Button(action: { Task { await runArtworkEmbedded() } }) {
    Label("Refresh embedded artwork", systemImage: "waveform.circle.fill")
}

// Button 2: Fetch from MusicBrainz (network-based, rate-limited)
Button(action: { Task { await runArtworkMusicBrainz() } }) {
    Label("Fetch from MusicBrainz", systemImage: "globe")
}
```

**Handler methods:**

```swift
/// Refresh embedded artwork for tracks without artwork via ArtworkBackfillService.
private func runArtworkEmbedded() async {
    guard let service = container.artworkBackfillService else { return }
    // Call refreshMissing() or refreshAll() based on planner discretion
    await service.refreshMissing()  // or refreshAll()
}

/// Fetch artwork from MusicBrainz for tracks without embedded art.
private func runArtworkMusicBrainz() async {
    guard let service = container.artworkService else { return }
    // Existing batchFetchArtwork logic, unchanged
    let tracks = try? await container.trackRepository?.fetchAll()
    if let tracks = tracks {
        let result = await service.batchFetchArtwork(tracks: tracks, repository: ...)
        // Update UI with result
    }
}
```

**Rationale:**
- D-16 splits the user action into two explicit buttons
- First button: fast, local, no network (ffmpeg backfill via ArtworkBackfillService)
- Second button: slower, network-dependent (MusicBrainz fetch via existing ArtworkService.batchFetchArtwork)

---

## Shared Patterns

### @MainActor @Observable Service Lifecycle
**Source:** `PlaylistCoverService.swift` lines 26–88
**Apply to:** `ArtworkBackfillService` (new service)

Pattern for long-lived background services that observe notifications and dispatch async work:
1. @MainActor isolation on class
2. @Observable for reactive state updates
3. NotificationCenter.addObserver with [weak self] capture
4. Task { @MainActor [weak self] in … } for re-entry from notification callback
5. inFlight: Set<Int64> coalescing to prevent duplicate requests
6. deinit cleanup with MainActor.assumeIsolated for token removal

**Concrete excerpt:**
```swift
@MainActor
@Observable
final class ArtworkBackfillService {
    private var inFlight: Set<Int64> = []
    private var observerToken: NSObjectProtocol?
    
    init(...) { startObserving() }
    
    deinit {
        if let token = MainActor.assumeIsolated({ observerToken }) {
            NotificationCenter.default.removeObserver(token)
        }
    }
    
    private func startObserving() {
        observerToken = NotificationCenter.default.addObserver(
            forName: .libraryDidImport,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor [weak self] in
                await self?.backfillMissing()
            }
        }
    }
}
```

---

### Task.detached for Subprocess Isolation
**Source:** `ArtworkService.extractEmbeddedArtwork` (lines 119–150) + RESEARCH.md Pattern 2 (lines 229–273)
**Apply to:** `ArtworkService.extractEmbeddedArtwork(from:)` static method (Phase 37 refactor)

Pattern for running blocking I/O (Process, file operations) without blocking the @MainActor:
1. Wrap in `await Task.detached(priority: .default) { … }.value`
2. Inside detached block, run Process synchronously (waitUntilExit is OK inside detached task)
3. Handle errors silently or log minimally
4. Return data or nil; caller decides post-processing

**Concrete excerpt:**
```swift
static func extractEmbeddedArtwork(from url: URL) async -> Data? {
    return await Task.detached(priority: .default) { () -> Data? in
        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else {
            AppLogger.warn("ffmpeg not found — artwork extraction disabled")
            return nil
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-i", url.path, "-an", "-vcodec", "mjpeg", "-vframes", "1", "-y", tmpOutput.path]
        // ... set standardOutput/Error to /dev/null ...
        try process.run()
        process.waitUntilExit()
        // ... cleanup and return data ...
    }.value
}
```

---

### NSCache with Key Scoping
**Source:** Foundation `NSCache<K, V>` + RESEARCH.md Pattern 3 (lines 283–312)
**Apply to:** `TrackArtworkCache` (new utility)

Pattern for thread-safe in-memory image caching with automatic memory pressure eviction:
1. Singleton: `static let shared = TrackArtworkCache()`
2. Internal NSCache<NSNumber, NSImage>
3. countLimit set conservatively (200 images baseline)
4. Keys scoped by trackId + size (e.g., `trackId * 10000 + size.rawValue`)
5. Invalidate entire track (all sizes) on notification

**Concrete excerpt:**
```swift
final class TrackArtworkCache: @unchecked Sendable {
    static let shared = TrackArtworkCache()
    private let cache = NSCache<NSNumber, NSImage>()
    
    init() { cache.countLimit = 200 }
    
    func image(forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) -> NSImage? {
        let key = NSNumber(value: trackId * 10000 + Int64(size.rawValue))
        return cache.object(forKey: key)
    }
    
    func setImage(_ image: NSImage, forTrackId trackId: Int64, size: ArtworkService.ArtworkSize) {
        let key = NSNumber(value: trackId * 10000 + Int64(size.rawValue))
        cache.setObject(image, forKey: key)
    }
    
    func invalidate(forTrackId trackId: Int64) {
        for size in [ArtworkService.ArtworkSize.small, .large] {
            let key = NSNumber(value: trackId * 10000 + Int64(size.rawValue))
            cache.removeObject(forKey: key)
        }
    }
}
```

---

### Notification Observation + Cache Invalidation
**Source:** `PlaylistCoverService.startObserving()` lines 67–87 (re-entry guard pattern) + `LibraryTable` @Environment pattern
**Apply to:** `TrackCoverView` (observe .trackArtworkDidChange)

Pattern for SwiftUI views to react to notifications and refresh cached state:
1. Use `.onReceive(NotificationCenter.default.publisher(for: name))` or `.addObserver` in Task
2. Guard on userInfo to target the specific instance (trackId match)
3. Invalidate cache + reload on match
4. Use @Environment(\.container) for service access if needed

**Concrete excerpt for TrackCoverView:**
```swift
struct TrackCoverView: View {
    let trackId: Int64
    @State private var image: NSImage?
    @Environment(\.container) private var container
    
    var body: some View {
        // ... view content ...
            .onReceive(NotificationCenter.default.publisher(for: .trackArtworkDidChange)) { note in
                if (note.userInfo?["trackId"] as? Int64) == trackId {
                    TrackArtworkCache.shared.invalidate(forTrackId: trackId)
                    image = nil
                    Task { await loadImage() }
                }
            }
    }
}
```

---

### File-Existence Check + Self-Healing
**Source:** `PlaylistCoverService.resolveLocalURL()` lines 239–253 (file existence check pattern) + D-14 (self-healing decision)
**Apply to:** `TrackCoverView.loadImage()` async method

Pattern for gracefully handling missing files (e.g., user cleared cache) by triggering re-backfill:
1. Query DB for artwork_path
2. Check `FileManager.fileExists(atPath:)` on the resolved path
3. If file missing but DB row exists: trigger single-track re-backfill via `ArtworkBackfillService.refreshSingleTrack(trackId:)`
4. While re-backfill is pending, render fallback (no error banner)

**Concrete excerpt:**
```swift
private func loadImage() async {
    // ... cache check, DB fetch ...
    
    guard let artworkPath = try? await container.analysisRepository?.fetchArtwork(trackId: trackId)?.artworkPath else {
        return  // No DB row; render fallback
    }
    
    let fileURL = URL(fileURLWithPath: artworkPath)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        // D-14: File missing, trigger self-healing
        if let service = container.artworkBackfillService {
            await service.refreshSingleTrack(trackId: trackId)
        }
        return  // Render fallback while re-backfill is pending
    }
    
    // File exists; load
    if let nsImage = NSImage(contentsOfFile: fileURL.path) {
        TrackArtworkCache.shared.setImage(nsImage, forTrackId: trackId, size: size)
        image = nsImage
    }
}
```

---

### Environment Dependency Injection
**Source:** `LibraryTable.swift` line 10 (@Environment pattern)
**Apply to:** All views using container (TrackCoverView, MaintenanceView, etc.)

Pattern for accessing DependencyContainer in SwiftUI views:
```swift
@Environment(\.container) private var container

// Use like:
guard let repo = container.analysisRepository else { return }
guard let service = container.artworkBackfillService else { return }
```

**Note:** DependencyContainer must be injected at root (AppDelegate/ContentView level) via:
```swift
.environment(\.container, DependencyContainer.shared)
```

---

## No Analog Found

Files with no close existing analog in the codebase (planner should bootstrap from stdlib/framework patterns):

| File | Role | Data Flow | Reason | Fallback Pattern |
|------|------|-----------|--------|------------------|
| `ArtworkBackfillServiceTests.swift` | test | unit-async | No existing async service unit test file in codebase; PlaylistCoverServiceTests may exist but wasn't found in search | XCTest + Task-based async test pattern from Apple docs; mock FileManager + ProcessRunner for subprocess testing |
| `TrackCoverViewTests.swift` | test | snapshot | No existing SwiftUI view snapshot test file found | XCTest + snapshot testing pattern (SwiftUI Previews + assertSnapshot, or manual image comparison) |
| `TrackArtworkCacheTests.swift` | test | unit | Standard NSCache behavior test (no app-specific analog) | XCTest + NSCache.countLimit verification + eviction behavior testing (standard Foundation testing) |

---

## Metadata

**Analog search scope:** 
- `macos-app/MLM/Services/` (Playlists, Analysis, Common, Import)
- `macos-app/MLM/Views/` (Library, TrackDetail, Player, Settings)
- `macos-app/MLM/App/` (DependencyContainer)
- `macos-app/MLM/Utilities/` (ProcessRunner, Notifications)
- `macos-app/MLM/Models/` (Track, Playlist, etc.)

**Files scanned:** 12 (PlaylistCoverService, ArtworkService, ArtworkExtractor, ProcessRunner, Notifications, DependencyContainer, LibraryTable, TrackDetailView, PlayerBar, MaintenanceView, and related)

**Pattern extraction date:** 2026-05-15

---

## PATTERN MAPPING COMPLETE

**Phase:** 37 — Album-Art-Pipeline durchziehen
**Files classified:** 14 (3 new services/utilities, 1 new view, 5 modified existing, 5 new test files)
**Analogs found:** 11 / 14 (78% match; 3 test files use stdlib/framework patterns)

### Coverage Summary
- **Files with exact analog:** 8
  - ArtworkBackfillService ← PlaylistCoverService (Phase 36 twin)
  - TrackArtworkCache ← NSCache stdlib pattern
  - ArtworkService (refactor) ← self-analog
  - ArtworkExtractor (refactor) ← self-analog
  - Notifications (add) ← self-analog
  - DependencyContainer (modify) ← self-analog (PlaylistCoverService init pattern)
  - LibraryTable, TrackDetailView, PlayerBar, MaintenanceView ← self-analogs

- **Files with partial analog:** 3
  - TrackCoverView ← SwiftUI Image + Notification pattern (synthesized from multiple sources)
  - ArtworkBackfillServiceTests ← XCTest async pattern
  - TrackCoverViewTests ← SwiftUI snapshot test pattern

- **Files with no analog (framework-standard):** 3
  - TrackArtworkCacheTests ← NSCache stdlib behavior test
  - (2 test patterns are bootstrapped from Apple framework examples)

### Key Patterns Identified
1. **@MainActor @Observable service with notification observer** — Phase 36 PlaylistCoverService is direct blueprint; ArtworkBackfillService replicates lifecycle exactly
2. **Task.detached subprocess isolation** — ProcessRunner + Task.detached pattern prevents UI blocking during ffmpeg extraction
3. **NSCache for hot-path image caching** — 200-image countLimit, scoped by trackId + size, automatic eviction under memory pressure
4. **Per-track notifications for incremental UI updates** — .trackArtworkDidChange fires post-extraction; views invalidate cache + reload individually (not batch)
5. **File-existence self-healing** — TrackCoverView checks both DB row + file existence; triggers single-track re-backfill if mismatch (D-14)
6. **DependencyContainer pattern for service wiring** — PlaylistCoverService init (line 122–133) is exact template for ArtworkBackfillService

### Ready for Planning
Planner can now reference these analogs and code excerpts in PLAN.md. Each task section can cite "Analog: PlaylistCoverService lines 26–88" and paste concrete code to adapt.

---

*Phase 37: Album-Art-Pipeline durchziehen*
*Pattern mapping: 2026-05-15*
*Status: COMPLETE*
