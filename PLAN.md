# MLM macOS — Native SwiftUI Rewrite Plan

> **Goal:** Rewrite the Music Library Manager as a native macOS app using SwiftUI.
> Same features, same user flows, same logic — native macOS experience.
> Lives alongside the existing Tauri app under `macos-app/`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Project Structure](#2-project-structure)
3. [Technology Stack](#3-technology-stack)
4. [Phase Plan](#4-phase-plan)
5. [Data Layer](#5-data-layer)
6. [UI Architecture](#6-ui-architecture)
7. [Feature Parity Matrix](#7-feature-parity-matrix)
8. [External Tool Integration](#8-external-tool-integration)
9. [Design System Translation](#9-design-system-translation)
10. [Migration Notes](#10-migration-notes)

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────┐
│                    SwiftUI Views                     │
│  Sidebar │ LibraryTable │ DetailPanels │ ActivityBar │
├─────────────────────────────────────────────────────┤
│                   ViewModels                         │
│  LibraryVM │ PlaylistVM │ SyncVM │ SourcesVM │ ...  │
├─────────────────────────────────────────────────────┤
│                    Services                          │
│  DownloadService │ SyncService │ ImportService │ ... │
├─────────────────────────────────────────────────────┤
│                   Core Layer                         │
│  Database (GRDB/SQLite) │ Auth │ Config │ Models     │
├─────────────────────────────────────────────────────┤
│              External Processes                       │
│  ffmpeg │ yt-dlp │ scdl │ fpcalc │ MusicKit          │
└─────────────────────────────────────────────────────┘
```

**Pattern:** MVVM with dependency injection via `@Environment`.

- **Models** — Pure structs, `Codable`, mirror the existing SQLite schema
- **ViewModels** — `@Observable` classes owning business logic and state
- **Services** — Stateless or singleton services for I/O, networking, processes
- **Views** — Declarative SwiftUI, thin, delegate to ViewModels

---

## 2. Project Structure

```
macos-app/
├── MLM.xcodeproj/                    # Xcode project
├── MLM/
│   ├── App/
│   │   ├── MLMApp.swift              # @main, WindowGroup, scene setup
│   │   ├── AppDelegate.swift         # NSApplicationDelegate for lifecycle
│   │   └── DependencyContainer.swift # Service registration
│   │
│   ├── Models/
│   │   ├── Track.swift               # Track + TrackMetadata
│   │   ├── Playlist.swift            # Playlist + PlaylistTrack
│   │   ├── SyncProfile.swift         # SyncProfile + FilterRule
│   │   ├── Album.swift               # Album + variant model
│   │   ├── Source.swift              # SourceType enum + Source model
│   │   ├── DownloadItem.swift        # Download queue item
│   │   ├── ReviewItem.swift          # Duplicate review queue
│   │   └── AppConfig.swift           # Config key-value wrapper
│   │
│   ├── Database/
│   │   ├── DatabaseManager.swift     # GRDB connection pool, migrations
│   │   ├── Schema.swift              # Table definitions (v0–v17)
│   │   ├── Migrations/
│   │   │   └── AllMigrations.swift   # Sequential migration registry
│   │   ├── TrackRepository.swift     # Track CRUD + search + filtering
│   │   ├── PlaylistRepository.swift  # Playlist CRUD + track ordering
│   │   ├── SyncRepository.swift      # Sync profiles, state, rules
│   │   ├── AlbumRepository.swift     # Albums, variants, siblings
│   │   ├── SourceRepository.swift    # Sources, track_sources
│   │   ├── AnalysisRepository.swift  # Fingerprints, replaygain, artwork
│   │   └── ConfigRepository.swift    # App config key-value store
│   │
│   ├── Services/
│   │   ├── Import/
│   │   │   ├── ImportService.swift         # Directory scanning + batch import
│   │   │   ├── MetadataExtractor.swift     # Audio tag reading (AVFoundation / TagLib)
│   │   │   ├── PathSanitizer.swift         # FAT32-safe organized path generation
│   │   │   └── PlaylistImportService.swift # M3U + Spotify JSON import
│   │   │
│   │   ├── Download/
│   │   │   ├── DownloadOrchestrator.swift  # DAB → SoundCloud → YouTube chain
│   │   │   ├── DABClient.swift             # DAB Music API client
│   │   │   ├── SoundCloudDownloader.swift  # scdl CLI wrapper
│   │   │   ├── YouTubeDownloader.swift     # yt-dlp CLI wrapper
│   │   │   └── DownloadQueue.swift         # Persistent queue with retry
│   │   │
│   │   ├── Sources/
│   │   │   ├── SpotifyClient.swift         # OAuth PKCE + Web API
│   │   │   ├── SoundCloudClient.swift      # OAuth PKCE + V1 API
│   │   │   ├── AppleMusicClient.swift      # MusicKit framework integration
│   │   │   └── SourceSyncService.swift     # Incremental sync orchestration
│   │   │
│   │   ├── Sync/
│   │   │   ├── SyncService.swift           # Profile-based device sync
│   │   │   ├── TranscodeCache.swift        # Shared AAC transcode cache
│   │   │   ├── DeviceDetector.swift        # Rockbox + volume mount detection
│   │   │   └── M3U8Generator.swift         # Playlist file generation
│   │   │
│   │   ├── Audio/
│   │   │   ├── AudioPlayer.swift           # AVAudioPlayer / AVAudioEngine
│   │   │   ├── TranscodeService.swift      # ffmpeg CLI wrapper
│   │   │   └── WaveformGenerator.swift     # Waveform data extraction
│   │   │
│   │   ├── Analysis/
│   │   │   ├── FingerprintService.swift    # fpcalc CLI + AcoustID API
│   │   │   ├── ReplayGainAnalyzer.swift    # EBU R128 via ffmpeg/AVAudioEngine
│   │   │   ├── EnergyBucketer.swift        # LUFS → 1-5 energy scale
│   │   │   └── ArtworkService.swift        # MusicBrainz + embedded art
│   │   │
│   │   ├── Auth/
│   │   │   ├── OAuthManager.swift          # PKCE flow with ASWebAuthenticationSession
│   │   │   ├── TokenStorage.swift          # Keychain-based token storage
│   │   │   └── TokenRefresh.swift          # Background token refresh
│   │   │
│   │   ├── Search/
│   │   │   └── SearchService.swift         # FTS5 full-text search
│   │   │
│   │   └── Mount/
│   │       └── MountObserver.swift         # DiskArbitration volume monitoring
│   │
│   ├── ViewModels/
│   │   ├── LibraryViewModel.swift          # Track list, filtering, search, batch ops
│   │   ├── PlaylistViewModel.swift         # Playlist CRUD, drag-drop ordering
│   │   ├── PlaylistDetailViewModel.swift   # Single playlist track management
│   │   ├── AlbumDetailViewModel.swift      # Album + variant toggle logic
│   │   ├── SyncViewModel.swift             # Sync profiles, preview, execute
│   │   ├── SourcesViewModel.swift          # Connect/disconnect/sync sources
│   │   ├── DownloadViewModel.swift         # Download queue progress
│   │   ├── SettingsViewModel.swift         # Config + maintenance commands
│   │   ├── FolderViewModel.swift           # Folder tree browsing
│   │   ├── PlaybackViewModel.swift         # Now playing state, play/pause/seek
│   │   ├── ReviewQueueViewModel.swift      # Duplicate review management
│   │   └── ActivityViewModel.swift         # Activity panel operations + logs
│   │
│   ├── Views/
│   │   ├── ContentView.swift               # NavigationSplitView root
│   │   ├── Sidebar/
│   │   │   └── SidebarView.swift           # 5 nav items + Settings
│   │   │
│   │   ├── Library/
│   │   │   ├── LibraryView.swift           # Local/Remote tab container
│   │   │   ├── LibraryTable.swift          # NSTableView-backed track table
│   │   │   ├── FilterBar.swift             # Search field + action buttons
│   │   │   ├── BatchBar.swift              # Enhancement progress indicator
│   │   │   ├── EnergyBars.swift            # 5-bar energy visualization
│   │   │   └── TrackContextMenu.swift      # Right-click context menu
│   │   │
│   │   ├── TrackDetail/
│   │   │   ├── TrackDetailView.swift       # Track metadata display
│   │   │   ├── MetadataPanel.swift         # Metadata sections
│   │   │   └── WaveformView.swift          # Waveform rendering
│   │   │
│   │   ├── Albums/
│   │   │   ├── AlbumDetailView.swift       # Album hero + tracklist
│   │   │   ├── AlbumHero.swift             # Cover art + metadata header
│   │   │   ├── AlbumTracklist.swift        # Track rows with variant switching
│   │   │   └── UfoToggle.swift             # Animated variant pill toggle
│   │   │
│   │   ├── Playlists/
│   │   │   ├── PlaylistsView.swift         # Playlist grid
│   │   │   ├── PlaylistCard.swift          # Single playlist card
│   │   │   └── PlaylistDetailView.swift    # Drag-and-drop tracklist
│   │   │
│   │   ├── Folders/
│   │   │   ├── FoldersView.swift           # Split: tree + tracks
│   │   │   └── FolderTreeView.swift        # OutlineGroup tree
│   │   │
│   │   ├── Sync/
│   │   │   ├── SyncView.swift              # Profile grid
│   │   │   ├── SyncProfileCard.swift       # Profile card
│   │   │   ├── SyncPreviewView.swift       # Preview diff + execute
│   │   │   └── FilterRuleEditor.swift      # Rule builder UI
│   │   │
│   │   ├── Sources/
│   │   │   ├── SourcesView.swift           # Source cards grid
│   │   │   └── SourceCard.swift            # Connect/sync per source
│   │   │
│   │   ├── Settings/
│   │   │   ├── SettingsView.swift          # Settings form
│   │   │   ├── LibrarySetupView.swift      # Root path + scan folders
│   │   │   └── MaintenanceView.swift       # Maintenance actions
│   │   │
│   │   ├── Activity/
│   │   │   ├── ActivityPanel.swift         # Collapsible bottom panel
│   │   │   ├── OperationsTab.swift         # Download/sync activity list
│   │   │   └── LogsTab.swift              # Real-time log stream
│   │   │
│   │   ├── MiniPlayer/
│   │   │   └── MiniPlayerView.swift        # Now playing bar
│   │   │
│   │   ├── Shared/
│   │   │   ├── StatusDot.swift             # Pulsing status indicator
│   │   │   ├── ProgressBar.swift           # Styled progress bar
│   │   │   └── FirstRunWizard.swift        # Onboarding wizard
│   │   │
│   │   └── ReviewQueue/
│   │       └── ReviewQueueView.swift       # Duplicate resolution UI
│   │
│   ├── Theme/
│   │   ├── Colors.swift                    # Color tokens (Solar, Midnight, etc.)
│   │   ├── Typography.swift               # Font definitions
│   │   └── Spacing.swift                  # Layout constants
│   │
│   ├── Utilities/
│   │   ├── ProcessRunner.swift             # CLI process execution helper
│   │   ├── FileHelpers.swift              # Path utilities
│   │   └── Debouncer.swift                # Search debounce utility
│   │
│   └── Resources/
│       ├── Assets.xcassets/               # App icons, color sets
│       └── MLM.entitlements               # Sandbox entitlements
│
├── MLMTests/
│   ├── DatabaseTests/
│   ├── ServiceTests/
│   └── ViewModelTests/
│
├── PLAN.md                                # This file
└── README.md                              # macOS-specific README
```

---

## 3. Technology Stack

| Layer | Technology | Rationale |
|---|---|---|
| **UI** | SwiftUI (macOS 14+) | Native macOS, declarative, `@Observable` macro |
| **Navigation** | `NavigationSplitView` | 3-column layout matching current Sidebar + Content + Detail |
| **Table** | `Table` (SwiftUI) + `NSViewRepresentable` fallback | Sortable columns, virtualized. NSTableView if perf needed |
| **Database** | [GRDB.swift](https://github.com/groue/GRDB.swift) | Best Swift SQLite lib, migration support, `Codable` mapping |
| **Networking** | URLSession + async/await | Native, no deps needed |
| **Auth (OAuth)** | `ASWebAuthenticationSession` | System OAuth browser, PKCE built-in |
| **Auth (Apple Music)** | MusicKit framework | Native macOS MusicKit, no webview scraping needed |
| **Audio Playback** | AVAudioEngine | Low-latency, ReplayGain gain adjustment, waveform |
| **Audio Tags** | [SwiftTagLib](https://github.com/nicktrienensfuzz/SwiftTagLib) or AVAsset | Read/write ID3, Vorbis, MP4 tags |
| **Waveform** | Custom `Canvas` / Core Graphics | Render waveform from audio samples |
| **File Monitoring** | `DispatchSource.makeFileSystemObjectSource` | Watch library folder changes |
| **Volume Detection** | DiskArbitration framework | Mount/unmount events |
| **Process Execution** | `Process` (Foundation) | Run ffmpeg, yt-dlp, scdl, fpcalc |
| **Keychain** | Security framework | Token storage (replaces file-based) |
| **Testing** | XCTest + Swift Testing | Unit + integration |
| **Package Manager** | Swift Package Manager | Dependencies |
| **Min Deployment** | macOS 14 (Sonoma) | `@Observable`, modern SwiftUI Table |

---

## 4. Phase Plan

### Phase 0 — Project Scaffold (Week 1)
- [ ] Create Xcode project with SwiftUI lifecycle
- [ ] Set up SPM dependencies (GRDB, SwiftTagLib)
- [ ] Configure entitlements (network, files, Keychain)
- [ ] Create `DependencyContainer` with protocol-based DI
- [ ] Set up base color theme (`Colors.swift`, dark-first)
- [ ] Implement `DatabaseManager` with GRDB connection pool
- [ ] Port all 17 migrations from Tauri schema
- [ ] **UAT:** App launches, database creates all tables

### Phase 1 — Core Data Layer (Week 1–2)
- [ ] Port all models: `Track`, `Playlist`, `SyncProfile`, `Album`, `Source`
- [ ] Implement repositories: `TrackRepository`, `PlaylistRepository`, `SyncRepository`
- [ ] Implement `ConfigRepository` for app_config key-value store
- [ ] Implement `SearchService` with FTS5
- [ ] Write unit tests for all repositories
- [ ] **UAT:** Can CRUD tracks, playlists, sync profiles via tests

### Phase 2 — Shell & Navigation (Week 2)
- [ ] Implement `ContentView` with `NavigationSplitView` (sidebar + detail)
- [ ] Implement `SidebarView` with 5 nav items + keyboard shortcuts (⌘1–5)
- [ ] Implement `MiniPlayerView` (empty state initially)
- [ ] Implement `ActivityPanel` (collapsed/expanded toggle)
- [ ] Wire up navigation state management
- [ ] **UAT:** Can navigate between all 5 sections, mini player visible, activity panel toggles

### Phase 3 — Library Browser (Week 2–3)
- [ ] Implement `LibraryTable` with SwiftUI `Table` — all columns: title, artist, album, format, bitrate, duration, genre, year, energy, date_added
- [ ] Implement column sorting (click header)
- [ ] Implement `FilterBar` with search (⌘F) + debounce
- [ ] Implement Local/Remote tab switching
- [ ] Implement `EnergyBars` column renderer
- [ ] Implement right-click `TrackContextMenu`
- [ ] Implement multi-select
- [ ] **UAT:** Table shows tracks, search works, sorting works, context menu appears, tabs switch

### Phase 4 — Import & Metadata (Week 3)
- [ ] Implement `MetadataExtractor` (read audio tags via SwiftTagLib / AVAsset)
- [ ] Implement `PathSanitizer` (FAT32-safe organized paths: `Artist/Album/Track.ext`)
- [ ] Implement `ImportService` (recursive directory scan, batch import)
- [ ] Implement first-run wizard (`FirstRunWizard`) — library root selection
- [ ] Implement `LibrarySetupView` in Settings
- [ ] **UAT:** Can pick folder, scan finds audio files, tracks appear in library table

### Phase 5 — Track Detail & Playback (Week 3–4)
- [ ] Implement `TrackDetailView` with metadata panel
- [ ] Implement `WaveformView` (render from AVAudioFile samples via Canvas)
- [ ] Implement `AudioPlayer` with AVAudioEngine
- [ ] Implement `PlaybackViewModel` (play, pause, seek, position tracking)
- [ ] Wire MiniPlayer to playback state
- [ ] Implement LUFS gain compensation
- [ ] Implement spacebar play/pause (global ⌘ shortcut)
- [ ] **UAT:** Click track → detail view, waveform renders, play/pause works, mini player updates

### Phase 6 — Playlists (Week 4)
- [ ] Implement `PlaylistsView` grid of playlist cards
- [ ] Implement `PlaylistDetailView` with sortable track list
- [ ] Implement drag-and-drop reorder with fractional positioning
- [ ] Implement create / delete / pin playlist
- [ ] Implement add/remove tracks from playlist (via context menu integration)
- [ ] Implement playlist import (M3U, Spotify JSON)
- [ ] **UAT:** Create playlist, add tracks, reorder, delete, import M3U

### Phase 7 — Folder Browser (Week 4–5)
- [ ] Implement `FolderTreeView` with `OutlineGroup` / `List` + `DisclosureGroup`
- [ ] Implement lazy child loading
- [ ] Implement split pane: tree (left) + tracks in selected folder (right)
- [ ] Implement folder context menu (reveal in Finder)
- [ ] **UAT:** Tree loads, expanding reveals children, selecting folder shows tracks

### Phase 8 — Source Integration: Spotify (Week 5)
- [ ] Implement `SpotifyClient` with OAuth 2.0 PKCE via `ASWebAuthenticationSession`
- [ ] Implement `TokenStorage` (Keychain)
- [ ] Implement liked songs sync (incremental via `last_sync_timestamps`)
- [ ] Implement playlist sync
- [ ] Implement connect/disconnect UI in `SourceCard`
- [ ] Implement rate limit handling (429 backoff)
- [ ] **UAT:** Connect Spotify, sync liked songs, tracks appear in Remote tab

### Phase 9 — Source Integration: SoundCloud (Week 5–6)
- [ ] Implement `SoundCloudClient` with OAuth 2.1 PKCE
- [ ] Implement liked tracks sync
- [ ] Implement playlist sync
- [ ] Implement `SourceCard` for SoundCloud
- [ ] **UAT:** Connect SoundCloud, sync liked tracks, tracks appear in Remote tab

### Phase 10 — Source Integration: Apple Music (Week 6)
- [ ] Implement `AppleMusicClient` using MusicKit framework (native, no webview scraping)
- [ ] Request MusicKit entitlement
- [ ] Implement library songs sync
- [ ] Implement playlist sync
- [ ] Implement `SourceCard` for Apple Music
- [ ] **UAT:** Authorize Apple Music, sync library, tracks appear in Remote tab

### Phase 11 — Download Pipeline (Week 6–7)
- [ ] Implement `DABClient` (HTTP API, FLAC download)
- [ ] Implement `SoundCloudDownloader` (scdl CLI wrapper via `Process`)
- [ ] Implement `YouTubeDownloader` (yt-dlp CLI wrapper via `Process`)
- [ ] Implement `DownloadOrchestrator` (DAB → SoundCloud → YouTube fallback chain)
- [ ] Implement `TranscodeService` (ffmpeg CLI: FLAC → 248kbps AAC)
- [ ] Implement persistent `DownloadQueue` with retry
- [ ] Implement download progress events → `ActivityPanel`
- [ ] **UAT:** Download track from Remote, progress shows, file appears in library

### Phase 12 — Sync Profiles (Week 7–8)
- [ ] Implement `SyncService` — profile CRUD, content resolution
- [ ] Implement `TranscodeCache` — shared AAC cache with hardlinks
- [ ] Implement `FilterRuleEditor` — field/operator/value builder
- [ ] Implement `SyncPreviewView` — dry run showing add/remove/size
- [ ] Implement sync execution with progress
- [ ] Implement M3U8 playlist generation
- [ ] Implement `DeviceDetector` — Rockbox `.rockbox` directory detection
- [ ] Implement incremental sync with SHA256 checksums
- [ ] **UAT:** Create profile, add playlists + rules, preview, sync to folder, M3U8 generated

### Phase 13 — Analysis & Enhancements (Week 8)
- [ ] Implement `FingerprintService` (fpcalc CLI → Chromaprint)
- [ ] Implement AcoustID HTTP lookup
- [ ] Implement `ReplayGainAnalyzer` (EBU R128 via ffmpeg or AVAudioEngine)
- [ ] Implement `EnergyBucketer` (LUFS → 1-5 scale)
- [ ] Implement `ArtworkService` (MusicBrainz API + embedded art extraction)
- [ ] Implement batch processing with progress in `BatchBar`
- [ ] Implement cancel support for all batch operations
- [ ] **UAT:** Run fingerprint batch, ReplayGain analysis, energy buckets populated, artwork fetched

### Phase 14 — Duplicate Detection & Review (Week 8–9)
- [ ] Implement string normalization (parenthetical stripping, unicode folding)
- [ ] Implement fuzzy matcher (fingerprint-based + metadata-based)
- [ ] Implement `ReviewQueueView` — approve/dismiss duplicate pairs
- [ ] Implement deep scan (fingerprint comparison across library)
- [ ] **UAT:** Deep scan finds duplicates, review queue shows matches, can resolve

### Phase 15 — Albums & Variants (Week 9)
- [ ] Implement `AlbumRepository` — album detection, variant linking, sibling discovery
- [ ] Implement `AlbumDetailView` — hero + tracklist
- [ ] Implement `UfoToggle` — animated variant switching (Yeat-specific)
- [ ] Implement tag backfill from folder structure
- [ ] **UAT:** Navigate to album, see tracklist, toggle variant, animation works

### Phase 16 — Activity Panel & Notifications (Week 9)
- [ ] Implement `ActivityPanel` fully — Ops tab (live operations), Logs tab (log stream)
- [ ] Implement operation tracking across downloads, syncs, imports, analysis
- [ ] Implement collapsible summary bar (counts + pulsing indicator)
- [ ] Implement macOS native notifications for completed operations
- [ ] **UAT:** Activity panel shows live progress, logs stream, collapse/expand works

### Phase 17 — Settings & Maintenance (Week 9–10)
- [ ] Implement theme switching (Solar, Midnight, Solarized Dark, Solarized Light)
- [ ] Implement file manager preference (Finder, ForkLift 4, custom)
- [ ] Implement maintenance actions: rescan metadata, rescan albums, backfill tags
- [ ] Implement orphan detection + purge
- [ ] Implement reindex search
- [ ] **UAT:** All maintenance actions run, theme switching works, settings persist

### Phase 18 — Mount Detection & Resilience (Week 10)
- [ ] Implement `MountObserver` using DiskArbitration
- [ ] Implement library drive disconnect/reconnect handling
- [ ] Implement Sidebar disconnected indicator
- [ ] Implement playback pause on unmount
- [ ] Implement app-level error handling with alert presentation
- [ ] **UAT:** Eject drive → sidebar shows dot, playback pauses, reconnect → recovers

### Phase 19 — Polish & Platform Integration (Week 10–11)
- [ ] macOS menu bar integration (File, Edit, View, Library, Playback menus)
- [ ] Keyboard shortcuts: ⌘F (search), ⌘1-5 (nav), Space (play/pause), ⌘N (new playlist)
- [ ] Touch Bar support (if applicable)
- [ ] Drag-and-drop from Finder (import files by dragging onto window)
- [ ] Spotlight / file association for audio files
- [ ] Window state persistence (frame, sidebar width, panel state)
- [ ] Implement proper `NSDocument`-less persistence pattern
- [ ] **UAT:** All shortcuts work, menu bar functional, window state restored on relaunch

### Phase 20 — Testing & Performance (Week 11–12)
- [ ] Unit tests for all repositories (GRDB in-memory DB)
- [ ] Unit tests for all services (mock process runner)
- [ ] ViewModel tests with mock services
- [ ] Performance profiling with Instruments (large library: 10k+ tracks)
- [ ] Memory profiling (image caching, audio buffers)
- [ ] Table scrolling performance validation
- [ ] **UAT:** All tests pass, 10k track library scrolls smoothly, no memory leaks

---

## 5. Data Layer

### 5.1 Database (GRDB.swift)

GRDB maps directly to the existing SQLite schema. All 17 migration versions will be ported as GRDB `DatabaseMigrator` steps.

```swift
// Example: Track model
struct Track: Codable, FetchableRecord, PersistableRecord, Identifiable {
    var id: Int64?
    var artist: String
    var albumArtist: String?
    var album: String
    var title: String
    var genre: String?
    var year: Int?
    var bitrate: Int?
    var duration: Double?
    var format: String
    var originalPath: String
    var organizedPath: String?
    var isDuplicate: Bool
    var dateAdded: String?
    var lufsI: Double?
    var lufsRange: Double?
    var truePeak: Double?
    var energyBucket: Int?
    var albumId: Int64?

    static let databaseTableName = "tracks"
}
```

### 5.2 Schema Compatibility

The macOS app will use the **exact same SQLite database file** and schema as the Tauri app. This means:

- A user can switch between the Tauri app and the macOS app on the same library
- No data migration needed
- Schema versions must stay in sync

### 5.3 Repositories

Each repository encapsulates SQL for its domain:

| Repository | Tables | Key Operations |
|---|---|---|
| `TrackRepository` | tracks, track_sources, track_tags | CRUD, search, filter, bulk import |
| `PlaylistRepository` | playlists, playlist_tracks, playlist_tags | CRUD, reorder, smart playlists |
| `SyncRepository` | sync_profiles, sync_profile_tracks/playlists/rules, sync_state | CRUD, resolve content, checksums |
| `AlbumRepository` | albums, user_album_variant_pref | Detection, variants, siblings |
| `SourceRepository` | sources, track_sources, last_sync_timestamps | CRUD, sync timestamps |
| `AnalysisRepository` | fingerprints, artwork, replaygain, review_queue, track_analysis | CRUD, batch status |
| `ConfigRepository` | app_config | Get/set config values |

---

## 6. UI Architecture

### 6.1 Window Layout

```
┌──────────────────────────────────────────────────────────┐
│ ● ● ●    MLM — Music Library Manager                     │ ← Title bar
├────────┬─────────────────────────────────────────────────┤
│        │  [Local] [Remote]          🔍 Search   ⚙ Actions│ ← Filter bar
│ Library│─────────────────────────────────────────────────│
│ Playlist│ Title     │ Artist │ Album  │ Fmt │ Dur │ ⚡   │ ← Table headers
│ Folders│ Song A    │ Art X  │ Alb 1  │ m4a │ 3:24│ ▃▅▇▅▃│ ← Table rows
│ Sync   │ Song B    │ Art Y  │ Alb 2  │ flac│ 4:01│ ▃▅▅▃▁│
│ Sources│ Song C    │ Art Z  │ Alb 3  │ mp3 │ 2:58│ ▁▃▅▃▁│
│        │           │        │        │     │     │      │
│        │           │        │        │     │     │      │
│────────│           │        │        │     │     │      │
│⚙ Prefs│           │        │        │     │     │      │
├────────┴─────────────────────────────────────────────────┤
│ ▶ Song A — Artist X            ───●──── 1:42 / 3:24     │ ← MiniPlayer
├──────────────────────────────────────────────────────────┤
│ ▼ Activity: 3 ops · 1 downloading                        │ ← Activity bar
│   ↓ Downloading "Song D" ████████░░░░ 67% · 1.2 MB/s    │
│   ✓ Imported 42 tracks                                   │
└──────────────────────────────────────────────────────────┘
```

### 6.2 Navigation

```swift
// NavigationSplitView with programmatic selection
@Observable class NavigationState {
    var selectedSection: Section = .library
    var selectedTrackID: Int64?
    var selectedAlbumSlug: String?
    var selectedPlaylistID: Int64?

    enum Section: Hashable {
        case library
        case playlists
        case folders
        case sync
        case sources
        case settings
    }
}
```

### 6.3 Key SwiftUI Patterns

| Pattern | Usage |
|---|---|
| `@Observable` | All ViewModels (macOS 14+) |
| `@Environment` | Inject services and shared state |
| `NavigationSplitView` | Sidebar + content + optional detail |
| `Table` | Library track list with sortable columns |
| `OutlineGroup` | Folder tree view |
| `.contextMenu` | Right-click menus on track rows |
| `.onDrop` / `.draggable` | Playlist reorder, Finder import |
| `.searchable` | Toolbar search integration |
| `NSViewRepresentable` | Wrap NSTableView if SwiftUI Table perf insufficient |
| `.inspector` | Track detail side panel |
| `ToolbarItemGroup` | Action buttons in toolbar area |

---

## 7. Feature Parity Matrix

| Feature | Tauri (current) | macOS SwiftUI | Notes |
|---|---|---|---|
| Library table (virtual scroll) | TanStack Table + Virtual | SwiftUI `Table` / NSTableView | Native table is faster |
| Search | Rust FTS | GRDB FTS5 | Same SQLite FTS |
| Local/Remote tabs | React tabs | SwiftUI `Picker(.segmented)` | |
| Track detail + waveform | React + wavesurfer.js | SwiftUI + Canvas/CoreGraphics | |
| Playback | HTML5 `<audio>` | AVAudioEngine | Better: gain control, DSP |
| Playlists (drag-drop) | @hello-pangea/dnd | SwiftUI `.onMove` / `.draggable` | |
| Folder tree | react-arborist | `OutlineGroup` / `List` | |
| Spotify OAuth | Local callback server | `ASWebAuthenticationSession` | Simpler, system browser |
| SoundCloud OAuth | Local callback server | `ASWebAuthenticationSession` | |
| Apple Music | Webview scraping | MusicKit framework | Much better: native API |
| Downloads (CLI) | Rust `tokio::process` | Foundation `Process` | Same approach |
| Sync profiles | Rust + hardlinks | Swift + hardlinks | Same approach |
| Transcoding | Rust → ffmpeg CLI | Swift → ffmpeg CLI | Same approach |
| Activity panel | React collapsible | SwiftUI collapsible panel | |
| MiniPlayer | React fixed bar | SwiftUI bottom bar | |
| Themes | Tailwind CSS vars | SwiftUI `Color` assets | |
| Menu bar | Tauri menu (limited) | Native `CommandMenu` | **Better**: full macOS menu |
| Keyboard shortcuts | JS event listeners | `.keyboardShortcut` | **Better**: native |
| Tray/Dock | Not implemented | Native dock menu | **New** |
| Notifications | Tauri notification | `UserNotifications` | **Better**: native |
| Drag from Finder | Not implemented | `.onDrop` | **New** |
| Touch Bar | Not possible | `NSTouchBar` | **New** |

---

## 8. External Tool Integration

All CLI tools are called via Foundation `Process` (same as Rust's `tokio::process::Command`):

```swift
class ProcessRunner {
    static func run(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        onOutput: ((String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }
        // stdout/stderr pipe setup, async reading, etc.
        ...
    }
}
```

| Tool | macOS Binary | Usage |
|---|---|---|
| `ffmpeg` | Homebrew / bundled | Transcoding, format detection |
| `ffprobe` | Homebrew / bundled | Audio metadata analysis |
| `yt-dlp` | Homebrew / pip | YouTube download fallback |
| `scdl` | pip install | SoundCloud direct download |
| `fpcalc` | Homebrew / bundled | Chromaprint fingerprint generation |

**Option:** Bundle `ffmpeg` and `fpcalc` inside the `.app` bundle for zero-dependency experience. Use `Bundle.main.url(forAuxiliaryExecutable:)`.

---

## 9. Design System Translation

### 9.1 Color Mapping (Solar Theme → SwiftUI)

```swift
extension Color {
    // Backgrounds
    static let mlmBase    = Color(hex: "#0c0c12")
    static let mlmSurface = Color(hex: "#14141c")
    static let mlmRaised  = Color(hex: "#1c1c26")
    static let mlmOverlay = Color(hex: "#24242e")

    // Borders
    static let mlmEdge       = Color(hex: "#2a2a36")
    static let mlmEdgeSubtle = Color(hex: "#1e1e28")

    // Text
    static let mlmInk          = Color(hex: "#e8e8f0")
    static let mlmInkSecondary = Color(hex: "#8888a0")
    static let mlmInkMuted     = Color(hex: "#55556a")

    // Accent
    static let mlmAccent       = Color(hex: "#d4940c")
    static let mlmAccentBright = Color(hex: "#f0a818")

    // Status
    static let mlmSuccess = Color(hex: "#34d399")  // emerald-400
    static let mlmError   = Color(hex: "#fb7185")  // rose-400
    static let mlmActive  = Color(hex: "#38bdf8")  // sky-400
    static let mlmWarning = Color(hex: "#fbbf24")  // amber-400
}
```

### 9.2 Spacing Constants

```swift
enum MLMSpacing {
    static let pagePadding: CGFloat = 16    // p-4
    static let cardPadding: CGFloat = 12    // p-3
    static let sectionGap: CGFloat = 12     // gap-3
    static let tableRowHeight: CGFloat = 36
    static let sidebarWidth: CGFloat = 192
    static let activityCollapsed: CGFloat = 36
    static let activityExpanded: CGFloat = 320
}
```

### 9.3 Typography

```swift
enum MLMFont {
    static let sectionLabel = Font.system(size: 11, weight: .semibold).uppercaseSmallCaps()
    static let body = Font.system(size: 13)
    static let data = Font.system(size: 13, design: .monospaced)
    static let muted = Font.system(size: 11)
}
```

---

## 10. Migration Notes

### 10.1 Advantages of Native macOS

1. **Apple Music** — MusicKit framework replaces webview scraping (much more reliable)
2. **Performance** — Native table rendering, no web engine overhead
3. **App size** — No Chromium/WebKit bundle (~100MB savings)
4. **Menu bar** — Full native menu bar with standard macOS conventions
5. **Notifications** — Native notification center integration
6. **Keychain** — Secure token storage (vs. file-based)
7. **Drag & drop** — System-level file drag support
8. **Appearance** — Follows system accent color, accessibility settings
9. **Memory** — No WebView process, lower baseline memory

### 10.2 Challenges

1. **SwiftUI Table maturity** — May need NSTableView fallback for large datasets
2. **No hot reload** — Previews help but slower iteration than Vite HMR
3. **Waveform rendering** — Must implement from scratch (no wavesurfer.js)
4. **Limited Swift audio tag libraries** — May need to bridge TagLib via C
5. **ffmpeg bundling** — App Store prohibits GPL; distribute outside App Store or use AVFoundation

### 10.3 What Can Be Shared

- **SQLite database** — Same file, same schema, same migrations
- **CLI tool integration** — Same ffmpeg/yt-dlp/scdl/fpcalc invocations
- **API endpoints** — Same Spotify, SoundCloud, DAB API calls
- **Business logic** — Same download chain, sync algorithm, fingerprint matching

### 10.4 Distribution

- **Outside App Store** — Direct `.dmg` / Sparkle auto-update (avoids GPL restrictions for ffmpeg)
- **Notarized** — Apple notarization for Gatekeeper
- **Hardened runtime** — Required for notarization, compatible with `Process` CLI calls via entitlements

---

## Estimated Timeline

| Phase | Duration | Cumulative |
|---|---|---|
| Phase 0–1: Scaffold + Data | 2 weeks | Week 2 |
| Phase 2–3: Shell + Library | 1.5 weeks | Week 3.5 |
| Phase 4–5: Import + Playback | 1.5 weeks | Week 5 |
| Phase 6–7: Playlists + Folders | 1.5 weeks | Week 6.5 |
| Phase 8–10: Sources | 2.5 weeks | Week 9 |
| Phase 11–12: Downloads + Sync | 2 weeks | Week 11 |
| Phase 13–15: Analysis + Albums | 2 weeks | Week 13 |
| Phase 16–18: Polish + Resilience | 1.5 weeks | Week 14.5 |
| Phase 19–20: Platform + Testing | 2 weeks | Week 16.5 |

**Total: ~16–17 weeks** for full feature parity.
