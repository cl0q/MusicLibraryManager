# Phase 38: Folder & Device Sync (v2.0 macOS Native) — Research

**Researched:** 2026-05-17
**Domain:** Native macOS Sync UX (SwiftUI/Swift Concurrency + GRDB migration v_sync_toggles + ffmpeg transcode cache + Rockbox M3U8)
**Confidence:** HIGH (codebase context is exhaustive; external libs are well-trodden Apple APIs)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** **Ein Profile-Typ mit expliziten Toggles, kein `kind`-Feld.** Schema-Erweiterung `sync_profiles` bekommt neue Spalten via Migration v6 (oder die nächste freie Version):
  - `generate_m3u8 INTEGER NOT NULL DEFAULT 0`
  - `transcode_mode TEXT NOT NULL DEFAULT 'keep_originals'` — enum: `keep_originals`, `aac_248`, `aac_320`
  - `fat32_safe_paths INTEGER NOT NULL DEFAULT 1` — Always-on by default (PathSanitizer existiert bereits)
  - `cleanup_removed_files INTEGER NOT NULL DEFAULT 1` — siehe D-04
- **D-02:** UI-Surface dieser Toggles im SyncProfileDetailView Settings-Section — kollabierbare Section unter dem Header, vor Preview. SwiftUI `Form` mit `Toggle` + `Picker` für transcode_mode. Editierbar zur Laufzeit; nach Edit triggert automatisch neue Preview-Berechnung.
- **D-03:** Smart-detect Defaults beim Create eines neuen Profils — Wenn der gewählte `outputFolder` (Browse-Result) auf einem Volume mit `.rockbox`-Directory liegt, schalten die Device-Defaults automatisch an: `generate_m3u8 = 1`, `transcode_mode = 'aac_248'`, `fat32_safe_paths = 1`, `cleanup_removed_files = 1`. Nicht-blockierender Toast „Rockbox iPod erkannt — Device-Defaults aktiviert". User kann jederzeit nachträglich togglen.
- **D-04:** `cleanup_removed_files` steuert Disk-Deletion-Semantik. Wenn `true`: bei `executeSync` werden die m4a-Files in `preview.filesToRemove` tatsächlich von Disk gelöscht (nicht nur `sync_state`-Row clearen). Wenn `false`: nur `sync_state`-Row löschen, File bleibt für User-manual-cleanup.
- **D-05:** MUST-have Picker-Sheet in SyncProfileDetailView + Context-Menu „Sync to ▸" auf PlaylistCard + TrackContextMenu (Submenu wie „Add to Playlist", plus Bottom-Eintrag „Create new profile…").
- **D-06:** Drag-Drop + Bulk-Bar deferred — kein UI in Phase 38.
- **D-07:** Profile-Detail zeigt "Playlists (N)" und "Tracks (N)" Sections mit Hover-Trash + ContextMenu „Remove from Profile". Removal **ausschließlich** über diese Sektionen.
- **D-08:** `SyncViewModel` Erweiterungen: `addPlaylists/addTracks/removePlaylists/removeTracks/updateProfileSettings`; nach jeder Mutation Re-Load Preview UND Post `.syncProfileDidChange`.
- **D-09:** DeviceDetector on-demand only — Dropdown „Detect device ▸" in createProfileSheet. KEIN background-polling, KEIN NSWorkspace observer.
- **D-10:** Empty-State Detect-Dropdown: disabled Eintrag „Keine Geräte gefunden — angeschlossen?".
- **D-11:** Toolbar-Indicator analog zu Phase 37 ArtworkBackfillService — global toolbar visible across routes; click navigates to sync. **Researcher-Anmerkung:** Phase 37 hat aktuell **kein** sichtbares Toolbar-Surface — siehe Open Questions #1.
- **D-12:** SyncProfileDetailView zeigt live Progress + Cancel during isRunning (Preview-Stats-Section wird ersetzt durch Live-Progress-Section).
- **D-13:** Failed tracks in DisclosureGroup (default collapsed) mit Retry-per-track + implicit auto-retry on next sync.
- **D-14:** cancelSync() flag-based, checked between files (NICHT mid-transcode subprocess kill). Bei Cancel: `currentFile=""`, `isRunning=false`, `progress` bleibt am letzten Wert.

### Claude's Discretion

- Migration-Versionsnummer und genaues Spalten-Naming
- Cancellation-Granularität (Default-Empfehlung: nein, fertig-Transcode dann-Stop)
- Toolbar-Indicator-Detail-Look (Pulse? Static Spinner?)
- Test-Strategie (mindestens SyncService Unit + TranscodeCache Hardlink-Fallback)
- „Add Tracks…"-Picker UX bei großer Library (>10k tracks)
- `addPlaylist`-Idempotenz UI-Feedback („3 added, 1 already in profile")
- Toolbar-Indicator-Hosting Fallback wenn global komplex

### Deferred Ideas (OUT OF SCOPE)

- Filter-Rules-UI für `SyncProfileRule`
- Drag-and-Drop „Playlist auf Profile-Card droppen"
- Bulk-Bar-Action „Add selection to Sync Profile"
- Dedicated „Devices"-Sidebar-Section / Live-Mount-Detection
- Auto-Sync bei Playlist-Change
- Sync zu Cloud-Targets
- Per-Track-Sync-Status-Badge in LibraryTable
- Transcode-Formate jenseits AAC (Opus, MP3, FLAC-Passthrough)
- Smart-Playlist-Sync
</user_constraints>

<phase_requirements>
## Phase Requirements

Phase 38 will introduce these requirement IDs (proposed coverage map derived 1:1 from CONTEXT D-IDs). The planner registers these in REQUIREMENTS.md.

| ID | Description | Backed by D-ID(s) | Research Support |
|----|-------------|-------------------|------------------|
| SYNC-v2-01 | `sync_profiles` table gets 4 new columns via migration (generate_m3u8, transcode_mode, fat32_safe_paths, cleanup_removed_files) | D-01 | Migration v6 design (this doc §Migration Design) |
| SYNC-v2-02 | `SyncProfile` model + GRDB Codable mapping for new columns | D-01 | Pattern: Models/SyncProfile.swift extension |
| SYNC-v2-03 | Smart-detect at create: outputFolder on `.rockbox` volume → auto-enables device defaults + toast | D-03 | DeviceDetector existing API; `.rockbox` scan |
| SYNC-v2-04 | Settings-Section UI in SyncProfileDetailView (Toggle + Picker for transcode_mode); edit triggers preview reload | D-02 | SwiftUI Form patterns, see §UX Patterns |
| SYNC-v2-05 | `cleanup_removed_files` actually deletes m4a files (current SyncService line 161-169 quirk fixed) | D-04 | `FileManager.trashItem` recommendation, this doc §Disk-Deletion Safety |
| SYNC-v2-06 | Picker-Sheet for Add-Playlists in SyncProfileDetailView | D-05 | PlaylistRepository.fetchAll, SwiftUI `List` selection |
| SYNC-v2-07 | Picker-Sheet for Add-Tracks in SyncProfileDetailView (with search-filter, virtualized for 10k+ tracks) | D-05 | §Picker-Sheet UX at scale |
| SYNC-v2-08 | Context-Menu „Sync to ▸ <Profile-Name>…" submenu on PlaylistCard | D-05 | TrackContextMenu line 60-79 pattern |
| SYNC-v2-09 | Context-Menu „Sync to ▸ <Profile-Name>…" submenu on TrackContextMenu (replace existing disabled placeholder line 84-89) | D-05 | TrackContextMenu existing placeholder |
| SYNC-v2-10 | „Playlists (N)" + „Tracks (N)" sections in SyncProfileDetailView with hover-trash + ContextMenu remove | D-07 | PlaylistDetailView pattern; SyncRepository.removeTrack/removePlaylist exist |
| SYNC-v2-11 | `SyncViewModel.addPlaylists/addTracks/removePlaylists/removeTracks/updateProfileSettings` + `.syncProfileDidChange` post | D-08 | Existing notification pattern, this doc §Notification Pattern |
| SYNC-v2-12 | `Notification.Name.syncProfileDidChange` declared in Notifications.swift | D-08 | This doc §Notification Pattern |
| SYNC-v2-13 | DeviceDetector dropdown in createProfileSheet next to Browse | D-09 | DeviceDetector existing API (no changes needed) |
| SYNC-v2-14 | Empty-state „Keine Geräte gefunden — angeschlossen?" disabled item in dropdown | D-10 | SwiftUI Menu disabled item |
| SYNC-v2-15 | Toolbar-Indicator for `SyncService.isRunning` visible across all routes; click → sync route | D-11 | This doc §Toolbar Indicator Hosting (see Open Questions for Phase 37 gap) |
| SYNC-v2-16 | Live Progress-Section in SyncProfileDetailView during isRunning (ProgressView + currentFile + counter + Cancel) | D-12 | SwiftUI `ProgressView(value:)`, existing `SyncService.progress` |
| SYNC-v2-17 | Failed-tracks DisclosureGroup with per-track Retry button | D-13 | Existing `SyncResult.failedTracks: [(Int64, String)]` |
| SYNC-v2-18 | `SyncService.cancelSync()` + `cancellationRequested` flag, checked between files | D-14 | This doc §Cancellation Semantics |
| SYNC-v2-19 | Transcode-Mode wiring: `keep_originals` mode bypasses TranscodeCache; `aac_320` mode passes bitrate to TranscodeService | D-01 | Currently TranscodeService hard-coded 248k — needs param |
| SYNC-v2-20 | M3U8 generation gated by `generate_m3u8 == true` (currently always runs) | D-01 | SyncService.executeSync line 218 |
| SYNC-v2-21 | Hardlink cross-FS-fallback survives FAT32 destination (EXDEV / EPERM) | D-01 | This doc §Hardlink Cross-FS Verification |
| SYNC-v2-22 | Toast UI primitive (or reuse existing) for D-03 „Rockbox erkannt" notification | D-03 | Researcher to verify: existing toast component? |
</phase_requirements>

---

## Summary

Phase 38 is **75% existing code, 25% new code** — the backbone (SyncService, TranscodeCache, SyncRepository, DeviceDetector, schema v4) is shipped and functional. The phase closes the UX gaps: a 4-column migration, two new Picker sheets, a Settings-Section in the Detail view with 4 toggles + 1 picker, a Progress-Section replacing Preview during runs, a Failed-tracks DisclosureGroup, a global toolbar indicator (new pattern — see Open Question #1), wire-up of the DeviceDetector that already exists but isn't called anywhere, and an idempotent Notification (`.syncProfileDidChange`) for cross-view refresh.

The hardest research questions are not in the Swift/SwiftUI domain — they are:
1. **There is no existing global toolbar indicator** for Phase 37's `ArtworkBackfillService` (verified via grep — `isBackfilling` is read only by tests, never by a view). D-11 says "analog to Phase 37" but the analog doesn't exist. The planner must design this surface from scratch. Recommendation: place the indicator in `ContentView.toolbar` `.primaryAction` slot, observe `container.syncService.isRunning`.
2. **Hardlink to FAT32 will always fail** (EXDEV or EPERM) — the existing `linkItem` → `copyItem` fallback in `TranscodeCache.linkToProfile` is correct in shape, but no test currently exercises the cross-FS fallback path. Phase 38 should add an integration test.
3. **`Cleanup_removed_files=true` should use `FileManager.trashItem`** for APFS/HFS+ output folders (recoverable from macOS Trash) and **`removeItem`** for FAT32/exFAT (Trash doesn't work on these). Detect filesystem via `URL.resourceValues(forKeys: [.volumeIsLocalKey, .volumeURLForRemountingKey, .volumeIsRootFileSystemKey])` or simpler: try `trashItem` first, fall back to `removeItem` on failure.

**Primary recommendation:** Treat this as a **2-wave plan** — Wave A is schema + service layer (migration, model, SyncViewModel methods, cancel flag, cleanup-deletion, `.syncProfileDidChange`, Notification declaration); Wave B is UI surface (Settings-Section, Pickers, Context-Menus, Progress-Section, Failed DisclosureGroup, toolbar indicator). Wave B depends on Wave A's API surface being stable.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Schema migration | Database (GRDB DatabaseMigrator) | — | All migrations centralized in `DatabaseManager.swift` |
| SyncProfile toggle persistence | Database (GRDB Codable record) | — | Existing `SyncProfile` struct extended |
| Settings/toggle UI | View (SwiftUI `Form`) | ViewModel (`SyncViewModel.updateProfileSettings`) | View binds to local @State, commits via async ViewModel call |
| Picker-Sheet UI | View (SwiftUI `.sheet` with `List(selection:)`) | Repository (PlaylistRepository.fetchAll / TrackRepository.fetchLocalTracks) | View pulls data on appear; selection commits via VM |
| Context-menu „Sync to ▸" | View (`PlaylistCard.contextMenu`, `TrackContextMenu`) | ViewModel (`addPlaylists`/`addTracks`) | Submenu items call VM methods directly |
| Smart-device-detect | Service (`DeviceDetector` — existing static enum) | View (Sheet UI), ViewModel (apply defaults on create) | Static fn callable from anywhere, no state |
| Sync execution | Service (`SyncService`) | View (`ProgressView` binds to `@Observable` state) | Service owns isRunning/progress/currentFile; View observes |
| Cancellation | Service (`SyncService.cancelSync()` flag) | View (Cancel-Button) | Flag-based — UI sets flag, loop in service checks it |
| File deletion | Service (`SyncService` calling FileManager) | — | UI delegates fully to service |
| Hardlink + copy fallback | Service (`TranscodeCache.linkToProfile`) | — | Existing implementation, only test coverage needed |
| M3U8 generation | Service (`SyncService.generatePlaylists` — existing private) | — | Already correct; just gate on `generate_m3u8` toggle |
| Toolbar indicator | View (`ContentView.toolbar`) | Service (`SyncService.isRunning` observable) | New surface in ContentView's toolbar block |
| Cross-view refresh | Foundation (`NotificationCenter`) | All view models | Established pattern |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| SwiftUI | macOS 14+ (already in use) | All UI surfaces | Project mandates native SwiftUI per Sonnet/SwiftUI rewrite |
| Swift Concurrency (async/await, Task) | Swift 5.9+ | All async paths | Already pervasive in codebase |
| GRDB.swift | 6.x (pinned in project) | DB access | Already used; migration system established |
| Foundation `FileManager` | system | Hardlink, copy, trash, removal | Apple-shipped; no third-party file lib needed |
| `Observation` framework (`@Observable`) | macOS 14+ | Service/ViewModel state | Already used by `SyncService`, `SyncViewModel`, `ArtworkBackfillService` |
| `NotificationCenter` | system | Cross-view refresh | Established `.libraryDidImport`/`.playlistDidChange`/`.trackArtworkDidChange` pattern |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| AppKit `NSOpenPanel` | system | Folder browse in createProfileSheet & Edit | Already in `SyncView.swift` line 142-152 |
| AppKit `NSWorkspace.activateFileViewerSelecting` | system | Reveal-in-Finder fallback if needed | Already in `TrackContextMenu` |
| `AsyncStream` / `AsyncAlgorithms.throttle` | optional | Progress throttling at >100Hz | Only if planner observes excessive SwiftUI re-renders; not pre-emptive — see Pitfall #4 |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| FileManager `linkItem` + copy fallback | rsync via Process | rsync is more battle-tested for cross-FS but adds subprocess dependency, complicates progress reporting and cancellation. **Stay with FileManager.** |
| `@Observable` Service-State binding | Combine `CurrentValueSubject` + debounce | Combine adds a layer; @Observable is already the project standard. **Stay with @Observable.** |
| `SwiftUI.Toast` (none exists) | Custom overlay or third-party library | Project has no toast component yet — researcher recommends a minimal in-app banner overlay (SwiftUI `.overlay` on root view, dismisses after 3s). See §Open Questions #2. |
| `Task.checkCancellation()` cooperative cancellation | Explicit `cancellationRequested: Bool` flag | D-14 explicitly chose flag for clean per-file `sync_state` updates. **Stay with flag (locked decision).** |

**Installation:** All dependencies already in project. No new packages needed.

**Version verification:** GRDB.swift, SwiftUI, Foundation, AppKit are all stable Apple/community APIs — no version drift risk. `[VERIFIED: codebase grep — all imports already present]`

---

## Architecture Patterns

### System Architecture Diagram

```
                       User selects profile
                              │
                              ▼
              ┌──────────────────────────┐
              │   SyncProfileDetailView  │
              │   (SwiftUI, @State+bind) │
              └──────────────┬───────────┘
                             │ observes
                             ▼
        ┌────────────────────────────────────┐
        │     SyncViewModel (@Observable)    │
        │  loadPreview/executeSync/cancelSync│◄────┐
        │  addPlaylists/addTracks/...        │     │
        │  posts .syncProfileDidChange       │     │ posts ╳ observes
        └────────┬────────────────┬──────────┘     │
                 │                │                │
       repos ◄───┘                └──► services    │
                                       │           │
        ┌───────────────────┐  ┌───────▼────────┐  │
        │  SyncRepository   │  │  SyncService   │  │
        │  (GRDB CRUD)      │  │  (@Observable) │──┘
        └─────────┬─────────┘  └────┬───────────┘
                  │                  │ uses
                  │                  ▼
                  │           ┌─────────────┐
                  │           │ Transcode   │
                  │           │ Cache       │
                  │           │ (hardlink+  │
                  │           │  copy)      │
                  │           └────┬────────┘
                  │                │ runs
                  │                ▼
                  │      ┌─────────────────────┐
                  │      │  TranscodeService   │
                  │      │  (ffmpeg subprocess)│
                  │      └─────────────────────┘
                  │
                  ▼
              SQLite DB (sync_profiles, sync_profile_tracks,
                         sync_profile_playlists, sync_state)
                              │
                              ▼
                         Output Folder
                  (m4a files via hardlink/copy
                   + .m3u8 playlists)
```

**Toolbar indicator path (cross-route):**

```
ContentView.toolbar
   └── ToolbarItem(.primaryAction)
        └── SyncStatusButton  (new)
             └── observes container.syncService.isRunning
                  └── on click → selectedSection = .sync
```

### Recommended Project Structure (additions)

```
macos-app/MLM/
├── Views/Sync/
│   ├── SyncView.swift                       # existing — minor edits
│   ├── SyncProfileDetailView.swift          # refactor: add Settings, Content sections, Progress, Failed
│   ├── SyncPickerSheet.swift                # NEW — playlist + track picker (generic)
│   ├── SyncSettingsForm.swift               # NEW — Form with 4 toggles + 1 picker
│   ├── SyncProgressSection.swift            # NEW — ProgressView + counter + Cancel
│   ├── SyncFailedDisclosure.swift           # NEW — DisclosureGroup with retry buttons
│   └── SyncToolbarIndicator.swift           # NEW — global indicator (hosted in ContentView)
├── Views/Sync/Pickers/
│   ├── PlaylistPickerSheet.swift            # NEW — multi-select playlists
│   └── TrackPickerSheet.swift               # NEW — search + multi-select tracks
├── ViewModels/
│   └── SyncViewModel.swift                  # extend (add 5 methods + cancel)
├── Services/Sync/
│   ├── SyncService.swift                    # extend (cancel flag, cleanup-deletion, toggle-aware execute)
│   └── DeviceDetector.swift                 # unchanged (already done)
├── Database/
│   ├── DatabaseManager.swift                # add `v_sync_toggles` migration
│   └── SyncRepository.swift                 # extend updateSettings signature with new toggles
├── Models/
│   └── SyncProfile.swift                    # extend with 4 new fields + enum TranscodeMode
└── Utilities/
    └── Notifications.swift                  # add .syncProfileDidChange
```

### Pattern 1: GRDB Additive Migration

**What:** Migrations are append-only registered in `DatabaseManager.buildMigrator()`. Each migration has a unique string name (e.g., `v20_playlist_cover_custom`). Idempotent via `IF NOT EXISTS` and column-existence guards.

**When to use:** Adding columns to existing tables.

**Example (verified — DatabaseManager.swift line 605-611):**
```swift
migrator.registerMigration("v_sync_toggles") { db in
    if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "generate_m3u8" }) {
        try db.alter(table: "sync_profiles") { t in
            t.add(column: "generate_m3u8", .integer).notNull().defaults(to: 0)
            t.add(column: "transcode_mode", .text).notNull().defaults(to: "keep_originals")
            t.add(column: "fat32_safe_paths", .integer).notNull().defaults(to: 1)
            t.add(column: "cleanup_removed_files", .integer).notNull().defaults(to: 1)
        }
    }
}
```

**Naming note:** Project uses descriptive string names (`v20_playlist_cover_custom`, `v_search_text_column`) rather than strictly numeric. The migration list is NOT sequential — there are mixed `vNN_` and `v_` prefixed migrations. Recommendation: `v_sync_toggles` (matches the unnumbered pattern, semantic-named).

### Pattern 2: `@Observable` Service Owning UI-Read State

**What:** Services that hold state read by SwiftUI views are `@Observable` classes; their `var` properties trigger View re-evaluation when mutated on the actor.

**When to use:** Any cross-view background operation (`SyncService`, `ArtworkBackfillService`).

**Example (verified — SyncService.swift line 8-42):** Already implemented. Phase 38 adds `cancellationRequested: Bool` and reads it in the for-loop.

### Pattern 3: NotificationCenter for Cross-View Refresh

**What:** Posts to `NotificationCenter.default`; views observe via `NotificationCenter.default.publisher(for:)`.

**Example (verified — Notifications.swift):**
```swift
// In Notifications.swift, add:
static let syncProfileDidChange = Notification.Name("MLMSyncProfileDidChange")

// In SyncViewModel after every mutation:
NotificationCenter.default.post(
    name: .syncProfileDidChange,
    object: nil,
    userInfo: ["profileId": profileId]
)
```

### Pattern 4: Picker-Sheet with Multi-Selection

**What:** SwiftUI `.sheet(isPresented:)` showing a `List` with `Set<Int64>` selection binding, search field at top, Done button commits.

**When to use:** D-05 Add-Playlists / Add-Tracks pickers.

**Example (synthesized — pattern verified against SwiftUI docs):**
```swift
struct PlaylistPickerSheet: View {
    let allPlaylists: [Playlist]
    @State private var selected: Set<Int64> = []
    @State private var query: String = ""
    let onCommit: ([Int64]) -> Void

    var filtered: [Playlist] {
        query.isEmpty ? allPlaylists : allPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding()
            List(filtered, id: \.id, selection: $selected) { p in
                Text(p.name).tag(p.id ?? -1)
            }
            HStack {
                Button("Cancel") { onCommit([]) }
                Spacer()
                Button("Add \(selected.count)") { onCommit(Array(selected)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
            }.padding()
        }.frame(width: 480, height: 520)
    }
}
```

### Anti-Patterns to Avoid

- **Background-polling for device-mount.** D-09 explicitly chose on-demand. Do NOT add `NSWorkspace.didMountNotification` observer.
- **Mid-transcode subprocess kill on cancel.** D-14 chose between-file flag check. Killing ffmpeg mid-frame produces corrupt .m4a files at destination that pass the `isCached` size-check (it only verifies `> 0`).
- **`@Published` + Combine for service state.** Project uses `@Observable` — do not mix.
- **Synchronous file I/O on MainActor.** All `FileManager` calls in the per-file loop should run on a background task. `SyncService` is `@Observable` (not `@MainActor`) — `progress` writes are already main-actor-isolated through `@Observable`'s magic; just don't mark the service `@MainActor`.
- **Returning early from `executeSync` without resetting state.** Currently `defer { isRunning = false }` handles this. New cancel flag must NOT bypass the defer.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| FAT32 filename sanitization | Custom regex | `PathSanitizer.sanitizeFilename` / `sanitizeComponent` (existing) | Handles unsafe chars, reserved names, trailing dots, 255-char limit, "unknown" fallback. Tested against Tauri pendant. |
| Hardlink + copy fallback | Manual stat + linkat syscall | `FileManager.linkItem(at:to:)` with `catch → copyItem` | Already implemented in `TranscodeCache.linkToProfile`. Foundation handles EXDEV/EPERM transparently. |
| AAC transcoding | Direct ffmpeg shellout | `TranscodeService.transcode(input:outputDir:)` (existing) | Handles libfdk_aac → aac fallback, cover-art preserve, lossy-skip logic. |
| M3U8 generation | String concatenation in views | `SyncService.generatePlaylists` (existing private) | Already implemented. Just gate on `generate_m3u8` toggle. |
| File-to-trash on cleanup | `removeItem` directly | `FileManager.trashItem(at:resultingItemURL:)` first, fall back to `removeItem` on FAT32 | macOS Trash is recoverable; FAT32 has no Trash. See §Disk-Deletion Safety. `[CITED: developer.apple.com/documentation/foundation/filemanager/1414306-trashitem]` |
| Rockbox device detection | Custom mount-table parse | `DeviceDetector.detectRockboxDevices()` (existing) | Scans `/Volumes/*/.rockbox`. Done. |
| Cross-view refresh | View polling | `NotificationCenter.default` + `.syncProfileDidChange` | Established pattern. |
| Search-filter list | Linear scan rebuilding views | SwiftUI `List` with `id:` (NOT `LazyVStack`) | List recycles cells via UICollectionView (iOS 16+) / NSTableView wrapper. 10k+ rows handled. `[CITED: fatbobman.com/en/posts/list-or-lazyvstack/]` |

**Key insight:** All the hard problems in this phase are already solved by existing services. Phase 38 is **predominantly UI wiring** — the temptation to "improve" `SyncService` or `TranscodeCache` should be resisted. The lines of new service code should be: cancel flag + flag check (~10 LOC), cleanup-deletion branch (~15 LOC), transcode-mode plumbing (~20 LOC). That's it. All other work is in Views/.

---

## Runtime State Inventory

This is a **feature-add phase**, not a rename/refactor. The state inventory below confirms no runtime state needs migration:

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Existing sync_profiles rows have no toggle columns; migration adds them with NOT NULL DEFAULTs so existing rows get sensible defaults (cleanup=1, fat32=1, m3u8=0, transcode='keep_originals'). | Migration handles automatically. No data backfill needed beyond DEFAULT clause. |
| Live service config | None — Phase 38 introduces no new external service config. ffmpeg is already required (Phase 37); no DAB/yt-dlp involvement. | None. |
| OS-registered state | None — no LaunchAgents, no Login Items, no Spotlight indexes. | None. |
| Secrets/env vars | None. | None. |
| Build artifacts | None — pure source additions to existing Xcode targets. | None. |

**Existing profiles after migration:** Will load with `generate_m3u8=0`, `transcode_mode='keep_originals'`, `fat32_safe_paths=1`, `cleanup_removed_files=1`. **Note:** This means existing profiles **stop generating M3U8** until user explicitly enables it. Researcher recommendation: in the migration, set `generate_m3u8 = 1` for any row whose `output_folder` currently lives on a `.rockbox` volume at migration time. Planner decision needed — see Open Questions #3.

---

## Migration Design

**Current state of DatabaseManager.swift:**

The migrator does NOT use sequential numeric versions. Registered migrations include `v1_core_tracks` through `v17_album_remediation`, then `v_organized_path_index`, `v_sort_indexes`, `v_migrations_tracking`, `v20_playlist_cover_custom`, `v_search_text_column`. The numbering is NOT strictly sequential. [VERIFIED: DatabaseManager.swift line 605, 617]

**CONTEXT.md says "v6"**, but **v6 is already taken** (`v6_app_config`, line 355). The next free purely-sequential number would be **v21** (after v20). However the project's convention is to use **semantic names** for non-core schema additions.

**Recommended migration name:** `v_sync_toggles` (matches `v_organized_path_index`, `v_sort_indexes`, `v_search_text_column` semantic-name pattern).

**Exact statements to register:**

```swift
// ──────────────────────────────────────────────────────────────
// Migration v_sync_toggles: Phase 38 — explicit folder/device toggles
// Adds 4 columns to sync_profiles for D-01:
//   generate_m3u8         — emit M3U8 playlists on sync (Rockbox)
//   transcode_mode        — 'keep_originals' | 'aac_248' | 'aac_320'
//   fat32_safe_paths      — apply PathSanitizer to dest paths
//   cleanup_removed_files — actually unlink m4a files on remove
// ──────────────────────────────────────────────────────────────
migrator.registerMigration("v_sync_toggles") { db in
    let cols = try db.columns(in: "sync_profiles").map(\.name)
    try db.alter(table: "sync_profiles") { t in
        if !cols.contains("generate_m3u8") {
            t.add(column: "generate_m3u8", .integer).notNull().defaults(to: 0)
        }
        if !cols.contains("transcode_mode") {
            t.add(column: "transcode_mode", .text).notNull().defaults(to: "keep_originals")
        }
        if !cols.contains("fat32_safe_paths") {
            t.add(column: "fat32_safe_paths", .integer).notNull().defaults(to: 1)
        }
        if !cols.contains("cleanup_removed_files") {
            t.add(column: "cleanup_removed_files", .integer).notNull().defaults(to: 1)
        }
    }
}
```

**Verification grep:** No existing migration named `v_sync_toggles`. [VERIFIED: codebase grep]

---

## Notification Pattern

**Existing notifications (verified — Notifications.swift):**

- `.libraryDidImport` line 20
- `.libraryDidDeleteTracks` line 26
- `.libraryRootDidChange` line 31
- `.playbackTrackDidChange` line 36 (reserved Phase 5)
- `.playbackStateDidChange` line 39 (reserved Phase 5)
- `.playlistDidChange` line 47
- `.trackArtworkDidChange` line 57
- `.syncDidComplete` line 62 (reserved Phase 12 — **but does NOT include `.syncProfileDidChange`**)
- `.downloadDidComplete` line 72
- `.focusSearchField`, `.showImportDialog`, `.revealSelectedInFinder`, `.showTrackDetail` (UI actions)

**Recommended addition (verified — none currently exists with this name):**

```swift
// MARK: Sync (Phase 12 + Phase 38)

/// Posted when a sync operation completes.
static let syncDidComplete = Notification.Name("MLMSyncDidComplete")  // existing

/// Posted when a sync profile is mutated (content added/removed, settings changed).
///
/// Observers should reload profile state. Used to keep SyncProfileDetailView,
/// PlaylistCard/TrackContextMenu "Sync to ▸" submenu, and toolbar indicator in sync.
///
/// - `userInfo["profileId"]`: `Int64` — the mutated profile (optional — nil = "any profile")
static let syncProfileDidChange = Notification.Name("MLMSyncProfileDidChange")
```

**Where to post (in SyncViewModel after each mutation):**

```swift
private func postProfileChange(_ id: Int64) {
    NotificationCenter.default.post(
        name: .syncProfileDidChange,
        object: nil,
        userInfo: ["profileId": id]
    )
}
```

---

## Toolbar Indicator Hosting

**⚠️ Critical finding:** CONTEXT.md D-11 says "Toolbar-Indikator-Pattern analog Phase 37 ArtworkBackfillService". **This pattern does NOT exist in the codebase.** [VERIFIED: grep `isBackfilling` in Views/ finds no view binding]

**What exists in `ContentView.swift` (line 117-123):**
```swift
.toolbar {
    ToolbarItem(placement: .principal) {
        if let vm = container.playbackViewModel {
            PlayerBar(viewModel: vm)
        }
    }
}
```

This is the **only** global toolbar slot, occupied by the player. The principal slot is full.

**Available placements in macOS SwiftUI toolbar:**
- `.principal` — center, taken by PlayerBar
- `.primaryAction` — trailing leading-most
- `.automatic` — usually trailing
- `.navigation` — leading
- `.confirmationAction` / `.cancellationAction` — for sheets

**Recommendation:** Add `ToolbarItem(placement: .primaryAction)` next to `.principal`:

```swift
.toolbar {
    ToolbarItem(placement: .principal) {
        if let vm = container.playbackViewModel { PlayerBar(viewModel: vm) }
    }
    ToolbarItem(placement: .primaryAction) {
        if let syncSvc = container.syncService, syncSvc.isRunning {
            SyncToolbarIndicator(service: syncSvc, onTap: {
                selectedSection = .sync
            })
        }
    }
}
```

**SyncToolbarIndicator view (new):**

```swift
struct SyncToolbarIndicator: View {
    let service: SyncService
    let onTap: () -> Void

    var counter: String {
        let total = max(Int(round(service.progress * /* known total */ 1)), 1)
        // Track processed/total externally on service. See SYNC-v2-18 / D-12.
        return ""  // populated when service exposes (processed, total)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Syncing…")
                    .font(MLMFont.muted)
            }
        }
        .buttonStyle(.plain)
        .help("Sync running — click to view")
    }
}
```

**Service exposure gap:** `SyncService` currently does NOT expose `(processed, total)` — only `progress: Double` and `currentFile: String`. For the toolbar counter ("23/145") in D-11, the planner must add `processed: Int` and `total: Int` properties to the service. Trivial: replace `progress = Double(processed) / Double(max(total, 1))` with also-store-them.

**Container exposure gap:** `DependencyContainer` does NOT expose `syncService` directly — only `syncViewModel`. The planner must add a `syncService` getter (or thread the service through `syncViewModel`).

---

## Cancellation Semantics

**Locked decision (D-14):** Flag-based, between-files, NOT mid-transcode kill.

**Recommended implementation:**

```swift
// In SyncService
private(set) var cancellationRequested = false

func cancelSync() {
    cancellationRequested = true
}

// In executeSync, inside the for-file loop:
for file in preview.filesToAdd {
    if cancellationRequested { break }   // <-- between files
    currentFile = "\(file.artist) - \(file.title)"
    // ... existing transcode + link work ...
    processed += 1
    progress = Double(processed) / Double(max(total, 1))
}

// Reset flag at top of executeSync:
isRunning = true
cancellationRequested = false
defer { isRunning = false; currentFile = "" }
```

**Why flag, not `Task.checkCancellation`:** [VERIFIED: D-14 rationale + Swift Concurrency semantics]

1. `Task.checkCancellation` would throw `CancellationError` from `await trackRepository.fetchTrack` — partial `sync_state` updates could be lost mid-transaction.
2. Cooperative cancellation does not stop subprocess work — would need explicit `Process.terminate()` on ffmpeg anyway.
3. Flag check between files guarantees the *most recent track* is fully written or fully skipped, never half-done.

**SwiftUI binding for Cancel button:**

```swift
// In SyncProgressSection
Button("Cancel") {
    container.syncService?.cancelSync()
}
.disabled(!service.isRunning)
```

**Result display after cancellation:** Add a `wasCancelled: Bool` field to `SyncResult` so the Result-Section can show "Sync cancelled — N synced, M skipped" per D-14 spec.

---

## Picker-Sheet UX at Scale

**Question:** Library has 10,000+ tracks. Will `List` with search-filter perform?

**Verified findings:**

1. **SwiftUI `List` (NOT `LazyVStack`) is the correct choice.** `List` wraps `NSTableView` (macOS) / `UICollectionView` (iOS 16+) with cell recycling. `LazyVStack` keeps every view in memory once created and does not recycle. `[CITED: fatbobman.com/en/posts/list-or-lazyvstack/]`
2. **`List` handles 10k rows smoothly** when the row body is simple and items conform to `Identifiable` with stable IDs. `[CITED: blog.stackademic.com — 10,000 items]`
3. **Search filter** should be applied in a computed property `filtered: [Track]` — SwiftUI re-renders the List on filter change, but cell recycling keeps it cheap.
4. **Multi-select with `Set<Int64>` selection binding** works natively with `List(selection:)` on macOS.

**Recommended pattern:**

```swift
struct TrackPickerSheet: View {
    @State private var query = ""
    @State private var selected: Set<Int64> = []
    @State private var allTracks: [Track] = []   // load .task

    @Environment(\.container) private var container

    var filtered: [Track] {
        if query.isEmpty { return allTracks }
        let q = query.lowercased()
        return allTracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search tracks…", text: $query)
                .textFieldStyle(.roundedBorder).padding()
            List(filtered, id: \.id, selection: $selected) { t in
                HStack {
                    Text(t.title)
                    Text("— \(t.artist)").foregroundColor(.secondary)
                }
                .tag(t.id ?? -1)
            }
            HStack {
                Button("Cancel") { /* dismiss */ }
                Spacer()
                Button("Add \(selected.count)") { /* commit */ }
                    .disabled(selected.isEmpty)
            }.padding()
        }
        .frame(width: 560, height: 600)
        .task {
            if let repo = container.trackRepository {
                allTracks = (try? await repo.fetchLocalTracks()) ?? []
            }
        }
    }
}
```

**Performance pitfall:** Re-running the filter on every keystroke for 10k tracks should still be <16ms (substring scan over String fields). If profiling reveals lag, debounce the `query` binding with a 100ms delay via `.onChange(of: query) + Task.sleep`. **Not pre-emptive — measure first.**

**Idempotency feedback (Claude's discretion in CONTEXT.md):** `SyncRepository.addTrack` uses `INSERT OR IGNORE`. After commit, the ViewModel can compute "X added, Y already in profile" by diffing `selected` against `fetchProfileTracks` post-add. Recommendation: optional polish — show a toast or inline count below header.

---

## Disk-Deletion Safety (D-04)

**Question:** When `cleanup_removed_files = true`, what is the safe FileManager pattern for deleting `.m4a` files from the output folder?

**Three options compared:**

| Method | Recoverable? | Works on FAT32? | Works on APFS? | Notes |
|--------|--------------|-----------------|----------------|-------|
| `FileManager.removeItem(at:)` | ❌ permanent | ✅ | ✅ | Direct unlink. Fast. No undo. |
| `FileManager.trashItem(at:resultingItemURL:)` | ✅ (macOS Trash) | ❌ throws | ✅ | macOS Trash is volume-specific; FAT32/exFAT have no `.Trashes` |
| `NSWorkspace.recycle(_:completionHandler:)` | ✅ (macOS Trash) | ❌ same limit | ✅ | Async; uses Finder coordination |

`[CITED: developer.apple.com/documentation/foundation/filemanager/1414306-trashitem]`
`[CITED: developer.apple.com/documentation/appkit/nsworkspace/1530465-recycleurls]`
`[CITED: christiantietze.de — trashItem uses NSFileCoordinator]`

**Recommended pattern (try-trash-fall-back-to-remove):**

```swift
private func safeDelete(at url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
        var resultingURL: NSURL? = nil
        try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
    } catch {
        // FAT32/exFAT/missing-Trash — fall back to direct removal
        try? FileManager.default.removeItem(at: url)
    }
}
```

**Sync-state cleanup:** Always remove the `sync_state` row, regardless of file-deletion success. `cleanup_removed_files = false` only suppresses the file-deletion step; the DB-row removal happens unconditionally (since the track is no longer in the profile content).

**Rationale for the current quirk fix:** Today, `executeSync` line 161-169 removes only the `sync_state` row, never the file. This causes orphaned `.m4a` files on the iPod. With `cleanup_removed_files=1` default, new behavior cleans them up. With `=0`, behavior preserved (deliberate user opt-out).

---

## Hardlink Cross-FS Verification

**Question:** Does `linkItem` → `copyItem` fallback in `TranscodeCache.linkToProfile` actually work for FAT32 destinations?

**Verified mechanics:** [CITED: Apple FileManager docs + POSIX `link(2)`]

1. `FileManager.linkItem(at:to:)` wraps POSIX `link(2)`.
2. `link()` returns `EXDEV` (Cross-device link) when source and destination are on different filesystems.
3. `link()` returns `EPERM` on filesystems that don't support hardlinks (FAT32 doesn't even with same-volume).
4. Both errors are thrown by `FileManager.linkItem` as `NSCocoaErrorDomain` / `NSPOSIXErrorDomain` `Error`s.
5. The existing `try { link } catch { copy }` pattern in `TranscodeCache.linkToProfile` lines 92-98 correctly handles **any** thrown error, including EXDEV and EPERM.

**Confidence:** HIGH — the pattern is sound.

**Caveats found in research:**

- **FUSE / network mounts** (rclone, NFS) also fail hardlinks; the same try/catch handles them. `[CITED: github.com/rclone/rclone/issues/4980]`
- **Disk-space penalty**: when fallback fires, the m4a is fully copied to the target — large m4a libraries copying to FAT32 takes proportionally longer. The user-visible UX impact is on progress reporting (per-file, no copy-progress). Acceptable for Phase 38.

**Test coverage gap:** Existing tests (`MLMTests/ServiceTests/`) have no `TranscodeCache` test for the cross-FS-fallback path. **Wave 0 should add one** — use `tempfile`-equivalent (Swift: `URL.temporaryDirectory`) with a mock FAT32 mount substitute (write-only `RAMDisk`-style: just create a directory and mock the link failure via swizzle, OR practically: write an integration test that requires a USB/iPod attached and is `.skip()`-able when not present).

**Recommended test pattern:**

```swift
@Suite("TranscodeCache cross-FS fallback")
struct TranscodeCacheFallbackTests {
    @Test func testCopyFallbackOnEXDEV() throws {
        // Create cache + dest on same FS — verify hardlink succeeds (link count = 2)
        // Then attempt to a USB/iPod mount if present; otherwise mock by swizzling linkItem to throw
    }
}
```

---

## ProgressBar Update Throttling

**Question:** `SyncService.progress` is set after every file. For 1000+ track syncs, does SwiftUI re-render at 1000 Hz?

**Verified mechanics:** [CITED: Apple Observation framework + SwiftUI rendering]

1. `@Observable` triggers View body re-evaluation **synchronously per property write** if the View observes that specific property.
2. SwiftUI coalesces rapid main-actor state changes into the next display cycle (~16ms / 60Hz). Multiple writes within a frame collapse to one re-render.
3. Per-file updates happen at the rate of disk-I/O (hardlink: <1ms; copy: tens of ms per MB; transcode: seconds). **Real-world rate is 1-10 Hz, not 1000 Hz.**

**Recommendation:** No throttling needed pre-emptively. SwiftUI's frame coalescing handles it.

**Defensive option (only if profiling shows lag):** Wrap progress writes with throttle via `AsyncStream` + `AsyncAlgorithms.throttle(for:.milliseconds(50))`. Adds complexity; recommend **deferring until measured**.

`[CITED: developer.apple.com/forums/thread/735510 — Debounce and Throttle with @Observable]`

---

## PathSanitizer FAT32 Behavior

**Question:** Does PathSanitizer handle all FAT32-illegal chars and the 255-char limit?

**Verified — PathSanitizer.swift line 25-32:**

```swift
private static let unsafeCharacters = CharacterSet(charactersIn: "<>:\"/\\|?*")
private static let reservedNames: Set<String> = [
    "CON", "PRN", "AUX", "NUL",
    "COM1"..."COM9",  // listed individually
    "LPT1"..."LPT9",
]
```

| FAT32 restriction | Handled? | How |
|-------------------|----------|-----|
| `< > : " / \ | ? *` | ✅ | replaced with `_` |
| Trailing dots | ✅ | line 66-68 strips |
| 255-char filename | ✅ | line 71-73 truncates |
| Windows reserved names (CON, AUX...) | ✅ | line 81-83 prefixes with `_` |
| Control characters (0x00-0x1F) | ✅ | `sanitizeComponent` filters via `CharacterSet.controlCharacters` |
| Leading dots (FAT32 allows but problematic on macOS) | ⚠️ NOT handled | Not a hard FAT32 restriction; macOS hides dotfiles. Low priority. |
| Empty/whitespace name | ✅ | returns `"unknown"` |
| Maximum path length (260 chars on Windows, no hard limit on FAT32 itself but mount drivers may enforce) | ⚠️ per-component only, NOT total path | Could break with very deep library hierarchies. Phase 38 inherits same behavior as Tauri pendant. |

**Confidence:** HIGH — coverage is sufficient for Rockbox iPod use cases. No patch needed in Phase 38.

**Possible Wave 0 addition:** Add an explicit unit test for the 255-char truncation case using a manufactured 300-char title.

---

## Common Pitfalls

### Pitfall 1: Forgetting the M3U8 toggle gate

**What goes wrong:** `SyncService.executeSync` always calls `generatePlaylists` (line 218). After Phase 38, this must be conditional on `profile.generateM3U8`.

**Why it happens:** Existing line is unconditional and easy to miss in a diff.

**How to avoid:** Add an explicit early-return guard:
```swift
if profile.generateM3U8 {
    try await generatePlaylists(profileId: profileId, profile: profile, libraryRoot: libraryRoot)
}
```

**Warning signs:** Folder-mode profiles get M3U8s scattered in target dirs.

### Pitfall 2: Transcode-mode `keep_originals` still goes through TranscodeCache

**What goes wrong:** `TranscodeCache.ensureCached` always transcodes to 248k AAC. For `keep_originals` mode, the source file should be linked/copied directly (no transcode).

**Why it happens:** `TranscodeCache` was designed for the Rockbox 248k-AAC use case only.

**How to avoid:** Branch in `executeSync`:
```swift
let sourceForLink: URL
switch profile.transcodeMode {
case .keepOriginals:
    sourceForLink = URL(fileURLWithPath: libraryRoot + "/" + (track.organizedPath ?? ""))
case .aac248, .aac320:
    sourceForLink = try await transcodeCache.ensureCached(track: track, bitrate: profile.transcodeMode.bitrate)
}
try transcodeCache.linkToProfile(source: sourceForLink, destinationPath: destURL)
```

Refactor: `linkToProfile` should accept a source URL parameter rather than reading cache path internally — this lets it serve both modes.

**Warning signs:** Setting transcode_mode to `keep_originals` still produces .m4a files (should be original format).

### Pitfall 3: Smart-detect toast fires while user is still typing

**What goes wrong:** Smart-detect (D-03) runs on `outputFolder` change. If user types a path manually (TextField), toast fires per keystroke.

**Why it happens:** SwiftUI `.onChange(of: newProfileOutput)` triggers per character.

**How to avoid:** Run smart-detect only after Browse button confirms a path OR after a debounce on the TextField. Recommended: only on Browse confirmation.

**Warning signs:** Toast flicker during typing.

### Pitfall 4: Cancel-flag NOT reset on subsequent run

**What goes wrong:** After cancellation, `cancellationRequested = true` persists. Next `executeSync` call exits immediately at the first file.

**Why it happens:** Forgetting to reset at the top of `executeSync`.

**How to avoid:** `cancellationRequested = false` at the very top of `executeSync`, before `isRunning = true`.

**Warning signs:** Sync exits immediately after a cancel-then-retry.

### Pitfall 5: `INSERT OR IGNORE` silently swallows duplicate adds

**What goes wrong:** Picker-Sheet shows tracks already in the profile — user doesn't realize. Adds 50, only 3 are actually new.

**Why it happens:** `SyncRepository.addTrack` uses `INSERT OR IGNORE` (correct for idempotency but no feedback).

**How to avoid:** Pre-filter the picker list by `fetchProfileTracks` to mark already-added items as disabled OR show a "(in profile)" tag. Polish: post-add diff to show "3 added, 47 already present".

**Warning signs:** Users complain "nothing happens" when they re-add tracks.

### Pitfall 6: Notification observer cleanup in SyncViewModel

**What goes wrong:** Adding `.syncProfileDidChange` observer in `SyncViewModel.init` without removing in deinit causes retain cycle.

**Why it happens:** `NotificationCenter.addObserver(forName:object:queue:using:)` retains the block.

**How to avoid:** Follow the pattern in `ArtworkBackfillService.deinit` (line 74-80) — store `observerToken: NSObjectProtocol?`, remove in deinit.

**Warning signs:** Memory profile shows SyncViewModel instances accumulating.

### Pitfall 7: Hardlink leaves stale destination after cache eviction

**What goes wrong:** Hardlink means cache file and destination share inode. If cache is evicted (`removeItem` on `{trackId}.m4a`), the destination still works (inode reference count). But if the cache is *rebuilt* (transcoded again to a new inode), the destination becomes a stale link to the old file.

**Why it happens:** `TranscodeCache.ensureCached` uses `moveItem` to rename — the new file gets a new inode.

**How to avoid:** Before re-transcoding, also `try? FileManager.default.removeItem(at: destinationPath)` on every profile that has a `sync_state` row for this track. Today this is implicit because Phase 38 doesn't re-transcode (cache is permanent). Future Phase 19/22 may need explicit invalidation.

**Warning signs:** Track-tag edits not reflected on iPod after re-sync.

### Pitfall 8: SwiftUI `.sheet` dismissal race with async commit

**What goes wrong:** Picker `Add` button: `Task { await vm.addTracks(...) }`; `showSheet = false`. Sheet closes immediately, Task runs after. If user reopens before Task completes, content list is stale.

**Why it happens:** Sheet dismissal is synchronous, Task is async.

**How to avoid:** Close sheet AFTER `await`:
```swift
Button("Add") {
    Task {
        await vm.addTracks(selected)
        showSheet = false
    }
}
```

**Warning signs:** Picker-Sheet appears to "add nothing" sometimes.

---

## Code Examples

### Example 1: Extended SyncProfile model

```swift
// Models/SyncProfile.swift — extension for Phase 38
extension SyncProfile {
    enum TranscodeMode: String, Codable, CaseIterable {
        case keepOriginals = "keep_originals"
        case aac248 = "aac_248"
        case aac320 = "aac_320"

        var displayName: String {
            switch self {
            case .keepOriginals: "Keep originals"
            case .aac248: "AAC 248 kbps (Rockbox)"
            case .aac320: "AAC 320 kbps"
            }
        }

        var aacBitrateKbps: Int? {
            switch self {
            case .keepOriginals: nil
            case .aac248: 248
            case .aac320: 320
            }
        }
    }
}

// Full struct (additions in bold)
struct SyncProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var outputFolder: String
    var playlistPathPrefix: String
    var dateCreated: String?
    var dateModified: String?
    // Phase 38:
    var generateM3U8: Bool = false
    var transcodeMode: TranscodeMode = .keepOriginals
    var fat32SafePaths: Bool = true
    var cleanupRemovedFiles: Bool = true

    enum CodingKeys: String, CodingKey {
        case id, name
        case outputFolder = "output_folder"
        case playlistPathPrefix = "playlist_path_prefix"
        case dateCreated = "date_created"
        case dateModified = "date_modified"
        case generateM3U8 = "generate_m3u8"
        case transcodeMode = "transcode_mode"
        case fat32SafePaths = "fat32_safe_paths"
        case cleanupRemovedFiles = "cleanup_removed_files"
    }
}
```

### Example 2: SyncViewModel.addPlaylists (D-08)

```swift
extension SyncViewModel {
    func addPlaylists(_ ids: [Int64]) async {
        guard let profile = selectedProfile, let pid = profile.id else { return }
        for playlistId in ids {
            do {
                try await syncRepository.addPlaylist(profileId: pid, playlistId: playlistId)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }
        await loadPreview(for: profile)
        NotificationCenter.default.post(
            name: .syncProfileDidChange,
            object: nil,
            userInfo: ["profileId": pid]
        )
    }

    func removeTracks(_ ids: [Int64]) async {
        guard let profile = selectedProfile, let pid = profile.id else { return }
        for trackId in ids {
            try? await syncRepository.removeTrack(profileId: pid, trackId: trackId)
        }
        await loadPreview(for: profile)
        NotificationCenter.default.post(
            name: .syncProfileDidChange, object: nil,
            userInfo: ["profileId": pid]
        )
    }

    func updateProfileSettings(
        name: String? = nil,
        outputFolder: String? = nil,
        generateM3U8: Bool? = nil,
        transcodeMode: SyncProfile.TranscodeMode? = nil,
        fat32SafePaths: Bool? = nil,
        cleanupRemovedFiles: Bool? = nil,
        playlistPathPrefix: String? = nil
    ) async {
        guard let profile = selectedProfile, let pid = profile.id else { return }
        // SyncRepository.updateSettings must be extended with the new params
        try? await syncRepository.updateSettings(
            profileId: pid,
            name: name,
            outputFolder: outputFolder,
            playlistPathPrefix: playlistPathPrefix,
            generateM3U8: generateM3U8,
            transcodeMode: transcodeMode?.rawValue,
            fat32SafePaths: fat32SafePaths,
            cleanupRemovedFiles: cleanupRemovedFiles
        )
        // Reload profile from DB to pick up changes
        if let updated = try? await syncRepository.fetch(id: pid) {
            if let idx = profiles.firstIndex(where: { $0.id == pid }) { profiles[idx] = updated }
            selectedProfile = updated
            await loadPreview(for: updated)
        }
        NotificationCenter.default.post(
            name: .syncProfileDidChange, object: nil,
            userInfo: ["profileId": pid]
        )
    }
}
```

### Example 3: Settings Form (D-02)

```swift
struct SyncSettingsForm: View {
    let profile: SyncProfile
    let onCommit: (SyncProfile) -> Void

    @State private var generateM3U8: Bool
    @State private var transcodeMode: SyncProfile.TranscodeMode
    @State private var fat32SafePaths: Bool
    @State private var cleanupRemovedFiles: Bool

    init(profile: SyncProfile, onCommit: @escaping (SyncProfile) -> Void) {
        self.profile = profile
        self.onCommit = onCommit
        _generateM3U8 = State(initialValue: profile.generateM3U8)
        _transcodeMode = State(initialValue: profile.transcodeMode)
        _fat32SafePaths = State(initialValue: profile.fat32SafePaths)
        _cleanupRemovedFiles = State(initialValue: profile.cleanupRemovedFiles)
    }

    var body: some View {
        Form {
            Toggle("Generate M3U8 playlists", isOn: $generateM3U8)
                .help("Required for Rockbox-based iPods")
            Picker("Transcode mode", selection: $transcodeMode) {
                ForEach(SyncProfile.TranscodeMode.allCases, id: \.self) {
                    Text($0.displayName).tag($0)
                }
            }
            Toggle("FAT32-safe filenames", isOn: $fat32SafePaths)
                .help("Replaces unsafe chars in folder/file names")
            Toggle("Delete removed files from disk", isOn: $cleanupRemovedFiles)
                .help("When off, removing tracks only clears the sync state but leaves files")
        }
        .onChange(of: [generateM3U8, fat32SafePaths, cleanupRemovedFiles]) { _, _ in
            commit()
        }
        .onChange(of: transcodeMode) { _, _ in commit() }
    }

    private func commit() {
        var p = profile
        p.generateM3U8 = generateM3U8
        p.transcodeMode = transcodeMode
        p.fat32SafePaths = fat32SafePaths
        p.cleanupRemovedFiles = cleanupRemovedFiles
        onCommit(p)
    }
}
```

### Example 4: "Sync to ▸" submenu in TrackContextMenu (D-05)

```swift
// Insert in TrackContextMenu.swift around current line 84-90 (the disabled placeholder)
Section {
    Menu {
        if availableSyncProfiles.isEmpty {
            Text("No sync profiles")
        } else {
            ForEach(availableSyncProfiles) { profile in
                Button {
                    syncTo(profile)
                } label: {
                    Label(profile.name, systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Divider()
            Button("Create new profile…") { /* trigger create sheet */ }
        }
    } label: {
        Label("Sync to\(countSuffix)", systemImage: "arrow.triangle.2.circlepath")
    }
    .disabled(selectedTracks.isEmpty)
}

private func syncTo(_ profile: Profile) {
    guard let pid = profile.id, let vm = container.syncViewModel else { return }
    let ids = Array(selectedTrackIDs)
    Task {
        await vm.addTracksDirectly(profileId: pid, trackIds: ids)  // new VM method that doesn't require selectedProfile
    }
}
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `ObservableObject` + `@Published` | `@Observable` macro | iOS 17 / macOS 14 (2023) | Already adopted project-wide. Property-level granularity, no `objectWillChange` boilerplate. |
| `Combine.throttle/debounce` | `AsyncAlgorithms.throttle/debounce` | Swift 5.9+ | Only needed if throttling required (this phase: no). |
| Manual `NSCollectionView` for 10k rows | SwiftUI `List` with `id:` | iOS 16 / macOS 13 | List now wraps UICollectionView with cell recycling — recommended approach |
| Strings everywhere | Codable enums | Swift 5+ | Use `TranscodeMode` enum, not raw strings, in Swift API (DB stores rawValue) |

**Deprecated/outdated:**

- **`NSWorkspace.recycleURLs(_:completionHandler:)`** is technically still supported but has been superseded by `FileManager.trashItem` for most use cases. Both work; `trashItem` is preferred for synchronous code paths. `[CITED: christiantietze.de — trashItem uses NSFileCoordinator internally]`

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Phase 37's "toolbar indicator" pattern does NOT yet exist in code | Toolbar Indicator Hosting | Low — verified by grep, see Open Questions #1 for confirmation request |
| A2 | `nyquist_validation` is enabled (config.json has no key, default enabled) | Validation Architecture | Low — verified config.json doesn't disable it |
| A3 | No existing toast component in macos-app/MLM/ | Standard Stack §Alternatives | Medium — researcher couldn't find one. Planner should verify before designing a new one. If existing toast pattern exists (e.g., in Phase 37 for Rockbox-erkannt scenario already designed), reuse it. |
| A4 | `SyncService` is not `@MainActor` (only `@Observable`) | Anti-Patterns | Verified — line 8-9 |
| A5 | Existing `SyncRepository.updateSettings` does not take toggle params | Code Examples §Example 2 | Verified — line 154-181, only takes name/outputFolder/playlistPathPrefix |
| A6 | `linkItem` throws on FAT32 destination consistently | Hardlink Cross-FS Verification | Medium — based on POSIX semantics; not measured against real iPod. Test will confirm. |
| A7 | DependencyContainer does NOT currently expose `syncService` (only `syncViewModel`) | Toolbar Indicator Hosting | Verified — line 49, 163-170 |
| A8 | M3U8 generation in `SyncService.generatePlaylists` line 218 is unconditional today | Pitfall #1 | Verified |
| A9 | Migration `v6` slot is already taken by `v6_app_config` | Migration Design | Verified — line 355 |
| A10 | "Toast" UI primitive: not in codebase | Phase Requirements SYNC-v2-22 | Medium — see A3 |

**Assumed claims that need user confirmation:**

- **A3, A10** — researcher could not locate any existing toast UI component. If Phase 37 introduces one for the artwork-pop-in scenario, it should be reused. **Discuss-phase recommendation:** confirm "Toast" component status before Wave B starts.

---

## Open Questions

1. **Toolbar Indicator: Phase 37 had no real toolbar pattern. What surface should Phase 38 use?**
   - What we know: `ContentView.toolbar` has only the PlayerBar in `.principal`. `.primaryAction` slot is free.
   - What's unclear: Whether the user wants a dedicated `ToolbarItem` slot or a small overlay on the sidebar's `Sync` row. CONTEXT.md says "Toolbar-Indicator-Hosting … Fallback: nur in SyncView selbst sichtbar" is acceptable.
   - Recommendation: **Primary** = `ToolbarItem(.primaryAction)` showing only while `isRunning`. **Fallback** = sidebar `Sync` row gets a `progressView()` badge. Implement both is cheap.

2. **Toast UI for D-03 "Rockbox iPod erkannt"**
   - What we know: No `Toast.swift` or `Banner.swift` found in `macos-app/MLM/Views/`.
   - What's unclear: Whether Phase 37 introduced one (researcher only read 37-CONTEXT.md, not implementation).
   - Recommendation: **Discuss-phase confirms.** If none exists, Phase 38 introduces a minimal one (60-line SwiftUI `.overlay` with auto-dismiss `Task.sleep(3s)`).

3. **Migration-time backfill for existing profiles on `.rockbox` volumes**
   - What we know: Migration defaults `generate_m3u8 = 0` for existing rows.
   - What's unclear: Whether to auto-set `=1` for profiles whose `output_folder` currently lives on a `.rockbox` volume (one-time backfill).
   - Recommendation: **Don't auto-backfill.** The output_folder may not be currently mounted at migration time. Better UX: show a one-time banner the first time the user opens a `.rockbox`-located profile after upgrade, asking "Enable Rockbox defaults?".

4. **Cancel-button-while-not-running edge cases**
   - What we know: Cancel button is disabled when `!isRunning` (D-12).
   - What's unclear: What if `cancelSync()` is called twice in rapid succession?
   - Recommendation: Idempotent — second call is a no-op (flag is already true).

5. **`createProfileSheet`: where does Smart-detect store the "device defaults active" decision?**
   - What we know: Detect-dropdown sets defaults at create time.
   - What's unclear: If user picks a `.rockbox` device but then manually toggles `generate_m3u8 = off` *before* clicking Create, the smart-defaults state needs to be local to the sheet.
   - Recommendation: Sheet holds `@State private var deviceDefaultsApplied: Bool` and renders the toggles inline — user-edited values take precedence over smart-defaults.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| ffmpeg | TranscodeService (aac_248 / aac_320 modes only) | ✓ (Phase 37 already requires) | n/a | Skip transcode, fail clearly. Already handled. |
| macOS APFS / HFS+ | Hardlink cache (internal cache dir) | ✓ | system | none — required |
| macOS FAT32/exFAT mount | Rockbox iPod outputFolder | conditional on user device | n/a | Copy-fallback in `linkToProfile` already handles |
| SwiftUI on macOS 14+ | All UI | ✓ | per project min-deployment | none |
| GRDB.swift | DB | ✓ | already pinned | none |
| Rockbox-flashed iPod device | UAT only | depends on user | n/a | Fake `.rockbox` folder under `/Volumes/test-rockbox/` works for unit tests |

**Missing dependencies with no fallback:** None.

**Missing dependencies with fallback:** Rockbox device — UAT requires the user's actual iPod (or a fake `.rockbox` directory created by tests).

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Swift Testing (`import Testing`) — newer pattern used by Phase 37 tests |
| Config file | none — built into Xcode test target `MLMTests` |
| Quick run command | `xcodebuild test -scheme MLM -only-testing:MLMTests/SyncServiceTests` (per-test-class) |
| Full suite command | `xcodebuild test -scheme MLM -destination 'platform=macOS'` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SYNC-v2-01 | Migration adds 4 columns idempotently | unit | `xcodebuild test -only-testing:MLMTests/DatabaseTests/SyncTogglesMigrationTests` | ❌ Wave 0 |
| SYNC-v2-02 | SyncProfile Codable round-trips all 4 toggles | unit | `xcodebuild test -only-testing:MLMTests/DatabaseTests/SyncProfileCodableTests` | ❌ Wave 0 |
| SYNC-v2-03 | DeviceDetector spots `.rockbox` directory in temp /Volumes-substitute | unit | `xcodebuild test -only-testing:MLMTests/ServiceTests/DeviceDetectorTests` | ❌ Wave 0 |
| SYNC-v2-04 | Settings form toggles commit → updateProfileSettings called | view | `xcodebuild test -only-testing:MLMTests/ViewTests/SyncSettingsFormTests` | ❌ Wave 0 |
| SYNC-v2-05 | cleanup_removed_files=true → trashItem succeeds; =false → file remains | integration | `xcodebuild test -only-testing:MLMTests/ServiceTests/SyncCleanupTests` | ❌ Wave 0 |
| SYNC-v2-06 | PlaylistPickerSheet filters via query | view | `xcodebuild test -only-testing:MLMTests/ViewTests/PlaylistPickerTests` | ❌ Wave 0 |
| SYNC-v2-07 | TrackPickerSheet handles 10k tracks (performance smoke) | manual-only | n/a — perf test outside CI | n/a |
| SYNC-v2-08 | PlaylistCard "Sync to ▸" submenu lists profiles | view | snapshot | ❌ Wave 0 |
| SYNC-v2-09 | TrackContextMenu Sync-to action commits via SyncViewModel | view | `xcodebuild test -only-testing:MLMTests/ViewTests/TrackContextMenuSyncToTests` | ❌ Wave 0 |
| SYNC-v2-10 | Profile-Detail removes track from sync_profile_tracks | unit (VM) | `xcodebuild test -only-testing:MLMTests/ViewModelTests/SyncViewModelMutationTests` | ❌ Wave 0 |
| SYNC-v2-11 | addPlaylists/removeTracks/etc. post .syncProfileDidChange | unit | `xcodebuild test -only-testing:MLMTests/ViewModelTests/SyncViewModelNotificationTests` | ❌ Wave 0 |
| SYNC-v2-12 | Notifications.swift declares .syncProfileDidChange | compile-only | `xcodebuild build -scheme MLM` | n/a — covered by build |
| SYNC-v2-13 | DeviceDetector dropdown shows detected devices | view | snapshot or runtime | ❌ Wave 0 |
| SYNC-v2-14 | Empty-state shows "Keine Geräte gefunden" disabled item | view | snapshot | ❌ Wave 0 |
| SYNC-v2-15 | Toolbar indicator appears when isRunning=true | view | snapshot or runtime | ❌ Wave 0 |
| SYNC-v2-16 | Progress-Section binds to currentFile/processed/total | view | runtime + Combine-trace style | ❌ Wave 0 |
| SYNC-v2-17 | Failed-tracks DisclosureGroup retry button calls executeSync on single track | view | runtime | ❌ Wave 0 |
| SYNC-v2-18 | cancelSync sets flag, executeSync exits between files | unit (service) | `xcodebuild test -only-testing:MLMTests/ServiceTests/SyncServiceCancelTests` | ❌ Wave 0 |
| SYNC-v2-19 | transcode_mode=keep_originals bypasses TranscodeService | integration | `xcodebuild test -only-testing:MLMTests/ServiceTests/SyncTranscodeModeTests` | ❌ Wave 0 |
| SYNC-v2-20 | generate_m3u8=false skips generatePlaylists | unit | `xcodebuild test -only-testing:MLMTests/ServiceTests/SyncM3U8GateTests` | ❌ Wave 0 |
| SYNC-v2-21 | TranscodeCache.linkToProfile falls back to copy on EXDEV | integration | `xcodebuild test -only-testing:MLMTests/ServiceTests/TranscodeCacheFallbackTests` | ❌ Wave 0 (extend existing TranscodeServiceTests) |
| SYNC-v2-22 | Toast appears + auto-dismisses for Rockbox-detected | manual-only | UAT | n/a |

### Sampling Rate

- **Per task commit:** `xcodebuild test -scheme MLM -only-testing:<single test class>` — typically <5s per class
- **Per wave merge:** `xcodebuild test -scheme MLM -only-testing:MLMTests/ServiceTests/SyncServiceCancelTests -only-testing:MLMTests/DatabaseTests/SyncTogglesMigrationTests` (or full suite)
- **Phase gate:** `xcodebuild test -scheme MLM -destination 'platform=macOS'` (full suite green) + manual UAT script

### Wave 0 Gaps

- [ ] `macos-app/MLMTests/DatabaseTests/SyncTogglesMigrationTests.swift` — covers SYNC-v2-01
- [ ] `macos-app/MLMTests/DatabaseTests/SyncProfileCodableTests.swift` — covers SYNC-v2-02
- [ ] `macos-app/MLMTests/ServiceTests/DeviceDetectorTests.swift` — covers SYNC-v2-03 (no test currently)
- [ ] `macos-app/MLMTests/ServiceTests/SyncServiceCancelTests.swift` — covers SYNC-v2-18, cancellation semantics
- [ ] `macos-app/MLMTests/ServiceTests/SyncCleanupTests.swift` — covers SYNC-v2-05, trash + remove fallback
- [ ] `macos-app/MLMTests/ServiceTests/SyncTranscodeModeTests.swift` — covers SYNC-v2-19
- [ ] `macos-app/MLMTests/ServiceTests/SyncM3U8GateTests.swift` — covers SYNC-v2-20
- [ ] `macos-app/MLMTests/ServiceTests/TranscodeCacheFallbackTests.swift` — covers SYNC-v2-21 (extends existing TranscodeServiceTests)
- [ ] `macos-app/MLMTests/ViewModelTests/SyncViewModelMutationTests.swift` — covers SYNC-v2-10, addPlaylists/removeTracks
- [ ] `macos-app/MLMTests/ViewModelTests/SyncViewModelNotificationTests.swift` — covers SYNC-v2-11
- [ ] `macos-app/MLMTests/ViewTests/SyncSettingsFormTests.swift` — covers SYNC-v2-04
- [ ] `macos-app/MLMTests/ViewTests/PlaylistPickerTests.swift` — covers SYNC-v2-06
- [ ] `macos-app/MLMTests/ViewTests/TrackContextMenuSyncToTests.swift` — covers SYNC-v2-09

**Manual UAT script (Phase 38 verification scenario):**

1. Plug in Rockbox-flashed iPod (or create `/Volumes/test-ipod/.rockbox/` for dry-run)
2. Open MLM macOS app → Sync tab
3. Click `+` → Browse → select iPod root
4. **Expected:** Toast "Rockbox iPod erkannt — Device-Defaults aktiviert"; settings show `generate_m3u8=on`, `transcode_mode=aac_248`, `fat32_safe_paths=on`, `cleanup_removed_files=on`
5. Switch to Playlists tab → right-click a 20-track playlist → "Sync to ▸ My iPod"
6. Switch back to Sync tab → profile-detail shows "Playlists (1)", "Tracks (0)" with the added playlist
7. Click "Sync Now" → toolbar indicator appears across all routes; Progress-Section shows ProgressView + "Artist — Title"
8. Navigate to Library tab — indicator still visible. Click indicator — jumps back to Sync.
9. Sync completes → Result-Section shows "20 synced, 0 failed"
10. Open iPod in Finder — verify `My-Playlist.m3u8` exists at root + 20 .m4a files in `Artist/Album/` hierarchy
11. Eject + connect iPod to Rockbox device — verify playlist plays

---

## Sources

### Primary (HIGH confidence)

- **Codebase grep** (verified):
  - `macos-app/MLM/Services/Sync/{SyncService,TranscodeCache,DeviceDetector}.swift` — service layer
  - `macos-app/MLM/Database/{DatabaseManager,SyncRepository}.swift` — schema + repo
  - `macos-app/MLM/Models/SyncProfile.swift` — GRDB record
  - `macos-app/MLM/ViewModels/SyncViewModel.swift` — VM
  - `macos-app/MLM/Views/Sync/SyncView.swift` — UI surface
  - `macos-app/MLM/App/DependencyContainer.swift` — DI wiring
  - `macos-app/MLM/Views/ContentView/ContentView.swift` — toolbar host
  - `macos-app/MLM/Views/Library/TrackContextMenu.swift` — context menu pattern
  - `macos-app/MLM/Utilities/Notifications.swift` — notification name registry
  - `macos-app/MLM/Services/Import/PathSanitizer.swift` — FAT32 sanitization
  - `macos-app/MLM/Services/Artwork/ArtworkBackfillService.swift` — Phase 37 pattern (for D-11 analog confirmation)
- **Apple developer docs**:
  - https://developer.apple.com/documentation/foundation/filemanager/1414456-linkitem (hardlink)
  - https://developer.apple.com/documentation/foundation/filemanager/1414306-trashitem (recoverable delete)
  - https://developer.apple.com/documentation/appkit/nsworkspace/1530465-recycleurls (Finder-style trash)
  - https://developer.apple.com/forums/thread/735510 (Debounce/Throttle with @Observable)
- **CONTEXT.md** (this phase) — D-01 through D-19 locked decisions

### Secondary (MEDIUM confidence)

- https://fatbobman.com/en/posts/list-or-lazyvstack/ — List vs LazyVStack performance, cell recycling
- https://blog.stackademic.com/swiftui-list-performance-smooth-scrolling-for-10-000-items — 10k row scrolling
- https://christiantietze.de/posts/2023/02/psa-filemanager-trashitem-uses-nsfilecoordinator-under-the-hood-automatically/ — trashItem internals
- https://github.com/element-hq/element-desktop/issues/2550 — EXDEV cross-FS hardlink failure
- https://github.com/rclone/rclone/issues/4980 — FUSE/network hardlink failure mode

### Tertiary (LOW confidence)

- https://eclecticlight.co/2019/01/05/aliases-hard-links-symlinks-and-copies-in-mojaves-apfs/ — APFS hardlink behavior context
- `src-tauri/src/sync/playlist_gen.rs` (v1.0 Tauri pendant) — reference for M3U8 wire format (already mirrored by SyncService.generatePlaylists; cross-checked OK)

---

## Metadata

**Confidence breakdown:**

- **Standard stack:** HIGH — Apple-shipped APIs, project-pinned versions, established patterns
- **Architecture:** HIGH — diagram derived from existing code; only additions are clearly scoped
- **Migration design:** HIGH — `v_sync_toggles` name confirmed unused, idempotent ALTER pattern verified against existing migrations
- **Notification pattern:** HIGH — direct extension of established `.libraryDidImport`/`.playlistDidChange` pattern
- **Toolbar indicator:** MEDIUM — `ContentView.toolbar` slot identified, but the "Phase 37 analog" referenced in CONTEXT.md doesn't actually exist in code. Open Question #1 flags this.
- **Cancellation:** HIGH — D-14 locked, implementation pattern verified against Swift Concurrency mechanics
- **Picker UX at scale:** MEDIUM — `List` recommended via multiple sources but project has no existing 10k-row picker to benchmark against. Performance assumed OK; will measure if planner reports lag.
- **Disk-deletion safety:** HIGH — verified API behavior of `trashItem` vs `removeItem` via Apple docs
- **Hardlink cross-FS:** HIGH — POSIX semantics + existing try/catch pattern; test coverage gap identified
- **PathSanitizer:** HIGH — verified line-by-line against FAT32 spec
- **ProgressBar throttling:** HIGH — SwiftUI frame coalescing handles real-world rates; no throttle needed pre-emptively
- **Toast UI primitive:** LOW — researcher could not find an existing one (Assumption A3). Discuss-phase should confirm.
- **Test framework:** HIGH — Swift Testing already used in Phase 37 tests; pattern reusable

**Research date:** 2026-05-17
**Valid until:** 2026-06-17 (30 days — stable Apple APIs, no fast-moving libraries involved)
