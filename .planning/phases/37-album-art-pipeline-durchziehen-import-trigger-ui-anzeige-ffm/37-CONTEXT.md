# Phase 37: Album-Art-Pipeline durchziehen (Import-Trigger + UI-Anzeige + ffmpeg-Pfad) - Context

**Gathered:** 2026-05-15
**Status:** Ready for planning

<domain>
## Phase Boundary

Album-Art systematisch durch MLM ziehen — Import-Pipeline triggert automatisch eine Embedded-Artwork-Extraktion (ffmpeg, Background-Queue), LibraryTable + TrackDetailView + PlayerBar zeigen das Cover (mit Solar-Gradient-Fallback), und die Phase-36-Cover-Pipeline wird auf den ffmpeg-Pfad umgestellt (statt AVFoundation `commonMetadata`, das bei FLAC/manchen MP3s inkonsistent ist).

**Treiber (aus ROADMAP.md):** Phase-36-UAT hat sichtbar gemacht, dass `ArtworkService.swift` (mit bewährtem ffmpeg-Subprocess) zwar existiert, aber nur via Settings → Maintenance manuell läuft — niemand triggert ihn beim Import. Album-Art ist in MLM bisher nirgendwo in der UI sichtbar. Phase 37 schließt diese drei Lücken: Trigger, UI-Anzeige, ffmpeg-Konsolidierung.

**Bereits gebaut (keine Re-Implementation):**
- `macos-app/MLM/Services/Analysis/ArtworkService.swift` — ffmpeg-Subprocess-Pfad + MusicBrainz-Fallback (private extractEmbeddedArtwork, batchFetchArtwork, saveResized auf 500+1200)
- `macos-app/MLM/Services/Playlists/ArtworkExtractor.swift` — AVFoundation-Wrapper (Phase 36) — wird zu thin wrapper um ArtworkService umgebaut
- `macos-app/MLM/Database/AnalysisRepository.swift` — fetchArtwork/saveArtwork ready
- `macos-app/MLM/Database/DatabaseManager.swift` — `artwork`-Tabelle (v5 migration: track_id, artwork_path, source, musicbrainz_release_group_id, resolution, fetched_at)
- `macos-app/MLM/App/DependencyContainer.swift` — analysisRepository injected, PlaylistCoverService init-Pattern (Z. 122-133) für ArtworkBackfillService kopierbar
- `macos-app/MLM/Services/Common/ProcessRunner.swift` — `findExecutable("ffmpeg")` Pattern etabliert

**Out of scope (aus ROADMAP.md):**
- MusicBrainz-Bulk-Fetch beim Import (Rate-Limit) — bleibt Settings-Maintenance-only
- Cover-Editor / Crop-UI für Track-Artwork
- Live-Lyrics / andere Metadata-Bereicherung

</domain>

<decisions>
## Implementation Decisions

### Import-Trigger & Background-Backfill

- **D-01:** **Post-Import-Background-Queue** — Artwork-Extraktion läuft NICHT inline im Import-Pipeline-Chunk-Loop, sondern startet erst nachdem der letzte `saveBatch` committed ist und `.libraryDidImport` gepostet wurde. Import-Speed bleibt unberührt; Tracks erscheinen kurz ohne Cover (Solar-Gradient-Fallback), dann poppen die Bilder nach.
- **D-02:** **TaskGroup mit fixer Concurrency 4** für die Backfill-Queue — `withTaskGroup`, max 4 parallele ffmpeg-Subprocesses. Mirrors den Import-Pipeline-Chunk-Loop. Schont CPU auch bei Initial-Library-Import mit tausenden Tracks; bewahrt vor Thermal-Throttling auf älteren Macs.
- **D-03:** **Per-Track Notification** `.trackArtworkDidChange` (userInfo: `["trackId": Int64, "artworkPath": String]`) wird nach jedem erfolgreichen Extract gepostet. LibraryTable + andere Surfaces observieren und re-rendern nur die betroffene Row. Inkrementelles "Bilder poppen rein"-Verhalten.
- **D-04:** **Owner = neuer `ArtworkBackfillService`** im `DependencyContainer`, analog zu `PlaylistCoverService` aus Phase 36: `@MainActor @Observable`, hält Queue + Progress-State, wird via `await MainActor.run { … }` im `initialize()` instanziiert. Bedient sowohl den Auto-Import-Trigger (observiert `.libraryDidImport`) als auch die manuelle Maintenance-Action „Refresh embedded artwork".

### ffmpeg-Konsolidierung & API-Surface

- **D-05:** **Single-Source-API:** `ArtworkService.extractEmbeddedArtwork(from:)` wird `static` + `public`. `ArtworkExtractor.extract(audioURL:)` (Phase 36) wird zu thin wrapper um diesen Aufruf — Signatur bleibt `async -> Data?`, sodass `PlaylistCoverService:112` unverändert weiterläuft, aber jetzt den ffmpeg-Pfad nutzt.
- **D-06:** **Signatur:** `static func extractEmbeddedArtwork(from url: URL) async -> Data?` — async (Subprocess in `Task.detached`), liefert raw bytes. Kein Result-Struct, kein Resize-im-Method — Caller (BackfillService bzw. PlaylistCoverService) entscheidet, was mit den Bytes passiert.
- **D-07:** **ffmpeg-Missing-Verhalten:** Silent return `nil` + einmaliger `AppLogger.warn("ffmpeg not found — artwork extraction disabled")`. Matches `FingerprintService`, `ReplayGainAnalyzer`, `TranscodeService`. UI fällt automatisch auf Solar-Gradient zurück, kein User-facing Error-Banner.
- **D-08:** **Cache-Resolutions:** Beim Backfill werden BEIDE Größen geschrieben — `{trackId}_500.jpg` (für Thumbnail-Surfaces) und `{trackId}_1200.jpg` (für TrackDetailView). `ArtworkService.saveResized` macht das bereits; BackfillService nutzt dieselbe Helfer-Methode.

### UI-Cover-Rendering & Fallback

- **D-09:** **Shared `TrackArtworkCache`** — `NSCache<NSNumber, NSImage>` mit `countLimit = 200`. Cache-Key: `"\(trackId)_\(size.rawValue)"`. Memory-bounded; bei 1000+ Rows in der Tabelle bleibt der Speicher beschränkt, während aktive Viewport-Rows schnell gerendert werden.
- **D-10:** **Custom `TrackCoverView`** (SwiftUI), nimmt `trackId: Int64`, `size: ArtworkService.ArtworkSize`, optional `cornerRadius`. View löst per `Task` aus dem Cache (oder von Disk via `NSImage(contentsOfFile:)`), zeigt während des Loads den Fallback. Observiert `.trackArtworkDidChange` und invalidiert Cache+Reload wenn `trackId` matcht.
- **D-11:** **Fallback-Look:** `RoundedRectangle(cornerRadius: …)` mit linearGradient `Color.mlmBase → Color.mlmRaised` (Solar-Palette) + zentriertes `Image(systemName: "music.note")` (foregroundStyle `.mlmInkMuted`). Funktioniert in allen drei Sizes ohne Layout-Anpassung. Konsistent mit existing `TrackDetailView`-Header-Look.
- **D-12:** **Smart-Resolution pro Surface:**
  - LibraryTable Title-Spalte: 18pt thumbnail aus `{trackId}_500.jpg`
  - PlayerBar `coverThumbnail`: 40pt aus `{trackId}_500.jpg`
  - TrackDetailView Header: 56-128pt aus `{trackId}_1200.jpg`
- **D-13:** **LibraryTable-Platzierung:** Inline links neben Title in der existierenden Title-Spalte — `HStack(spacing: 8) { TrackCoverView ; nowPlayingIndicator? ; Text(title) }`. Title-Spalte Min-Width bleibt 140; ideal-Width ggf. leicht erhöhen falls visuell gedrängt.

### Schema-Quelle, Re-Extract & Maintenance-Compat

- **D-14:** **Source-of-Truth = DB-Row + File-Existence-Check.** `TrackCoverView` und `ArtworkBackfillService` lesen `AnalysisRepository.fetchArtwork(trackId:)` UND prüfen `FileManager.fileExists(atPath:)`. Wenn DB sagt „ja" aber File weg (User hat `~/Library/Caches/com.mlm.artwork_cache` geleert), triggert `TrackCoverView` einen Re-Backfill für dieses einzelne Track. Self-Healing.
- **D-15:** **Kein automatisches Re-Extract bei bestehenden Tracks.** Cover ist „sticky once extracted". File-Mtime-Checks beim Re-Scan kosten extra `stat()`-Calls und wurden bewusst NICHT gewählt. User-File-Replace wird über Settings → Maintenance „Refresh embedded artwork" abgedeckt.
- **D-16:** **Maintenance-View Split** (Roadmap-Success-#6): „Fetch Artwork" wird zu zwei Buttons:
  - **„Refresh embedded artwork"** — `ArtworkBackfillService.refreshAll()` (oder `refreshMissing()`): ffmpeg-Backfill mit Concurrency 4, kein Network, keine Rate-Limit. Default-Action für „die meisten Tracks haben jetzt Cover".
  - **„Fetch from MusicBrainz"** — alter `ArtworkService.batchFetchArtwork`-Pfad mit 1s Rate-Limit. Separate Button, expliziter User-Trigger. Filter: nur Tracks ohne `artwork`-Row (embedded fehlgeschlagen).
- **D-17:** **Source-Anzeige in UI:** NICHT sichtbar. `artwork.source` (`embedded` vs `musicbrainz`) bleibt nur in der DB für Debug/Stats; UI zeigt nur „Cover oder Fallback". Kein Badge, keine Metadata-Row.

### Aus Scope ausgeschlossen (für Phase 37)

- **D-18 [informational]:** MusicBrainz-Auto-Trigger beim Import. Rate-Limit (1 req/s) macht das beim Initial-Import unbrauchbar. Bleibt Settings-Maintenance-only Action.
- **D-19 [informational]:** Cover-Crop-UI / Edit-UI für Track-Artwork. Phase 36 deckt Playlist-Cover via Drop; Track-Cover-Edit ist eigene Phase, falls überhaupt.
- **D-20 [informational]:** File-Mtime-getriebenes Auto-Re-Extract. Bewusst nicht gewählt — User-File-Replace ist selten genug, dass eine Maintenance-Action ausreicht.

### Claude's Discretion

Diese Themen blieben absichtlich offen — Researcher/Planner entscheidet:

- **Konkrete Cache-LRU-Eviction-Strategy** für `TrackArtworkCache`. `NSCache` evicted automatisch unter Memory-Pressure; ob zusätzliche `countLimit`-Tweaks (200 ist initial-Vorschlag) oder `totalCostLimit` (geschätzte Image-Bytes als Kosten) sinnvoll sind, muss Researcher messen.
- **`refreshMissing()` vs `refreshAll()`**-Granularität im neuen `ArtworkBackfillService`. Maintenance-Button „Refresh embedded" sollte mindestens missing-only-Mode haben (idempotent, schnell bei großer Library); ob full-refresh als Modifier (z.B. ⌥-Click) angeboten wird, ist UI-Detail.
- **Progress-UI während Backfill.** Roadmap sagt „blockt UI nicht", aber ob ein dezenter Toolbar-Indikator („Indexing artwork: 423/1200…") sinnvoll ist, oder ob die Per-Track-Notifications visuell genug Feedback geben, entscheidet Planner. Optional: ActivityViewModel-Integration analog zu Downloads.
- **Test-Strategie.** Mindestens: ArtworkBackfillService Unit-Tests mit Mock-FileSystem + Mock-ProcessRunner (für Concurrency-4-Verhalten); TrackCoverView Snapshot-Test für Fallback-State. Stretch: E2E-Import-Test mit echtem Sample-FLAC, prüft dass nach Import die DB-Row + 2 Cache-Files existieren.
- **`AppDelegate`/`ContentView`-Wire-up.** `ArtworkBackfillService` muss als `@Environment(\.container)` exposed werden; ob neue View ihn direkt liest oder ob nur LibraryTable den Reload triggert ist Detail.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase-37-Spec & Roadmap

- `.planning/ROADMAP.md` §"Phase 37: Album-Art-Pipeline durchziehen" — Goal, Anchor refs, Success criteria, Out of scope
- `.planning/PROJECT.md` §"Current Milestone" (v2.0 macOS Native) — milestone scope
- `.planning/STATE.md` — aktuelle Position (Phase 36 abgeschlossen, Phase 37 kickoff)
- `.planning/phases/36-playlists-v2-0-macos-native/36-CONTEXT.md` §"Cover-Image-Quelle & Layout" — D-01..D-06 — Phase 36 Cover-Logik, die in Phase 37 auf ffmpeg umgestellt wird
- `macos-app/PLAN.md` §"Phase 6 — Playlists" — Original SwiftUI-Architektur-Skizze, Container-DI-Pattern

### Existing Implementation (MUST READ before planning)

- `macos-app/MLM/Services/Analysis/ArtworkService.swift` — ffmpeg-Subprocess (Z. 119-150), MusicBrainz-Fetch (Z. 154-196), `saveResized` (Z. 200-209), `batchFetchArtwork` (Z. 59-114). `extractEmbeddedArtwork` ist aktuell `private`/instance — wird `static public` (D-05/D-06)
- `macos-app/MLM/Services/Playlists/ArtworkExtractor.swift` — komplett 30 LOC. Wird in Phase 37 thin-wrapper-fied (D-05). PlaylistCoverService:112 nicht anfassen
- `macos-app/MLM/Services/Playlists/PlaylistCoverService.swift` — Phase-36-Pattern für `@MainActor @Observable` Service + Notification-Observer + Re-Entry-Guard via `userInfo["origin"]`. Vorbild für `ArtworkBackfillService`
- `macos-app/MLM/Services/Import/ImportService.swift` — Pipeline orchestrator. KEINE Inline-Änderung — Trigger läuft nach `.libraryDidImport`. `chunked(into:)` Helper aus Z. 322-331 evtl. wiederverwendbar in BackfillService
- `macos-app/MLM/Services/Import/MetadataExtractor.swift` — touched NICHT artwork. Reference für AVFoundation→AVAsset-Pattern (irrelevant für Phase 37, da wir auf ffmpeg gehen)
- `macos-app/MLM/Database/AnalysisRepository.swift` — `fetchArtwork(trackId:)` (Z. 32) + `saveArtwork(_:)` (Z. 39) — beide ready. `Artwork`-Model (track_id, artwork_path, source, musicbrainz_release_group_id, resolution, fetched_at)
- `macos-app/MLM/Database/DatabaseManager.swift` §"Migration v5" — `artwork`-Tabelle. KEINE neue Migration in Phase 37 nötig — Schema schon richtig
- `macos-app/MLM/App/DependencyContainer.swift` Z. 122-133 — Pattern für `@MainActor`-Service-Init im `initialize()`. ArtworkBackfillService analog einbauen
- `macos-app/MLM/Views/Settings/MaintenanceView.swift` Z. 170-195 — `runArtwork()` — der heutige einzige ArtworkService-Trigger. Wird auf zwei Buttons split (D-16)

### UI-Surfaces (alle drei MUSS modifiziert)

- `macos-app/MLM/Views/Library/LibraryTable.swift` — Title-Spalte Z. 54-68. Cover-Thumbnail wird inline neben Title eingefügt (D-13). `isNowPlaying`-Indicator bleibt erhalten
- `macos-app/MLM/Views/Track/TrackDetailView.swift` — Header `headerSection` Z. 65-78. `RoundedRectangle` + `music.note`-Icon wird zu `TrackCoverView(trackId: …, size: .large)` mit Fallback-Built-In
- `macos-app/MLM/Views/Player/PlayerBar.swift` Z. 67-78 — `coverThumbnail` ist aktuell hardcoded `music.note`-Placeholder. Wird zu `TrackCoverView(trackId: viewModel.currentTrack?.id, size: .small)` mit gleicher 40pt-Bounds

### Notification-Topology

- `macos-app/MLM/Models/Notifications.swift` — `.libraryDidImport` (existiert), `.playlistDidChange` (Phase 36 Pattern für origin-Guard). Neue Notification `.trackArtworkDidChange` muss hier hinzugefügt werden mit userInfo-Schema `{trackId: Int64, artworkPath: String}`

### Common Utilities

- `macos-app/MLM/Services/Common/ProcessRunner.swift` — `findExecutable("ffmpeg")` + `run(_:arguments:)` Pattern (siehe FingerprintService:14/29, ReplayGainAnalyzer:22/40, TranscodeService:27/138)
- `macos-app/MLM/Utilities/AppLogger.swift` — `.warn` Channel für ffmpeg-Missing (D-07)

### Cache-Verzeichnis-Pattern

- `~/Library/Caches/com.mlm.artwork_cache/{trackId}_{500|1200}.jpg` — etabliert in `MaintenanceView.runArtwork` Z. 177-179. `BackfillService` muss denselben Cache-Pfad nutzen, damit Maintenance-Action und Auto-Trigger denselben Speicher teilen
- macOS `FileManager.SearchPathDirectory.cachesDirectory` — bereits in mehreren Services verwendet

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets

- **`ArtworkService.saveResized(data:trackId:)`** (Z. 200-209) — schreibt large+small in einem Call. Direkt von `ArtworkBackfillService` aufrufbar nach `extractEmbeddedArtwork` (private auf instance method aktuell — muss static helper extrahiert werden, oder Service-Instanz wird wiederverwendet)
- **`ArtworkService.cachedPath(trackId:size:)`** — single canonical path-resolver. Sowohl BackfillService als auch TrackCoverView müssen das nutzen (KEIN eigener Pfad-Aufbau)
- **`AnalysisRepository.fetchArtwork` + `saveArtwork`** — komplette DB-Schicht ready. Kein neuer SQL-Code in Phase 37 nötig
- **`PlaylistCoverService` Re-Entry-Guard-Pattern** (Z. 64-78) — `userInfo["origin"] = "coverService"` filtert eigene Notifications. ArtworkBackfillService sollte analog `["origin": "artworkBackfill"]` taggen, falls cross-talk-Risiko besteht (eher niedrig, da BackfillService nicht selbst `.trackArtworkDidChange` als Trigger lauscht)
- **`Array.chunked(into:)`** (`ImportService.swift:322-331`) — Helper für Concurrency-Chunks im TaskGroup-Pattern (D-02)
- **`@Environment(\.container) private var container`** + `container.analysisRepository` — DI für neue View `TrackCoverView` und neuer Service
- **`PlayerBar.coverThumbnail`** Z. 69-78 ist eine isolierte private property — clean swap-Target

### Established Patterns

- **`@Observable` `@MainActor` Service** — siehe `PlaylistCoverService`. Async-Methoden hopen über Suspension-Points; Actor-Isolation hält State konsistent. `ArtworkBackfillService` MUSS dem folgen
- **`NotificationCenter.default.addObserver(forName:object:queue:)` mit `[weak self]`** + `Task { @MainActor [weak self] in … }` Re-Entry-Pattern — `PlaylistCoverService:64-90`
- **`ProcessRunner.findExecutable` lazy in Service-Init oder pro-Call** — beide Patterns existieren. Für `ArtworkService.extractEmbeddedArtwork` als static ist pro-Call OK (cached intern via ProcessRunner)
- **`NSCache` für UI-Image-Caching** — keine existing Vorlage in macos-app; Pattern muss neu eingeführt werden. Soll als shared singleton oder via Container exposed werden (Researcher entscheidet)
- **`Color.mlmBase` / `.mlmRaised` / `.mlmInkMuted`** + `MLMFont.*` — Solar-Palette aus `Colors.swift` (Phase 36 CONTEXT.md confirmed in Phase 37 ebenfalls genutzt — kein Konflikt mit den Tokens trotz „native"-Goal: Tokens bleiben, Look-Decisions wurden in Phase 36 lokal getroffen)
- **`.fileImporter` / SwiftUI-Sheets** — nicht relevant für Phase 37 (kein File-Pick), aber falls Maintenance-View einen optionalen „Choose folder to refresh" bekommt, Pattern via `PlaylistDetailView:62-73`

### Integration Points

1. **`ArtworkService.extractEmbeddedArtwork(from:)` API-Surface-Change** — von private instance → public static. Bestehende interne Aufrufer (`batchFetchArtwork:84-95`) müssen umgebaut werden auf `Self.extractEmbeddedArtwork(from: URL(fileURLWithPath: filePath))`
2. **`ArtworkExtractor.extract(audioURL:)` Body-Rewrite** — bleibt async, ruft jetzt `ArtworkService.extractEmbeddedArtwork`. Tests dafür gibt es (ArtworkExtractor wird in Phase-36-Plan-02-Tests verwendet) — die müssen weiter grün bleiben
3. **`DependencyContainer.initialize()` Erweiterung** — neuer `private(set) var artworkBackfillService: ArtworkBackfillService?` + init-Block nach `playlistCoverService`-Init (Z. 133). `.libraryDidImport`-Observer ist intern im Service (nicht im Container)
4. **`Notifications.swift` Neue Notification** — `static let trackArtworkDidChange = Notification.Name("trackArtworkDidChange")` + Doku-Kommentar über userInfo-Schema
5. **`LibraryTable.swift` Title-Spalte** — HStack-Erweiterung mit `TrackCoverView` als erstes Element. `width(min: 140, ideal: 260)` evtl. auf `min: 160` setzen, damit Cover+Text gut atmen
6. **`TrackDetailView.headerSection`** — Z. 65-78 RoundedRectangle ersetzen durch `TrackCoverView(trackId: track.id, size: .large, cornerRadius: 6)`. Symbol-Effect-Logik bleibt für Now-Playing-State, evtl. als Overlay über Cover
7. **`PlayerBar.coverThumbnail`** — komplettes property body ersetzen mit `TrackCoverView(trackId: …, size: .small, cornerRadius: 5)`. Bounds 40x40 bleiben
8. **`MaintenanceView.runArtwork()`** — wird zu `runArtworkEmbedded()` (BackfillService.refreshMissing) + `runArtworkMusicBrainz()` (alter batchFetchArtwork-Pfad ohne Embedded-Try). Buttons-Layout in der View entsprechend updaten

</code_context>

<specifics>
## Specific Ideas

- **iTunes/Apple-Music-Style Inline-Cover-Thumbnail** in der LibraryTable-Title-Spalte (D-13) — bewährte UX, keine separate Cover-Spalte.
- **Spotify-Style „Bilder poppen rein"-Verhalten** während Background-Backfill (D-01 + D-03) — Solar-Gradient-Fallback erst, dann inkrementell echte Cover.
- **Phase-36 Service-Lifecycle-Parallele:** ArtworkBackfillService = PlaylistCoverService-Twin. Observiert eigene Trigger-Notification (.libraryDidImport statt .playlistDidChange), nutzt selbes @MainActor @Observable Init-Pattern im Container, hat eigene `inFlight: Set<Int64>` Coalescing-Strategie analog Phase 36.
- **Self-Healing wenn Cache-Folder geleert** (D-14) — TrackCoverView triggert einzelnen Re-Backfill bei File-miss. Robust gegen System-Cleanup ohne globalen Re-Scan.

</specifics>

<deferred>
## Deferred Ideas

- **Cover-Crop / Edit-UI für Track-Artwork** — eigene Phase, falls überhaupt Bedarf entsteht. Phase 36 deckt nur Playlist-Cover via Drop.
- **MusicBrainz-Auto-Trigger beim Import** — Rate-Limit (1 req/s) macht das bei Initial-Library-Imports unbrauchbar. Bleibt Settings-Maintenance-only — entspricht ROADMAP-Out-of-Scope.
- **File-Mtime-getriebenes Auto-Re-Extract bei Re-Scan** — User-File-Replace ist selten genug, dass die Maintenance-Action „Refresh embedded artwork" ausreicht. Falls Bedarf entsteht: eigene kleine Phase.
- **Cover-Source-Badge in UI** (embedded vs MusicBrainz Indikator) — bewusst verworfen (D-17); würde den sauberen Cover-Look verschmutzen.
- **Smart-Fallback mit deterministischem Gradient aus track.id** (Spotify-2020-Style, analog Phase 36 D-03 für Playlists) — verworfen zugunsten Solar-Gradient + music.note-Glyph (D-11), weil während des Backfills die Farben sonst „hüpfen" würden. Falls später gewünscht: eigene UX-Iteration.
- **Toolbar-Progress-Indicator während Backfill** — Planner-Discretion. Falls die Per-Track-Notifications visuell nicht reichen, kann ein dezenter „Indexing artwork: 423/1200…"-Badge an `ActivityViewModel` angebunden werden.
- **Higher-concurrency Backfill (8+ parallel ffmpeg)** — verworfen wegen Thermal-Throttling-Risiko. Falls Profiling auf M3+ zeigt dass 4 zu konservativ ist: eigene Tuning-PR.

### Reviewed Todos (not folded)

- **`.planning/todos/pending/audio-analysis-ux-cleanup.md`** — von `gsd-sdk todo.match-phase 37` als schwacher Match (Score 0.6, Keyword-Match auf „analysis, gsd, user") zurückgegeben. Thematisch unrelated: betrifft Rust/Tauri-Side Analyse-Button-UX (Loudness/Fingerprint-Feedback), nicht macos-app SwiftUI Album-Art. Bleibt im pending-Pool; weiterhin v1.3-Resume-Blocker, nicht hier.

</deferred>

---

*Phase: 37-Album-Art-Pipeline-durchziehen*
*Context gathered: 2026-05-15*
