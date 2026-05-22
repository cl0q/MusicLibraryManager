# Phase 38: Folder & Device Sync (v2.0 macOS Native) - Pattern Map

**Mapped:** 2026-05-17
**Files analyzed:** 21 (15 new + 6 modified)
**Analogs found:** 19 / 21 (toast + global toolbar indicator have no in-repo analog)

This map exists so the planner can quote concrete line-numbered excerpts when writing each plan's action steps. Every file below is keyed to the closest analog in `macos-app/MLM/`. Where no analog exists (toolbar indicator, toast), the gap is documented explicitly with the closest distant cousin to use as a skeleton.

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `Database/DatabaseManager.swift` (extend) | migration | DDL alter-table | self `v20_playlist_cover_custom` (line 605-611) and `v13_playlist_path_prefix` (line 433-439) | exact |
| `Models/SyncProfile.swift` (extend) | model | GRDB Codable record | self (Playlist `coverIsCustom`, `Models/Playlist.swift`) | exact |
| `Database/SyncRepository.swift` (extend `updateSettings`) | repository | request-response (mutate) | self `updateSettings` line 153-181 | exact |
| `ViewModels/SyncViewModel.swift` (extend with 5 methods + cancel) | viewmodel | request-response mutation + notify | `ViewModels/PlaylistDetailViewModel.swift` `addTracks`/`removeSelectedTracks` line 84-156 | exact |
| `Services/Sync/SyncService.swift` (cancel flag + cleanup + toggles + retry) | service | streaming (per-file loop with progress) | self (existing `executeSync` line 140-223); `ArtworkBackfillService.backfillMissing` line 119-168 for `isRunning` / inFlight pattern | exact |
| `Utilities/Notifications.swift` (add `.syncProfileDidChange`) | utility/constants | event-driven name declaration | self existing declarations line 20-87 | exact |
| `Views/Sync/SyncView.swift` (toolbar host wrapper + extend createSheet) | view | container | self existing (line 1-179) | exact |
| `Views/Sync/SyncProfileDetailView.swift` (extract + refactor) | view | request-response (binds VM state) | self existing line 202-362; `Views/Playlists/PlaylistDetailView.swift` line 21-402 | exact |
| `Views/Sync/SyncSettingsForm.swift` (NEW) | view | form binding | NONE inside MLM (no existing SwiftUI `Form` with Toggle+Picker bound to model). Closest distant cousin: `Views/Settings/SettingsView.swift` (Form layout) — use as skeleton | partial |
| `Views/Sync/Pickers/PlaylistPickerSheet.swift` (NEW) | view | multi-select list + sheet dismissal | `Views/Playlists/PlaylistDetailView.swift` `.fileImporter` + `trackList(viewModel)` line 72-83, 223-247 (List w/ selection binding) | role-match |
| `Views/Sync/Pickers/TrackPickerSheet.swift` (NEW) | view | virtualized list + search filter + sheet | `Views/Library/LibraryTable.swift` line 53-120 (Table w/ selection) + `PlaylistDetailViewModel.applyFilter` line 266-277 (search filter) | role-match |
| `Views/Sync/SyncContentSections.swift` (NEW) | view | list + hover-trash + context-menu | `Views/Playlists/PlaylistDetailView.swift` trackRow + contextMenu line 251-339; selection pattern line 223-247 | exact |
| `Views/Sync/SyncProgressSection.swift` (NEW) | view | observable binding | `Views/Sync/SyncView.swift` previewSection line 291-332 (stat layout); `@Observable` binding pattern from SyncService line 40-42 | role-match |
| `Views/Sync/SyncFailedDisclosure.swift` (NEW) | view | DisclosureGroup + retry button | NONE direct (no DisclosureGroup-of-failures exists). Closest: `Views/Sidebar/PinnedPlaylistsDisclosure.swift` for DisclosureGroup pattern | partial |
| `Views/Sync/SyncToolbarIndicator.swift` (NEW) | view | global toolbar item | **NO ANALOG** — Phase 37 ArtworkBackfillService has `isBackfilling` state but no rendered toolbar UI exists (verified). Closest distant cousin: `Views/Player/PlayerBar.swift` (hosted in ContentView.toolbar `.principal` line 117-123) for ToolbarItem hosting pattern | partial |
| `Views/Sync/SyncToast.swift` (NEW) | view | overlay banner with timer | **NO ANALOG** — no existing toast component. Closest: `Views/Playlists/PlaylistsView.swift` banner using `pinLimitHintMessage` transient state + auto-clear (mentioned in PlaylistViewModel line 36-46) | partial |
| `Views/Playlists/PlaylistCard.swift` (extend contextMenu) | view (modify) | static submenu add | `Views/Library/TrackContextMenu.swift` line 60-79 ("Add to Playlist" submenu) | exact |
| `Views/Library/TrackContextMenu.swift` (replace placeholder line 83-90) | view (modify) | static submenu replace | self line 60-79 (same file) | exact |
| `Views/ContentView/ContentView.swift` (add SyncToolbarIndicator to `.toolbar`) | view (modify) | toolbar slot | self line 117-123 (existing PlayerBar in `.principal`) | exact |
| `MLMTests/DatabaseTests/SyncMigrationTests.swift` (NEW) | test | schema verify | `MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift` line 22-41 (column existence + default) | exact |
| `MLMTests/ViewModelTests/SyncViewModelTests.swift` (NEW) | test | VM behavior + notify | `MLMTests/ViewModelTests/PlaylistViewModelTests.swift` line 14-130 (in-memory DB + notification observation) | exact |
| `MLMTests/ServiceTests/SyncServiceTests.swift` (NEW) | test | service behavior + observable state | `MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift` line 17-95 (`@MainActor` Suite, in-memory DB makeService helper) | exact |
| `MLMTests/ServiceTests/DeviceDetectorTests.swift` (NEW) | test | static function over temp /Volumes | `MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift` (static fn pattern at line 89-94) | role-match |

---

## Pattern Assignments

### `Database/DatabaseManager.swift` (extend — register `v_sync_toggles`)

**Analog:** self — `v20_playlist_cover_custom` (line 605-611) for additive boolean; `v13_playlist_path_prefix` (line 433-439) for existing alter-on `sync_profiles`. Both use `if try !db.columns(in:).contains(where: { $0.name == ... })` for idempotence.

**Naming convention** (verified via grep — line 571-617): project uses BOTH numeric (`v20_…`) and unnumbered semantic prefixes (`v_search_text_column`, `v_organized_path_index`, `v_sort_indexes`, `v_migrations_tracking`). RESEARCH.md picks `v_sync_toggles` to match unnumbered semantic style and avoid confusion if other contributors add `v18`/`v19` in parallel.

**Reference excerpt — single boolean add (DatabaseManager.swift:605-611):**
```swift
migrator.registerMigration("v20_playlist_cover_custom") { db in
    if try !db.columns(in: "playlists").contains(where: { $0.name == "cover_is_custom" }) {
        try db.alter(table: "playlists") { t in
            t.add(column: "cover_is_custom", .integer).notNull().defaults(to: 0)
        }
    }
}
```

**Reference excerpt — multi-column add on `sync_profiles` (DatabaseManager.swift:444-464, the v14 LUFS pattern with one-by-one guards):**
```swift
migrator.registerMigration("v14_lufs_columns") { db in
    if try !db.columns(in: "tracks").contains(where: { $0.name == "lufs_i" }) {
        try db.alter(table: "tracks") { t in
            t.add(column: "lufs_i", .double)
        }
    }
    if try !db.columns(in: "tracks").contains(where: { $0.name == "lufs_range" }) {
        try db.alter(table: "tracks") { t in
            t.add(column: "lufs_range", .double)
        }
    }
    // … repeat per column
}
```

**Adaptation note:** Phase 38 has 4 columns to add; use the v14 per-column guard pattern (not the v20 single-`alter` block) so a partial migration from an aborted run can resume. Each column gets its own `if try !db.columns(in: "sync_profiles").contains` check + single `alter`. Defaults must match D-01: `generate_m3u8=0`, `transcode_mode='keep_originals'`, `fat32_safe_paths=1`, `cleanup_removed_files=1`.

---

### `Models/SyncProfile.swift` (extend)

**Analog:** self — the existing `SyncProfile` struct (line 8-35). Adds 4 fields matching the migration columns, plus a `TranscodeMode` enum.

**Reference excerpt — current struct (Models/SyncProfile.swift:8-35):**
```swift
struct SyncProfile: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    var id: Int64?
    var name: String
    var outputFolder: String
    var playlistPathPrefix: String
    var dateCreated: String?
    var dateModified: String?

    static let databaseTableName = "sync_profiles"

    enum CodingKeys: String, CodingKey {
        case id, name
        case outputFolder = "output_folder"
        case playlistPathPrefix = "playlist_path_prefix"
        case dateCreated = "date_created"
        case dateModified = "date_modified"
    }
    // … Columns enum, didInsert
}
```

**Adaptation note:** Add 4 new stored properties (`generateM3U8: Bool`, `transcodeMode: String`, `fat32SafePaths: Bool`, `cleanupRemovedFiles: Bool`) with matching `CodingKeys` (snake_case for DB). GRDB maps SQLite `INTEGER 0/1` to Swift `Bool` natively when the field type is `Bool`. Define `enum TranscodeMode: String { case keepOriginals = "keep_originals", aac248 = "aac_248", aac320 = "aac_320" }` in the same file; SyncProfile keeps `transcodeMode: String` for GRDB and exposes a computed `var transcodeModeEnum: TranscodeMode { TranscodeMode(rawValue: transcodeMode) ?? .keepOriginals }`.

---

### `Database/SyncRepository.swift` (extend `updateSettings`)

**Analog:** self — existing `updateSettings(profileId:name:outputFolder:playlistPathPrefix:)` line 153-181. Already uses optional-parameter / dynamic-SET pattern that scales cleanly.

**Reference excerpt — existing updateSettings (SyncRepository.swift:153-181):**
```swift
func updateSettings(profileId: Int64, name: String?, outputFolder: String?, playlistPathPrefix: String?) async throws {
    try await database.write { db in
        var sets: [String] = []
        var args: [DatabaseValueConvertible?] = []

        if let name {
            sets.append("name = ?")
            args.append(name)
        }
        if let outputFolder {
            sets.append("output_folder = ?")
            args.append(outputFolder)
        }
        if let playlistPathPrefix {
            sets.append("playlist_path_prefix = ?")
            args.append(playlistPathPrefix)
        }

        guard !sets.isEmpty else { return }
        sets.append("date_modified = datetime('now')")
        args.append(profileId)

        try db.execute(
            sql: "UPDATE sync_profiles SET \(sets.joined(separator: ", ")) WHERE id = ?",
            arguments: StatementArguments(args)
        )
    }
}
```

**Adaptation note:** Extend the signature with `generateM3U8: Bool?`, `transcodeMode: String?`, `fat32SafePaths: Bool?`, `cleanupRemovedFiles: Bool?` — one `if let …` block per parameter, append `"col = ?"` to `sets` and the value to `args`. Bool values must be passed as Int (1/0): `args.append(value ? 1 : 0)`. The `date_modified = datetime('now')` line is reused as-is.

---

### `ViewModels/SyncViewModel.swift` (extend with 5 mutation methods + cancel)

**Analog:** `ViewModels/PlaylistDetailViewModel.swift` line 84-156. Same MVVM shape: `addTracks([Int64])` → repo call → `loadTracks()` → `NotificationCenter.post(name:object:userInfo:)`. Mirrors D-08 + `.syncProfileDidChange` requirement perfectly.

**Reference excerpt — addTracks (PlaylistDetailViewModel.swift:84-108):**
```swift
@MainActor
func addTracks(_ trackIds: [Int64]) async {
    guard let playlistId = playlist.id else { return }

    let nextPosition = generateNextPosition()

    do {
        try await playlistRepository.addTracks(
            playlistId: playlistId,
            trackIds: trackIds,
            startPosition: nextPosition
        )
        await loadTracks()

        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistId": playlistId]
        )
    } catch {
        errorMessage = "Failed to add tracks: \(error.localizedDescription)"
    }
}
```

**Reference excerpt — removeSelectedTracks (PlaylistDetailViewModel.swift:113-136):**
```swift
@MainActor
func removeSelectedTracks() async {
    guard let playlistId = playlist.id else { return }
    do {
        for trackId in selectedTrackIDs {
            try await playlistRepository.removeTrack(
                playlistId: playlistId,
                trackId: trackId
            )
        }
        selectedTrackIDs.removeAll()
        await loadTracks()
        NotificationCenter.default.post(
            name: .playlistDidChange,
            object: nil,
            userInfo: ["playlistId": playlistId]
        )
    } catch {
        errorMessage = "Failed to remove tracks: \(error.localizedDescription)"
    }
}
```

**Existing SyncViewModel structure to extend (SyncViewModel.swift:1-107):** already `@Observable`, already has `profiles`, `selectedProfile`, `preview`, `loadPreview`, `executeSync`. The 5 new methods follow the exact same shape: guard `selectedProfile.id`, try repo call (`syncRepository.addTrack` etc., already exist in repo line 86-103, 184-201), then `await loadPreview(for: profile)` to refresh the preview-derived disk-space stats, then `NotificationCenter.default.post(name: .syncProfileDidChange, …)`.

**Adaptation note for cancel:** Add `func cancelSync()` that calls `syncService.cancelSync()` (which sets the flag inside the service). No await needed — `cancelSync` is sync-and-immediate; the running `executeSync` Task observes the flag and unwinds at the next loop iteration. Do not set `isSyncing = false` here — let the running task do it via its `defer`.

---

### `Services/Sync/SyncService.swift` (extend with cancel flag, cleanup-deletion branch, toggle-aware execute, retry)

**Analog:** self — existing `executeSync` line 140-223. Already `@Observable` with `isRunning`, `progress`, `currentFile` matching D-12 needs. Already has the per-file for-loop that needs a cancel check inserted.

**Reference excerpt — existing execute loop (SyncService.swift:153-215, abridged):**
```swift
isRunning = true
defer { isRunning = false }

var result = SyncResult()
let total = preview.filesToAdd.count + preview.filesToRemove.count
var processed = 0

// 1. Remove stale files
for file in preview.filesToRemove {
    try? await syncRepository.removeSyncState(
        profileId: profileId,
        trackId: file.trackId
    )
    processed += 1
    progress = Double(processed) / Double(max(total, 1))
}

// 2. Sync new files
for file in preview.filesToAdd {
    currentFile = "\(file.artist) - \(file.title)"
    progress = Double(processed) / Double(max(total, 1))
    do {
        if let track = try await trackRepository.fetchTrack(id: file.trackId) {
            if let cachedURL = try await transcodeCache.ensureCached(track: track) {
                // … hardlink + sync_state update
                result.syncedCount += 1
            } else {
                result.failedCount += 1
                result.failedTracks.append((file.trackId, "Transcode failed"))
            }
        }
    } catch {
        result.failedCount += 1
        result.failedTracks.append((file.trackId, error.localizedDescription))
    }
    processed += 1
}
```

**Reference excerpt — `@Observable` re-entry guard from ArtworkBackfillService (line 119-125):**
```swift
private func backfillMissing() async {
    isBackfilling = true
    progress = (0, 0)
    defer {
        isBackfilling = false
        inFlight.removeAll()
    }
    // …
}
```

**Adaptation notes — 4 distinct extensions:**

1. **Cancel flag** (D-14): add `private(set) var cancellationRequested = false` next to `isRunning`. `cancelSync()` sets it true. The loops in `executeSync` insert `if cancellationRequested { break }` *after* each `processed += 1` (D-14: check between files, never mid-transcode). Reset `cancellationRequested = false` at the start of `executeSync` (before the `defer`).

2. **Cleanup-deletion** (D-04, SYNC-v2-05): replace the existing `for file in preview.filesToRemove { try? await syncRepository.removeSyncState(…) }` block with a conditional:
   ```swift
   for file in preview.filesToRemove {
       if profile.cleanupRemovedFiles {
           // Try trashItem first (APFS/HFS+); fall back to removeItem (FAT32/exFAT)
           let url = URL(fileURLWithPath: file.destinationPath)
           if FileManager.default.fileExists(atPath: url.path) {
               var trashed: NSURL? = nil
               do {
                   try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
               } catch {
                   try? FileManager.default.removeItem(at: url)
               }
           }
       }
       try? await syncRepository.removeSyncState(profileId: profileId, trackId: file.trackId)
       processed += 1
       progress = Double(processed) / Double(max(total, 1))
       if cancellationRequested { break }
   }
   ```
   The trashItem-then-removeItem pattern is verified-already-in-codebase at `TrackContextMenu.swift:184-189` — reuse the same shape.

3. **Toggle-aware transcode** (SYNC-v2-19): the `transcodeCache.ensureCached(track:)` call currently always returns the 248k AAC. New behavior:
   - `profile.transcodeModeEnum == .keepOriginals`: skip TranscodeCache entirely, hardlink/copy `track.originalPath` (or `libraryRoot + organizedPath`) directly to the destination via `TranscodeCache.linkToProfile` (the linker function already accepts arbitrary source URLs).
   - `.aac248`: existing behavior, no change.
   - `.aac320`: requires `TranscodeCache.ensureCached` to accept a bitrate parameter — planner decides whether to extend that signature or stage 320k as a follow-up. CONTEXT D-19 explicitly allows aac_320 in scope, so planner must wire the bitrate parameter through `TranscodeService` (currently hard-coded 248k).

4. **M3U8 gate** (SYNC-v2-20): wrap the existing `try await generatePlaylists(…)` call at line 218 in `if profile.generateM3U8 { … }`.

5. **Retry single track** (SYNC-v2-17): add `func executeSync(profileId:onlyTrackIds:[Int64]?) async throws -> SyncResult` overload (or expose internal helper) so the Retry button can re-run just one trackId. Easier than parameterizing — copy the for-loop into a `private func syncSingleTrack(profileId:trackId:)` helper, call from both the loop body and the public retry method.

---

### `Utilities/Notifications.swift` (add `.syncProfileDidChange`)

**Analog:** self — existing declarations at line 20-87. Already has `.syncDidComplete` at line 62, `.playlistDidChange` at line 47, `.trackArtworkDidChange` at line 57.

**Reference excerpt — Notifications.swift:47-57:**
```swift
/// Posted when a playlist is created, deleted, renamed, pinned, or its tracks change.
///
/// Observers should reload playlist data. Used to keep PlaylistsView,
/// TrackContextMenu submenu, and SidebarView in sync.
static let playlistDidChange = Notification.Name("MLMPlaylistDidChange")

/// Posted by `ArtworkBackfillService` after successful embedded-art extraction + DB save.
/// - `userInfo["trackId"]`: `Int64` — track whose artwork was updated
/// - `userInfo["artworkPath"]`: `String` — absolute path to cached artwork file
static let trackArtworkDidChange = Notification.Name("MLMTrackArtworkDidChange")
```

**Adaptation note:** Add under the existing `// MARK: Sync (reserved for Phase 12)` section, replacing the "(reserved)" marker. Use `Notification.Name("MLMSyncProfileDidChange")` — the `MLM` prefix matches every existing project notification. Document `userInfo["profileId"]: Int64` so observers can filter.

---

### `Views/Sync/SyncProfileDetailView.swift` (extract + refactor)

**Analog:** self — currently embedded inline at `SyncView.swift:202-362`. Phase 38 extracts it into its own file (per UI-SPEC Component Inventory) and replaces the `previewSection` with conditional Settings + Content + Progress + Result subsections.

**Reference excerpt — existing header + preview + result layout (SyncView.swift:227-289):**
```swift
var body: some View {
    ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            // Header (name + outputFolder + Refresh + Sync Now button)
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name).font(MLMFont.title2)
                    Text(profile.outputFolder).font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                }
                Spacer()
                Button("Refresh") { onRefresh() }.disabled(isLoading)
                Button("Sync Now") { onSync() }
                    .disabled(isSyncing || !(preview?.hasSufficientSpace ?? false))
                    .buttonStyle(.borderedProminent)
            }
            // … disabledReason label, Divider, previewSection, error label, resultSection
        }
        .padding(16)
    }
    .background(Color.mlmBase)
}
```

**Reference excerpt — PlaylistDetailView refresh-on-notification (PlaylistDetailView.swift:55-71):**
```swift
.task {
    initializeViewModel()
    await viewModel?.loadTracks()
}
.onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
    Task { await viewModel?.refresh() }
}
.onAppear {
    // Revalidate when view becomes visible
    guard let pid = playlist.id else { return }
    NotificationCenter.default.post(
        name: .playlistDidChange,
        object: nil,
        userInfo: ["playlistId": pid]
    )
}
```

**Adaptation note:** Keep the existing header HStack (it already has the right Sync Now button + disabledReason logic). Below the Divider, switch on `isSyncing` to choose between `SyncProgressSection(syncService:)` (when running) and `previewSection` (idle). Add the new `SyncSettingsForm`, `SyncContentSections`, and `SyncFailedDisclosure` as siblings inside the VStack. Mirror the PlaylistDetailView `.onReceive(.syncProfileDidChange)` pattern to trigger `vm.loadPreview()` on any cross-view mutation.

---

### `Views/Sync/SyncSettingsForm.swift` (NEW)

**Analog:** **Partial — no existing SwiftUI `Form` with Toggle+Picker bound to a `@Bindable` ViewModel** exists in MLM. Closest distant cousin: `Views/Settings/SettingsView.swift` (Form section layout — read for shape, but the binding model differs).

**Reference excerpt — closest local pattern (Toggle binding from PlaylistViewModel use in PlaylistsView):** see how `var pinLimitHintMessage` is consumed in views. For Picker-on-enum bindings, the codebase has no in-repo example — the planner can lean on Apple's standard SwiftUI shape:
```swift
Form {
    Section(header: Text("Einstellungen").font(MLMFont.sectionLabel)) {
        Toggle("M3U8-Playlisten generieren", isOn: $generateM3U8)
        Picker("Transcode-Modus", selection: $transcodeMode) {
            Text("Originals behalten").tag("keep_originals")
            Text("248 kbps AAC").tag("aac_248")
            Text("320 kbps AAC").tag("aac_320")
        }
        Toggle("FAT32-sichere Dateinamen", isOn: $fat32SafePaths)
        Toggle("Gelöschte Dateien vom Ziel entfernen", isOn: $cleanupRemovedFiles)
    }
}
```

**Adaptation note:** Implement as a SwiftUI struct wrapping a `DisclosureGroup` (UI-SPEC line 149 — collapsed by default) with four `@State` mirrors of the profile fields. `.onChange(of:)` on each `@State` triggers `Task { await viewModel.updateProfileSettings(...) }`. Use the same `MLMFont.sectionLabel` + `Color.mlmSurface` background as `SyncView.profileList` header (SyncView.swift:42-55) for visual consistency.

---

### `Views/Sync/Pickers/PlaylistPickerSheet.swift` (NEW)

**Analog:** `Views/Playlists/PlaylistDetailView.swift` line 223-247 (List with `selection:` binding) + line 178-219 (search field). Plus `PlaylistRepository.fetchAll` (PlaylistRepository.swift:17-21) as the data source.

**Reference excerpt — List with Set<Int64> selection (PlaylistDetailView.swift:223-247):**
```swift
private func trackList(_ viewModel: PlaylistDetailViewModel) -> some View {
    List(selection: Binding(
        get: { viewModel.selectedTrackIDs },
        set: { viewModel.selectedTrackIDs = $0 }
    )) {
        ForEach(Array(viewModel.displayedTracks.enumerated()), id: \.element.id) { index, track in
            trackRow(track, index: index + 1, viewModel: viewModel)
                .listRowBackground(
                    viewModel.selectedTrackIDs.contains(track.id ?? -1)
                        ? Color.mlmAccent.opacity(0.15)
                        : Color.clear
                )
                .listRowSeparator(.hidden)
        }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
    .background(Color.mlmBase)
}
```

**Reference excerpt — search field (PlaylistDetailView.swift:180-197):**
```swift
HStack(spacing: 4) {
    Image(systemName: "magnifyingglass")
        .font(.system(size: 11))
        .foregroundColor(.mlmInkMuted)
    TextField("Search tracks…", text: Binding(
        get: { viewModel.searchQuery },
        set: { viewModel.searchQuery = $0 }
    ))
    .textFieldStyle(.plain)
    .font(MLMFont.body)
    .foregroundColor(.mlmInk)
    .frame(width: 140)
}
.padding(.horizontal, 8)
.padding(.vertical, 5)
.background(Color.mlmRaised)
.clipShape(RoundedRectangle(cornerRadius: 6))
```

**Adaptation note:** Sheet shape is `VStack { titleBar, searchField, List(selection:), HStack { Cancel, Add(N) } }`. The List driver is `playlistRepository.fetchAll()` filtered by `searchText.lowercased()`. On "Hinzufügen" click: call `vm.addPlaylists(Array(selectedIds))` then `dismiss()`. UI-SPEC line 248-291 documents the exact dimensions (400×500) and German copy.

---

### `Views/Sync/Pickers/TrackPickerSheet.swift` (NEW)

**Analog:** `Views/Library/LibraryTable.swift` line 53-120 for `Table(selection:)` shape; `TrackRepository.fetchLocalTracks` (line 43-48) + `TrackRepository.search` (line 98-108) as data source; `PlaylistDetailViewModel.applyFilter` line 266-277 for in-memory case-insensitive filter.

**Reference excerpt — virtualized Table with Set<Int64> selection (LibraryTable.swift:54):**
```swift
Table(rows, selection: $viewModel.selectedTrackIDs, sortOrder: $sortOrder) {
    TableColumn("Title", value: \.track.title) { row in
        // …
    }
    .width(min: 160, ideal: 280)
    // …
}
```

**Reference excerpt — search filter (PlaylistDetailViewModel.swift:266-277):**
```swift
private func applyFilter() {
    if searchQuery.isEmpty {
        displayedTracks = tracks
    } else {
        let query = searchQuery.lowercased()
        displayedTracks = tracks.filter { track in
            track.title.lowercased().contains(query) ||
            track.artist.lowercased().contains(query) ||
            track.album.lowercased().contains(query)
        }
    }
}
```

**Adaptation note:** UI-SPEC says use SwiftUI `List` (not `Table`) for the picker — `List` virtualizes natively for 10k+ rows. The selection-binding shape is identical: `List(selection: $selectedIds)` plus `ForEach(filteredTracks, id: \.id)`. Local in-memory `applyFilter` is sufficient because all-local-tracks fits in RAM; no need to round-trip `TrackRepository.search` per keystroke (search hits SQLite, slower than in-memory `lowercased().contains()`). Sheet dimensions 500×600 per UI-SPEC line 318-320.

---

### `Views/Sync/SyncContentSections.swift` (NEW — Playlists + Tracks lists)

**Analog:** `Views/Playlists/PlaylistDetailView.swift` line 251-339. Exact match for the row + hover-trash + context-menu remove pattern.

**Reference excerpt — trackRow with context menu (PlaylistDetailView.swift:251-307):**
```swift
private func trackRow(_ track: Track, index: Int, viewModel: PlaylistDetailViewModel) -> some View {
    HStack(spacing: 8) {
        Text("\(index)").font(MLMFont.dataSmall).foregroundColor(.mlmInkMuted)
        VStack(alignment: .leading, spacing: 1) {
            Text(track.title).font(MLMFont.tableCell).foregroundColor(.mlmInk).lineLimit(1)
            Text(track.artist).font(MLMFont.muted).foregroundColor(.mlmInkSecondary).lineLimit(1)
        }
        Spacer()
        // album, format badge, duration
    }
    .padding(.vertical, 6)
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { onTrackDoubleClick?(track) }
    .contextMenu {
        trackContextMenu(track, viewModel: viewModel)
    }
}

@ViewBuilder
private func trackContextMenu(_ track: Track, viewModel: PlaylistDetailViewModel) -> some View {
    Button {
        trackToDelete = track
        showDeleteConfirmation = true
    } label: {
        Label("Remove from Playlist", systemImage: "minus.circle")
    }
    // … reveal in finder etc.
}
```

**Reference excerpt — hover detection (PlaylistCard.swift:68-72):**
```swift
.onHover { hovering in
    withAnimation(.easeInOut(duration: 0.15)) {
        isHovered = hovering
    }
}
```

**Adaptation note:** Two parallel DisclosureGroups (default collapsed per UI-SPEC line 405), one for Playlists, one for Tracks. Each row uses `.onHover { isHovered = $0 }` plus an opacity-modulated trash icon. ContextMenu has a single `Button(role: .destructive) { Task { await vm.removePlaylists([id]) } }`. The selection-state for multi-select-bulk-remove comes from a `@State var selectedPlaylistIds: Set<Int64>` and `@State var selectedTrackIds: Set<Int64>` held in the section view; bulk Remove button shows when count >= 1 (mirror PlaylistDetailView line 208-217 "Remove selected" pattern).

---

### `Views/Sync/SyncProgressSection.swift` (NEW)

**Analog:** Existing stat-card layout in `SyncView.previewSection` (SyncView.swift:291-332) for the visual shape; `@Observable` binding (read directly from `container.syncService.progress` / `.currentFile`).

**Reference excerpt — stat card layout (SyncView.swift:297-325):**
```swift
HStack(spacing: 24) {
    VStack {
        Text("\(preview.filesToAdd.count)")
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .foregroundColor(.green)
        Text("To Add").font(MLMFont.muted)
    }
    // … repeat for ToRemove, NewSize, Available
}
```

**Adaptation note:** Layout per UI-SPEC line 415-422: header row with counter + Cancel button, then full-width `ProgressView(value: syncService.progress)`, then `Text(syncService.currentFile)` truncated single-line. Cancel button: `.tint(.mlmError)` and `Button(role: .destructive)` — match the existing PlaylistDetailView "Remove N" button shape (PlaylistDetailView.swift:208-217). Bind the view to the service through the container: `@Environment(\.container) var container; let syncService = container.syncService` and read `.progress` directly (it's `@Observable`, so SwiftUI re-renders automatically).

---

### `Views/Sync/SyncFailedDisclosure.swift` (NEW)

**Analog:** **Partial.** No DisclosureGroup-of-failures exists. Closest local DisclosureGroup pattern: `Views/Sidebar/PinnedPlaylistsDisclosure.swift` (project uses DisclosureGroup for pinned playlists in sidebar) — read for the shape, not the content.

**Reference structure (apply to failures):**
```swift
DisclosureGroup(
    isExpanded: $isExpanded,
    content: {
        ForEach(failedTracks, id: \.0) { trackId, errorMessage in
            VStack(alignment: .leading, spacing: 4) {
                Text(trackTitleLookup[trackId] ?? "Unknown")
                    .font(MLMFont.body).foregroundColor(.mlmInk)
                Text(errorMessage)
                    .font(MLMFont.muted).foregroundColor(.mlmError)
                    .lineLimit(2)
                Button("Wiederholen") {
                    Task { await vm.retryFailedTrack(trackId) }
                }
                .buttonStyle(.borderless)
                .tint(.mlmAccent)
            }
            .padding(.vertical, 8)
        }
    },
    label: {
        Text("Fehlgeschlagene Tracks (\(failedTracks.count))")
            .font(MLMFont.bodyBold)
            .foregroundColor(.mlmInk)
    }
)
```

**Adaptation note:** Default collapsed (`@State var isExpanded = false`). The retry button calls a new `SyncViewModel.retryFailedTrack(trackId:)` method (planner adds this to VM); under the hood that calls the `SyncService` per-track helper described in the SyncService section above.

---

### `Views/Sync/SyncToolbarIndicator.swift` (NEW)

**Analog:** **NO ANALOG** — Phase 37's `ArtworkBackfillService.isBackfilling` flag exists but is never read by any view (verified via `grep "isBackfilling"` returning only the service file + tests). D-11 explicitly invokes a Phase-37 pattern that does not visually exist; this is a known gap documented in RESEARCH.md Open Question #1.

**Closest distant cousin — toolbar item hosting** (ContentView.swift:117-123):
```swift
.toolbar {
    ToolbarItem(placement: .principal) {
        if let vm = container.playbackViewModel {
            PlayerBar(viewModel: vm)
        }
    }
}
```

**Adaptation note (greenfield design — planner has full discretion):**
1. **View shape:** `HStack(spacing: 4) { ProgressView().controlSize(.small); Text("\(processed)/\(total)") }`. Render only when `container.syncService?.isRunning == true`.
2. **Placement:** add a second `ToolbarItem(placement: .primaryAction)` (UI-SPEC line 501) sibling to the existing `.principal` PlayerBar in `ContentView.swift:117-123`.
3. **Click action:** capture `@Binding var selectedSection: SidebarSection` (already in ContentView line 45). On tap, `selectedSection = .sync`.
4. **Hidden state:** wrap the entire item content in `if let svc = container.syncService, svc.isRunning { … }` — SwiftUI's `ToolbarItem` collapses cleanly when its content is empty.
5. **Persist across routes:** since the toolbar is attached to `NavigationSplitView` in ContentView (not the detail view), the indicator survives `selectedSection` changes automatically.

Implementation gap: if the planner finds toolbar layout crowding, RESEARCH.md fallback is "indicator visible only in SyncView itself" — but D-11 prefers global, so attempt global first.

---

### `Views/Sync/SyncToast.swift` (NEW)

**Analog:** **NO ANALOG.** No toast component exists. Closest local pattern: transient `pinLimitHintMessage` / `coverDropErrorMessage` state on `PlaylistViewModel` (line 36-46) consumed as an inline banner by `PlaylistsView` (mentioned in PlaylistViewModel docstring). That pattern uses `@State` + scheduled `Task.sleep` auto-clear — not a true overlay toast.

**Adaptation note (greenfield, but constrained by UI-SPEC line 672-700):**
1. **Implementation:** SwiftUI `.overlay` on the SyncView root with `@State var showRockboxToast = false` + a 3-second `Task.sleep` auto-dismiss timer.
2. **Pattern reference for auto-clear timer:** PlaylistViewModel line 36-46 docstring mentions `pinLimitHintMessage` is "auto-clears 3 seconds after `togglePin` hard-blocks" — same approach (`Task { try? await Task.sleep(for: .seconds(3)); showRockboxToast = false }`).
3. **Trigger:** when `createProfile` succeeds and `shouldApplyDeviceDefaults == true`, set `showRockboxToast = true`.
4. **Styling:** per UI-SPEC line 692-698 — `Color.mlmRaised` background with `Color.mlmSuccess` 4px left border, `checkmark.circle.fill` icon, German copy "Rockbox iPod erkannt — Device-Defaults aktiviert".

Implementation gap: the entire toast UI surface is new. Planner should keep it minimal — one struct, ≤80 LOC, no animation library dependency.

---

### `Views/Playlists/PlaylistCard.swift` (extend `contextMenuItems` with "Sync to ▸")

**Analog:** `Views/Library/TrackContextMenu.swift` line 60-79 — the existing "Add to Playlist" submenu is the exact shape.

**Reference excerpt — "Add to Playlist" submenu (TrackContextMenu.swift:60-79):**
```swift
Section {
    Menu {
        if availablePlaylists.isEmpty {
            Text("No playlists")
        } else {
            ForEach(availablePlaylists) { playlist in
                Button {
                    addToPlaylist(playlist)
                } label: {
                    HStack {
                        if playlist.isPinned == 1 {
                            Image(systemName: "pin.fill")
                        }
                        Text(playlist.name)
                    }
                }
            }
        }
    } label: {
        Label("Add to Playlist\(countSuffix)", systemImage: "text.badge.plus")
    }
    .disabled(selectedTracks.isEmpty)
}
```

**Existing PlaylistCard contextMenuItems to extend (PlaylistCard.swift:180-222):** already has Open / Rename / Pin / Reset / Delete. Insert the "Sync zu ▸" submenu before the Delete section.

**Adaptation note:** PlaylistCard doesn't currently observe sync profiles. The planner must either (a) thread `availableSyncProfiles: [SyncProfile]` and `onAddToSyncProfile: (SyncProfile.ID) -> Void` callbacks through from the parent (`PlaylistsView`), mirroring how `availablePlaylists` is threaded into LibraryTable→TrackContextMenu, or (b) capture them via `@Environment(\.container)` directly inside the card. Option (a) matches the existing TrackContextMenu pattern; prefer it.

Submenu logic per D-05/UI-SPEC line 543-553: if `availableSyncProfiles.isEmpty`, show only "Neues Profil erstellen…"; else show profile names + Divider + "Neues Profil erstellen…" entry.

---

### `Views/Library/TrackContextMenu.swift` (replace disabled placeholder line 83-90)

**Analog:** Same file — line 60-79 (the "Add to Playlist" submenu, already-working pattern). Pure swap-in: replace the disabled placeholder Button with a live Menu.

**Reference excerpt — current placeholder to replace (TrackContextMenu.swift:83-90):**
```swift
Section {
    Button {
        // Placeholder — Phase 12
    } label: {
        Label("Add to Sync Profile…", systemImage: "arrow.triangle.2.circlepath")
    }
    .disabled(true)
}
```

**Adaptation note:** Mirror the line 60-79 shape exactly. New props `availableSyncProfiles: [SyncProfile]` (threaded from LibraryTable → LibraryView, like `availablePlaylists`); new private method `addToSyncProfile(_ profile: SyncProfile)` that calls `container.syncViewModel?.addTracks(Array(selectedTrackIDs))` after setting `selectedProfile = profile`. Multi-select-aware: when `selectedTracks.count > 1`, add ALL selected (D-05 + UI-SPEC line 594-596). Posts `.syncProfileDidChange` automatically via the VM.

---

### `Views/ContentView/ContentView.swift` (add SyncToolbarIndicator to `.toolbar`)

**Analog:** self — existing `.toolbar` block at line 117-123.

**Reference excerpt (ContentView.swift:117-123):**
```swift
.toolbar {
    ToolbarItem(placement: .principal) {
        if let vm = container.playbackViewModel {
            PlayerBar(viewModel: vm)
        }
    }
}
```

**Adaptation note:** Add a second `ToolbarItem(placement: .primaryAction) { SyncToolbarIndicator(selectedSection: $selectedSection) }` inside the existing `.toolbar { … }` block. Pass the existing `$selectedSection` binding so the indicator can route the user to `.sync` on click.

---

## Shared Patterns

### Notification Post & Observe

**Source:** `Utilities/Notifications.swift` declaration + post pattern from `ViewModels/PlaylistDetailViewModel.swift:100-104` and observe pattern from `Views/Playlists/PlaylistDetailView.swift:59-61`.

**Apply to:** All SyncViewModel mutation methods (addPlaylists, addTracks, removePlaylists, removeTracks, updateProfileSettings); PlaylistCard / TrackContextMenu submenu actions; SyncProfileDetailView (observe to refresh preview).

**Post excerpt:**
```swift
NotificationCenter.default.post(
    name: .syncProfileDidChange,
    object: nil,
    userInfo: ["profileId": profileId]
)
```

**Observe excerpt:**
```swift
.onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { _ in
    Task { await vm.loadPreview(for: profile) }
}
```

---

### MVVM Async Mutation Boilerplate

**Source:** `ViewModels/PlaylistDetailViewModel.swift:84-156`.

**Apply to:** All 5 new SyncViewModel methods (D-08).

```swift
@MainActor
func <mutationName>(<args>) async {
    guard let profileId = selectedProfile?.id else { return }
    do {
        try await syncRepository.<repoCall>(...)
        if let profile = selectedProfile {
            await loadPreview(for: profile)
        }
        NotificationCenter.default.post(
            name: .syncProfileDidChange,
            object: nil,
            userInfo: ["profileId": profileId]
        )
    } catch {
        errorMessage = error.localizedDescription
    }
}
```

---

### Solar Design Tokens

**Source:** `Theme/Colors.swift`, `Theme/Typography.swift`.

**Apply to:** Every new view. Mandatory per project MEMORY ("macOS-App native look", no Solar palette deviation).

Tokens used in Phase 38 (verified via UI-SPEC §Color):
- Backgrounds: `Color.mlmBase` (window), `Color.mlmSurface` (panels/rows), `Color.mlmRaised` (hover/elevated)
- Text: `Color.mlmInk` (primary), `Color.mlmInkSecondary` (secondary), `Color.mlmInkMuted` (placeholders/muted)
- Action: `Color.mlmAccent` (Sync Now, Cancel, Retry, Detect-device button)
- Destructive: `Color.mlmError` (trash icons, Delete)
- Edge: `Color.mlmEdge`, `Color.mlmEdgeSubtle` (separators, card strokes)
- Fonts: `MLMFont.body`, `MLMFont.bodyBold`, `MLMFont.muted`, `MLMFont.sectionLabel`, `MLMFont.title2`, `MLMFont.badge`

---

### `trashItem` then `removeItem` Cross-FS Fallback

**Source:** `Views/Library/TrackContextMenu.swift:184-189`.

**Apply to:** `SyncService.executeSync` cleanup-deletion branch (D-04 / SYNC-v2-05).

```swift
if let url = await resolveLocalURL(for: track) {
    var trashed: NSURL? = nil
    try? FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
}
```

For sync (FAT32 destination must work too — Trash on FAT32 fails, fall back to `removeItem`):
```swift
do {
    try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
} catch {
    try? FileManager.default.removeItem(at: url)
}
```

---

### NSOpenPanel Folder Browse

**Source:** `Views/Sync/SyncView.swift:142-152` (createProfileSheet).

**Apply to:** Edit-profile dialog (if added) and any future folder-browse surface.

```swift
let panel = NSOpenPanel()
panel.canChooseDirectories = true
panel.canChooseFiles = false
panel.canCreateDirectories = true
panel.allowsMultipleSelection = false
panel.prompt = "Choose"
if panel.runModal() == .OK, let url = panel.url {
    newProfileOutput = url.path
}
```

---

### In-Memory GRDB Test Setup

**Source:** `MLMTests/ViewModelTests/PlaylistViewModelTests.swift:18-23` and `MLMTests/ServiceTests/ArtworkBackfillServiceTests.swift:20-32`.

**Apply to:** All 4 new test files (SyncMigrationTests, SyncViewModelTests, SyncServiceTests, DeviceDetectorTests).

```swift
private func makeViewModel() throws -> (DatabaseQueue, SyncRepository, SyncViewModel) {
    let db = try DatabaseManager.inMemory()
    let repo = SyncRepository(database: db)
    let syncService = SyncService(/* mocked deps */)
    let vm = SyncViewModel(syncRepository: repo, syncService: syncService)
    return (db, repo, vm)
}
```

`DatabaseManager.inMemory()` runs the full migrator including `v_sync_toggles`, so the new columns are exercised on every test run.

---

### Column Existence + Default Verification Test

**Source:** `MLMTests/DatabaseTests/PlaylistRepositoryCoverTests.swift:22-41`.

**Apply to:** `SyncMigrationTests` — verify each of the 4 new columns exists with the correct default after a fresh in-memory migration.

```swift
@Test func syncProfilesHasGenerateM3U8Column() async throws {
    let db = try DatabaseManager.inMemory()
    try await db.read { db in
        let columns = try db.columns(in: "sync_profiles").map(\.name)
        #expect(columns.contains("generate_m3u8"))
    }
}

@Test func generateM3U8DefaultIsZero() async throws {
    let db = try DatabaseManager.inMemory()
    try await db.write { db in
        try db.execute(sql: "INSERT INTO sync_profiles (name, output_folder, playlist_path_prefix) VALUES ('T', '/tmp', '')")
        let value = try Int.fetchOne(db, sql: "SELECT generate_m3u8 FROM sync_profiles WHERE name = 'T'")
        #expect(value == 0)
    }
}
```

---

## No Analog Found

| File | Role | Data Flow | Reason | Recommendation |
|------|------|-----------|--------|----------------|
| `Views/Sync/SyncToolbarIndicator.swift` | view | global toolbar item | RESEARCH Open Q #1: Phase 37 `ArtworkBackfillService.isBackfilling` flag never bound to a visible toolbar item. The "analog from Phase 37" cited in D-11 does not exist. | Greenfield design constrained by UI-SPEC Surface 8 (line 497-525). Use `ContentView.swift:117-123` ToolbarItem pattern as host skeleton. Keep view ≤ 60 LOC. |
| `Views/Sync/SyncToast.swift` | view | overlay banner | No SwiftUI toast component exists in MLM. Closest cousin (`pinLimitHintMessage` inline banner) is a banner, not a toast. | Greenfield. Implement via `.overlay` on SyncView root with `@State` + `Task.sleep(for: .seconds(3))` auto-dismiss. UI-SPEC Surface 12 (line 672-700) is the visual spec. |
| `Views/Sync/SyncSettingsForm.swift` | view | SwiftUI Form w/ Picker | No existing SwiftUI `Form` with Toggle+Picker bound to a `@Bindable` ViewModel inside MLM (Settings exists but uses different shape). | Use Apple-standard `Form { Section { Toggle…, Picker… } }`. Wrap in `DisclosureGroup(isExpanded: $expanded)` for the collapse default per UI-SPEC. |
| `Views/Sync/SyncFailedDisclosure.swift` | view | DisclosureGroup of records | No DisclosureGroup-of-failures exists. `PinnedPlaylistsDisclosure.swift` shows DisclosureGroup shape but content is different. | Use standard SwiftUI `DisclosureGroup` with ForEach over `result.failedTracks`. Retry button calls new `vm.retryFailedTrack(trackId:)` method. |

These four files are net-new design work — the planner has explicit UI-SPEC guidance for each. The pattern map flags them as "no direct analog" so the planner allocates extra design+review time vs. the analog-driven copy work elsewhere.

---

## Metadata

**Analog search scope:**
- `macos-app/MLM/Database/` (all 8 repositories + DatabaseManager.swift)
- `macos-app/MLM/Models/` (SyncProfile, Playlist, Track, Album, Source, AppModels)
- `macos-app/MLM/ViewModels/` (Sync, PlaylistDetail, Playlist, Library, Folder, Import, ReviewQueue, Activity, Sources, Download, Playback)
- `macos-app/MLM/Services/Sync/` (SyncService, TranscodeCache, DeviceDetector)
- `macos-app/MLM/Services/Artwork/` (ArtworkBackfillService — D-11 reference)
- `macos-app/MLM/Views/Sync/` (existing SyncView + embedded SyncProfileDetailView)
- `macos-app/MLM/Views/Playlists/` (PlaylistCard, PlaylistDetailView, PlaylistsView)
- `macos-app/MLM/Views/Library/` (LibraryTable, TrackContextMenu)
- `macos-app/MLM/Views/ContentView/` (ContentView toolbar host)
- `macos-app/MLM/Utilities/Notifications.swift`
- `macos-app/MLMTests/` (ViewModelTests, ServiceTests, DatabaseTests)

**Files scanned:** ~30 Swift sources + 8 test files

**Pattern extraction date:** 2026-05-17

*Phase: 38-folder-device-sync-v2-0-macos-native*
