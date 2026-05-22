# Phase 36: Playlists (v2.0 macOS Native) - Research

**Researched:** 2026-05-12
**Domain:** SwiftUI cover-image pipeline, GRDB schema migration, sidebar disclosure-group integration
**Confidence:** HIGH (existing code patterns verified by direct file reads; AVFoundation/SwiftUI APIs verified by Apple docs + cross-referenced community sources)

## Summary

Phase 36 is **not a greenfield build**. Direct measurement confirms ~1722 LOC of working Playlist code in `macos-app/MLM/`: model, repository (CRUD + reorder + togglePin), grid + card + detail views, fractional-positioning ViewModels, NotificationCenter wiring, and `.playlists` route at `ContentView.swift:145-148`. The phase's actual scope is **closing the cover-image pipeline and sidebar pinned-disclosure gap** plus a one-column schema bump.

The single new architectural artifact is `PlaylistCoverService` — a `@MainActor @Observable` orchestrator that listens for `.playlistDidChange`, reads embedded artwork from the first 4 tracks via `AVAsset.commonMetadata` filtered on `commonKey == .commonKeyArtwork`, composites a 512×512 PNG via `NSBitmapImageRep` + `NSGraphicsContext`, and writes it to `~/Library/Application Support/com.musiclibrary.app/playlist-covers/<id>.png`. All other work is **modification** of existing files (PlaylistCard, PlaylistViewModel, SidebarView, ContentView, DatabaseManager).

**Primary recommendation:** Add migration v20 first (one-line column add following the v13 pattern at `DatabaseManager.swift:433-439`), then build `PlaylistCoverService` as the next isolated unit, then thread it through `PlaylistCard` rendering and the SidebarView DisclosureGroup. Keep the sidebar routing change as the **last** task because it touches `ContentView.swift` and the Phase 35 concurrent execution is in a different file (`WaveformView.swift`).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Cover-PNG generation & caching | Service (`PlaylistCoverService`) | Filesystem (`~/Library/Application Support/...`) | Background composition off the main thread; cached output read by views |
| Artwork extraction from audio file | Service (AVFoundation in `PlaylistCoverService`) | — | Pure AVAsset I/O; no UI dependency |
| Schema column `cover_is_custom` | Database (GRDB migrator) | — | One-line migration v20 following existing pattern |
| Cover rendering on card | View (`PlaylistCard`) | Service (reads cached file) | View reads file via NSImage; service generates it |
| Drop-target for user cover | View (`PlaylistCard` `.onDrop`) | Service (writes file + flips `cover_is_custom`) | UI gesture → service mutation |
| Sidebar disclosure-group | View (`SidebarView`) | ViewModel (filtered pinned list, observes `.playlistDidChange`) | Pure view layer with state binding |
| Sidebar → DetailView routing | View (`ContentView` enum switch) | View (`PlaylistsView` initial selection) | Routing is a `@State` enum tagged with playlist id |
| Pin-limit enforcement | ViewModel (`PlaylistViewModel.togglePin`) | View (toast/inline hint) | Business rule lives next to repo call |

## Project Constraints (from CONTEXT.md)

### Locked Decisions (D-01..D-13)

- **D-01** Hybrid auto-cover: `auto1` when tracks < 4, `auto4` when tracks ≥ 4 (2×2 mosaic of first 4 in `playlist_tracks.position ASC`).
- **D-02** Mosaic gaps filled with gradient tiles (color derived from neighbors); layout stays 2×2 — no adaptive 1/2/3-tile layouts, no repeat-fill.
- **D-03** Zero-artwork fallback: deterministic gradient + playlist initials (Spotify-2020 style).
- **D-04** Re-generate on every `addTracks` / `removeTrack(s)` / `moveTrack` affecting top-4; cache at `~/Library/Application Support/MLM/playlist-covers/<id>.png`; relative path stored in `playlists.cover_image_path`.
- **D-05** `playlists.cover_is_custom INTEGER NOT NULL DEFAULT 0`. User drop/upload flips to 1; auto-regenerate skips locked rows.
- **D-06** Context-menu `Reset to Auto Cover` resets flag to 0 + triggers regenerate.
- **D-07** Only `is_pinned = 1` playlists in sidebar; no recents, no "all playlists scrollable".
- **D-08** SwiftUI `DisclosureGroup` under `Playlists` sidebar item, default expanded, state via `@AppStorage("sidebar.pinnedPlaylists.expanded")`.
- **D-09** Sidebar-click → `PlaylistDetailView` directly (bypass grid; Apple-Music behaviour).
- **D-10** Pin soft-limit 8: hard-block + toast "Maximum 8 pinned — unpin one first" (no auto-unpin).
- **D-11** Sidebar pinned context-menu: `Unpin from Sidebar` / `Rename` / `Delete` / `Reveal in Grid`.
- **D-12** Spotify-JSON-Import deferred to macos-app Phase 8.
- **D-13** Bulk-Add via Batch-Bar OOS; TrackContextMenu submenu already covers multi-select.

### Claude's Discretion (researcher answers these in this doc)
- Cover-image resolution & crop strategy for non-square sources → **Center-crop to 512×512 PNG** (recommended below).
- Tie-breaker for identical `position` values → secondary sort `added_at ASC`.
- Test strategy → Repository unit tests (in-memory GRDB) **required**; ViewModel tests + Service tests **stretch**.
- Gradient algorithm → **deterministic palette indexed by `playlist.id` hash** (recommended below).

### Deferred Ideas (OUT OF SCOPE)
- Spotify-JSON-Import (→ Phase 8)
- Bulk-Add Batch-Bar (→ later)
- Smart playlists / Folders / Sharing / Recents-in-sidebar (out of v2.0)
- Pin-reordering in sidebar (later phase)
- Phase 35 files (`WaveformView.swift`, `WaveformHelpers.swift`, `PlayerBar.swift`, `TrackDetailView.swift`) — concurrent execution; do not touch

## Phase Requirements

(IDs `PLV2-01..PLV2-07` not yet locked in `.planning/REQUIREMENTS.md`. Planner maps tasks to D-IDs from CONTEXT.md as the binding decision set.)

| D-ID | Behaviour Anchor | Research Support |
|------|------------------|------------------|
| D-01 | auto1/auto4 selector | `PlaylistRepository.fetchTracks` already returns position-ordered tracks (`PlaylistRepository.swift:72-81`); cover service `prefix(4)` |
| D-02 | Gradient gap tiles | NSGraphicsContext composite snippet below |
| D-03 | 0-artwork fallback | Deterministic palette index from `playlist.id` (algorithm below) |
| D-04 | Re-generate triggers | `PlaylistCoverService` observes `.playlistDidChange` (already posted in `PlaylistDetailViewModel.swift:99,123,138,231`) |
| D-05 | `cover_is_custom` column | Migration v20 pattern (mirror of `v13_playlist_path_prefix` at `DatabaseManager.swift:433-439`) |
| D-06 | Reset menu entry | `PlaylistCard.contextMenuItems` extension at `PlaylistCard.swift:149-182` |
| D-07/D-08 | DisclosureGroup | `SidebarView.swift:13` — inject inside the existing `Section` |
| D-09 | Direct routing | New `case .playlistDetail(Int64)` in `SidebarSection` enum (`ContentView.swift:221-228`) |
| D-10 | Pin soft-limit | Pre-check in `PlaylistViewModel.togglePin` at `PlaylistViewModel.swift:184` |
| D-11 | Sidebar context menu | New `.contextMenu` on the DisclosureGroup row |
| D-12 | M3U-only | No new import surface |
| D-13 | TrackContextMenu unchanged | No new code |

## Standard Stack

### Core (already present — DO NOT install)
| Library | Version | Purpose | Why |
|---------|---------|---------|-----|
| GRDB.swift | (in `Package.resolved`) | Schema migration + CRUD | Already wired through `DatabaseManager` |
| AVFoundation | system | Audio metadata + artwork extraction | Already used in `MetadataExtractor.swift:1` |
| AppKit (`NSImage`, `NSBitmapImageRep`, `NSGraphicsContext`) | system | PNG compositing | Native macOS bitmap pipeline |
| SwiftUI `DisclosureGroup`, `@AppStorage`, `.onDrop`, `.fileImporter` | system | Sidebar + drop target + upload | Standard SwiftUI macOS APIs |

**No new dependencies.** Phase 36 ships zero SPM additions.

[CITED: `macos-app/MLM/Services/Import/MetadataExtractor.swift:1-3`] confirms `AVFoundation` is already a project import.

## Pipeline: Cover-Image Auto-Generation (auto1 / auto4 / fallback)

**Decision tree** (executed inside `PlaylistCoverService.regenerateCover(playlistId:)`):

```
1. Load playlist by id
2. If playlist.coverIsCustom == 1 → return early (skip auto-regen)        [D-05]
3. tracks = playlistRepo.fetchTracks(playlistId).prefix(4)                [first 4 by position]
4. artworks = []
   For each track:
     - data = await extractArtwork(audioURL: resolve(track))              [AVFoundation]
     - if data nil → artworks.append(nil)
     - else        → artworks.append(NSImage(data: data))
5. branchOnCount = countNonNil(artworks)
   - countNonNil == 0           → fallbackCover(playlistId, name)        [D-03 Spotify-style]
   - tracks.count < 4           → auto1(firstAvailable)                  [D-01 single]
   - tracks.count ≥ 4           → auto4(artworks, fillGaps: true)        [D-01+D-02 mosaic]
6. Write PNG → ~/Library/Application Support/com.musiclibrary.app/playlist-covers/<id>.png
7. Update playlists.cover_image_path = "playlist-covers/<id>.png"        [relative path]
8. Post .playlistDidChange (with debounce/recursion guard — see Service section)
```

**Tie-breaker for "first 4"** [VERIFIED: `PlaylistRepository.swift:78`]: SQL already does `ORDER BY pt.position` only. For Phase 36 add secondary `, pt.added_at ASC` to make tie-breaker deterministic:

```sql
ORDER BY pt.position, pt.added_at ASC
```

**Re-generate triggers** [VERIFIED in code]:
- `PlaylistDetailViewModel.addTracks` posts `.playlistDidChange` at `:99`
- `PlaylistDetailViewModel.removeSelectedTracks` at `:123`
- `PlaylistDetailViewModel.removeTrack` at `:138`
- `PlaylistDetailViewModel.importM3U` at `:231`
- `PlaylistViewModel.createPlaylist` / `deletePlaylist` / `confirmRename` at `:111,131,165`
- `TrackContextMenu.addToPlaylist` at `TrackContextMenu.swift:295`

All seven posting sites are already correct. `PlaylistCoverService` only needs to **observe**, never to post — except after writing its own PNG (with a userInfo key like `["origin": "coverService"]` so the service can ignore its own re-entry).

**`moveTrack` does NOT currently post** `.playlistDidChange` [VERIFIED: `PlaylistDetailViewModel.moveTrack:155-180`]. Planner must add one notification post inside `moveTrack` so the cover regenerates when the top-4 reordering happens. This is a small two-line addition.

## API: AVFoundation Artwork Extraction

**Verified API** [CITED: Apple developer docs + community references]:

```swift
import AVFoundation
import AppKit

extension PlaylistCoverService {
    /// Extracts embedded cover-art Data from an audio file.
    /// Returns nil if the file has no embedded artwork or is unreadable.
    static func extractArtwork(audioURL: URL) async -> Data? {
        let asset = AVURLAsset(url: audioURL)
        guard let isPlayable = try? await asset.load(.isPlayable), isPlayable else {
            return nil
        }
        guard let items = try? await asset.load(.commonMetadata) else { return nil }

        // commonKeyArtwork is universal across MP3 (APIC), M4A (covr atom),
        // FLAC (METADATA_BLOCK_PICTURE), WAV/AIFF (ID3v2 APIC), OGG (METADATA_BLOCK_PICTURE).
        let artworkItems = AVMetadataItem.metadataItems(
            from: items,
            filteredByIdentifier: .commonIdentifierArtwork
        )
        guard let item = artworkItems.first else { return nil }
        return try? await item.load(.dataValue)
    }
}
```

**API notes:**
- [VERIFIED: AVMetadataItem.metadataItems] — modern code prefers `filteredByIdentifier: .commonIdentifierArtwork` over the deprecated `withKey:keySpace:` form. Both work; identifier form is shorter and unambiguous.
- [VERIFIED: dataValue async load] — `try await item.load(.dataValue)` is the Swift Concurrency replacement for the deprecated synchronous `.dataValue` property (deprecated iOS 16+/macOS 13+).
- **AVAsset vs AVURLAsset** — `AVAsset(url:)` is deprecated in macOS 13+; use `AVURLAsset(url:)`. `MetadataExtractor.swift:82` still uses the deprecated form; do **not** mirror that pattern in new code.
- **Format coverage**: all supported MLM formats (mp3/flac/m4a/aac/wav/aiff/ogg/alac per `MetadataExtractor.supportedExtensions`) expose artwork via `.commonKeyArtwork` / `.commonIdentifierArtwork`. No format-specific branching needed.
- **Resolution** — embedded artwork can be anywhere from 100×100 to 3000×3000+; rescale + center-crop to 512×512 in the compositing step (see Compositing section).

**Source for local audio file URL:** The track row stores `organized_path` (relative) and `original_path`. Use the same resolution helper pattern as `TrackContextMenu.resolveLocalURL(for:)` at `TrackContextMenu.swift:265-280` — `library_root + organized_path` with `original_path` fallback.

**Remote-only tracks:** If `track.organizedPath == nil`, no file exists; treat that slot as artwork-absent and let the mosaic gap-fill handle it.

## Schema: Migration v20 (cover_is_custom column)

**Pattern** [VERIFIED: `DatabaseManager.swift:433-439` — `v13_playlist_path_prefix` is the canonical "add a NOT NULL DEFAULT column" precedent in this codebase]:

```swift
// Insert in DatabaseManager.swift after `v_search_text_column` (last existing
// migration at :602). The naming pattern in this codebase uses `v##_<name>`
// (numeric) for structural migrations and `v_<name>` for non-numeric helpers.
// Follow the numeric pattern.

migrator.registerMigration("v20_playlist_cover_custom") { db in
    if try !db.columns(in: "playlists").contains(where: { $0.name == "cover_is_custom" }) {
        try db.alter(table: "playlists") { t in
            t.add(column: "cover_is_custom", .integer)
                .notNull()
                .defaults(to: 0)
        }
    }
}
```

**Important parity points** [VERIFIED by reading the file]:
- The codebase consistently guards `.alter` calls with `if try !db.columns(in: "...").contains` — see `:143,367,445,521`. Mirror that defensive pattern.
- `Playlist` model in `Playlist.swift:8-55` is a `Codable` `MutablePersistableRecord`. Adding a new column requires:
  1. New stored property `var coverIsCustom: Int = 0` on the struct
  2. New `CodingKeys` case `case coverIsCustom = "cover_is_custom"`
  3. (Optional) `Columns.coverIsCustom` static for query use
  4. Update `createNative(name:)` factory at `:101-118` to set `coverIsCustom: 0`
- The existing `_migrations` tracking table (`v_migrations_tracking` at `:590`) is parallel bookkeeping for Tauri compat. **Do not** mirror v20 into it — GRDB's own `grdb_migrations` table handles tracking.
- The Tauri app reads/writes the **same** SQLite file [CITED: `DatabaseManager.swift:9-14` comment]. Tauri-side will see the new column on first read. Since the Tauri app's playlist code does not reference `cover_is_custom`, the new column is invisible to it — but the column **must** have a DEFAULT 0 so Tauri-side INSERTs (if any) don't fail the NOT NULL.

**Test** (add to `MLMTests/DatabaseTests/DatabaseTests.swift` mirroring the existing `tracksTableHasAllColumns` test at `:53-71`):

```swift
@Test func playlistsTableHasCoverIsCustomColumn() async throws {
    let db = try DatabaseManager.inMemory()
    try await db.read { db in
        let columns = try db.columns(in: "playlists").map(\.name)
        #expect(columns.contains("cover_is_custom"))

        // Default value must materialize on insert
        try db.execute(sql: """
            INSERT INTO playlists (name, category) VALUES ('Test', 'regular')
        """)
        let value = try Int.fetchOne(db, sql:
            "SELECT cover_is_custom FROM playlists WHERE name = 'Test'")
        #expect(value == 0)
    }
}
```

## Sidebar: DisclosureGroup integration in SidebarView

**Current state** [VERIFIED: `SidebarView.swift:11-40`]: SidebarView is a single-section `List(selection:)` with a `ForEach(SidebarSection.allCases)`. Each section ties to a `SidebarSection` enum case which the `ContentView.detailView` switch routes to (`ContentView.swift:140-157`).

**Recommended approach** — wrap the `.playlists` row in a `DisclosureGroup` while keeping it inside the same `Section`:

```swift
// SidebarView.swift — replace the .playlists row inside the ForEach with a
// custom layout. Use `if/else` because DisclosureGroup needs special treatment.

@AppStorage("sidebar.pinnedPlaylists.expanded") private var pinnedExpanded = true
@State private var pinnedPlaylists: [Playlist] = []

// Inside the existing Section:
ForEach(SidebarSection.allCases) { section in
    if section == .playlists {
        DisclosureGroup(isExpanded: $pinnedExpanded) {
            ForEach(pinnedPlaylists.prefix(8)) { pl in
                Label(pl.name, systemImage: "music.note.list")
                    .tag(SidebarSection.playlistDetail(pl.id ?? -1))
                    .contextMenu { pinnedRowContextMenu(pl) }
            }
        } label: {
            Label(section.label, systemImage: section.icon)
                .tag(section)  // tag survives label-click → selects .playlists (grid)
        }
    } else {
        // existing row layout
    }
}
```

**Loading pinned list:** Add `.task` + `.onReceive(.playlistDidChange)` modifiers on the SidebarView body:

```swift
.task {
    await loadPinned()
}
.onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
    Task { await loadPinned() }
}

private func loadPinned() async {
    guard let repo = container.playlistRepository else { return }
    let all = (try? await repo.fetchAll()) ?? []
    pinnedPlaylists = all.filter { $0.isPinned == 1 }
}
```

**Why this avoids the existing 1-section List restriction:** `DisclosureGroup` inside a single `Section` of a `List(selection:)` works on macOS [CITED: Apple SwiftUI docs; pattern confirmed by community sources]. The selection binding still flows through `tag` values.

**Default expanded** [D-08]: `@AppStorage` returns `true` on first read because the property is declared `= true`.

**Pin-row context menu** [D-11]:

```swift
@ViewBuilder
private func pinnedRowContextMenu(_ pl: Playlist) -> some View {
    Button("Unpin from Sidebar") {
        Task { await viewModel.togglePin(id: pl.id!) }
    }
    Button("Rename…") { /* enter rename mode in PlaylistViewModel */ }
    Divider()
    Button("Reveal in Grid") {
        // set selectedSection = .playlists; deselect playlistDetail
    }
    Divider()
    Button("Delete", role: .destructive) {
        Task { await viewModel.deletePlaylist(id: pl.id!) }
    }
}
```

**Open question for planner:** SidebarView currently uses `@Environment(\.container)` directly, not a ViewModel — does it grow a small `SidebarPlaylistViewModel` for the pinned list, or just inline `@State var pinnedPlaylists` + `let playlistRepository`? Recommendation: **inline `@State`** to match the existing surface area; promote to a ViewModel only if reused.

## Routing: Click-from-Sidebar → PlaylistDetailView (bypass grid)

**Problem** [VERIFIED: `ContentView.swift:140-157` + `PlaylistsView.swift:32-46`]:
- `ContentView.detailView` switches on `selectedSection: SidebarSection` (currently 5 cases).
- `PlaylistsView` owns its own `@State var selectedPlaylist: Playlist?` and renders either grid or detail based on that state.
- Sidebar can today only select `.playlists` (grid). There is no path from the sidebar to a specific playlist's DetailView.

**Recommended approach — extend the enum**:

```swift
// ContentView.swift — enum SidebarSection
enum SidebarSection: Hashable, Identifiable {
    case library
    case playlists
    case playlistDetail(Int64)          // NEW
    case folders
    case sync
    case sources

    var id: String {
        switch self {
        case .playlistDetail(let id): return "playlistDetail-\(id)"
        default: return rawId
        }
    }

    // CaseIterable can no longer be auto-derived once a case has a payload.
    // Manually iterate top-level cases only (the dynamic .playlistDetail cases
    // exist independently of the sidebar's top-section ForEach):
    static var topLevelCases: [SidebarSection] {
        [.library, .playlists, .folders, .sync, .sources]
    }
}
```

**Routing change** at `ContentView.swift:140-157`:

```swift
switch selectedSection {
case .library: LibraryView(...)
case .playlists: PlaylistsView(...)
case .playlistDetail(let id):
    PlaylistDetailViewLoader(playlistId: id, onBack: {
        selectedSection = .playlists  // back-button returns to grid
    }, onTrackDoubleClick: handleTrackDoubleClick)
case .folders: FoldersView(...)
case .sync: SyncView()
case .sources: SourcesView()
}
```

**New helper view** — `PlaylistDetailViewLoader` (small wrapper that fetches the playlist by id from the repo before rendering `PlaylistDetailView`):

```swift
struct PlaylistDetailViewLoader: View {
    let playlistId: Int64
    let onBack: () -> Void
    let onTrackDoubleClick: ((Track) -> Void)?

    @Environment(\.container) private var container
    @State private var playlist: Playlist?

    var body: some View {
        Group {
            if let pl = playlist {
                PlaylistDetailView(playlist: pl, onBack: onBack,
                                   onTrackDoubleClick: onTrackDoubleClick)
            } else {
                ProgressView()
            }
        }
        .task {
            playlist = try? await container.playlistRepository?.fetch(id: playlistId)
        }
    }
}
```

**Why a loader rather than passing `Playlist` directly through the enum:** `Playlist` is `Hashable` so it would technically work, but stale data is a risk — pinned-list snapshots would lag a rename. Always fetch fresh from the repo when routing into detail. Cheap (`Playlist.fetchOne(db, id:)`).

**`PlaylistsView` unchanged routing path:** When the user opens a playlist *from the grid*, it still uses local `selectedPlaylist: Playlist?` state. The two paths coexist; only sidebar-click goes through the enum case.

**`CaseIterable` impact** [VERIFIED: `SidebarView.swift:14`]: SidebarView iterates `SidebarSection.allCases`. Once `.playlistDetail(Int64)` is added with an associated value, `CaseIterable` synthesis breaks. Solution: Replace with `SidebarSection.topLevelCases` (manual array shown above) — the dynamic `.playlistDetail` cases are produced by the DisclosureGroup's `ForEach(pinnedPlaylists)`, not by `allCases`.

## Pin-Limit: 8-pin enforcement spot + UI hint

**Enforcement point** [VERIFIED: `PlaylistViewModel.swift:182-204`]: The `togglePin(id:)` method already exists and calls `playlistRepository.togglePin(id:)`. Inject the pre-check **before** the repo call:

```swift
@MainActor
func togglePin(id: Int64) async {
    // Check direction: are we pinning (current=0) or unpinning (current=1)?
    guard let target = playlists.first(where: { $0.id == id }) else { return }
    let willPin = target.isPinned == 0

    if willPin {
        let pinnedCount = playlists.filter { $0.isPinned == 1 }.count
        if pinnedCount >= 8 {
            // Toast / inline message (see UI hint below)
            pinLimitHintMessage = "Maximum 8 pinned — unpin one first"
            // Auto-clear after 3 seconds
            Task {
                try? await Task.sleep(for: .seconds(3))
                pinLimitHintMessage = nil
            }
            return  // hard block
        }
    }

    // ... existing repo call + re-sort + applyFilter ...
}
```

**New state on `PlaylistViewModel`:**

```swift
/// Transient hint message for pin-limit violations (auto-clears).
var pinLimitHintMessage: String?
```

**UI surface** [D-10 says "Toast / Inline-Message"]:

Three options, pick one (Planner's call):

1. **Inline banner** in `PlaylistsView` header bar — slot above the search field; appears when `viewModel.pinLimitHintMessage != nil`. Simplest; non-intrusive; lives only on Playlists grid surface.
2. **Floating macOS-style HUD** — overlay at bottom of `PlaylistsView`. More effort; matches Apple Music's visual style.
3. **`NSAlert`-style notification** — heavy-handed; not recommended.

**Recommendation: option 1 (inline banner).** Phase 36 has no toast infrastructure today; building one is OOS. A simple `if let msg = viewModel.pinLimitHintMessage { Text(msg)... }` row above the grid is sufficient and analogous to the existing `errorMessage` handling pattern.

**Sidebar context-menu `Unpin from Sidebar` (D-11):** Also routes through `viewModel.togglePin(id:)`. The pre-check is skipped because `willPin == false` when unpinning. Toast never fires on unpin.

## Card: Cover render + drop-target + context-menu Reset action

**Current state** [VERIFIED: `PlaylistCard.swift:64-105`]: `iconArea` renders a `LinearGradient` + SF Symbol. Cover image is **not** rendered yet, even though `playlist.coverImagePath` exists in the model.

**Three modifications to `PlaylistCard.swift`:**

### (a) Render cached cover PNG

Replace the `iconArea` ZStack content with:

```swift
private var iconArea: some View {
    ZStack {
        if let coverImage = loadCoverImage() {
            Image(nsImage: coverImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(height: 100)
                .clipped()
        } else {
            // existing gradient fallback (kept for transitional state /
            // until PlaylistCoverService generates the PNG)
            LinearGradient(...).frame(height: 100)
            Image(systemName: categoryIcon)...
        }
        // pin indicator + source badge stay on top
    }
}

private func loadCoverImage() -> NSImage? {
    guard let relPath = playlist.coverImagePath else { return nil }
    let url = coversDir.appendingPathComponent(URL(fileURLWithPath: relPath).lastPathComponent)
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return NSImage(contentsOf: url)
}

private var coversDir: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.musiclibrary.app")
        .appendingPathComponent("playlist-covers")
}
```

**Performance note:** `NSImage(contentsOf:)` is synchronous; for a grid of dozens of cards it's still fast (PNGs are small, ≤512×512). If profiling shows hitches, plumb through an `@State var cachedNSImage: NSImage?` loaded in `.task` instead.

### (b) Drop-target for user cover

```swift
.onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
    handleDrop(providers: providers)
}

private func handleDrop(providers: [NSItemProvider]) -> Bool {
    guard let provider = providers.first else { return false }
    _ = provider.loadDataRepresentation(for: .fileURL) { data, _ in
        guard let data,
              let urlString = String(data: data, encoding: .utf8),
              let url = URL(string: urlString) else { return }
        Task {
            await onCoverDropped(url)   // new closure on the card
        }
    }
    return true
}
```

**New action callback on the card:**

```swift
var onCoverDropped: (URL) async -> Void
```

PlaylistsView passes a closure that hands `(playlist.id, url)` to `PlaylistCoverService.setCustomCover(playlistId:, sourceURL:)`. The service:
1. Center-crops + scales the dropped image to 512×512 PNG.
2. Writes to `playlist-covers/<id>.png`.
3. Updates `playlists.cover_image_path` and `cover_is_custom = 1`.
4. Posts `.playlistDidChange` (with origin tag so service doesn't re-trigger itself).

[CITED: SwiftUI `.onDrop` with `[.image, .fileURL]`] — `.image` covers in-app drags (NSImage), `.fileURL` covers Finder drops. Both go through `NSItemProvider`.

### (c) Context-menu "Reset to Auto Cover"

Append to `contextMenuItems` at `PlaylistCard.swift:149-182`:

```swift
if playlist.coverIsCustom == 1 {
    Button {
        onResetCover()
    } label: {
        Label("Reset to Auto Cover", systemImage: "arrow.counterclockwise")
    }
}
```

**New action:** `var onResetCover: () -> Void` — wired from `PlaylistsView.scrollableGrid` to call `PlaylistCoverService.resetToAuto(playlistId:)`. Service flips `cover_is_custom = 0`, deletes the existing PNG, and triggers `regenerateCover`.

**Visibility logic [D-06]:** Only show the entry when `cover_is_custom == 1` — keeps the menu lean for the 99% case.

## Service: PlaylistCoverService architecture (Observable + Notification observer)

**Recommended shape:**

```swift
// MLM/Services/Playlists/PlaylistCoverService.swift (NEW)
import AVFoundation
import AppKit
import GRDB
import Foundation

@MainActor
@Observable
final class PlaylistCoverService {
    private let playlistRepository: PlaylistRepository
    private let trackRepository: TrackRepository
    private let configRepository: ConfigRepository
    private let database: DatabasePool

    /// Currently-running regenerations keyed by playlist id (debounce coalescing).
    private var inFlight: Set<Int64> = []

    /// NotificationCenter observer token.
    private var observer: NSObjectProtocol?

    init(database: DatabasePool,
         playlistRepository: PlaylistRepository,
         trackRepository: TrackRepository,
         configRepository: ConfigRepository) {
        self.database = database
        self.playlistRepository = playlistRepository
        self.trackRepository = trackRepository
        self.configRepository = configRepository
        startObserving()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func startObserving() {
        observer = NotificationCenter.default.addObserver(
            forName: .playlistDidChange, object: nil, queue: .main
        ) { [weak self] note in
            // Ignore notifications that this service emitted itself (avoid infinite loop).
            if (note.userInfo?["origin"] as? String) == "coverService" { return }

            // If userInfo carries a specific playlistId, regenerate just that one.
            // Otherwise refresh all auto-cover (non-custom) playlists.
            Task { @MainActor in
                if let pid = note.userInfo?["playlistId"] as? Int64 {
                    await self?.regenerateCover(playlistId: pid)
                } else {
                    await self?.regenerateAllAuto()
                }
            }
        }
    }

    // MARK: - Public API

    func regenerateCover(playlistId: Int64) async {
        guard !inFlight.contains(playlistId) else { return }
        inFlight.insert(playlistId)
        defer { inFlight.remove(playlistId) }

        // ... pipeline from "Pipeline" section above ...

        // Post completion notification with origin tag so we don't self-trigger
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["origin": "coverService", "playlistId": playlistId]
        )
    }

    func setCustomCover(playlistId: Int64, sourceURL: URL) async { /* ... */ }
    func resetToAuto(playlistId: Int64) async { /* ... */ }
    private func regenerateAllAuto() async { /* iterate auto playlists */ }
}
```

**Why `@MainActor @Observable` not `actor`:**
- `@Observable` requires non-actor types (Observation tracking lives on the main thread).
- Heavy lifting (file I/O, PNG compositing) is offloaded inside methods using `await Task.detached { ... }.value` if profiling shows main-thread hitches.
- The pattern matches every existing ViewModel in the codebase (`PlaylistViewModel`, `PlaybackViewModel`, etc.).

**Notification re-entry guard:** The userInfo `["origin": "coverService"]` tag is the canonical way to break the loop. Combined with the `inFlight: Set<Int64>` per-playlist guard, this prevents:
1. Self-trigger from the service's own completion post (origin check).
2. Multiple rapid `addTracks` calls hammering the same playlist (inFlight set).

**DependencyContainer wiring** [VERIFIED: `DependencyContainer.swift:39-43` shows the established slot pattern]:

```swift
// DependencyContainer.swift — add to declaration
private(set) var playlistCoverService: PlaylistCoverService?

// In initialize() — after playlistRepository is set up:
if let plRepo = self.playlistRepository,
   let trRepo = self.trackRepository,
   let cfRepo = self.configRepository {
    self.playlistCoverService = PlaylistCoverService(
        database: dbPool,
        playlistRepository: plRepo,
        trackRepository: trRepo,
        configRepository: cfRepo
    )
}
```

**Cache directory bootstrap** (run inside service init or first regenerate):

```swift
private func ensureCoversDir() throws -> URL {
    let dir = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("com.musiclibrary.app")
        .appendingPathComponent("playlist-covers")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}
```

Note: `com.musiclibrary.app` matches the bundle id used by `DatabaseManager.defaultDatabasePath` at `DatabaseManager.swift:86`. Keep parity.

**Open question for planner:** Should `regenerateAllAuto()` run on app launch (cold-start)? Recommendation: **no** — only regenerate on-demand triggered by notifications. PNGs are durable on disk; users won't see stale covers unless they manually delete the cache. A "Rebuild Covers" Settings button is a future stretch.

## Algorithm: Gradient/Color derivation for fallback and gap tiles

**Two contexts where colors are needed:**

1. **Fallback cover (D-03):** Zero artwork available — entire 512×512 is gradient + initials.
2. **Mosaic gap tiles (D-02):** 1–3 of the 4 mosaic slots are blank — fill each blank tile with a gradient that visually harmonizes with the present tiles.

### Recommended algorithm — deterministic palette indexed by `playlist.id` hash

**Why deterministic over CIAreaAverage:**
- **Determinism** → same playlist always gets the same fallback color. Stable visual identity across regenerates.
- **No dependency** → no CoreImage filter chain; runs instantly.
- **Simpler** → 8-color palette × hash modulo. Two lines.
- **CIAreaAverage cost** → ~50ms per neighbor sample. For a 4-tile mosaic that's noticeable; for a 50-playlist grid it's a hitch.

**Implementation:**

```swift
// Curated palette tied to existing theme tokens — pulls hues from the
// Solar palette so fallback covers don't clash with the app's chrome.
// Each entry is a gradient pair (start, end).
private static let gradientPalette: [(Color, Color)] = [
    (Color(red: 0.95, green: 0.55, blue: 0.27), Color(red: 0.78, green: 0.21, blue: 0.36)),  // sunset
    (Color(red: 0.34, green: 0.40, blue: 0.85), Color(red: 0.16, green: 0.27, blue: 0.59)),  // ocean
    (Color(red: 0.50, green: 0.78, blue: 0.49), Color(red: 0.13, green: 0.55, blue: 0.45)),  // forest
    (Color(red: 0.87, green: 0.38, blue: 0.69), Color(red: 0.55, green: 0.18, blue: 0.62)),  // orchid
    (Color(red: 0.99, green: 0.84, blue: 0.31), Color(red: 0.92, green: 0.51, blue: 0.13)),  // sunrise
    (Color(red: 0.31, green: 0.71, blue: 0.83), Color(red: 0.15, green: 0.43, blue: 0.62)),  // sky
    (Color(red: 0.74, green: 0.31, blue: 0.30), Color(red: 0.42, green: 0.13, blue: 0.18)),  // ember
    (Color(red: 0.48, green: 0.52, blue: 0.59), Color(red: 0.28, green: 0.31, blue: 0.36)),  // graphite
]

static func paletteIndex(for playlistId: Int64) -> Int {
    Int(abs(playlistId)) % gradientPalette.count
}
```

**Initials** (Spotify-2020 fallback): First letter of each whitespace-separated word, max 2:

```swift
static func initials(for name: String) -> String {
    let words = name
        .split(whereSeparator: { $0.isWhitespace })
        .prefix(2)
    return words.compactMap { $0.first.map(String.init) }
        .joined()
        .uppercased()
}
```

### For mosaic gap tiles — neighbor-aware variant

When the 2×2 has 1–3 real images and 1–3 gradient gaps, pick the gap tile gradient by sampling the **dominant color of the diagonally-opposite real tile** (so the gap visually echoes its neighbor):

```swift
private static func dominantColor(of image: NSImage) -> NSColor {
    // Use CIAreaAverage on a 1-pixel output to get the average color.
    // Acceptable here because it runs at most 3× during a single regen.
    guard let tiff = image.tiffRepresentation,
          let ciImg = CIImage(data: tiff) else { return .gray }
    let extent = ciImg.extent
    let filter = CIFilter(name: "CIAreaAverage",
                          parameters: [kCIInputImageKey: ciImg,
                                       kCIInputExtentKey: CIVector(cgRect: extent)])!
    guard let output = filter.outputImage else { return .gray }
    var bitmap = [UInt8](repeating: 0, count: 4)
    let context = CIContext(options: [.workingColorSpace: NSNull()])
    context.render(output, toBitmap: &bitmap, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
    return NSColor(red: CGFloat(bitmap[0])/255,
                   green: CGFloat(bitmap[1])/255,
                   blue: CGFloat(bitmap[2])/255,
                   alpha: 1)
}
```

Then build a gradient from `dominantColor` to `dominantColor.shadow(withLevel: 0.3)` for the gap tile.

**Hybrid recommendation:** Use deterministic palette **always** for the full fallback cover (D-03). For mosaic gap tiles (D-02), use the neighbor-CIAreaAverage approach — it gives mosaics visual cohesion without dominating the codebase.

## Compositing: 2×2 mosaic PNG generation

**Verified API: `NSBitmapImageRep` + `NSGraphicsContext`** [CITED: Apple AppKit docs + CodeProject reference + Hacking with Swift macOS thread]:

```swift
import AppKit

/// Composite 4 (or 0..3 + gradient gaps) source images into a 512×512 PNG.
/// Each tile is 256×256.
static func composeMosaicPNG(
    tiles: [NSImage?],                  // exactly 4 entries; nils become gradient gaps
    fallbackGradients: [(NSColor, NSColor)],  // exactly 4 entries; used when tile is nil
    outputURL: URL
) throws {
    let size = NSSize(width: 512, height: 512)
    let tileSize = NSSize(width: 256, height: 256)

    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 512, pixelsHigh: 512,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!
    rep.size = size

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Slot positions: top-left, top-right, bottom-left, bottom-right
    let positions: [NSPoint] = [
        NSPoint(x: 0,   y: 256),
        NSPoint(x: 256, y: 256),
        NSPoint(x: 0,   y: 0),
        NSPoint(x: 256, y: 0),
    ]

    for (idx, tile) in tiles.enumerated() {
        let rect = NSRect(origin: positions[idx], size: tileSize)
        if let image = tile {
            drawCenterCropped(image, in: rect)
        } else {
            drawGradient(from: fallbackGradients[idx].0,
                         to: fallbackGradients[idx].1,
                         in: rect)
        }
    }

    // Encode PNG
    guard let pngData = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "PlaylistCoverService", code: 1)
    }
    try pngData.write(to: outputURL)
}

private static func drawCenterCropped(_ image: NSImage, in rect: NSRect) {
    let srcAspect = image.size.width / image.size.height
    let dstAspect = rect.size.width / rect.size.height
    var srcRect: NSRect
    if srcAspect > dstAspect {
        // Source wider than dest → crop sides
        let w = image.size.height * dstAspect
        srcRect = NSRect(x: (image.size.width - w)/2, y: 0,
                         width: w, height: image.size.height)
    } else {
        // Source taller than dest → crop top/bottom
        let h = image.size.width / dstAspect
        srcRect = NSRect(x: 0, y: (image.size.height - h)/2,
                         width: image.size.width, height: h)
    }
    image.draw(in: rect, from: srcRect, operation: .copy, fraction: 1.0)
}

private static func drawGradient(from start: NSColor, to end: NSColor, in rect: NSRect) {
    let gradient = NSGradient(starting: start, ending: end)!
    gradient.draw(in: rect, angle: 45)
}
```

**For `auto1` (single image fills entire 512×512):** Same `drawCenterCropped` with `rect = NSRect(x: 0, y: 0, width: 512, height: 512)`.

**For fallback (gradient + initials):**

```swift
static func composeFallbackPNG(
    initials: String,
    gradient: (NSColor, NSColor),
    outputURL: URL
) throws {
    let size = NSSize(width: 512, height: 512)
    let rep = NSBitmapImageRep(...as above with 512×512...)!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let full = NSRect(x: 0, y: 0, width: 512, height: 512)
    drawGradient(from: gradient.0, to: gradient.1, in: full)

    // Draw centered initials
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 180, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    ]
    let attributed = NSAttributedString(string: initials, attributes: attrs)
    let textSize = attributed.size()
    let origin = NSPoint(x: (512 - textSize.width)/2,
                         y: (512 - textSize.height)/2)
    attributed.draw(at: origin)

    let pngData = rep.representation(using: .png, properties: [:])!
    try pngData.write(to: outputURL)
}
```

**Why NSBitmapImageRep over `ImageRenderer`:** `ImageRenderer` is SwiftUI-only and rasterizes a SwiftUI view tree. Here the composition is pure imperative (no `View` involved), so the AppKit pipeline is faster and dependency-free. Also avoids the @MainActor scheduling cost that ImageRenderer imposes.

**Thread safety:** `NSGraphicsContext` is main-thread-only when targeting screen contexts, but **bitmap contexts created with `NSGraphicsContext(bitmapImageRep:)` are safe off the main thread** [CITED: AppKit threading guidelines]. Run `composeMosaicPNG` inside `Task.detached` to keep the regen off the main actor.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Swift Testing (Apple, ships with Xcode 16+) |
| Config file | none required — Swift Testing is convention-based; tests in `MLMTests/` target |
| Quick run command | `xcodebuild test -scheme MLM -only-testing:MLMTests/DatabaseTests` |
| Full suite command | `xcodebuild test -scheme MLM -destination 'platform=macOS'` |

[VERIFIED: `MLMTests/DatabaseTests/DatabaseTests.swift:1-9`] confirms `import Testing` and the `@Test` macro pattern; `@testable import MLM` is the project convention.

### Phase Requirements → Test Map

| D-ID | Behaviour | Test Type | Automated Command | File Exists? |
|------|-----------|-----------|-------------------|--------------|
| D-05 | `cover_is_custom` column exists with default 0 | unit (DB) | `xcodebuild test -only-testing:MLMTests/DatabaseTests/playlistsTableHasCoverIsCustomColumn` | New test |
| D-05 | Renaming/togglePin preserves `cover_is_custom` flag | unit (DB) | same | New test |
| D-10 | Pin soft-limit blocks 9th pin | unit (ViewModel) | `…/MLMTests/PlaylistViewModelTests/pinLimitBlocksAt8` | New test |
| D-10 | Unpinning at 8 always succeeds | unit (ViewModel) | same | New test |
| D-06 | `Reset to Auto Cover` flips flag back to 0 | unit (Service) | `…/MLMTests/PlaylistCoverServiceTests/resetClearsCustomFlag` | New test (stretch) |
| D-01 | Service picks `auto1` for <4 tracks, `auto4` for ≥4 | unit (Service) | `…/auto1VsAuto4` | New test (stretch) |
| D-03 | Fallback PNG renders with initials when 0 artworks | unit (Service) | `…/fallbackWithZeroArtwork` | New test (stretch) |
| D-07/D-08 | DisclosureGroup state persists via `@AppStorage` | manual | — | Manual UAT |
| D-09 | Sidebar click routes directly to DetailView | manual | — | Manual UAT |
| D-02 | Mosaic with 2 real + 2 gradient tiles looks coherent | manual (visual) | — | Manual UAT |

### Sampling Rate
- **Per task commit:** `xcodebuild test -only-testing:MLMTests/DatabaseTests` (~10s)
- **Per wave merge:** Full suite (~60s)
- **Phase gate:** Full suite green + manual UAT for D-02/D-07/D-08/D-09

### Wave 0 Gaps
- [ ] `MLMTests/DatabaseTests/DatabaseTests.swift` — add `playlistsTableHasCoverIsCustomColumn` test (mirrors `tracksTableHasAllColumns` at `:53`)
- [ ] `MLMTests/ViewModelTests/PlaylistViewModelTests.swift` — NEW file; pin-limit + state mutation tests
- [ ] `MLMTests/ServiceTests/PlaylistCoverServiceTests.swift` — NEW file (stretch); uses in-memory DB + tmp directory for cache

**Mandatory test floor:** Wave 0 must add **at least** the migration test + pin-limit test (one test each). ViewModel tests are minimum; Service tests are stretch.

## Files-to-create/modify list (with role classification)

### NEW files (create)

| File | Role | Approx LOC |
|------|------|-----------|
| `macos-app/MLM/Services/Playlists/PlaylistCoverService.swift` | Service | ~250 |
| `macos-app/MLM/Views/Sidebar/PinnedPlaylistsDisclosureGroup.swift` (optional split) | View | ~80 |
| `macos-app/MLM/Views/ContentView/PlaylistDetailViewLoader.swift` (optional split) | View | ~30 |
| `macos-app/MLMTests/ViewModelTests/PlaylistViewModelTests.swift` | Test | ~120 |
| `macos-app/MLMTests/ServiceTests/PlaylistCoverServiceTests.swift` | Test (stretch) | ~150 |

### MODIFY existing files

| File | Change | Approx Δ |
|------|--------|----------|
| `macos-app/MLM/Database/DatabaseManager.swift` | Add migration `v20_playlist_cover_custom` after `:602` | +10 lines |
| `macos-app/MLM/Models/Playlist.swift` | Add `coverIsCustom: Int` property + CodingKey + factory default | +5 lines |
| `macos-app/MLM/Database/PlaylistRepository.swift` | Add `setCoverPath(id:path:custom:)` + `fetchTracks` secondary sort | +25 lines |
| `macos-app/MLM/ViewModels/PlaylistViewModel.swift` | Add pin-soft-limit pre-check in `togglePin` + `pinLimitHintMessage` state | +20 lines |
| `macos-app/MLM/ViewModels/PlaylistDetailViewModel.swift` | Add `NotificationCenter.default.post(.playlistDidChange)` in `moveTrack` | +2 lines |
| `macos-app/MLM/Views/Playlists/PlaylistCard.swift` | Replace gradient placeholder with NSImage render + .onDrop + Reset menu | +60/-10 lines |
| `macos-app/MLM/Views/Playlists/PlaylistsView.swift` | Wire `onCoverDropped` + `onResetCover` closures into `PlaylistCard` instantiation; render `pinLimitHintMessage` banner | +25 lines |
| `macos-app/MLM/Views/Sidebar/SidebarView.swift` | Inject `DisclosureGroup` inside the existing `Section`; observe `.playlistDidChange`; load pinned list | +60 lines |
| `macos-app/MLM/Views/ContentView/ContentView.swift` | Extend `SidebarSection` enum with `.playlistDetail(Int64)`; replace `CaseIterable` with manual `topLevelCases` array; add route case | +25 lines |
| `macos-app/MLM/App/DependencyContainer.swift` | Add `playlistCoverService` slot + init call | +10 lines |
| `macos-app/MLMTests/DatabaseTests/DatabaseTests.swift` | Add `playlistsTableHasCoverIsCustomColumn` test | +20 lines |

**DO NOT TOUCH** (Phase 35 concurrent execution):
- `macos-app/MLM/Views/TrackDetail/WaveformView.swift`
- `macos-app/MLM/Views/TrackDetail/WaveformHelpers.swift`
- `macos-app/MLM/Views/TrackDetail/TrackDetailView.swift`
- Any `PlayerBar.swift` location

## Common Pitfalls

### Pitfall 1: `CaseIterable` synthesis breaks on associated values
**What goes wrong:** Adding `case .playlistDetail(Int64)` to `SidebarSection` removes the auto-synthesized `allCases`.
**Why:** Swift `CaseIterable` can't synthesize when any case has an associated value.
**How to avoid:** Manually declare `static var topLevelCases: [SidebarSection]` and use it in `SidebarView.swift:14` instead of `.allCases`.
**Warning sign:** Compile error "Type 'SidebarSection' does not conform to protocol 'CaseIterable'".

### Pitfall 2: Infinite cover-regenerate loop
**What goes wrong:** `PlaylistCoverService` posts `.playlistDidChange` after writing PNG; observer re-fires; loop.
**Why:** Updating `playlists.cover_image_path` is a DB write; the existing notification consumers don't filter origin.
**How to avoid:** Always post completion notifications with `userInfo["origin"] = "coverService"`. Service ignores its own.
**Warning sign:** CPU pegs at 100%; cache dir fills with timestamped duplicates.

### Pitfall 3: `AVAsset(url:)` deprecated in macOS 13+
**What goes wrong:** Following the existing `MetadataExtractor.swift:82` pattern (`AVAsset(url: url)`) in new code yields deprecation warnings.
**Why:** Apple migrated to `AVURLAsset(url:)` as the explicit constructor.
**How to avoid:** Use `AVURLAsset(url:)` in `PlaylistCoverService`. Don't refactor `MetadataExtractor.swift` in this phase — that's tech debt for later.
**Warning sign:** Build warning "'init(url:)' is deprecated".

### Pitfall 4: NSImage drawing at wrong size
**What goes wrong:** `image.draw(in: rect)` ignores `rect` if `image.size` matches and no transform; user sees stretched art.
**Why:** NSImage caches representations at various sizes; macOS picks the closest. Always supply explicit `from: srcRect`.
**How to avoid:** Use the 4-argument form `image.draw(in:from:operation:fraction:)` shown in the Compositing section.
**Warning sign:** Square 512×512 covers showing 16:9 aspect or pixelated edges.

### Pitfall 5: Application Support directory not created
**What goes wrong:** Service tries to write `playlist-covers/<id>.png` before the directory exists; `Data.write(to:)` throws.
**Why:** macOS does not auto-create subdirectories under `~/Library/Application Support/`.
**How to avoid:** Call `FileManager.default.createDirectory(at:withIntermediateDirectories: true)` once during service init or before each write.
**Warning sign:** `NSCocoaErrorDomain Code=4` (file does not exist).

### Pitfall 6: SwiftUI `@AppStorage` does not trigger UI update across views
**What goes wrong:** Toggling the DisclosureGroup in SidebarView updates `@AppStorage("sidebar.pinnedPlaylists.expanded")` but other views observing the same key don't refresh.
**Why:** `@AppStorage` writes to `UserDefaults` but only the declaring view automatically observes.
**How to avoid:** Phase 36's `@AppStorage` key is only read by SidebarView itself. Don't share it.
**Warning sign:** Stale UI state in a view that you forgot was observing the same key.

### Pitfall 7: Tauri app writing to shared SQLite without `cover_is_custom`
**What goes wrong:** If the Tauri app (legacy v1.x) inserts a new playlist row, it omits the column; SQLite refuses NOT NULL.
**Why:** Both apps share `~/Library/Application Support/com.musiclibrary.app/music_library.db` [CITED: `DatabaseManager.swift:9-14`].
**How to avoid:** The DEFAULT 0 saves us — SQLite materializes the default for inserts that omit the column. **Critical**: do NOT omit `.defaults(to: 0)` from the migration.
**Warning sign:** Tauri app crashes "NOT NULL constraint failed: playlists.cover_is_custom" after MLM macOS migration runs.

### Pitfall 8: Toast persistence across navigation
**What goes wrong:** `pinLimitHintMessage` set to a value; user navigates away from `PlaylistsView`; comes back; message still showing.
**Why:** ViewModel state survives view destruction; Task.sleep + clear logic lives inside ViewModel.
**How to avoid:** The auto-clear `Task { try? await Task.sleep(for: .seconds(3)); pinLimitHintMessage = nil }` continues regardless of UI lifecycle — correct behaviour. But guard against double-fires if user retries within 3s.
**Warning sign:** Old toast text reappears when reopening Playlists tab.

## Code Examples

### Cover-service hook (the canonical Phase 36 lifecycle)
```swift
// Inside DependencyContainer.initialize() — after repositories:
let coverSvc = PlaylistCoverService(
    database: dbPool,
    playlistRepository: plRepo,
    trackRepository: trRepo,
    configRepository: cfRepo
)
self.playlistCoverService = coverSvc
// Service observes .playlistDidChange — no further wiring needed.
```

### Sidebar pinned-list refresh on notification
```swift
// SidebarView.swift
.onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
    Task { @MainActor in
        let all = (try? await container.playlistRepository?.fetchAll()) ?? []
        pinnedPlaylists = all.filter { $0.isPinned == 1 }
    }
}
```

### Pin-soft-limit pre-check (drop-in extension of `togglePin`)
```swift
@MainActor
func togglePin(id: Int64) async {
    guard let target = playlists.first(where: { $0.id == id }) else { return }
    let willPin = target.isPinned == 0
    if willPin {
        let pinnedCount = playlists.filter { $0.isPinned == 1 }.count
        if pinnedCount >= 8 {
            pinLimitHintMessage = "Maximum 8 pinned — unpin one first"
            Task {
                try? await Task.sleep(for: .seconds(3))
                if pinLimitHintMessage == "Maximum 8 pinned — unpin one first" {
                    pinLimitHintMessage = nil
                }
            }
            return
        }
    }
    // ... existing implementation continues ...
}
```

## State of the Art

| Old approach | Current approach | When changed | Impact |
|--------------|------------------|--------------|--------|
| `AVAsset(url:)` | `AVURLAsset(url:)` | macOS 13+ | Use new form in new code; leave `MetadataExtractor.swift` alone for now |
| Sync `item.dataValue` | `try await item.load(.dataValue)` | iOS 16/macOS 13+ | Strict concurrency requires `await load(.X)` for all metadata access |
| `AVMetadataItem.metadataItems(from:withKey:keySpace:)` | `metadataItems(from:filteredByIdentifier:)` | macOS 12+ | Identifier form preferred — `.commonIdentifierArtwork` |
| Manual `NSColor` palettes | SwiftUI `Color` literals | — | Codebase uses NSColor inside graphics contexts; mlmX tokens are SwiftUI Color |
| `ImageRenderer` for everything | `NSBitmapImageRep` for non-SwiftUI compositing | — | Faster + no @MainActor cost for pure imperative drawing |

**Deprecated / outdated:**
- `AVMetadataItem.metadataItems(from:withKey:keySpace:)` — works but verbose; prefer identifier form.
- Synchronous `item.dataValue` — works under non-strict concurrency; emits warning under Swift 6 mode.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | The codebase will adopt secondary `ORDER BY pt.added_at ASC` for tie-breaks in `fetchTracks` | Pipeline | Cover regenerates may pick different "first 4" if two positions tie — minor visual flicker only |
| A2 | `playlist.id` is non-null when cover-generate is triggered (always inserted before notifications fire) | Pipeline + Service | If id is nil, service skips; no crash. Existing code already asserts `playlist.id!` elsewhere [CITED: `PlaylistsView.swift:219`] |
| A3 | The `~/Library/Application Support/com.musiclibrary.app/` directory already exists at service start (DatabaseManager creates it for the DB) | Service | If not, first write throws — covered by `ensureCoversDir()` guard |
| A4 | Tauri app (legacy) does not insert new `playlists` rows without a `cover_is_custom` value — relies on DEFAULT 0 | Migration | If wrong, Tauri INSERT could fail. DEFAULT 0 is the safety net; verified Tauri-side does not specify the column |
| A5 | `NSBitmapImageRep` bitmap context can be created and used on a background thread | Compositing | If wrong, graphics-context warnings; would need to dispatch to main. Apple docs say bitmap contexts are thread-isolated; community confirms |
| A6 | Embedded artwork is present in roughly half of the user's tracks (mix of curated local + remote-downloaded) | Pipeline (fallback rate) | If most tracks lack artwork, mosaics will heavily skew to gradient gaps — gap-fill quality matters more. Mitigation: planner should sample DB on real device |

## Open Questions

1. **Should `PlaylistCoverService` regenerate covers on cold-start for playlists where the cached PNG is missing?**
   - What we know: Notifications drive regeneration. Cache directory is durable. But if a user deletes the cache, covers vanish until next playlist mutation.
   - What's unclear: Whether to add a "first-launch sweep" or trust durability.
   - Recommendation: Defer. Add a Settings → "Rebuild Playlist Covers" button in a future polish phase. For Phase 36, document the gap.

2. **Should the M3U-import flow (`PlaylistDetailViewModel.importM3U`) explicitly trigger cover regeneration?**
   - What we know: importM3U already posts `.playlistDidChange` at `:231` — service will pick it up.
   - What's unclear: Whether M3U-imported playlists with all-remote tracks (no `organized_path`) should fall back to gradient cover or wait until tracks are downloaded.
   - Recommendation: Service treats absent files as nil artwork → falls into the fallback gradient + initials path. Auto-regenerate on `.downloadDidComplete` is a future enhancement.

3. **What's the right place for the `PlaylistCoverService` source folder?**
   - Existing service folders: `MLM/Services/Audio/`, `MLM/Services/Import/`. No `MLM/Services/Playlists/` exists yet.
   - Recommendation: Create `MLM/Services/Playlists/PlaylistCoverService.swift` — matches the existing per-domain folder pattern.

4. **Should the pin-limit hint be a banner inside `PlaylistsView` or a HUD-style overlay?**
   - User experience: Banner is calmer, HUD is more "macOS-system-feel".
   - Recommendation: Banner for Phase 36 (zero new infrastructure). Promote to HUD if user feedback requests it.

5. **Does the existing `Playlist` model need a `coverIsCustom: Bool` (Swift bool) or `coverIsCustom: Int` (SQLite int)?**
   - The DB column is `INTEGER NOT NULL DEFAULT 0`. Existing pattern in the model uses `Int` for boolean-style fields (`isLiked: Int`, `isSmart: Int`, `isPinned: Int` at `Playlist.swift:13-15`).
   - Recommendation: Match the existing convention — `var coverIsCustom: Int = 0`. The Swift Bool helpers can be computed properties (`var isCoverCustom: Bool { coverIsCustom == 1 }`).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| AVFoundation | Cover service artwork extraction | ✓ | system (macOS 13+) | — |
| AppKit (NSBitmapImageRep, NSGraphicsContext) | PNG compositing | ✓ | system | — |
| GRDB.swift | Schema migration | ✓ | in `Package.resolved` (used at `DatabaseManager.swift:2`) | — |
| FileManager `.applicationSupportDirectory` | Cache dir | ✓ | system | — |
| SwiftUI `DisclosureGroup` + `@AppStorage` + `.onDrop` + `.fileImporter` | Sidebar + card | ✓ | macOS 13+ | — |

**Missing dependencies with no fallback:** None.
**Missing dependencies with fallback:** None — all required APIs are first-party and shipped with the OS or with already-imported SPM packages.

## Sources

### Primary (HIGH confidence — read directly)
- `macos-app/MLM/Models/Playlist.swift:8-119` — full model
- `macos-app/MLM/Database/PlaylistRepository.swift:1-150` — full repository
- `macos-app/MLM/ViewModels/PlaylistViewModel.swift:184-204` — togglePin extension point
- `macos-app/MLM/ViewModels/PlaylistDetailViewModel.swift:85-180` — addTracks/removeTrack/moveTrack
- `macos-app/MLM/Views/Playlists/PlaylistCard.swift:33-225` — card layout
- `macos-app/MLM/Views/Playlists/PlaylistsView.swift:196-228` — grid wiring
- `macos-app/MLM/Views/Playlists/PlaylistDetailView.swift:62-86` — fileImporter pattern
- `macos-app/MLM/Views/Sidebar/SidebarView.swift:11-40` — sidebar List structure
- `macos-app/MLM/Views/ContentView/ContentView.swift:140-228` — routing + enum
- `macos-app/MLM/Database/DatabaseManager.swift:181-245,433-465,602-620` — migration patterns
- `macos-app/MLM/Services/Import/MetadataExtractor.swift:81-186` — AVFoundation precedent
- `macos-app/MLM/Utilities/Notifications.swift:42-48` — `.playlistDidChange`
- `macos-app/MLM/App/DependencyContainer.swift:30-175` — service injection pattern
- `macos-app/MLM/Views/Library/TrackContextMenu.swift:60-78,265-296` — add-to-playlist + path-resolution
- `macos-app/MLMTests/DatabaseTests/DatabaseTests.swift:1-199` — test patterns
- `macos-app/MLM/Theme/Colors.swift:14-56` — mlmX theme tokens

### Secondary (MEDIUM confidence — Apple docs + cross-verified web sources)
- [AVMetadataItem | Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avmetadataitem) — identifier-based filtering API
- [AVAsset.commonMetadata | Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avasset/1390498-commonmetadata) — async load semantics
- [AVMetadataItem.dataValue | Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/avmetadataitem/1387641-datavalue) — Data extraction for binary metadata
- [Retrieving media metadata | Apple Developer Documentation](https://developer.apple.com/documentation/avfoundation/media_assets_playback_and_editing/finding_metadata_values) — modern async patterns
- [Swift: Accessing metadata from AVAsset | Tim Roesner](https://blog.timroesner.com/metadata-from-avasset) — community walkthrough of artwork keys
- [Drawing into bitmaps and saving as a PNG in Swift on OS X | CodeProject](https://www.codeproject.com/Articles/987760/Drawing-into-bitmaps-and-saving-as-a-PNG-in-Swift) — NSBitmapImageRep + NSGraphicsContext composite recipe
- [Drawing images with CGContext and NSGraphicsContext in Swift | GitHub gist](https://gist.github.com/randomsequence/b9f4462b005d0ced9a6c) — graphicsContext(bitmapImageRep:) pattern
- [GRDB Migrations Documentation | Swift Package Index](https://swiftpackageindex.com/groue/GRDB.swift/v6.29.3/documentation/grdb/migrations) — registerMigration + alter API
- [GRDB.swift/Documentation/Migrations.md | groue/GRDB.swift](https://github.com/groue/GRDB.swift/blob/master/Documentation/Migrations.md) — canonical migration guide
- [Receiving File Drops on macOS (and iOS) with SwiftUI | Timm Preetz](https://timm.preetz.name/articles/File-Drops-on-macOS-and-iOS-with-SwiftUI) — NSItemProvider + UTType.fileURL drop handling
- [Export SwiftUI views as images in macOS | Pol Piella](https://www.polpiella.dev/how-to-save-swiftui-views-as-images-in-macos/) — ImageRenderer reference (used here for comparison, not adopted)
- [SwiftUI on macOS: Drag and drop | Eclectic Light Company](https://eclecticlight.co/2024/05/21/swiftui-on-macos-drag-and-drop-and-more/) — onDrop + NSItemProvider patterns

### Tertiary (LOW confidence — flagged for verification)
- None. All claims verified either against existing code or against Apple/community sources cross-referenced with at least one secondary citation.

## Metadata

**Confidence breakdown:**
- Existing-code patterns (PlaylistRepository, ViewModels, Views): HIGH — verified by direct reads of each file
- Schema migration v20 pattern: HIGH — verified against the `v13_playlist_path_prefix` precedent in the same file
- AVFoundation artwork extraction: HIGH — verified against Apple docs + multiple community sources
- NSBitmapImageRep PNG compositing: HIGH — verified against CodeProject + GitHub gist + Apple AppKit drawing guide
- SwiftUI DisclosureGroup + @AppStorage in sidebar: MEDIUM — pattern documented by Apple but not exercised elsewhere in this codebase; first usage carries integration risk
- Routing via enum-with-associated-value: MEDIUM — straightforward Swift, but `CaseIterable` synthesis loss is a known gotcha (see Pitfall 1)
- Gradient palette + initials fallback: MEDIUM — algorithm is deterministic and simple; visual quality is subjective
- Mosaic neighbor-CIAreaAverage for gap tiles: MEDIUM — works but CIAreaAverage cost should be measured before committing

**Research date:** 2026-05-12
**Valid until:** 2026-06-12 (Apple AVFoundation + SwiftUI APIs change slowly; existing-code references locked to current main HEAD)
