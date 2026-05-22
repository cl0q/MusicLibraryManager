# Phase 36: Playlists (v2.0 macOS Native) — Pattern Map

**Mapped:** 2026-05-13
**Files analyzed:** 16 (7 NEW + 9 MODIFIED)
**Analogs found:** 16 / 16

> Pattern map for the planner. Every new/modified file in Phase 36 has a concrete analog in `macos-app/MLM/` with line refs and code excerpts the executor can mimic verbatim.

## File Classification

| New / Modified File | Role | Data Flow | Closest Analog | Match Quality |
|---|---|---|---|---|
| `MLM/Services/Playlists/PlaylistCoverService.swift` (NEW) | service | event-driven (NotificationCenter) + file-I/O | `MLM/ViewModels/PlaylistViewModel.swift` (Observable + notification observer pattern) + `MLM/Services/Mount/MountObserver.swift` (long-lived NotificationCenter observer) | exact (compose 2 analogs) |
| `MLM/Services/Playlists/MosaicCompositor.swift` (NEW) | service utility | transform (in-memory image compositing) | `MLM/Services/Import/MetadataExtractor.swift` (stateless `enum` namespace + static funcs) | role-match |
| `MLM/Services/Playlists/GradientPalette.swift` (NEW) | service utility | transform (deterministic hash → palette) | `MLM/Services/Import/MetadataExtractor.swift` (`enum` namespace, private statics) | role-match |
| `MLM/Services/Playlists/ArtworkExtractor.swift` (NEW) | service utility | file-I/O (AVURLAsset read) | `MLM/Services/Import/MetadataExtractor.swift` (AVAsset.commonMetadata pipeline) | exact |
| `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift` (NEW) | view (subcomponent) | request-response (renders observable list) | `MLM/Views/Sidebar/SidebarView.swift` (List + Section + tag + .contextMenu) | role-match |
| `MLMTests/ServiceTests/PlaylistCoverServiceTests.swift` (NEW) | test | event-driven | `MLMTests/ServiceTests/TranscodeServiceTests.swift` (tmp-dir fixture + assertions) | role-match |
| `MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift` (NEW) | test | CRUD | `MLMTests/DatabaseTests/DatabaseTests.swift:53-71,127-145` (columns + CRUD test) | exact |
| `MLM/Database/DatabaseManager.swift` (MODIFIED) | migration | schema migration | `DatabaseManager.swift:433-439` (`v13_playlist_path_prefix` is the canonical "add a NOT NULL DEFAULT column" migration) | exact |
| `MLM/Models/Playlist.swift` (MODIFIED) | model | static schema | `Playlist.swift:8-55` (existing GRDB `Codable` + `CodingKeys` + `Columns` enums) | exact (self-extension) |
| `MLM/Database/PlaylistRepository.swift` (MODIFIED) | repository | CRUD | `PlaylistRepository.swift:42-67` (`rename` and `togglePin` are existing parameterized `UPDATE` setters) | exact |
| `MLM/ViewModels/PlaylistViewModel.swift` (MODIFIED) | viewmodel | event-driven (UI gesture → repo + Notification) | `PlaylistViewModel.swift:182-204` (existing `togglePin`) + `PlaylistViewModel.swift:30-45` (existing transient state like `errorMessage`) | exact (self-extension) |
| `MLM/ViewModels/PlaylistDetailViewModel.swift` (MODIFIED) | viewmodel | CRUD + Notification post | `PlaylistDetailViewModel.swift:84-103` (`addTracks` posts `.playlistDidChange` after repo call) | exact (mirror existing posts in same file) |
| `MLM/Views/Playlists/PlaylistCard.swift` (MODIFIED) | view (component) | request-response + drag-and-drop | `PlaylistCard.swift:64-105` (existing `iconArea`) + `PlaylistDetailView.swift:62-73` (`.fileImporter` precedent for file pickers) | exact (self-extension) |
| `MLM/Views/Sidebar/SidebarView.swift` (MODIFIED) | view | request-response + event-driven (observes `.playlistDidChange`) | `SidebarView.swift:11-40` (existing `List(selection:) + Section + ForEach`) + `PlaylistsView.swift:48-54` (`.task` + `.onReceive(.playlistDidChange)` reload pattern) | exact (self-extension + cross-file copy) |
| `MLM/Views/ContentView/ContentView.swift` (MODIFIED) | router | request-response (enum switch) | `ContentView.swift:138-158, 221-259` (existing `SidebarSection` enum + `detailView` switch) | exact (self-extension) |
| `MLM/App/DependencyContainer.swift` (MODIFIED) | DI container | construction | `DependencyContainer.swift:77-92, 117-131` (existing repository + service wiring pattern with optional unwrap chain) | exact (self-extension) |

---

## Pattern Assignments

### 1. `MLM/Services/Playlists/PlaylistCoverService.swift` (NEW)

**Role:** service · **Data flow:** event-driven + file-I/O

**Analog A — class shape, dependency injection, `@Observable @MainActor` pattern:** `MLM/ViewModels/PlaylistViewModel.swift:10-55`

```swift
// PlaylistViewModel.swift:10-55 — the canonical `@Observable final class` in the codebase
@Observable
final class PlaylistViewModel {
    private(set) var playlists: [Playlist] = []
    var searchQuery: String = "" { didSet { applyFilter() } }
    private(set) var trackCounts: [Int64: Int] = [:]
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private let playlistRepository: PlaylistRepository

    init(playlistRepository: PlaylistRepository) {
        self.playlistRepository = playlistRepository
    }

    @MainActor
    func loadPlaylists() async { /* ... */ }
}
```

**Mimic:** `@Observable final class PlaylistCoverService { ... init(...) { startObserving() } }`. All public methods `@MainActor func ... async`.

**Analog B — long-lived NotificationCenter observer (token-based, deinit-cleanup):** `MLM/App/DependencyContainer.swift:54-64, 149-167`

```swift
// DependencyContainer.swift:54
private var libraryRootObserver: NSObjectProtocol?

// :60
deinit {
    if let token = libraryRootObserver {
        NotificationCenter.default.removeObserver(token)
    }
}

// :149-167
libraryRootObserver = NotificationCenter.default.addObserver(
    forName: .libraryRootDidChange,
    object: nil,
    queue: .main
) { notification in
    let newRoot = (notification.userInfo?["path"] as? String) ?? ""
    guard !newRoot.isEmpty else { return }
    Task { @MainActor in
        // ... handle ...
    }
}
```

**Mimic:** Store the `NSObjectProtocol` token, register in `init` (or a `startObserving()` helper), remove in `deinit`. Use `queue: .main` and dispatch real work via `Task { @MainActor in ... }`. Re-entry guard via `note.userInfo?["origin"] as? String == "coverService"`.

**Analog C — AVURLAsset commonMetadata extraction (avoid the deprecated `AVAsset(url:)`):** `MLM/Services/Import/MetadataExtractor.swift:81-105` (current code uses deprecated `AVAsset`; new service MUST use `AVURLAsset`)

```swift
// MetadataExtractor.swift:81-94 — same shape, but NEW code uses AVURLAsset
static func extract(from url: URL) async throws -> TrackMetadata {
    let asset = AVAsset(url: url)   // ⚠ deprecated — new code: AVURLAsset(url: url)
    let isPlayable = try await asset.load(.isPlayable)
    guard isPlayable else { throw ExtractionError.cannotOpenFile(...) }
    let metadata = try await asset.load(.commonMetadata)
    ...
}

// :175-186 — metadata-key filter pattern (older API)
private static func metadataValue(for key: AVMetadataKey, in items: [AVMetadataItem]) async -> String? {
    let matching = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: nil)
    guard let item = matching.first else { return nil }
    return try? await item.load(.stringValue)
}
```

**Mimic (in ArtworkExtractor.swift):** Use `AVURLAsset(url:)` (not `AVAsset(url:)` — RESEARCH §"API notes" line 165), filter by `filteredByIdentifier: .commonIdentifierArtwork`, and `try await item.load(.dataValue)`.

**Analog D — Application Support cache directory pattern:** `MLM/App/DependencyContainer.swift:120-123`

```swift
let cacheDir = FileManager.default
    .urls(for: .cachesDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("com.mlm.transcode_cache")
let cache = TranscodeCache(cacheDir: cacheDir)
```

**Mimic (PNG cache for covers):** Use `.applicationSupportDirectory` (not `.cachesDirectory` — covers must survive OS cache eviction) per RESEARCH lines 467-471:

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

**Analog E — Resolve local audio URL (library_root + organized_path):** `MLM/Views/Library/TrackContextMenu.swift:262-280`

```swift
// TrackContextMenu.swift:265-280
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
```

**Mimic:** Identical resolve helper inside `PlaylistCoverService`. Service holds `configRepository` so it can call `getLibraryRoot()` itself. Remote-only tracks (`organizedPath == nil` + unresolvable `originalPath`) → treat slot as `nil` artwork; mosaic gap-fill handles them (D-02).

**Analog F — AppLogger pattern (silent-fail logging per UI-SPEC line 173):** `MLM/App/DependencyContainer.swift:162-173`

```swift
AppLogger.shared.info(
    "Download pipeline reconfigured for new library root: \(newRoot)",
    source: "Download"
)
```

**Mimic:** `AppLogger.shared.error("Cover generation failed for playlist \(id): \(error)", source: "PlaylistCover")`. No toast surfaces for generation errors — only for the user-drop failure (UI-SPEC line 174 banner).

---

### 2. `MLM/Services/Playlists/MosaicCompositor.swift` (NEW)

**Role:** service utility · **Data flow:** transform (NSBitmapImageRep compositing)

**Analog — stateless `enum` namespace + static funcs:** `MLM/Services/Import/MetadataExtractor.swift:38-69`

```swift
// MetadataExtractor.swift:38-69
enum MetadataExtractor {
    enum ExtractionError: Error, LocalizedError { /* ... */ }

    static let supportedExtensions: Set<String> = ["mp3", "flac", ...]

    static func isAudioFile(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    static func extract(from url: URL) async throws -> TrackMetadata { /* ... */ }
}
```

**Mimic:** `enum MosaicCompositor { static func composite2x2(tiles: [NSImage?], gradientFallback: ...) -> Data { ... } static func centerCrop(_ image: NSImage, to size: CGSize) -> NSImage { ... } }`. No state, no init. Returns PNG `Data` ready to write to disk.

**Geometry contract (UI-SPEC lines 54-65):** Source PNG 512×512, per-tile 256×256, inter-tile gap 2 px filled with `NSColor.windowBackgroundColor` (the `Color.mlmBase` equivalent), tile corners square (outer card clips to 8 pt).

---

### 3. `MLM/Services/Playlists/GradientPalette.swift` (NEW)

**Role:** service utility · **Data flow:** transform (deterministic hash → palette)

**Analog — stateless `enum` namespace:** `MLM/Services/Import/MetadataExtractor.swift:38-69` (same as #2)

**Palette content (UI-SPEC lines 124-138, locked):**

```swift
enum GradientPalette {
    /// Returns 2 NSColors for a linear gradient (topLeading → bottomTrailing).
    static func colors(forPlaylistId id: Int64) -> (NSColor, NSColor) {
        let index = abs(Int(id)) % 4
        switch index {
        case 0: return (.controlAccentColor, .controlAccentColor.blended(withFraction: 0.4, of: .darkGray) ?? .controlAccentColor)
        case 1: return (.systemBlue, .systemIndigo)
        case 2: return (.systemTeal, .systemBlue.blended(withFraction: 0.3, of: .black) ?? .systemBlue)
        case 3: return (.systemGray, .controlAccentColor)
        default: return (.controlAccentColor, .systemBlue)
        }
    }
}
```

---

### 4. `MLM/Services/Playlists/ArtworkExtractor.swift` (NEW)

**Role:** service utility · **Data flow:** file-I/O (AVURLAsset)

**Analog — Same as PlaylistCoverService Analog C above:** `MLM/Services/Import/MetadataExtractor.swift:81-105`. Already covered. The new file is a thin wrapper:

```swift
enum ArtworkExtractor {
    /// Reads embedded cover-art Data from an audio file.
    /// Returns nil if no embedded artwork or file unreadable.
    static func extract(audioURL: URL) async -> Data? {
        let asset = AVURLAsset(url: audioURL)
        guard let isPlayable = try? await asset.load(.isPlayable), isPlayable else { return nil }
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

(Exact API verified in RESEARCH lines 143-158.)

---

### 5. `MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift` (NEW)

**Role:** view (subcomponent) · **Data flow:** request-response + observes `.playlistDidChange`

**Analog A — DisclosureGroup inside `List(selection:)` with `.tag()`-based selection:** `MLM/Views/Sidebar/SidebarView.swift:11-40`

```swift
// SidebarView.swift:11-40
var body: some View {
    List(selection: $selectedSection) {
        Section {
            ForEach(SidebarSection.allCases) { section in
                HStack {
                    Label(section.label, systemImage: section.icon)
                    if section == .library && !container.isLibraryDriveMounted {
                        Spacer()
                        Circle().fill(Color.mlmError).frame(width: 7, height: 7)
                    }
                }
                .tag(section)
            }
        } header: {
            Text("NAVIGATION")
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkMuted)
        }
    }
    .listStyle(.sidebar)
}
```

**Mimic:** Wrap the `.playlists` row in a `DisclosureGroup(isExpanded: $pinnedExpanded)`. Each pinned playlist row uses `.tag(SidebarSection.playlistDetail(pl.id ?? -1))` for native `List(selection:)` highlight. Empty-state row uses `Text("No pinned playlists")` with `.disabled(true)` (UI-SPEC lines 252-255).

**Analog B — observe `.playlistDidChange` to refresh state:** `MLM/Views/Playlists/PlaylistsView.swift:48-54`

```swift
.task {
    initializeViewModel()
    await viewModel?.loadPlaylists()
}
.onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
    Task { await viewModel?.refresh() }
}
```

**Mimic:**

```swift
@State private var pinnedPlaylists: [Playlist] = []
@AppStorage("sidebar.pinnedPlaylists.expanded") private var pinnedExpanded = true

.task { await loadPinned() }
.onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
    Task { await loadPinned() }
}

private func loadPinned() async {
    guard let repo = container.playlistRepository else { return }
    let all = (try? await repo.fetchAll()) ?? []
    pinnedPlaylists = all.filter { $0.isPinned == 1 }
}
```

**Analog C — context-menu on a sidebar row:** `MLM/Views/Playlists/PlaylistCard.swift:149-182`

```swift
// PlaylistCard.swift:149-182 — context-menu structure with @ViewBuilder, Divider, role: .destructive
@ViewBuilder
private var contextMenuItems: some View {
    Button { onTap() } label: { Label("Open", systemImage: "arrow.right.circle") }
    Divider()
    Button { onRename() } label: { Label("Rename…", systemImage: "pencil") }
    Button { onTogglePin() } label: {
        if playlist.isPinned == 1 { Label("Unpin", systemImage: "pin.slash") }
        else { Label("Pin to Top", systemImage: "pin") }
    }
    Divider()
    Button(role: .destructive) { onDelete() } label: {
        Label("Delete Playlist", systemImage: "trash")
    }
}
```

**Mimic — sidebar pinned-row context menu (UI-SPEC lines 261-267, D-11):**

```swift
.contextMenu {
    Button("Unpin from Sidebar") { Task { await viewModel.togglePin(id: pl.id!) } }
    Button("Rename…") { /* enter rename mode */ }
    Divider()
    Button("Reveal in Grid") { selectedSection = .playlists }
    Divider()
    Button("Delete", role: .destructive) { Task { await viewModel.deletePlaylist(id: pl.id!) } }
}
```

---

### 6. `MLMTests/ServiceTests/PlaylistCoverServiceTests.swift` (NEW)

**Role:** test · **Data flow:** event-driven

**Analog A — service-tests scaffolding with tmp dirs + ffmpeg gating:** `MLMTests/ServiceTests/TranscodeServiceTests.swift:19-40`

```swift
// TranscodeServiceTests.swift:19-25 — tmp-dir helper
private func makeTempDir() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("mlm_transcode_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    return tmp
}

// :67-89 — Swift Testing-style @Test with #require + #expect + defer cleanup
@Test func transcodesLosslessFlacToAac() async throws {
    try #require(Self.ffmpegAvailable, "ffmpeg + ffprobe required for transcode test")
    let tmp = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tmp) }
    /* ... arrange + act + assert ... */
}
```

**Mimic:** Use Swift Testing's `@Test` + `#expect` + `#require`. Fixtures should be MP3/M4A files in `MLMTests/Fixtures/` (create dir if missing) with known embedded covers + tracks without covers, so the test can exercise all three branches (`auto1`, `auto4`, `fallback`).

**Test cases to ship (RESEARCH-recommended minimum + stretch):**

1. `auto4_with_4_tracks_each_having_artwork` → composited PNG exists, 512×512.
2. `auto1_with_1_track_having_artwork` → single cover PNG.
3. `fallback_with_0_artwork` → gradient + initials PNG produced (`name = "🎵 Workout"` should yield `🎵W` as initials per UI-SPEC line 83).
4. `respects_cover_is_custom_flag` → `cover_is_custom = 1` causes `regenerateCover` to return early (no file written, no DB change).
5. `re_entry_guard` → posting `.playlistDidChange` with `userInfo["origin"] = "coverService"` does NOT trigger re-regeneration.

---

### 7. `MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift` (NEW)

**Role:** test · **Data flow:** CRUD

**Analog — in-memory GRDB CRUD + column existence assertions:** `MLMTests/DatabaseTests/DatabaseTests.swift:53-71, 127-145`

```swift
// DatabaseTests.swift:53-71 — column existence pattern
@Test func tracksTableHasAllColumns() async throws {
    let db = try DatabaseManager.inMemory()
    try await db.read { db in
        let columns = try db.columns(in: "tracks").map(\.name)
        let expectedColumns = ["id", "artist", /* ... */]
        for col in expectedColumns {
            #expect(columns.contains(col), "Missing column: tracks.\(col)")
        }
    }
}

// :127-145 — playlist CRUD pattern
@Test func playlistCRUD() async throws {
    let db = try DatabaseManager.inMemory()
    try await db.write { db in
        var playlist = Playlist.createNative(name: "My Playlist")
        try playlist.insert(db)
        let id = playlist.id!
        let fetched = try Playlist.fetchOne(db, id: id)
        #expect(fetched?.name == "My Playlist")
        try Playlist.deleteOne(db, id: id)
    }
}
```

**Mimic (one file, three tests):**

1. `playlistsTableHasCoverIsCustomColumn` — verify the v20 column exists + DEFAULT 0 materializes on insert (full code in RESEARCH lines 207-222).
2. `setCoverPath_updatesPathAndCustomFlag` — call repo setter, fetch back, assert both `cover_image_path` and `cover_is_custom`.
3. `setCoverPath_resetToAuto_clearsBoth` — call `setCoverPath(id:, path: nil, isCustom: false)`, assert both columns return to defaults.

**Note:** `DatabaseManager.inMemory()` returns `DatabaseQueue` (not `DatabasePool`). The `PlaylistRepository.init(database:)` takes `DatabasePool`. For tests, follow `TrackRepositoryTests.swift:9-13`:

```swift
// TrackRepositoryTests.swift:9-13
private func makeRepo() throws -> (DatabaseQueue, TrackRepository) {
    let db = try DatabaseManager.inMemory()
    let repo = TrackRepository(database: db)  // implicit conversion / both accept DatabaseWriter
    return (db, repo)
}
```

Confirm `PlaylistRepository`'s `private let database: DatabasePool` allows `DatabaseQueue`. If not, planner may need to widen the type to `DatabaseWriter` — but `TrackRepositoryTests` already does it for `TrackRepository`, so the same pattern probably already works.

---

### 8. `MLM/Database/DatabaseManager.swift` (MODIFIED — register migration v20)

**Role:** migration · **Data flow:** schema migration

**Analog (verbatim — same shape, mirror this exactly):** `DatabaseManager.swift:433-439`

```swift
// DatabaseManager.swift:433-439 — v13_playlist_path_prefix is the canonical
// "add a NOT NULL DEFAULT column to an existing table" precedent
migrator.registerMigration("v13_playlist_path_prefix") { db in
    if try !db.columns(in: "sync_profiles").contains(where: { $0.name == "playlist_path_prefix" }) {
        try db.alter(table: "sync_profiles") { t in
            t.add(column: "playlist_path_prefix", .text).notNull().defaults(to: "")
        }
    }
}
```

**Add — between `v_search_text_column` (ends at line 619) and `return migrator` (line 622):**

```swift
// ──────────────────────────────────────────────────────────────
// Migration v20: playlist cover lock flag (Phase 36)
// ──────────────────────────────────────────────────────────────
migrator.registerMigration("v20_playlist_cover_custom") { db in
    if try !db.columns(in: "playlists").contains(where: { $0.name == "cover_is_custom" }) {
        try db.alter(table: "playlists") { t in
            t.add(column: "cover_is_custom", .integer).notNull().defaults(to: 0)
        }
    }
}
```

**ALSO** add the same registration to `inMemoryMigrator` if that has a parallel block (verify around line 101+).

**Parity constraints (RESEARCH lines 194-202):**
- DEFAULT 0 mandatory so Tauri-side INSERTs (which don't know about the column) don't fail NOT NULL.
- Do NOT mirror into `_migrations` tracking table — GRDB's own `grdb_migrations` handles it.

---

### 9. `MLM/Models/Playlist.swift` (MODIFIED — add `coverIsCustom` field)

**Role:** model · **Data flow:** static schema

**Analog (self):** `MLM/Models/Playlist.swift:8-55, 101-118`

```swift
// Playlist.swift:8-34 — existing Codable + CodingKeys pattern (Int for SQLite-bool)
struct Playlist: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var description: String?
    var category: String
    var isLiked: Int
    var isSmart: Int
    var isPinned: Int
    var coverImagePath: String?
    var coverImageUrl: String?
    var sourceId: Int64?
    var externalId: String?
    var dateCreated: String?

    enum CodingKeys: String, CodingKey {
        case id, name, description, category
        case isLiked = "is_liked"
        case isSmart = "is_smart"
        case isPinned = "is_pinned"
        case coverImagePath = "cover_image_path"
        case coverImageUrl = "cover_image_url"
        case sourceId = "source_id"
        case externalId = "external_id"
        case dateCreated = "date_created"
    }
}
```

**Add (4 mechanical edits):**

1. New stored property after `isPinned`: `var coverIsCustom: Int = 0`
2. New CodingKey: `case coverIsCustom = "cover_is_custom"`
3. (Optional but recommended) new `Columns` entry: `static let coverIsCustom = Column(CodingKeys.coverIsCustom)`
4. Update `createNative(name:)` factory at `:103-118` to add `coverIsCustom: 0` after `isPinned: 0`.

**Why `Int` not `Bool`:** SQLite-bool convention; matches `isLiked`/`isSmart`/`isPinned` in the same struct.

---

### 10. `MLM/Database/PlaylistRepository.swift` (MODIFIED — add `setCoverPath(id:path:isCustom:)`)

**Role:** repository · **Data flow:** CRUD (setter)

**Analog (self — parameterized UPDATE):** `PlaylistRepository.swift:42-67`

```swift
// PlaylistRepository.swift:42-49 — rename setter
func rename(id: Int64, name: String) async throws {
    try await database.write { db in
        try db.execute(
            sql: "UPDATE playlists SET name = ? WHERE id = ?",
            arguments: [name, id]
        )
    }
}

// :59-67 — togglePin setter
func togglePin(id: Int64) async throws {
    try await database.write { db in
        try db.execute(
            sql: "UPDATE playlists SET is_pinned = CASE WHEN is_pinned = 1 THEN 0 ELSE 1 END WHERE id = ?",
            arguments: [id]
        )
    }
}
```

**Add (new method, mirror `rename` shape):**

```swift
/// Set the playlist's cover image path and lock flag.
///
/// - Parameter path: Relative path under `~/Library/Application Support/.../playlist-covers/`,
///                   or nil to clear (use when resetting to auto).
/// - Parameter isCustom: 1 if the user explicitly set this cover (skip auto-regen),
///                       0 if produced by the auto generator.
func setCoverPath(id: Int64, path: String?, isCustom: Bool) async throws {
    try await database.write { db in
        try db.execute(
            sql: "UPDATE playlists SET cover_image_path = ?, cover_is_custom = ? WHERE id = ?",
            arguments: [path, isCustom ? 1 : 0, id]
        )
    }
}
```

**Also update `fetchTracks` (line 78) to add deterministic tie-breaker per RESEARCH line 117:**

```swift
// PlaylistRepository.swift:78 — current SQL
ORDER BY pt.position
// →
ORDER BY pt.position, pt.added_at ASC
```

---

### 11. `MLM/ViewModels/PlaylistViewModel.swift` (MODIFIED — 8-pin soft-limit + hint state)

**Role:** viewmodel · **Data flow:** event-driven (UI gesture → repo + Notification)

**Analog A — transient error/state pattern already in this file:** `PlaylistViewModel.swift:32-33`

```swift
// PlaylistViewModel.swift:32-33
/// Error message from the last failed operation.
private(set) var errorMessage: String?
```

**Mimic:** Add a sibling transient property:

```swift
/// Transient hint message for pin-limit violations (auto-clears after 3s).
var pinLimitHintMessage: String?
```

**Analog B — existing `togglePin` is the exact insertion site:** `PlaylistViewModel.swift:182-204` (line 184 is where the new pre-check lives per RESEARCH line 73)

```swift
// PlaylistViewModel.swift:182-204 — current togglePin
@MainActor
func togglePin(id: Int64) async {
    do {
        try await playlistRepository.togglePin(id: id)
        if let idx = playlists.firstIndex(where: { $0.id == id }) {
            playlists[idx].isPinned = playlists[idx].isPinned == 1 ? 0 : 1
        }
        playlists.sort { a, b in
            if a.isPinned != b.isPinned { return a.isPinned > b.isPinned }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        applyFilter()
    } catch {
        errorMessage = "Failed to toggle pin: \(error.localizedDescription)"
    }
}
```

**Mimic — insert pre-check at top of function body (RESEARCH lines 388-409):**

```swift
@MainActor
func togglePin(id: Int64) async {
    // Direction check
    guard let target = playlists.first(where: { $0.id == id }) else { return }
    let willPin = target.isPinned == 0

    // Soft limit: max 8 pinned (D-10). Hard-block; user must unpin first.
    if willPin {
        let pinnedCount = playlists.filter { $0.isPinned == 1 }.count
        if pinnedCount >= 8 {
            pinLimitHintMessage = "Pinned limit reached"  // UI banner title; body lives in the View
            Task {
                try? await Task.sleep(for: .seconds(3))
                pinLimitHintMessage = nil
            }
            return  // hard block, no repo call
        }
    }

    // ... existing body unchanged ...
}
```

Also: `NotificationCenter.default.post(name: .playlistDidChange, object: nil)` should be added after the existing `applyFilter()` call inside `togglePin` so the sidebar disclosure refreshes when a pin toggles. (Existing posts at `:111, :131, :165` confirm the convention — `togglePin` is the only mutator that currently DOESN'T post and should.)

---

### 12. `MLM/ViewModels/PlaylistDetailViewModel.swift` (MODIFIED — post `.playlistDidChange` from `moveTrack`)

**Role:** viewmodel · **Data flow:** CRUD + Notification post

**Analog (self — same file already posts the notification in 4 sibling methods):** `PlaylistDetailViewModel.swift:84-103, 105-127, 129-142, 184-235`

```swift
// PlaylistDetailViewModel.swift:84-103 — addTracks posts at :99
@MainActor
func addTracks(_ trackIds: [Int64]) async {
    guard let playlistId = playlist.id else { return }
    let nextPosition = generateNextPosition()
    do {
        try await playlistRepository.addTracks(playlistId: playlistId, trackIds: trackIds, startPosition: nextPosition)
        await loadTracks()
        NotificationCenter.default.post(name: .playlistDidChange, object: nil)  // ← :99
    } catch {
        errorMessage = "Failed to add tracks: \(error.localizedDescription)"
    }
}
```

**Mimic — `moveTrack` at lines 155-180 is missing this post (RESEARCH line 130). Add one line after `await loadTracks()`:**

```swift
// PlaylistDetailViewModel.swift:155-180 — current moveTrack
@MainActor
func moveTrack(from sourceIndex: Int, to destinationIndex: Int) async {
    // ... existing body ...
    do {
        try await playlistRepository.reorderTrack(...)
        await loadTracks()
        NotificationCenter.default.post(name: .playlistDidChange, object: nil)  // ← ADD THIS
    } catch {
        errorMessage = "Failed to reorder: \(error.localizedDescription)"
    }
}
```

**Why this matters for Phase 36:** Without this post, reordering the first 4 tracks won't trigger cover regeneration (D-04 violation). With this post, `PlaylistCoverService` observes the same notification and regenerates.

**Optional enrichment** (recommended by RESEARCH line 581): Add `userInfo: ["playlistId": playlistId]` so the service can target a specific playlist instead of refreshing all. Not strictly required for v1.

---

### 13. `MLM/Views/Playlists/PlaylistCard.swift` (MODIFIED — cover render, drop-target, Reset menu entry)

**Role:** view (component) · **Data flow:** request-response + drag-and-drop

**Analog A — existing `iconArea` and gradient fallback (extend, don't replace):** `PlaylistCard.swift:64-105`

```swift
// PlaylistCard.swift:64-105
private var iconArea: some View {
    ZStack {
        LinearGradient(
            colors: categoryGradient,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .frame(height: 100)

        Image(systemName: categoryIcon)
            .font(.system(size: 32, weight: .light))
            .foregroundColor(.white.opacity(0.8))

        if playlist.isPinned == 1 {
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(6)
                }
                Spacer()
            }
        }

        if playlist.sourceId != nil {
            VStack { HStack { sourceBadge.padding(6); Spacer() }; Spacer() }
        }
    }
}
```

**Mimic — wrap existing content with a cover-image check (RESEARCH lines 442-472):**

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
            // existing LinearGradient + Image(systemName: categoryIcon)
            LinearGradient(colors: categoryGradient, ...).frame(height: 100)
            Image(systemName: categoryIcon)...
        }
        // pin indicator + source badge (unchanged) stay on top of either branch
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

**Analog B — drop-target with isTargeted-driven visual feedback (UI-SPEC lines 208-214):**

`PlaylistCard` already has hover state (`@State private var isHovered` at `:31`, animation at `:47-51`). Mirror that with:

```swift
@State private var isDropTargeted = false

.onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
    handleDrop(providers: providers)
}

// Update existing overlay stroke at :43-46
.overlay(
    RoundedRectangle(cornerRadius: 8)
        .stroke(strokeColor, lineWidth: isDropTargeted ? 2 : 1)
)

private var strokeColor: Color {
    if isDropTargeted { return .mlmAccent }
    return isHovered ? .mlmEdge : .mlmEdgeSubtle
}
```

**Analog C — context-menu extension (`@ViewBuilder` + Divider conventions already in this file):** `PlaylistCard.swift:149-182` (already shown in #5 Analog C).

**Mimic — add a conditional menu item per UI-SPEC line 165, before the existing destructive Divider:**

```swift
@ViewBuilder
private var contextMenuItems: some View {
    Button { onTap() } label: { Label("Open", systemImage: "arrow.right.circle") }
    Divider()
    Button { onRename() } label: { Label("Rename…", systemImage: "pencil") }
    Button { onTogglePin() } label: { /* existing pin label */ }

    if playlist.coverIsCustom == 1 {                      // ← NEW
        Button { onResetCover() } label: {
            Label("Reset to Auto Cover", systemImage: "arrow.counterclockwise")
        }
    }

    Divider()
    Button(role: .destructive) { onDelete() } label: {
        Label("Delete Playlist", systemImage: "trash")
    }
}
```

**New action closures on the card (extend the action block at `:24-29`):**

```swift
var onCoverDropped: (URL) async -> Void   // NEW
var onResetCover: () -> Void               // NEW
```

`PlaylistsView.scrollableGrid` (lines 197-225) passes the closures by calling `container.playlistCoverService?.setCustomCover(...)` / `.resetToAuto(...)`.

---

### 14. `MLM/Views/Sidebar/SidebarView.swift` (MODIFIED — inject DisclosureGroup, direct-to-detail nav)

**Role:** view · **Data flow:** request-response + event-driven

**Analog (self):** `MLM/Views/Sidebar/SidebarView.swift:11-40` (full body already shown in #5 Analog A).

**Mimic — replace the `ForEach(SidebarSection.allCases)` body with branching on `.playlists`** (RESEARCH lines 237-253):

```swift
ForEach(SidebarSection.topLevelCases) { section in   // ← was .allCases
    if section == .playlists {
        DisclosureGroup(isExpanded: $pinnedExpanded) {
            if pinnedPlaylists.isEmpty {
                Text("No pinned playlists")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .italic()
                    .disabled(true)
            } else {
                ForEach(pinnedPlaylists.prefix(8)) { pl in
                    Label(pl.name, systemImage: "music.note.list")
                        .tag(SidebarSection.playlistDetail(pl.id ?? -1))
                        .contextMenu { pinnedRowContextMenu(pl) }
                        .help("\(pl.name) — \(trackCounts[pl.id ?? -1] ?? 0) tracks")
                }
            }
        } label: {
            Label(section.label, systemImage: section.icon)
                .tag(section)  // tag survives label-click → selects .playlists (grid)
        }
    } else {
        // existing HStack/Label/Tag layout for library/folders/sync/sources (unchanged)
    }
}
```

Plus the `@AppStorage` + `@State` + reload pattern from #5 Analog B (`.task` + `.onReceive(.playlistDidChange)` + `loadPinned()`).

---

### 15. `MLM/Views/ContentView/ContentView.swift` (MODIFIED — add `.playlistDetail(Int64)` route)

**Role:** router · **Data flow:** request-response (enum switch)

**Analog (self):** `MLM/Views/ContentView/ContentView.swift:138-158, 221-259`

```swift
// ContentView.swift:138-158 — existing routing switch
@ViewBuilder
private var detailView: some View {
    switch selectedSection {
    case .library:
        LibraryView(onTrackDoubleClick: { track in handleTrackDoubleClick(track) })
    case .playlists:
        PlaylistsView(onTrackDoubleClick: { track in handleTrackDoubleClick(track) })
    case .folders:
        FoldersView(onTrackDoubleClick: { track in handleTrackDoubleClick(track) })
    case .sync:
        SyncView()
    case .sources:
        SourcesView()
    }
}

// :221-259 — current enum (rawValue/CaseIterable)
enum SidebarSection: String, CaseIterable, Identifiable, Hashable {
    case library
    case playlists
    case folders
    case sync
    case sources

    var id: String { rawValue }

    var label: String { switch self { ... } }
    var icon: String { switch self { ... } }
    var keyboardShortcut: KeyEquivalent { switch self { ... } }
}
```

**Mimic — extend enum + switch (RESEARCH lines 310-348):**

```swift
enum SidebarSection: Hashable, Identifiable {       // ← drop String + CaseIterable
    case library
    case playlists
    case playlistDetail(Int64)                       // ← NEW (carries playlist id)
    case folders
    case sync
    case sources

    var id: String {
        switch self {
        case .library: "library"
        case .playlists: "playlists"
        case .playlistDetail(let id): "playlistDetail-\(id)"
        case .folders: "folders"
        case .sync: "sync"
        case .sources: "sources"
        }
    }

    /// Manual replacement for synthesized CaseIterable (broken once we added an associated value).
    /// SidebarView iterates these for the top-level rows; .playlistDetail cases are produced
    /// dynamically by the DisclosureGroup's pinnedPlaylists ForEach.
    static var topLevelCases: [SidebarSection] {
        [.library, .playlists, .folders, .sync, .sources]
    }

    var label: String { /* extend with playlistDetail returning "" or a debug name */ }
    var icon: String { /* same */ }
    var keyboardShortcut: KeyEquivalent? { /* mark optional; .playlistDetail returns nil */ }
}
```

And add the route in `detailView`:

```swift
case .playlistDetail(let id):
    PlaylistDetailViewLoader(
        playlistId: id,
        onBack: { selectedSection = .playlists },
        onTrackDoubleClick: handleTrackDoubleClick
    )
```

**`PlaylistDetailViewLoader` (NEW — RESEARCH lines 353-374) lives at `MLM/Views/Playlists/PlaylistDetailViewLoader.swift`. Treat it as a small extension of this file's routing concern — same role as ContentView (routing/loading shell), no separate analog needed.**

---

### 16. `MLM/App/DependencyContainer.swift` (MODIFIED — add `playlistCoverService` slot)

**Role:** DI container · **Data flow:** construction

**Analog (self):** `MLM/App/DependencyContainer.swift:20-43, 77-92, 117-131`

```swift
// DependencyContainer.swift:30-31 — services declaration block
private(set) var importService: ImportService?
private(set) var audioPlayer: AudioPlayer?

// :117-131 — conditional initialization pattern with optional unwrap chain
if let trackRepo = self.trackRepository,
   let syncRepo = self.syncRepository,
   let configRepo = self.configRepository {
    // ... build SyncService + SyncViewModel ...
    self.syncViewModel = SyncViewModel(syncRepository: syncRepo, syncService: syncSvc)
}
```

**Mimic — RESEARCH lines 622-636:**

```swift
// Add to the services block (around :35)
private(set) var playlistCoverService: PlaylistCoverService?

// Add to initialize() after the line `self.configRepository = ConfigRepository(database: dbPool)` (line 83)
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

---

## Shared Patterns

### S-1: `@Observable @MainActor` ViewModel/Service shape
**Source:** `MLM/ViewModels/PlaylistViewModel.swift:10-55`
**Apply to:** PlaylistCoverService

```swift
@Observable
final class XYZ {
    private(set) var publicState: T = ...
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    private let dependency: Dep
    init(dependency: Dep) { self.dependency = dependency }
    @MainActor func action() async { /* ... */ }
}
```

### S-2: NotificationCenter long-lived observer (token + deinit cleanup)
**Source:** `MLM/App/DependencyContainer.swift:54-64, 149-167`
**Apply to:** PlaylistCoverService

```swift
private var observer: NSObjectProtocol?
deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
observer = NotificationCenter.default.addObserver(forName: ..., object: nil, queue: .main) { note in
    Task { @MainActor in /* dispatch real work */ }
}
```

### S-3: Async repository CRUD with `database.read/write` block
**Source:** `MLM/Database/PlaylistRepository.swift:42-67`
**Apply to:** `PlaylistRepository.setCoverPath(id:path:isCustom:)`

```swift
func mutator(...) async throws {
    try await database.write { db in
        try db.execute(sql: "UPDATE ... SET ... WHERE id = ?", arguments: [...])
    }
}
```

### S-4: SwiftUI view reload on `.playlistDidChange`
**Source:** `MLM/Views/Playlists/PlaylistsView.swift:48-54`
**Apply to:** SidebarView, PinnedPlaylistsDisclosure

```swift
.task { await viewModel?.loadPlaylists() }
.onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
    Task { await viewModel?.refresh() }
}
```

### S-5: `@ViewBuilder` context menu with `Divider`s and `role: .destructive`
**Source:** `MLM/Views/Playlists/PlaylistCard.swift:149-182`
**Apply to:** PinnedPlaylistsDisclosure rows, PlaylistCard (Reset to Auto entry)

```swift
@ViewBuilder
private var contextMenuItems: some View {
    Button { onTap() } label: { Label(..., systemImage: ...) }
    Divider()
    /* common actions */
    Divider()
    Button(role: .destructive) { onDelete() } label: { Label("Delete", systemImage: "trash") }
}
```

### S-6: Color & typography tokens (UI-SPEC contract — zero new tokens)
**Source:** `MLM/Theme/Colors.swift`, `MLM/Theme/Typography.swift` (via UI-SPEC lines 27-28, 70-86, 92-118)
**Apply to:** All new views

| Use | Token |
|---|---|
| Surface | `Color.mlmSurface` |
| Hover surface | `Color.mlmRaised` |
| Background | `Color.mlmBase` |
| Default border | `Color.mlmEdgeSubtle` |
| Hover border | `Color.mlmEdge` |
| Accent (drop target, CTA only) | `Color.mlmAccent` |
| Warning (pin banner) | `Color.mlmWarning` |
| Error (drop-rejected) | `Color.mlmError` |
| Primary text | `Color.mlmInk` |
| Secondary text | `Color.mlmInkSecondary` |
| Muted text | `Color.mlmInkMuted` |
| Body text | `MLMFont.body` |
| Bold/name | `MLMFont.bodyBold` |
| Caption | `MLMFont.muted` |
| Page title | `MLMFont.pageTitle` |

### S-7: Swift Testing `@Test` + `#expect` + tmp-dir cleanup
**Source:** `MLMTests/ServiceTests/TranscodeServiceTests.swift:19-40, 67-89`
**Apply to:** PlaylistCoverServiceTests, PlaylistRepositoryCoverTests

```swift
@Test func someBehavior() async throws {
    let tmp = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: tmp) }
    /* arrange + act */
    #expect(condition, "reason")
}
```

### S-8: GRDB in-memory test DB
**Source:** `MLMTests/DatabaseTests/DatabaseTests.swift:13-15, 127-145` + `MLMTests/DatabaseTests/TrackRepositoryTests.swift:9-13`
**Apply to:** PlaylistRepositoryCoverTests

```swift
let db = try DatabaseManager.inMemory()
try await db.write { db in /* arrange + assertions */ }
```

---

## No Analog Found

None. Every file has at least one strong analog already in the codebase.

The closest thing to a "new pattern" is **NSBitmapImageRep + NSGraphicsContext compositing** inside `MosaicCompositor.swift` — there is no precedent in `macos-app/MLM/` for in-memory PNG composition. Planner should treat this as a system-API task (Apple AppKit docs) rather than searching for an internal analog. The `enum`-namespace shell still mirrors `MetadataExtractor`; only the body content is new.

---

## Metadata

**Analog search scope:**
- `macos-app/MLM/Database/` (8 files)
- `macos-app/MLM/Models/` (6 files)
- `macos-app/MLM/ViewModels/` (11 files; touched PlaylistViewModel + PlaylistDetailViewModel)
- `macos-app/MLM/Services/` (9 subdirs; touched Audio, Import, Mount, Auth)
- `macos-app/MLM/Views/Playlists/` (3 files), `Sidebar/` (1), `ContentView/` (1), `Library/` (4)
- `macos-app/MLM/App/` (3 files)
- `macos-app/MLMTests/DatabaseTests/` (2 files), `ServiceTests/` (5 files)
- `macos-app/MLM/Utilities/Notifications.swift`

**Files scanned:** ~22 file reads, all targeted (no whole-file scans of 1000+ LOC files; `DatabaseManager.swift` read in three non-overlapping chunks: header, migration v13 reference, end-of-file).

**Pattern extraction date:** 2026-05-13

**Concurrency guard honored:** Phase 35 files (`WaveformView.swift`, `WaveformHelpers.swift`, `PlayerBar.swift`, `TrackDetailView.swift`) NOT read, NOT referenced in any analog.
