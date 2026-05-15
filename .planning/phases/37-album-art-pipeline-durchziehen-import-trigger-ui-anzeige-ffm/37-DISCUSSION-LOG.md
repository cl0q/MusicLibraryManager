# Phase 37: Album-Art-Pipeline durchziehen (Import-Trigger + UI-Anzeige + ffmpeg-Pfad) - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-15
**Phase:** 37-Album-Art-Pipeline-durchziehen
**Areas discussed:** Import-Trigger-Strategie, ffmpeg-Konsolidierung & API-Surface, UI-Cover-Rendering & Fallback, Schema-Quelle / Re-Extract / Maintenance-Compat

---

## Import-Trigger-Strategie

### Trigger-Zeitpunkt

| Option | Description | Selected |
|--------|-------------|----------|
| Post-Import-Background-Queue | Erst nach letztem Insert läuft ArtworkService über alle frisch importierten trackIds (Background-Task, Concurrency=4-8). Import-Speed bleibt unberührt, Tracks erscheinen erst ohne Cover, dann poppen die Bilder nach. | ✓ |
| Inline parallel zur Metadata-Extraction | Im selben TaskGroup-Chunk-Loop (chunk 50): pro File extract-metadata UND extract-artwork synchron. Track + Cover landen zusammen in der DB. Import wird ~30-50% langsamer (zweiter ffmpeg-Subprocess pro File). | |
| Inline sequentiell post-Insert | Direkt nach jedem saveBatch-Commit: Cover-Extract für die 500 neuen Tracks bevor nächster Batch. UI bleibt im 'Importing'-State länger, aber Tracks sind nie 'ohne Cover' sichtbar. | |

**User's choice:** Post-Import-Background-Queue (Recommended)

### Concurrency

| Option | Description | Selected |
|--------|-------------|----------|
| TaskGroup mit fester Concurrency (4) | withTaskGroup, max 4 parallele ffmpeg-Subprocesses. Mirrors Import-Pipeline-Pattern (chunk-loop). Schont CPU bei Initial-Library-Import. | ✓ |
| Serial Queue (1 at a time) | DispatchQueue mit Concurrency 1. Langsam, aber kein Subprocess-Storm. | |
| Higher concurrency (8) | 8 parallele ffmpeg. Schneller bei M1+, riskiert Thermal-Throttling auf älteren Macs. | |

**User's choice:** TaskGroup mit fester Concurrency 4 (Recommended)

### UI-Benachrichtigung

| Option | Description | Selected |
|--------|-------------|----------|
| Per-Track Notification post-extract | Nach jedem erfolgreichen Extract: NotificationCenter.post(.trackArtworkDidChange, userInfo: [trackId, artworkPath]). LibraryTable observiert und re-rendert nur die eine Row. Inkrementelles 'Bilder poppen rein'-Verhalten. | ✓ |
| Batch-Notification am Ende | Eine Notification .libraryDidImport nachdem ALLE Cover fertig sind. Alle Rows refreshen einmal. | |
| Beides — per-Track für Library, batch für TrackDetail/PlayerBar | Hybrid, mehr Code, mehr Pfade. | |

**User's choice:** Per-Track Notification post-extract (Recommended)

### Owner

| Option | Description | Selected |
|--------|-------------|----------|
| Neuer ArtworkBackfillService im DependencyContainer | @MainActor @Observable, hält Queue + Progress. Container instanziiert ihn analog zu PlaylistCoverService. Sauber separiert, testbar, kann auch MaintenanceView 'Refresh Embedded' bedienen. | ✓ |
| ImportService bekommt Inline-Phase 4 'Extracting artwork' | ImportService besitzt die Queue selbst. Mischt Sync- und Background-Logik. | |
| ImportViewModel.observer reagiert auf .libraryDidImport | Kein neuer Service — ImportViewModel triggert ArtworkService.batchFetchArtwork. Läuft nur während ImportVM lebt. | |

**User's choice:** Neuer ArtworkBackfillService im DependencyContainer (Recommended)

---

## ffmpeg-Konsolidierung & API-Surface

### Konsolidierungs-Strategie

| Option | Description | Selected |
|--------|-------------|----------|
| ArtworkExtractor wird thin wrapper um ArtworkService | extractEmbeddedArtwork wird public/static auf ArtworkService. ArtworkExtractor.extract(audioURL:) ruft das auf (async-bridge: Subprocess in detached Task). PlaylistCoverService bleibt unberührt — dieselbe API, neue Implementation. | ✓ |
| ArtworkExtractor wird gelöscht, Consumer rufen ArtworkService direkt | PlaylistCoverService:112 wird auf ArtworkService.extractEmbeddedArtwork umgestellt. Weniger Indirection, aber ein anderer Phase-36-File muss angefasst werden. | |
| Beide bleiben, ArtworkExtractor kriegt nur ffmpeg-Implementation getauscht | Duplizierter Code. | |

**User's choice:** ArtworkExtractor wird thin wrapper um ArtworkService (Recommended)

### ffmpeg-Missing-Verhalten

| Option | Description | Selected |
|--------|-------------|----------|
| Silent nil + Log warning | ProcessRunner.findExecutable('ffmpeg') liefert nil → extract gibt nil zurück, AppLogger.warn einmalig. UI zeigt Solar-Fallback statt Cover, kein User-facing-Error. | ✓ |
| Throw Error mit User-Banner | extract throwt 'ffmpegMissing'. UI zeigt Notification 'ffmpeg fehlt'. | |
| Fallback auf AVFoundation commonMetadata | Widerspricht dem Phase-Goal (AVFoundation-Inkonsistenz war ja der Treiber). | |

**User's choice:** Silent nil + Log warning (Recommended)

### API-Signatur

| Option | Description | Selected |
|--------|-------------|----------|
| static func extractEmbeddedArtwork(from url: URL) async -> Data? | Static auf ArtworkService, async (Subprocess in Task.detached). Liefert raw bytes — Caller entscheidet ob caching, resizing oder direkt-Verwendung. | ✓ |
| Instance-Method, gibt Data + Metadata-Struct zurück | async -> ArtworkExtractionResult mit (data, mimeType, dimensions). YAGNI. | |
| Direkt-to-File Variante | Schreibt JPEG direkt auf disk. PlaylistCoverService braucht bytes für Mosaic-Composition — zwei Varianten nötig. | |

**User's choice:** static func extractEmbeddedArtwork(from url: URL) async -> Data? (Recommended)

### Cache-Auflösungen

| Option | Description | Selected |
|--------|-------------|----------|
| Beide Sizes vorab schreiben (500 + 1200) | Mirrors batchFetchArtwork-Verhalten. UI kann thumbnail den 500er und TrackDetailView den 1200er nehmen. Disk-Kosten: ~80-150KB × 2 × Track-Count. | ✓ |
| Nur 1200, UI downscaled in NSImage | Eine Datei. 1000 Rows in Tabelle laden 1200er full — Memory-Pressure. | |
| Nur Original-Auflösung wie eingebettet | Keine Resize-Logik. Memory wird kritisch. | |

**User's choice:** Beide Sizes vorab schreiben (500 + 1200) (Recommended)

---

## UI-Cover-Rendering & Fallback

### Loading-Strategie

| Option | Description | Selected |
|--------|-------------|----------|
| Custom NSCache + AsyncImage-ähnlicher View | Shared TrackArtworkCache (NSCache<NSNumber, NSImage>, countLimit 200). Custom TrackCoverView observiert .trackArtworkDidChange. Memory-bounded, scrollt flüssig bei 1000+ rows. | ✓ |
| SwiftUI AsyncImage(url:) direkt | Native AsyncImage. Kein Limit; Memory wächst ungehindert. Kein stable cache. | |
| Sync-Load on demand | Im Body direkt von disk laden. Performance-Killer bei 1000 Rows. | |

**User's choice:** Custom NSCache + AsyncImage-ähnlicher View (Recommended)

### Fallback-Look

| Option | Description | Selected |
|--------|-------------|----------|
| Solar-Gradient + music.note-Glyph | RoundedRectangle mit linearGradient Color.mlmBase→Color.mlmRaised + zentriertes music.note. Konsistent mit aktuellem TrackDetailView-Header. | ✓ |
| Deterministischer Gradient aus track.id | Spotify-Style — jeder Track eigenes Farbpaar. Während Backfill 'hüpfen' die Farben. | |
| Nur music.note-Icon ohne Hintergrund | Aktuelles Verhalten. Visuell schwach bei 1000 Rows. | |

**User's choice:** Solar-Gradient + music.note-Glyph (Recommended)

### Quell-Auflösung pro Surface

| Option | Description | Selected |
|--------|-------------|----------|
| Smart: 500er für LibraryTable+PlayerBar, 1200er für TrackDetailView | Thumbnail-Surfaces lesen 500er. TrackDetailView header 1200er für Hi-DPI. Cache-Keys differenzieren nach Size. | ✓ |
| Immer 1200er, SwiftUI .resizable() | 1000 Rows × 1200er-NSImage in RAM — GBs Speicher. | |
| Immer 500er | TrackDetailView-Header verwaschen auf Retina. | |

**User's choice:** Smart-Resolution (Recommended)

### Table-Placement

| Option | Description | Selected |
|--------|-------------|----------|
| Inline links neben Title in der Title-Spalte | iTunes/Apple-Music-Pattern: HStack(spacing: 8) { TrackCoverView ; Text(title) }. Bestehende speaker.wave (now-playing) bleibt. | ✓ |
| Separate Cover-Spalte ganz links (24pt fix) | Klarere Trennung, kostet horizontal-Raum. | |
| Optional via Settings-Toggle | Default off — widerspricht Phase-Goal (sollte default sein). | |

**User's choice:** Inline links neben Title (Recommended)

---

## Schema-Quelle, Re-Extract & Maintenance-Compat

### Source-of-Truth

| Option | Description | Selected |
|--------|-------------|----------|
| DB-Row in artwork + File-Existence-Check | fetchArtwork + FileManager.fileExists. Triggert Re-Backfill wenn DB sagt ja aber File weg. Self-Heal. | ✓ |
| Nur DB-Row | User löscht Cache → DB sagt vorhanden, File weg, UI leer. Kein Self-Heal. | |
| Nur File-Existence | Backfill-Status nicht trackbar, keine Source-Info. | |

**User's choice:** DB-Row + File-Existence-Check (Recommended)

### Re-Extract-Trigger

| Option | Description | Selected |
|--------|-------------|----------|
| Nie automatisch — nur via Settings/Maintenance | Cover ist 'sticky once extracted'. Vorhersagbar, kein hidden CPU-burn. | ✓ |
| Bei Re-Scan eines bestehenden Library-Roots | File-Mtime-Checks kosten extra stat() Calls. | |
| Bei jedem App-Launch für fehlende Cover | Self-Healing nach Cache-Wipe — aber App startet langsamer. | |

**User's choice:** Nie automatisch — nur via Settings/Maintenance (Recommended)

### Maintenance-View-Layout

| Option | Description | Selected |
|--------|-------------|----------|
| Split in zwei Buttons: 'Refresh embedded' + 'Fetch from MusicBrainz' | 'Refresh embedded' — schneller ffmpeg-Backfill, kein Network. 'Fetch from MusicBrainz' — alter Pfad mit 1s rate-limit, optional. Roadmap-Success-Criterion #6 erfüllt. | ✓ |
| Ein Button bleibt, läuft Embedded-first-MB-fallback wie heute | MB-Rate-Limit bremst auch wenn User nur lokale Re-Extract will. | |
| Dropdown: User wählt Mode pro Run | Overkill für Settings-Tab-Aktion. | |

**User's choice:** Split in zwei Buttons (Recommended)

### Source-Anzeige in UI

| Option | Description | Selected |
|--------|-------------|----------|
| Nein — unsichtbar | Source bleibt nur in DB für Debug/Stats. UI zeigt nur 'Cover oder Fallback'. | ✓ |
| Klein in TrackDetailView Metadata-Panel | Nur für Power-User. | |
| Badge auf Cover-Thumbnail | Verschmutzt das saubere Cover-Render. Anti-Feature. | |

**User's choice:** Nein — unsichtbar (Recommended)

---

## Claude's Discretion

Folgende Themen blieben absichtlich offen — Researcher/Planner entscheidet:

- **NSCache-LRU-Eviction-Tuning** — countLimit 200 ist initial-Vorschlag. totalCostLimit (Image-Bytes als Kosten) wäre robuster — Researcher misst.
- **`refreshMissing()` vs `refreshAll()`** im ArtworkBackfillService. Maintenance-Button sollte mindestens missing-only haben (idempotent). Full-Refresh via ⌥-Click oder zweiter Button.
- **Progress-UI-Granularität** während Backfill. Per-Track-Notifications geben visuelles Feedback — ob zusätzlicher Toolbar-Indikator nötig ist, entscheidet Planner.
- **Test-Strategie**: ArtworkBackfillService Unit-Tests mit Mock-FileSystem + Mock-ProcessRunner sind Minimum. TrackCoverView Snapshot-Test für Fallback-State. E2E-Import-Test als Stretch.
- **Container-Wiring**: ArtworkBackfillService als `@Environment(\.container)` exposed. Wo der Reload-Listener sitzt (per-View vs global) ist Detail.

## Deferred Ideas

- **Cover-Crop / Edit-UI** für Track-Artwork — eigene Phase falls Bedarf entsteht.
- **MusicBrainz-Auto-Trigger beim Import** — Rate-Limit blockt Initial-Imports. Bleibt Maintenance-only.
- **File-Mtime-getriebenes Auto-Re-Extract** — User-File-Replace ist selten genug für Maintenance-Action.
- **Cover-Source-Badge in UI** — verworfen, würde sauberen Look verschmutzen.
- **Deterministischer Gradient aus track.id** — verworfen, weil Farben während Backfill "hüpfen" würden.
- **Toolbar-Progress-Indicator** — Planner-Discretion; ActivityViewModel-Integration optional.
- **Higher-concurrency Backfill (8+)** — verworfen wegen Thermal-Throttling. Falls Profiling es zeigt: eigene Tuning-PR.

### Reviewed Todos (not folded)

- **`.planning/todos/pending/audio-analysis-ux-cleanup.md`** — schwacher Match (Score 0.6, Keyword-Match). Thematisch unrelated: Rust/Tauri Analyse-Button-UX, nicht macos-app Album-Art. Bleibt im pending-Pool.
