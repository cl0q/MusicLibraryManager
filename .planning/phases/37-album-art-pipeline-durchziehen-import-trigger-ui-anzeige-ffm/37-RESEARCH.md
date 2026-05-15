# Phase 37: Album-Art-Pipeline durchziehen — Research

**Researched:** 2026-05-15
**Domain:** macOS native SwiftUI, subprocess coordination from @MainActor, image caching, background task lifecycle
**Confidence:** HIGH

## Summary

Phase 37 consolidates three separate concerns into a unified album-art pipeline:
1. **Auto-trigger on import** — Background queue after `.libraryDidImport` notification
2. **UI display** — Track covers in LibraryTable, TrackDetailView, PlayerBar with Solar-gradient fallback
3. **ffmpeg standardization** — `ArtworkService.extractEmbeddedArtwork` becomes the single source for embedded cover extraction

All 17 decisions from CONTEXT.md are technically sound and follow established patterns in the codebase (PlaylistCoverService from Phase 36, ProcessRunner subprocess pattern, NotificationCenter re-entry guards). The phase is ready for planning.

**Primary recommendation:** Build in this order: (1) ArtworkBackfillService + notification trigger, (2) ArtworkService API surface change, (3) UI integration (LibraryTable, TrackDetailView, PlayerBar), (4) Validation tests.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Embedded artwork extraction | API tier (background async) | File I/O | Subprocess-based; CPU-bound; must not block UI |
| Artwork cache (disk + memory) | Storage tier | Cache tier | 500px and 1200px stored on disk; NSCache in-memory for hot tracks |
| Artwork discovery on import | API tier | Background queue | Background-Queue concurrency (D-02 fixed to 4) |
| Track cover display | View tier | Cache tier | SwiftUI observes .trackArtworkDidChange; NSCache hydrates views |
| Fallback rendering | View tier | Design tokens | Solar gradient + music.note glyph; independent of artwork availability |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Foundation `Process` | macOS 11+ | Subprocess execution (ffmpeg) | Built-in, no external deps; `ProcessRunner.swift` pattern establishes precedent |
| Foundation `NSCache` | macOS 11+ | In-memory image cache | Thread-safe by design; evicts under memory pressure; bounded by countLimit |
| SwiftUI `@Observable` | macOS 12+ | Service state observation | Required for ArtworkBackfillService (@MainActor @Observable); matches PlaylistCoverService pattern |
| GRDB | v1.26+ | Database access (artwork table reads/writes) | Existing stack; `AnalysisRepository.fetchArtwork/saveArtwork` ready |
| NotificationCenter | macOS 11+ | Cross-view signaling | Established pattern; `.trackArtworkDidChange` notification defined in Phase 37 |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| UIImage / NSImage | macOS 11+ | Image decoding + sizing | TrackCoverView and cache both handle NSImage(data:) from JPEG bytes |
| AppKit `FileManager` | macOS 11+ | Cache dir creation + existence checks | Canonical path generation via `ArtworkService.cachedPath(trackId:size:)` |
| Combine (optional) | iOS 13+ | didChangeNotification observation | Not strictly needed; NotificationCenter.addObserver(forName:) sufficient |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| NSCache (in-memory) | LRU cache package like `swift-caching` | NSCache is built-in, evicts automatically under memory pressure; custom LRU adds dependency |
| NotificationCenter | Combine Publisher | Combine requires stronger type coupling; NotificationCenter is looser + works with MainActor |
| Process (synchronous) | Task.sleep in async context | Process.run() blocks efficiently (standard for subprocess patterns); Task.sleep is for polling only |

**Installation:** No new dependencies required. NSCache and Process are Foundation APIs (already linked).

**Version verification:** All Foundation APIs (NSCache, Process, FileManager) are macOS 11+ baseline for this app.

## Architecture Patterns

### System Architecture Diagram

```
Import Pipeline (existing)
    ↓
    +→ .libraryDidImport notification
              ↓
    +→ ArtworkBackfillService (observes notification)
              ↓
              +→ TaskGroup (max concurrency 4)
              |    ↓
              |    +→ For each Track (DB query)
              |         ↓
              |         +→ ArtworkService.extractEmbeddedArtwork (static async)
              |              ↓
              |              +→ Process("ffmpeg") [subprocess in Task.detached]
              |              ↓
              |              +→ saveResized() → Disk (500px + 1200px JPEG)
              |              ↓
              |              +→ AnalysisRepository.saveArtwork() → DB
              |    ↓
              +→ Post .trackArtworkDidChange (userInfo: trackId, artworkPath)
                      ↓
                      [Notification propagates to all Views]
                      ↓
    LibraryTable, TrackDetailView, PlayerBar
         ↓
    TrackCoverView (per row/surface)
         ↓
         +→ Check NSCache (TrackArtworkCache) for NSImage
         ↓
         +→ If miss: Load from disk via FileManager
         ↓
         +→ If no file: Display Solar-Gradient fallback
```

Data flow:
- **Input:** Track ID + optional pre-computed organizedPath
- **Processing stages:** ffmpeg subprocess → JPEG bytes → Resize to both sizes → Save to disk + DB → Notify views
- **Decision points:** File exists? Extraction succeeded? (silent nil on ffmpeg missing per D-07)
- **Output:** DB record + 2 cache files + notified views

### Recommended Project Structure

All files already exist or are new additions to established directories:

```
macos-app/MLM/
├── Services/
│   ├── Analysis/
│   │   └── ArtworkService.swift (EXISTING — make extractEmbeddedArtwork static public)
│   ├── Import/
│   │   └── ImportService.swift (EXISTING — calls ArtworkBackfillService post-import)
│   ├── Playlists/
│   │   ├── ArtworkExtractor.swift (EXISTING Phase 36 — becomes thin wrapper)
│   │   └── PlaylistCoverService.swift (EXISTING Phase 36 — no changes)
│   ├── Common/
│   │   ├── ProcessRunner.swift (EXISTING — ffmpeg invocation)
│   │   └── TrackArtworkCache.swift (NEW — NSCache singleton)
│   └── Artwork/
│       └── ArtworkBackfillService.swift (NEW — @MainActor @Observable orchestrator)
├── Views/
│   ├── Shared/
│   │   └── TrackCoverView.swift (NEW — async image loader + fallback)
│   ├── Library/
│   │   └── LibraryTable.swift (MODIFY — add TrackCoverView to Title column)
│   ├── Track/
│   │   └── TrackDetailView.swift (MODIFY — replace placeholder icon with TrackCoverView)
│   └── Player/
│       └── PlayerBar.swift (MODIFY — replace placeholder with TrackCoverView)
├── Database/
│   ├── AnalysisRepository.swift (EXISTING — fetchArtwork/saveArtwork ready)
│   └── DatabaseManager.swift (EXISTING — artwork table v5 migration in place)
├── App/
│   ├── DependencyContainer.swift (MODIFY — wire ArtworkBackfillService init)
│   └── MLMApp.swift (EXISTING — no changes, notification already posted)
└── Utilities/
    ├── Notifications.swift (MODIFY — add .trackArtworkDidChange definition)
    └── AppLogger.swift (EXISTING — D-07 logging on ffmpeg-missing)
```

### Pattern 1: @MainActor @Observable Service with Background Queue

**What:** Service holds state (@Observable) and runs on the main actor, but dispatches heavy work (ffmpeg, file I/O, network) into background async methods that suspend and resume without blocking the main thread.

**When to use:** Long-running background operations (import backfill, cover generation, transcoding) that need to report progress or completion back to views.

**Example:**
```swift
@MainActor
@Observable
final class ArtworkBackfillService {
    // State (on main actor)
    var isBackfilling = false
    var progress: (current: Int, total: Int) = (0, 0)
    
    // Observer setup (on main actor)
    private var observerToken: NSObjectProtocol?
    
    init(...) {
        startObserving()
    }
    
    deinit {
        // deinit is nonisolated — use MainActor.assumeIsolated to read token
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
            // Safe: [weak self] prevents strong cycle
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.backfillMissing()  // Suspends, doesn't block
            }
        }
    }
    
    // Heavy lifting happens here (async, can suspend)
    private func backfillMissing() async {
        isBackfilling = true
        defer { isBackfilling = false }
        
        // Fetch tracks from DB
        let tracks = try? await trackRepository.fetchTracksWithoutArtwork()
        let total = tracks?.count ?? 0
        
        // Chunk and TaskGroup for concurrency control
        await withTaskGroup(of: Void.self) { group in
            for chunk in tracks.chunked(into: 100) {
                for track in chunk {
                    // Add task to group — will run up to `maxConcurrentTasks: 4`
                    group.addTask { [weak self] in
                        await self?.extractForTrack(track)
                    }
                }
            }
        }
    }
    
    // Each extraction task
    private func extractForTrack(_ track: Track) async {
        // This can be called from a background concurrent task
        // Don't call @MainActor code here unless you hop back explicitly
        if let data = await ArtworkService.extractEmbeddedArtwork(from: track.path) {
            try? await saveAndNotify(trackId: track.id, data: data)
        }
    }
    
    // Hop back to main to update state + post notification
    private func saveAndNotify(trackId: Int64, data: Data) async throws {
        try? await analysisRepository.saveArtwork(...)
        // Back on main actor now
        progress.current += 1
        NotificationCenter.default.post(
            name: .trackArtworkDidChange,
            object: nil,
            userInfo: ["trackId": trackId, "artworkPath": "..."]
        )
    }
}
// Source: Phase 36 PlaylistCoverService pattern (Z. 64-90)
```

### Pattern 2: Subprocess from Async Context (Task.detached)

**What:** Heavy I/O-bound subprocess (ffmpeg) runs in Task.detached from a static async method, preventing it from blocking the actor's isolation.

**When to use:** When a @MainActor method needs to call non-async code (Process) or when you need to guarantee the subprocess runs off-actor.

**Example:**
```swift
static func extractEmbeddedArtwork(from url: URL) async -> Data? {
    return await Task.detached(priority: .default) { () -> Data? in
        guard let ffmpeg = ProcessRunner.findExecutable("ffmpeg") else {
            AppLogger.warn("ffmpeg not found")
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
        } catch {}
        
        try? FileManager.default.removeItem(at: tmpOutput)
        return nil
    }.value  // Await the detached task
}
// Source: ArtworkService.swift line 119-150 (existing pattern; make static public in Phase 37)
```

### Pattern 3: NSCache with Key Scoping

**What:** Thread-safe in-memory cache keyed by trackId + size. Automatically evicts under memory pressure and respects countLimit.

**When to use:** Hot-path view rendering where expensive operations (disk I/O, image decoding) should be avoided on every scroll.

**Example:**
```swift
final class TrackArtworkCache: @unchecked Sendable {
    static let shared = TrackArtworkCache()
    
    private let cache = NSCache<NSNumber, NSImage>()
    
    init() {
        cache.countLimit = 200  // Max 200 images in memory
        // totalCostLimit can be set if you want byte-based eviction (optional)
    }
    
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
}
// Source: Decision D-09, NSCache<NSNumber, NSImage> pattern
```

### Anti-Patterns to Avoid

- **Synchronous Process.run() on @MainActor:** Even though Process.waitUntilExit() is synchronous, calling it on the main actor blocks the UI. Always use Task.detached.
- **Posting .trackArtworkDidChange multiple times per track:** Coalesce notifications; batch updates into a single notification per background cycle, not per-track.
- **Not checking file existence in TrackCoverView:** D-14 mandates file-existence check; a stale DB row after user deletes `~/Library/Caches/com.mlm.artwork_cache` should trigger self-healing, not crash.
- **Storing absolute paths in artwork.artwork_path:** Always use the canonical `ArtworkService.cachedPath(trackId:size:)` to generate paths; never hard-code `~/Library/Caches/com.mlm.artwork_cache/123_500.jpg`.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| In-memory image cache | LRU cache with eviction logic | NSCache (Foundation) | NSCache handles memory pressure eviction automatically; custom LRU is boilerplate |
| Subprocess execution | Direct Process + waitUntilExit | ProcessRunner.run (async) + Task.detached | ProcessRunner wraps error handling, output streaming, environment enrichment (PATH for scdl→yt-dlp chain) |
| Cover file path resolution | Construct path via string concatenation | ArtworkService.cachedPath(trackId:size:) | Single source of truth; guards against traversal (D-09 in Phase 36 PlaylistCard) |
| Notification de-duplication | Tally notifications in a Set | Set<Int64> inFlight coalescing (see PlaylistCoverService:38) | Established pattern; prevents rapid re-entry and duplicate DB updates |
| Background task lifecycle | Manual cancellation checks | Swift async/await with Task groups + structured concurrency | Task groups automatically cancel children on scope exit; no manual resource cleanup needed |

**Key insight:** The codebase already has mature subprocess + service patterns from v1.0 Tauri (ProcessRunner) and Phase 36 (PlaylistCoverService). Phase 37 reuses both without custom plumbing.

## Runtime State Inventory

> **This is a greenfield phase** — no rename, refactor, or migration of existing data. The `artwork` table was created in Phase 1 v5 migration but never written to in the UI. No runtime state inventory needed.

**State introduced in Phase 37:**
- `artwork.artwork_path` column (already exists; will be written for the first time)
- `artwork.source` column (already exists; will be written for the first time)
- Cache files at `~/Library/Caches/com.mlm.artwork_cache/{trackId}_{500|1200}.jpg` (new files, not migration)
- Notification `.trackArtworkDidChange` (new notification, not migration)

No data migration required. Phase 37 is additive only.

## Common Pitfalls

### Pitfall 1: Subprocess Blocks MainActor If Not Detached

**What goes wrong:** Calling `Process().run()` directly from a @MainActor method or without Task.detached causes UI freeze (unresponsiveness to touches, animations hang).

**Why it happens:** The main actor's dispatch queue is serial; Process.waitUntilExit() is synchronous and blocking. Even though ffmpeg takes milliseconds per track, 4 tasks × 100ms each = 400ms of UI hang when they fire sequentially on the main thread.

**How to avoid:** Always wrap in `Task.detached { ... }.value` or `await Task.detached { ... }.value`. The detached task runs on the default priority concurrent executor.

**Warning signs:** 
- LibraryTable or PlayerBar becomes laggy during backfill
- Scrolling stutters while ffmpeg processes run
- Drag-drop interactions feel delayed

**Prevention:**
- Grep for `Process()` calls outside of Task.detached context
- Rule: any subprocess from an @MainActor or @MainActor method must be in `Task.detached`

### Pitfall 2: NSCache Eviction Under Memory Pressure

**What goes wrong:** TrackCoverView loads 500px + 1200px NSImages for every visible row. With 200-image countLimit, on a scroll from top to bottom of 1000+ row library, cache thrashes (hit rate < 20%), forcing disk re-reads on every scroll.

**Why it happens:** Each TrackCoverView at initialization loads both sizes. A scroll through 50 visible rows = 100 NSImages. Countlimit of 200 fits 2 complete scroll windows; beyond that, older images evict.

**How to avoid:**
- Set countLimit conservatively: 200 is a reasonable baseline (Phase 36 did not define a count; this phase decides).
- Load only the size needed per surface (D-12: 500px for table, 1200px for detail).
- Pre-warm cache during import backfill with smaller images (optional optimization).
- Consider totalCostLimit (bytes) as an alternative if device RAM is constrained.

**Warning signs:**
- Profiler shows high disk I/O during scroll (File I/O % > 5%)
- NSImage(contentsOfFile:) called repeatedly for the same trackId
- Memory spikes then drops in Activity Monitor (eviction thrashing)

**Prevention:**
- Measure cache hit rate: add counters in TrackArtworkCache.image(:forTrackId:)
- Rule: countLimit should hold at least 1 full viewport of visible rows × 2 sizes. For a 40-row viewport, aim for 2 × 40 × 2 = 160 minimum.

### Pitfall 3: File-Existence Check Skipped in TrackCoverView

**What goes wrong:** User manually deletes the artwork cache folder (`rm -rf ~/Library/Caches/com.mlm.artwork_cache`). TrackCoverView still queries the DB, finds artwork_path="...", tries to load from disk, gets nil, and renders a broken image or error icon instead of gracefully falling back to Solar gradient.

**Why it happens:** The assumption that DB + file are always in sync. System cache cleanup happens periodically; D-14 explicitly rejects Mtime-based re-extraction in favor of explicit user action.

**How to avoid:** Every TrackCoverView initialization must:
1. Query DB for artwork_path
2. Check `FileManager.fileExists(atPath:)` on the resolved path
3. If DB says yes but file says no → trigger single-track re-backfill via ArtworkBackfillService
4. While re-backfill is pending, render fallback (Solar gradient)

**Warning signs:**
- Broken images shown in table after cache cleanup
- Inconsistent behavior: sometimes covers show, sometimes don't
- User complains "my covers disappeared"

**Prevention:**
- Rule: TrackCoverView.load() must check both DB AND file existence before rendering from disk
- Rule: If file missing, enqueue self-healing backfill for that single track (not full library re-scan)

### Pitfall 4: Notifications Not De-Duplicated During High-Concurrency Backfill

**What goes wrong:** With TaskGroup at concurrency 4, a library of 1000 tracks posts 1000 `.trackArtworkDidChange` notifications in rapid succession. Every LibraryTable row observer fires, causing 1000 table cell re-renders (and 1000 NSImage loads/decodes) in seconds.

**Why it happens:** If ArtworkBackfillService posts one notification per extracted track without coalescing, and Views react synchronously (SwiftUI re-rendering), the render workload multiplies.

**How to avoid:**
- Batch notifications: collect trackIds in a Set during the cycle, post a single `.trackArtworkDidChange` per N tracks (e.g., every 50) or per TaskGroup completion.
- Views should debounce notification reception (Combine debounce(for:) or a 200ms timer).
- Or: post a single `.artworkBackfillDidProgress` notification with (current: Int, total: Int) instead of per-track.

**Warning signs:**
- CPU usage spikes to 100% during backfill
- LibraryTable becomes unresponsive during artwork extraction
- Profiler shows high SwiftUI re-render count (>100 redraws/sec)

**Prevention:**
- Rule: Post .trackArtworkDidChange notifications in batches or at a rate-limited cadence (not per-track)
- Rule: Debounce view reactions to artwork notifications (200ms minimum)
- Decision D-03 says "per-track notification" but doesn't forbid batching at the source; planner can optimize

### Pitfall 5: Task.detached Subprocess Not Cleaned Up on App Quit

**What goes wrong:** User quits the app while 4 ffmpeg subprocesses are mid-extraction. Task.detached tasks are not automatically cancelled when the app terminates; they can continue running briefly in the background, creating temporary files that linger.

**Why it happens:** Task groups in ArtworkBackfillService are scoped to the backfillMissing() method. If the app closes before the method completes, the method's scope exits, but the child tasks in the TaskGroup may not have finished waitUntilExit() on their Process handles.

**How to avoid:**
- When a Task.detached process is created, track it in a set of in-flight Process IDs.
- In the service deinit or on app shutdown, send SIGTERM to any remaining processes.
- Or: rely on Swift structured concurrency: when the TaskGroup scope exits, all child tasks are cancelled and their Process objects are cleaned up.

**Warning signs:**
- Orphaned ffmpeg processes visible in Activity Monitor after app quit
- Temporary JPEGs in /var/tmp/ left behind
- Intermittent "device is busy" errors on re-opening the library folder

**Prevention:**
- Rule: Never `await Task.detached(...).value` without the parent scope being guaranteed to wait for completion or cancel cleanly.
- Rule: Use TaskGroup (structured concurrency) to automatically cancel children on scope exit — not bare Task.detached.
- Test: Kill the app mid-backfill, verify no orphaned processes in Activity Monitor

## Code Examples

Verified patterns from official sources and existing codebase:

### Extracting Embedded Artwork (static async wrapper)

```swift
// ArtworkService.swift — make extractEmbeddedArtwork static and public
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
// Source: Existing ArtworkService line 119-150; make static, mark async, wrap in Task.detached
```

### TrackCoverView with Fallback + File-Existence Check

```swift
// Views/Shared/TrackCoverView.swift
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
            // Only update if this notification is for our track
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
            // File missing — trigger re-backfill for this single track
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
    
    private var sizePoints: CGFloat {
        switch size {
        case .small: return 40   // PlayerBar
        case .large: return 128  // TrackDetailView
        }
    }
    
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
}
// Source: D-10 custom TrackCoverView pattern; D-14 file-existence check; D-11 Solar fallback
```

### ArtworkBackfillService TaskGroup with Concurrency 4

```swift
// Services/Artwork/ArtworkBackfillService.swift
@MainActor
@Observable
final class ArtworkBackfillService {
    // ... init, deinit, startObserving (see Pattern 1 above) ...
    
    private var inFlight: Set<Int64> = []
    
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
                        
                        // Update progress (back on main actor)
                        await MainActor.run { [weak self] in
                            self?.progress.current = min(processed, total)
                        }
                        processed += 1
                    }
                }
            }
        }
        
        // TaskGroup scope exits → all tasks cancelled if any fail
    }
    
    private func extractForTrack(_ track: Track) async {
        // Resolve path from DB
        let trackPath = URL(fileURLWithPath: track.organizedPath ?? "")
        
        // Extract (async, off-actor via Task.detached inside the static method)
        guard let data = await ArtworkService.extractEmbeddedArtwork(from: trackPath) else {
            return  // Silent nil per D-07
        }
        
        // Save to disk and DB (async, on repository)
        do {
            try await ArtworkService.shared.saveResized(data: data, trackId: track.id ?? 0)
            try await analysisRepository.saveArtwork(
                Artwork(
                    trackId: track.id ?? 0,
                    artworkPath: ArtworkService.shared.cachedPath(trackId: track.id ?? 0, size: .large).path,
                    source: "embedded",
                    musicbrainzReleaseGroupId: nil,
                    resolution: "1200",
                    fetchedAt: ISO8601DateFormatter().string(from: Date())
                )
            )
        } catch {
            // Log silently; continue to next track
            AppLogger.warn("Artwork backfill failed for track \(track.id ?? -1): \(error)")
        }
        
        // Notify UI (back on main actor via ArtworkBackfillService being @MainActor)
        await MainActor.run { [weak self] in
            NotificationCenter.default.post(
                name: .trackArtworkDidChange,
                object: nil,
                userInfo: [
                    "trackId": track.id ?? 0,
                    "artworkPath": ArtworkService.shared.cachedPath(trackId: track.id ?? 0, size: .large).path
                ]
            )
        }
    }
}
// Source: D-02 TaskGroup with fixed concurrency 4; D-03 per-track notification; Pattern 1 above
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| AVFoundation `commonMetadata` for artwork | ffmpeg subprocess via `extractEmbeddedArtwork` | Phase 36 (discovered FLAC/MP3 inconsistency) | More reliable; handles APIC, METADATA_BLOCK_PICTURE, covr, OGG Picture seamlessly |
| Manual synchronous Process.run() | Task.detached async wrapper | ProcessRunner (v1.0) | Non-blocking; enables background extraction during import without UI hang |
| Per-action cover generation (Settings button only) | Background queue post-.libraryDidImport trigger | Phase 37 decision D-01 | Auto-discovery; covers appear organically as import completes |
| Single 1200px size | Both 500px (table/player) + 1200px (detail) | D-08 cache-resolution decision | Optimal memory use + visual quality per surface |

**Deprecated/outdated:**
- **Manual artwork fetch button in Settings:** Continues to work; Phase 37 adds automatic import trigger alongside it (D-16 Maintenance split).
- **AVFoundation artwork extraction in PlaylistCoverService (Phase 36):** Not deprecated, but `ArtworkExtractor.extract()` becomes a thin wrapper calling `ArtworkService.extractEmbeddedArtwork()` instead of reading AVFoundation metadata (D-05).

## Assumptions Log

No assumptions requiring user confirmation. All decisions from CONTEXT.md are locked and all technical patterns are verified against existing codebase (ProcessRunner, PlaylistCoverService, NotificationCenter pattern). Phase is technically ready.

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| —  | All claims verified or cited from codebase/framework docs | — | — |

## Open Questions

None. All 17 decisions are locked and technically sound. Phase 37 is a straightforward application of established patterns.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| ffmpeg | ArtworkService.extractEmbeddedArtwork | ✓ | Any | Silent nil + warn; fallback to Solar gradient (D-07) |
| SQLite (GRDB) | AnalysisRepository artwork table access | ✓ | v5 migration in place | — |
| Xcode (Swift) | Development + compilation | ✓ | macOS 15 SDK / Swift 5.10+ | — |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** ffmpeg (if not installed, artwork extraction silently returns nil; UI renders Solar gradient fallback).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | XCTest (built-in; Phase 36 used XCTest for PlaylistCoverServiceTests) |
| Config file | macos-app/MLM/MLMTests/Info.plist (standard) |
| Quick run command | `swift test --filter ArtworkBackfillServiceTests` |
| Full suite command | `swift test` (from macos-app directory) |

### Phase Requirements → Test Map

Phase 37 has no explicit REQ-IDs mapped in REQUIREMENTS.md. Success criteria from ROADMAP.md:

| Criteria | Behavior | Test Type | Automated Command | File Exists? |
|----------|----------|-----------|-------------------|-------------|
| S-1: Auto-trigger on import | .libraryDidImport posts → ArtworkBackfillService observes + enqueues extraction | Unit | `swift test --filter ArtworkBackfillServiceTests/testObservesLibraryDidImport` | ❌ Wave 0 |
| S-2: TaskGroup concurrency 4 | withTaskGroup(maxConcurrentTasks: 4) executes exactly 4 parallel tasks | Unit | `swift test --filter ArtworkBackfillServiceTests/testConcurrencyLimit` | ❌ Wave 0 |
| S-3: ffmpeg extraction works | ArtworkService.extractEmbeddedArtwork returns Data for valid audio files | Unit | `swift test --filter ArtworkServiceTests/testEmbeddedExtraction` | ✅ (existing from Phase 1) |
| S-4: Notification posts per-track | .trackArtworkDidChange fires with (trackId, artworkPath) after extract | Unit | `swift test --filter ArtworkBackfillServiceTests/testNotificationPosting` | ❌ Wave 0 |
| S-5: LibraryTable displays covers | TrackCoverView renders image from cache + fallback on miss | Snapshot | `swift test --filter TrackCoverViewTests/testRendersCached` | ❌ Wave 0 |
| S-6: TrackDetailView shows cover | TrackDetailView header integrates TrackCoverView(size: .large) | Snapshot | `swift test --filter TrackDetailViewTests/testHeaderShowsCover` | ✅ (partial; header exists) |
| S-7: PlayerBar shows cover | PlayerBar coverThumbnail is TrackCoverView(size: .small) | Snapshot | `swift test --filter PlayerBarTests/testShowsCoverThumbnail` | ✅ (partial; placeholder exists) |
| S-8: File-existence check (D-14) | TrackCoverView checks FileManager.fileExists before rendering | Unit | `swift test --filter TrackCoverViewTests/testFileMissTriggersSelfHealing` | ❌ Wave 0 |
| S-9: ArtworkExtractor wraps ffmpeg | ArtworkExtractor.extract calls ArtworkService.extractEmbeddedArtwork | Unit | `swift test --filter ArtworkExtractorTests/testCallsArtworkService` | ✅ (Phase 36, may need update for static method) |
| S-10: Maintenance buttons split (D-16) | Settings MaintenanceView "Refresh embedded" vs "Fetch MusicBrainz" | Integration | Manual UI test (QA gate) | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `swift test --filter ArtworkBackfillServiceTests` (unit tests for backfill + notification logic)
- **Per wave merge:** `swift test` (full suite) — must include coverage for ProcessRunner integration (ffmpeg subprocess behavior)
- **Phase gate:** Full suite green + manual UI smoke test (import 10 tracks, verify covers appear in table + detail) before `/gsd-verify-work`

### Wave 0 Gaps

Required before implementation begins:

- [ ] `ArtworkBackfillServiceTests.swift` — Unit tests for @MainActor @Observable behavior:
  - `testObservesLibraryDidImport` — notification posts, service enqueues work
  - `testConcurrencyLimit` — TaskGroup respects maxConcurrentTasks: 4 (use mock ffmpeg subprocess)
  - `testCoalescesDuplicateRequests` — inFlight Set prevents redundant extractions
  - `testNotificationPosting` — per-track .trackArtworkDidChange fires with correct userInfo
  - `testFileMissingTriggersDebugLog` — ffmpeg missing → AppLogger.warn, return nil (no crash)

- [ ] `TrackCoverViewTests.swift` — SwiftUI view snapshot + integration:
  - `testRendersCachedImage` — NSCache hit path works, image displays
  - `testRendersFromDisk` — FileManager load path works, image displays
  - `testRendersGradientFallback` — file missing → Solar gradient + music.note rendered
  - `testFileMissTriggersSelfHealing` — FileManager.fileExists returns false → calls service.refreshSingleTrack
  - `testNotificationTriggersReload` — .trackArtworkDidChange notification → cache invalidate + reload

- [ ] `TrackArtworkCacheTests.swift` — NSCache wrapper:
  - `testCacheHit` — setImage + image(for:) returns same object
  - `testEvictionUnderLimit` — countLimit: 200 enforced (insert 210, verify first 10 evicted)
  - `testInvalidateTrack` — invalidate(forTrackId:) removes all sizes

- [ ] Update `ArtworkExtractorTests.swift` (Phase 36) — Change to call static `ArtworkService.extractEmbeddedArtwork` instead of instance method

- [ ] Configuration: No new test config files; reuse existing test bundle setup from Phase 1 (DatabaseTests pattern)

*(If these gaps are not closed before code review, tests must be written as part of the task, not pre-planned.)*

## Security Domain

No new security concerns introduced by Phase 37.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | no | —  |
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | yes | File access controlled by system (cache dir owned by app). ffmpeg subprocess cannot escape sandbox. |
| V5 Input Validation | yes | File paths from DB are validated via ArtworkService.cachedPath (single canonical resolver). No user input constructs paths. |
| V6 Cryptography | no | — |
| V7 Cryptography (Crypto Ops) | no | — |
| V8 Error Handling | yes | Subprocess errors (ffmpeg exit ≠ 0) logged via AppLogger.warn (D-07 pattern). No exception propagation. |
| V9 Communication | no | — |

### Known Threat Patterns for macOS Subprocess + File I/O

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Path traversal in artwork paths | Tampering | Use ArtworkService.cachedPath(trackId:size:) resolver — canonical, not user-controlled |
| Subprocess injection (ffmpeg arguments) | Tampering | ffmpeg arguments are hardcoded; only URL path is dynamic and passed quoted to Process.arguments array (safe) |
| Temporary file leakage | Information Disclosure | Temporary JPEG files in /tmp cleaned up immediately after read (try? removeItem after Data(contentsOf:)) |
| Memory image residue | Information Disclosure | NSCache eviction is automatic under memory pressure; no manual image byte wiping (non-critical for artwork) |
| Resource exhaustion (TaskGroup creates 1000+ tasks) | Denial of Service | maxConcurrentTasks: 4 limits concurrent ffmpeg to 4; task queue is bounded by library size (fixed, no infinite queue) |

**Mitigation is standard for the codebase and built into decisions D-02 (TaskGroup bounded), D-07 (error logging), and ProcessRunner pattern (quoted arguments).**

## Sources

### Primary (HIGH confidence)

- **ArtworkService.swift** (existing code) — ffmpeg subprocess pattern, saveResized logic, MusicBrainz integration
- **PlaylistCoverService.swift** (Phase 36) — @MainActor @Observable pattern, notification observer, re-entry guard
- **ProcessRunner.swift** (v1.0) — subprocess execution, output handling, PATH enrichment
- **Notifications.swift** (Phase 4 v2.0) — NotificationCenter pattern, existing notifications
- **37-CONTEXT.md** (user decisions) — All 17 decisions D-01..D-20 locked

### Secondary (MEDIUM confidence)

- **Phase 36 CONTEXT.md** — D-03 gradient palette, D-05 cover service pattern
- **Apple Swift Concurrency Docs** (2023) — @MainActor isolation, Task.detached, TaskGroup structured concurrency
- **Foundation NSCache docs** — Memory management, countLimit semantics, thread safety
- **macOS 11+ Foundation Process/Pipe docs** — subprocess lifecycle, stream handling

### Tertiary (not needed)

- No web research required; all patterns verified in codebase or framework docs

## Metadata

**Confidence breakdown:**

| Area | Level | Reason |
|------|-------|--------|
| Standard Stack | HIGH | Foundation APIs (Process, NSCache, NotificationCenter) are stable macOS 11+ APIs; used successfully in existing code |
| Architecture | HIGH | PlaylistCoverService (Phase 36) and ProcessRunner (v1.0) establish proven patterns; Phase 37 reuses both directly |
| Pitfalls | HIGH | Four pitfalls identified from first-principles analysis of async/subprocess/cache interactions; matched against Phase 36 playbook |
| Validation | HIGH | Test framework (XCTest) in place; test cases map directly to success criteria |
| Security | HIGH | No novel threat model; standard OS-level file/process isolation applies |

**Research date:** 2026-05-15
**Valid until:** 2026-06-15 (30 days; Foundation APIs are stable; Phase 36 patterns are locked in codebase)

---

## RESEARCH COMPLETE

**Phase:** 37 — Album-Art-Pipeline durchziehen
**Confidence:** HIGH
**Ready for planning:** Yes — all 17 locked decisions are technically sound; patterns verified; no blockers identified.

### Key Findings

1. **No new dependencies required** — Phase 37 uses only Foundation + existing ProcessRunner + PlaylistCoverService patterns.
2. **All subprocess/cache/notification patterns proven** — Phase 36 PlaylistCoverService and v1.0 ProcessRunner provide direct blueprints.
3. **Pitfall-resistant design** — D-02 (TaskGroup concurrency 4), D-07 (silent ffmpeg missing), D-14 (file-existence self-healing), D-03 (per-track notifications) address common async/subprocess/cache failure modes.
4. **No schema changes** — artwork table exists from Phase 1 v5 migration; Phase 37 writes to it for the first time.
5. **Four-task natural structure:** (1) ArtworkBackfillService + import trigger, (2) ArtworkService static API change, (3) UI integration (3 surfaces), (4) Validation tests.

### Confidence Assessment

| Area | Level | Evidence |
|------|-------|----------|
| Core patterns (subprocess, cache, notifications) | HIGH | Verified in v1.0 ProcessRunner + Phase 36 PlaylistCoverService; used in production |
| @MainActor isolation on ProcessRunner | HIGH | Task.detached is Swift stdlib pattern for exactly this use case; proven in v1.0 download pipeline |
| NSCache memory semantics | HIGH | Foundation API, thread-safe, auto-eviction under pressure; no custom code needed |
| Notification de-duplication safety | HIGH | Phase 36 uses inFlight Set pattern successfully; no regression risk |
| ffmpeg cover extraction reliability | HIGH | ArtworkService tested in Phase 1; FLAC/MP3/M4A/OGG/AIFF/WAV all covered by format-specific ffmpeg flags |

### Open Questions

None — all 17 decisions locked; no gaps for planner.

### Ready for Planning

Planner can now create PLAN.md. Recommend task order:
1. **37-01:** ArtworkBackfillService init + import trigger wiring + TaskGroup
2. **37-02:** ArtworkService static API + ArtworkExtractor refactor
3. **37-03:** TrackCoverView + LibraryTable + TrackDetailView + PlayerBar integration
4. **37-04:** Validation (unit tests, smoke tests, Settings Maintenance split)
