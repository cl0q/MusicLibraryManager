# Phase 38: Folder & Device Sync (v2.0 macOS Native) - Context

**Gathered:** 2026-05-17
**Status:** Ready for planning

<domain>
## Phase Boundary

Sync-Subsystem in der macOS-App zum „endlich benutzen können"-Loop fertigstellen: Playlists und Library-Auswahlen in einen Zielordner kopieren+transcoden, Device-Sync (Rockbox-iPod mit M3U8 + 248k AAC) als Spezialfall via Toggle-Settings auf demselben Profile-Typ. Der Code-Backbone ist zu ~75% da; Phase 38 schließt die UI- und UX-Lücken, damit der User seine kuratierten Playlists tatsächlich auf externe SSDs oder iPod ziehen kann.

**Bereits gebaut (keine Re-Implementation):**
- `macos-app/MLM/Services/Sync/SyncService.swift` (267 LOC) — `previewSync()` + `executeSync()` + interne `generatePlaylists()` für M3U8 voll funktional. State: `isRunning`, `progress`, `currentFile` publishbar.
- `macos-app/MLM/Services/Sync/TranscodeCache.swift` (174 LOC) — Hardlink-basierter Cache, `buildProfilePath()` mit Library-Hierarchy-Preserve + Fallback `Artist/Album/Title.m4a`, SHA256-Checksum, Cross-Filesystem-Copy-Fallback.
- `macos-app/MLM/Services/Sync/DeviceDetector.swift` (47 LOC) — `.rockbox`-Scan in `/Volumes`, gibt `[RockboxDevice]` mit mountPoint + deviceName + availableSpace zurück. **Aktuell nirgendwo aufgerufen.**
- `macos-app/MLM/Database/SyncRepository.swift` (205 LOC) — komplettes CRUD: `fetch*`, `create`, `delete`, `addTrack`/`addPlaylist`, `removeTrack`/`removePlaylist`, `updateSettings(name?, outputFolder?, playlistPathPrefix?)`, `addRule`/`removeRule`, `updateSyncState`/`removeSyncState`.
- `macos-app/MLM/Models/SyncProfile.swift` — `SyncProfile`, `SyncProfileTrack`, `SyncProfilePlaylist`, `SyncProfileRule`, `SyncState` als GRDB-Records.
- `macos-app/MLM/Database/DatabaseManager.swift` — Migration `v4_sync_profiles` (Z. 250-299) + `playlist_path_prefix` Spalten-Add (Z. 434).
- `macos-app/MLM/ViewModels/SyncViewModel.swift` (107 LOC) — `@Observable` mit `loadProfiles`/`createProfile`/`deleteProfile`/`loadPreview`/`executeSync`. **Fehlt:** Add/Remove-Content-Methoden, Settings-Update-Methoden.
- `macos-app/MLM/Views/Sync/SyncView.swift` (362 LOC) — HSplitView mit Profile-List + `SyncProfileDetailView` (Preview-Stats + Sync-Now-Button + Result-Section). **Fehlt:** Add/Remove-Content-UI, Edit-Profile-UI, Toggles für Behavior, Live-Progress-Anzeige.
- `macos-app/MLM/Services/Download/TranscodeService.swift` — `transcode(input:outputDir:)` lossless→248k AAC mit Cover-Art-Preserve (`-c:v copy -disposition:v attached_pic`), Fallback `-vn` bei Cover-Stream-Errors. libfdk_aac → aac Encoder-Detection. Skip-Logik für Lossy <248kbps. Wird von `TranscodeCache.ensureCached()` aufgerufen.
- `macos-app/MLM/Services/Common/ProcessRunner.swift` — `findExecutable("ffmpeg")` Pattern.
- `macos-app/MLM/App/DependencyContainer.swift` (Z. 86, 163-170) — SyncRepository + TranscodeCache + SyncService + SyncViewModel sind im Container exposed.
- `macos-app/MLM/Views/ContentView/ContentView.swift` (Z. 161-162, 249, 267, 278, 290) — `.sync` Route, ⌘4 Shortcut, Sidebar-Eintrag „Sync" mit `arrow.triangle.2.circlepath` Icon.
- v1.0 Tauri Pendant: `src-tauri/src/sync/{cache,device,profile,playlist_gen,progress}.rs` als Inspiration für offene UX-Details.

**Echte Gaps, die Phase 38 schließt:**
1. Keine UI zum Hinzufügen von Playlists/Tracks zu einem Profil (Repo-API ready, Buttons fehlen)
2. `DeviceDetector` wird nirgendwo aufgerufen → Rockbox-iPod-Plug-in ist UX-Tod
3. Keine Trennung Folder-Profile vs Device-Profile (alles transcoded fix zu 248k AAC, M3U8 wird immer generiert)
4. Keine Edit-UI (Rename, Output-Folder ändern, playlistPathPrefix)
5. `executeSync` löscht nur `sync_state`-Row, NICHT die tatsächliche m4a-Datei vom Zielordner (Bug ODER Feature — siehe D-04)
6. `SyncService.progress`/`currentFile` werden im SyncView gar nicht angezeigt → User sieht nur „Sync Now" → „done"
7. `lastResult.failedTracks` wird nicht visualisiert (Result-Section zeigt nur Count)

**Out of scope (für Phase 38):**
- Filter-Rules-UI (`SyncProfileRule` Modell bleibt, kein UI in dieser Phase — manual selection only).
- Drag-and-Drop „Playlist auf Profile-Card droppen" — Polish-Folge-Phase.
- Bulk-Bar-Action „Add selection to Sync Profile" — verschoben in spätere Phase, sobald Picker + Context-Menu sich gesetzt haben.
- Dedicated „Devices"-Sidebar-Section (Apple-Music-Style) — DeviceDetector wird stattdessen on-demand im Create-Sheet gerunnt.
- Background-Polling / NSWorkspace-Mount-Observer für iPod-Detection — kein Banner, keine Auto-Pop-Up-UI.
- Per-Profile Transcode-Format-Wahl jenseits {Keep originals, 248k AAC, 320k AAC} — z.B. Opus/MP3 ist Folge-Phase.

</domain>

<decisions>
## Implementation Decisions

### Profile-Modell — Folder vs Device

- **D-01:** **Ein Profile-Typ mit expliziten Toggles, kein `kind`-Feld.** Schema-Erweiterung `sync_profiles` bekommt neue Spalten via Migration v6 (oder die nächste freie Version):
  - `generate_m3u8 INTEGER NOT NULL DEFAULT 0`
  - `transcode_mode TEXT NOT NULL DEFAULT 'keep_originals'` — enum: `keep_originals`, `aac_248`, `aac_320`
  - `fat32_safe_paths INTEGER NOT NULL DEFAULT 1` — Always-on by default (PathSanitizer existiert bereits)
  - `cleanup_removed_files INTEGER NOT NULL DEFAULT 1` — siehe D-04
- **D-02:** **UI-Surface dieser Toggles im SyncProfileDetailView Settings-Section** — kollabierbare Section unter dem Header, vor Preview. SwiftUI `Form` mit `Toggle` + `Picker` für transcode_mode. Editierbar zur Laufzeit; nach Edit triggert automatisch neue Preview-Berechnung (Disk-Pfade können sich ändern weil transcode-Modus → File-Größe-Estimate).
- **D-03:** **Smart-detect Defaults beim Create eines neuen Profils** — Wenn der gewählte `outputFolder` (Browse-Result) auf einem Volume mit `.rockbox`-Directory liegt, schalten die Device-Defaults automatisch an: `generate_m3u8 = 1`, `transcode_mode = 'aac_248'`, `fat32_safe_paths = 1`, `cleanup_removed_files = 1`. UI zeigt nicht-blockierenden Toast „Rockbox iPod erkannt — Device-Defaults aktiviert". User kann jederzeit nachträglich togglen.
- **D-04:** **`cleanup_removed_files` steuert Disk-Deletion-Semantik.** Wenn `true` (Default für neue Profile): bei `executeSync` werden die m4a-Files in `preview.filesToRemove` tatsächlich von Disk gelöscht (nicht nur `sync_state`-Row clearen). Wenn `false`: nur `sync_state`-Row löschen, File bleibt für User-manual-cleanup. Diese Entscheidung fixt das aktuelle Bug-/Quirk-Verhalten in `SyncService.executeSync` Z. 161-169.

### Content hinzufügen — Add-to-Profile UX

- **D-05:** **MUST-have für Phase 38 ship** — zwei Mechanismen:
  - **Picker-Sheet im Profile-Detail.** Im `SyncProfileDetailView` zwei Buttons unter Header: „Add Playlists…" und „Add Tracks…". Sheet öffnet Multi-Select-Liste aller verfügbaren Playlists bzw. aller Tracks (mit Search-Filter). Select + Done ruft `SyncViewModel.addPlaylists([Int64])` / `addTracks([Int64])`.
  - **Context-Menu „Sync to…" an der Quelle.** `PlaylistCard.contextMenu` und `TrackContextMenu` bekommen Submenu „Sync to ▸ <Profile-Name>…" mit allen existierenden Profilen + Bottom-Eintrag „Create new profile…". Click ruft `addPlaylist`/`addTrack` und postet `.syncProfileDidChange`-Notification. Multi-Selektion in der LibraryTable funktioniert via existing TrackContextMenu (alle selected Tracks werden hinzugefügt, analog zu „Add to Playlist").
- **D-06:** **Polish-Folge (NICHT in Phase 38):**
  - Drag-and-Drop „Playlist auf Profile-Card droppen" — Deferred.
  - Bulk-Bar Action „Add selection to Sync Profile" (Phase 19 Multi-Select-Bar Erweiterung) — Deferred.
- **D-07:** **Profile-Detail zeigt zugewiesenen Content in zwei Sektionen:**
  - „Playlists (3)" Liste — Row pro Playlist mit Name + Track-Count + Hover-Trash-Icon. ContextMenu „Remove from Profile". Multi-Select via Click+Shift, „Remove" Bulk-Action.
  - „Tracks (12)" Liste — Row pro direkt zugewiesenem Track (Artist — Title), gleiches Pattern.
  - Removal **ausschließlich** über diese Sektionen, kein Toggle-Off-Checkmark im Sync-To-ContextMenu an der Quelle (D-05 ist Add-only).
- **D-08:** **`SyncViewModel` Erweiterungen für Phase 38:**
  - `addPlaylists([Int64]) async`
  - `addTracks([Int64]) async`
  - `removePlaylists([Int64]) async`
  - `removeTracks([Int64]) async`
  - `updateProfileSettings(name?, outputFolder?, generateM3U8?, transcodeMode?, fat32SafePaths?, cleanupRemovedFiles?, playlistPathPrefix?) async`
  - Nach jeder Mutation: Re-Load der Preview UND Post `.syncProfileDidChange` Notification.

### Rockbox-iPod Auto-Detection UX

- **D-09:** **On-demand DeviceDetector im Create-Sheet — kein Background-Polling, kein Sidebar-Indicator.** Im `createProfileSheet` neben dem „Browse…"-Button ein zusätzliches Dropdown-Button „Detect device ▸". Click ruft `DeviceDetector.detectRockboxDevices()`. Dropdown listet alle Hits (Name + freier Speicher als Suffix). Selection setzt:
  - `newProfileOutput` = `device.mountPoint`
  - Falls noch leer: `newProfileName` = `"<deviceName> iPod"` als Suggestion
  - Markiert intern „Device-Defaults aktivieren" → beim `createProfile` werden die Smart-Defaults aus D-03 angewendet
- **D-10:** **Empty-State im Detect-Dropdown:** Wenn keine `.rockbox`-Volumes gefunden, zeigt das Dropdown einen disabled Eintrag „Keine Geräte gefunden — angeschlossen?". Kein Error, kein modaler Alert.

### Sync-Execution — Progress, Cancel, Errors

- **D-11:** **Toolbar-Indikator-Pattern analog Phase 37 ArtworkBackfillService.** Während `SyncService.isRunning = true`:
  - Kleiner Spinner + Counter (`23/145`) in der globalen Toolbar-Trailing-Area (TitleBar-Region). Sichtbar **über alle Routes** hinweg, nicht nur auf der `.sync`-Route — User soll wegnavigieren können und der Sync läuft im Background weiter.
  - Click auf Indikator → springt zu `.sync` und selektiert das laufende Profile in der List.
- **D-12:** **Im SyncProfileDetailView wird während `isRunning` die Preview-Stats-Section durch eine Live-Progress-Section ersetzt:**
  - SwiftUI `ProgressView(value: progress)` (linear, full-width)
  - `Text("\(currentFile)")` — „Artist — Title"
  - `Text("\(processed) of \(total)")` — counter
  - „Cancel"-Button rechts. Cancel setzt internes Flag, `executeSync` checkt zwischen jedem Track und bricht sauber ab → restliche `filesToAdd` bleiben unverarbeitet (kein `sync_state`-Update für sie), bereits gesynchte Files bleiben am Zielort + in `sync_state`.
- **D-13:** **Failed-Tracks-UX kombiniert beide Mechanismen:**
  - **Result-Section nach Run:** zeigt `"\(synced) synced, \(failed) failed"`. Bei `failed > 0` ist die `failedTracks`-Liste expandable (`DisclosureGroup`, default collapsed) mit Row pro Eintrag (Track-Title + Error-Message). Pro Row ein „Retry"-Button, der nur diesen einen Track erneut durch `executeSync`-Pfad schickt (single-track variant).
  - **Implicit Auto-Retry:** Failed Tracks sind nicht in `sync_state`, also fallen sie beim nächsten `previewSync` automatisch wieder in `filesToAdd`. Beide Verhalten sind kompatibel — explizit (Retry-Button für sofortige Action) + implizit (next sync räumt's auf).
- **D-14:** **Cancellation-Semantik:** `SyncService` bekommt `cancelSync()` Methode, setzt `cancellationRequested: Bool` Flag. Die per-File-Schleife in `executeSync` checkt das Flag **nach jedem File** (nicht mit Cooperative-Task-Cancellation, um saubere `sync_state`-Updates pro Track zu garantieren). Bei Cancel: `currentFile = ""`, `isRunning = false`, `progress` bleibt am letzten Wert. Result-Section zeigt „Sync cancelled — N synced, M skipped".

### Aus Scope ausgeschlossen (für Phase 38)

- **D-15 [informational]:** Filter-Rules-UI (`SyncProfileRule`). Modell + DB-Tabelle bleiben unangetastet, kein UI. Manual selection (D-05/D-07) reicht für den Daily-Driver-Loop.
- **D-16 [informational]:** Drag-and-Drop Playlist auf Profile. Macht erst Sinn, wenn Sidebar-Profile-Surface existiert — separate Phase.
- **D-17 [informational]:** Bulk-Bar Action „Add selection to Sync Profile". Phase 19 Multi-Select-Bar wird nicht erweitert in Phase 38.
- **D-18 [informational]:** „Devices"-Sidebar-Section / NSWorkspace-Mount-Observer / Auto-Banner bei iPod-Plug-In. D-09 (on-demand im Create-Sheet) ist die explizite Wahl gegen reactive Surfaces.
- **D-19 [informational]:** Transcode-Formate jenseits {keep, aac_248, aac_320}. Opus, MP3, FLAC-Passthrough sind Folge-Themen.

### Claude's Discretion

Diese Themen blieben absichtlich offen — Researcher/Planner entscheidet:

- **Migration-Versionsnummer und genaues Spalten-Naming** für die neuen sync_profiles-Spalten (D-01). `generate_m3u8` vs `m3u8_enabled` etc. Researcher prüft existing naming-conventions in `DatabaseManager.swift`.
- **Cancellation-Granularität exakt.** D-14 sagt „nach jedem File"; ob „mitten im Transcode" auch abgebrochen wird (würde ffmpeg-Subprocess-Kill bedeuten) ist Planner-Entscheidung. Default-Empfehlung: nein, fertig-Transcode + dann-Stop reicht.
- **Toolbar-Indicator-Detail-Look** (D-11). Phase 37 Artwork-Backfill als Vorbild, exact-pixel-positioning und Animation (Pulse? Static Spinner?) bleibt UI-Detail.
- **Test-Strategie.** Mindestens: `SyncService` Unit-Tests mit Mock-Repos für Preview/Execute/Cancel-Paths, `TranscodeCache` Hardlink-Fallback-Test mit cross-FS-Setup. Stretch: SyncView Snapshot-Test für Empty-State + In-Progress-State.
- **„Add Tracks…"-Picker UX bei großer Library** (>10k tracks). Search-Filter ist Pflicht, ob virtualisierte Liste (`List` mit `id:`) oder Pagination, ist Researcher-Detail.
- **`addPlaylist`-Idempotenz-Verhalten.** Repository nutzt `INSERT OR IGNORE` — Picker kann also Multi-Select ohne Pre-Filter machen. ViewModel-Methode sollte aber duplicate-aware sein für UI-Feedback („3 added, 1 already in profile").
- **Toolbar-Indicator-Hosting.** Phase 37 Pattern ist „in der globalen App-Toolbar". Wenn das Toolbar-Hosting komplex wird (TitleBar-Customization), Fallback: nur in SyncView selbst sichtbar + Notification-Sound o.Ä. wenn Sync von anderer Route fertig wird.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase-38-Spec & Roadmap

- `.planning/ROADMAP.md` §„Phase 38: Folder & Device Sync (v2.0 macOS Native)" — Goal, Driver, Depends-on, Anchor refs
- `macos-app/PLAN.md` §„Phase 7 — Sync" (im Phase-Plan-Abschnitt) — Original SwiftUI-Architektur-Skizze für SyncService + DeviceDetector + Views/Sync
- `.planning/STATE.md` — aktuelle Position (Phase 37 verifying)
- `.planning/PROJECT.md` — Core-Value-Statement und v2.0-Milestone-Scope

### Existing Implementation (READ before planning)

- `macos-app/MLM/Services/Sync/SyncService.swift` — Preview + Execute + M3U8-Generation funktional
- `macos-app/MLM/Services/Sync/TranscodeCache.swift` — Hardlink-Cache + `buildProfilePath()`
- `macos-app/MLM/Services/Sync/DeviceDetector.swift` — `.rockbox`-Scan (aktuell unused)
- `macos-app/MLM/Services/Download/TranscodeService.swift` — ffmpeg 248k AAC mit Cover-Art-Preserve
- `macos-app/MLM/Database/SyncRepository.swift` — komplettes CRUD
- `macos-app/MLM/Models/SyncProfile.swift` — alle GRDB-Records
- `macos-app/MLM/Database/DatabaseManager.swift` Z. 250-299 (v4_sync_profiles Migration) + Z. 434 (playlist_path_prefix Add)
- `macos-app/MLM/ViewModels/SyncViewModel.swift` — bestehende Methoden (loadProfiles/createProfile/deleteProfile/loadPreview/executeSync)
- `macos-app/MLM/Views/Sync/SyncView.swift` — HSplitView + SyncProfileDetailView
- `macos-app/MLM/App/DependencyContainer.swift` Z. 22, 49, 86, 163-170 — DI-Wiring für Sync-Stack
- `macos-app/MLM/Views/ContentView/ContentView.swift` Z. 161-162, 290 — `.sync` Route + ⌘4 Shortcut

### Pattern Inspiration

- `.planning/phases/37-album-art-pipeline-durchziehen-import-trigger-ui-anzeige-ffm/37-CONTEXT.md` — `ArtworkBackfillService` Toolbar-Indicator-Pattern und Background-Task-Service-Wiring im DependencyContainer (D-11/D-04 dort)
- `.planning/phases/36-playlists-v2-0-macos-native/36-CONTEXT.md` — Multi-Select + Drag-Reorder Patterns im Playlist-Detail (Inspiration für Profile-Detail Add/Remove-Sektionen)
- `macos-app/MLM/Views/Playlists/PlaylistDetailView.swift` — bestehende Multi-Select-Liste mit Hover-Trash + ContextMenu (D-07-Pattern)
- `macos-app/MLM/Views/Library/TrackContextMenu.swift` Z. 62-78 — „Add to Playlist"-Submenu als Vorlage für „Sync to ▸"-Submenu (D-05)
- `src-tauri/src/sync/{cache,device,profile,playlist_gen,progress}.rs` — v1.0 Tauri-Pendant für Verhalten-Vergleich bei UX-Details

### Solar Design / Conventions

- `macos-app/MLM/Resources/MLMFont.swift` und `Color+MLM.swift` Extensions (`mlmBase`, `mlmRaised`, `mlmSurface`, `mlmInkPrimary`, `mlmInkMuted`) — Pflicht für jede neue UI in Phase 38

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`SyncService.previewSync()`** liefert `SyncPreview` mit `filesToAdd`/`filesToRemove`/Space-Check — kann unverändert für UI-Counts genutzt werden
- **`TranscodeCache.buildProfilePath()`** statische Funktion macht den Profile-Output-Path korrekt — keine Path-Logik in Views nötig
- **`DeviceDetector.detectRockboxDevices()`** ist eine `static` enum-Funktion — kein State, direkt aus SwiftUI-Sheet aufrufbar
- **`PathSanitizer.sanitizeComponent()`** existiert bereits — wird für FAT32-Mode wiederverwendet
- **`PlaylistRepository.fetchTracks(playlistId:)`** + `TrackRepository.fetchAll()` — Quellen für Picker-Sheets
- **`@Observable` + `@Environment(\.container)`** + `container.syncViewModel` Pattern ist überall etabliert
- **Notification-Pattern:** `.libraryDidImport`, `.playlistDidChange`, `.trackArtworkDidChange` existieren in `Notifications.swift` — `.syncProfileDidChange` analog hinzufügen
- **`SyncService.SyncResult.failedTracks: [(Int64, String)]`** existiert schon, wird nur nicht angezeigt

### Established Patterns
- **MVVM mit DI** — alle Mutations gehen durch ViewModel, das hält Repository-Calls + State-Updates + Notification-Posts atomar
- **`Task { await … }` in SwiftUI-Buttons** für async Repository-Aufrufe
- **`@MainActor` für Service-States** die in UI gelesen werden (siehe `SyncService.isRunning/progress/currentFile` — schon `@Observable`)
- **NSOpenPanel für Folder-Browse** (bereits in `createProfileSheet` Z. 142-152) — Pattern für Edit-Dialog wiederverwendbar
- **GRDB `INSERT OR IGNORE`** für additive Sets (`addTrack`, `addPlaylist`) — Picker kann blind multi-select machen
- **Phase-37 Background-Task-Service-Pattern** (`ArtworkBackfillService` in DI-Container, observiert Notifications, hält Queue-State, postet Per-Item-Notifications) — passendes Vorbild falls Sync von „push-Sync" zu „auto-Sync-on-playlist-change" erweitert wird (NICHT in Phase 38, aber Architektur-kompatibel halten)

### Integration Points
- **Migration**: nächste freie Schema-Version in `DatabaseManager.swift` (Phase 37 hat v5 belegt, Phase 38 wird v6)
- **`Notifications.swift`**: neue Notification `.syncProfileDidChange` einführen, in `SyncViewModel` + Add-from-Source-Punkten posten
- **`PlaylistCard.contextMenu`** (Phase 36) + **`TrackContextMenu.swift`** Z. 62-78 — Submenu „Sync to ▸" eingeben, analog zum existing „Add to Playlist"-Submenu
- **`ContentView.swift`** Toolbar-Region — falls Toolbar-Indicator-Hosting global gemacht wird (D-11), hier landet das View-Element
- **`SyncProfileDetailView`** — größter Refactor-Surface: Settings-Section + Content-Sektionen + Progress-Section + Result-Section
- **`createProfileSheet`** — Detect-device-Dropdown Hinzufügen (Z. 139-153 Erweiterung)
- **`SyncViewModel`** — neue Methoden (D-08), Cancellation-Flag, Smart-detect-Logic beim createProfile

</code_context>

<specifics>
## Specific Ideas

- **„Endlich benutzen können"-Test:** der User muss in Phase 38 erstmals seinen iPod anstecken, eine Sync-Profile dafür erstellen, eine seiner Playlists (z.B. „Spotify-Favorites" oder „Club-Set-2026") draufschieben können, syncen, und am Ende auf dem iPod Rockbox-seitig die M3U8-Playlist sehen + die 248k-AAC-Files abspielen können. **Das ist das Phase-38-Verification-Szenario.**
- **Phase-37-Toolbar-Indicator-Pattern** wird explizit als Vorbild für D-11 referenziert — D-11 sagt „analog zu Phase 37 ArtworkBackfillService".
- **Phase-36-Multi-Select-Pattern** (Playlist-Detail mit `List`-onMove + ContextMenu) ist die Inspiration für die Content-Sektionen in D-07.
- **„Sync to ▸ \<Profile\>"** ist die explizite Naming-Wahl (D-05) — kein „Add to Sync Profile", weil Daily-Driver-Verb-Konsistenz mit „Sync Now"-Button.
- **Toast „Rockbox iPod erkannt — Device-Defaults aktiviert"** (D-03) ist die einzige Smart-Detect-UI-Surface — kein modaler Alert.

</specifics>

<deferred>
## Deferred Ideas

- **Filter-Rules-UI** für `SyncProfileRule` (Tag = X, Format = lossless, BPM > Y). Modell + DB bleiben, kein UI in Phase 38. Eigene Folge-Phase wenn Bedarf entsteht.
- **Drag-and-Drop „Playlist auf Profile-Card droppen"** — Polish-Layer, sobald Sidebar-Profile-Surface existiert.
- **Bulk-Bar-Action „Add selection to Sync Profile"** — Erweiterung der Phase-19-Multi-Select-Batch-Bar. Klein, billig, aber bewusst aus Phase 38 raus.
- **Dedicated „Devices"-Sidebar-Section** (Apple-Music-Style) mit Live-Mount-Detection via NSWorkspace.didMountNotification. Folge-Phase, wenn iPod-Workflow sich gesetzt hat.
- **Auto-Sync bei Playlist-Change** (Background-Service observiert `.playlistDidChange` und re-runt Sync). Architektur (D-11-Pattern, Notification-System) ist kompatibel — bewusst deferred, weil Manual-Sync-First explizite Wahl ist.
- **Sync zu Cloud-Targets** (Dropbox, iCloud Drive, S3). Out-of-scope für v2.0 — folder-sync ist disk-target-only.
- **Per-Track-Sync-Status-Anzeige in der LibraryTable** (Badge „auf 2 Devices synced"). Folge-Phase wenn Sync-Discoverability ein Thema wird.
- **Transcode-Formate jenseits AAC** (Opus, MP3, FLAC-Passthrough). Folge-Phase.
- **Smart-Playlist-Sync** (Rule-based: „alle Tracks mit Tag=club" auto-sync). Hängt an Filter-Rules-UI; eigene Phase.

### Reviewed Todos (not folded)

- **`audio-analysis-ux-cleanup.md`** (Score 0.6, generic match auf „source/gsd/user" Keywords) — nicht gefoldet weil thematisch unrelated (Audio-Analysis ist Loudness/Fingerprinting-Domain, nicht Sync). Bleibt im Pending-Pool für Phase 22 Yeat-Resume oder eigene UX-Cleanup-Phase.

</deferred>

---

*Phase: 38-folder-device-sync-v2-0-macos-native*
*Context gathered: 2026-05-17*
