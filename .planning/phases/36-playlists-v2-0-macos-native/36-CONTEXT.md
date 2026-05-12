# Phase 36: Playlists (v2.0 macOS Native) - Context

**Gathered:** 2026-05-12
**Status:** Ready for planning

<domain>
## Phase Boundary

Ship-bereit machen der SwiftUI-Playlist-Surface in der macOS-App. Die Kernimplementierung ist bereits da (~1722 LOC: Repository, Models, ViewModels, PlaylistsView, PlaylistCard, PlaylistDetailView, ContextMenu-Wiring, NotificationCenter). Diese Phase schließt die offenen visuellen + navigatorischen Lücken — **Cover-Image-Generierung** (Auto-Mosaic aus Track-Artwork + User-Override) und **Sidebar-Surface für Pinned-Playlists** (Apple-Music-Style verschachtelter Eintrag).

Entspricht Phase 6 in `macos-app/PLAN.md` ("Playlists"). Spotify-JSON-Import wird zu macos-app Phase 8 (Spotify-Integration) verschoben. Bulk-Add-via-Batch-Bar bleibt im Context-Menu (kein neuer Surface in Phase 36). Test-Strategie bleibt Planner-Entscheidung.

**Bereits gebaut (keine Re-Implementation nötig):**
- `macos-app/MLM/Models/Playlist.swift` — Model + `PlaylistTrack` + `PlaylistTag` + `createNative()` factory
- `macos-app/MLM/Database/PlaylistRepository.swift` — Full CRUD inkl. `addTracks` / `reorderTrack` / `togglePin`
- `macos-app/MLM/ViewModels/PlaylistViewModel.swift` — `@Observable`, Pinned-First-Sort, Inline-Rename, Search
- `macos-app/MLM/ViewModels/PlaylistDetailViewModel.swift` — `moveTrack` (Fractional Positioning), `importM3U`, `removeSelectedTracks`
- `macos-app/MLM/Views/Playlists/*` — Grid, Card, DetailView (M3U `.fileImporter`, Drag-Reorder via `List.onMove`, Delete-Confirmation)
- `macos-app/MLM/Views/ContentView/ContentView.swift:146` — `.playlists` Route → `PlaylistsView`, ⌘2 Shortcut
- `macos-app/MLM/Views/Library/TrackContextMenu.swift:62-78` — "Add to Playlist" Submenu live
- `macos-app/MLM/Models/Notifications.swift` — `.playlistDidChange` definiert + überall observiert

</domain>

<decisions>
## Implementation Decisions

### Cover-Image-Quelle & Layout

- **D-01:** Hybrid-Auto-Cover-Generierung — bei `< 4 Tracks` Single-Cover aus dem ersten Track ("auto1"), bei `≥ 4 Tracks` 2×2-Mosaic aus den ersten 4 Tracks ("auto4"). „Erste" = nach `playlist_tracks.position` Fractional-Order.
- **D-02:** Mosaic-Gap-Strategie: vorhandene Embedded-Artwork belegt ihre Slots; fehlende Slots werden mit Gradient-Tiles gefüllt (Farb-Ableitung aus benachbarten Tiles). Layout bleibt immer 2×2 — kein adaptives 1/2/3-Tile-Layout, kein Cover-Repeat.
- **D-03:** Fallback wenn 0 verfügbare Embedded-Artwork: deterministischer Gradient + Playlist-Initials (Spotify-2020-Style). Funktioniert auch für Playlists mit reinen Remote-Tracks.
- **D-04:** Re-Generate-Trigger: bei jedem `addTracks` / `removeTrack(s)` / `moveTrack` (das die ersten 4 betrifft). Generierte PNG wird in `~/Library/Application Support/MLM/playlist-covers/<playlist_id>.png` gecached; relativer Pfad landet in `playlists.cover_image_path`.

### Cover-User-Override

- **D-05:** Sticky-Lock via Schema-Bump — neue Spalte `playlists.cover_is_custom INTEGER NOT NULL DEFAULT 0`. Setzt User ein eigenes Cover (Drop auf Card / File-Picker), wird `cover_is_custom = 1` markiert. Auto-Regenerate skipt diese Zeile.
- **D-06:** Card-Context-Menu bekommt `Reset to Auto Cover` Eintrag — setzt `cover_is_custom = 0` und triggert Auto-Generate.

### Sidebar-Surface für Pinned-Playlists

- **D-07:** Sidebar-Präsenz: ausschließlich `is_pinned = 1` Playlists erscheinen als verschachtelte Einträge unter dem `Playlists` Top-Level-Eintrag. Keine Recent-Playlists, keine "alle Playlists scrollbar".
- **D-08:** Darstellung: SwiftUI `DisclosureGroup` unter dem `Playlists` Sidebar-Item, **default expanded**. Auf-/Zugeklappt-State persistiert in `@AppStorage("sidebar.pinnedPlaylists.expanded")`.
- **D-09:** Click-Navigation: Click auf Pinned-Sidebar-Eintrag springt **direkt zu `PlaylistDetailView`** — kein Umweg über Grid, kein Card-Highlight-Roundtrip. Apple-Music-Verhalten.
- **D-10:** Pin-Soft-Limit: maximal 8 Pinned-Playlists. Bei Versuch zu pinnen wenn schon 8 sind → UI zeigt einen kurzen Hinweis (Toast / Inline-Message) "Maximum 8 pinned — unpin one first". Hard-Block, kein Auto-Unpin.
- **D-11:** Sidebar-Pinned-Context-Menu (Rechtsklick): `Unpin from Sidebar` / `Rename` / `Delete` / `Reveal in Grid`. Funktional vollständig — keine künstliche Minimal-Variante.

### Aus Scope ausgeschlossen (für Phase 36)

- **D-12:** Spotify-JSON-Import wird zu macos-app Phase 8 (Spotify-Integration) verschoben — auch wenn Quellen wie Soundiiz/TuneMyMusic JSON ohne Spotify-Auth liefern. Phase 36 ist M3U-only.
- **D-13:** Bulk-Add via separate Batch-Bar wird nicht hinzugefügt. `TrackContextMenu` Add-to-Playlist deckt Multi-Selection bereits ab (s. `TrackContextMenu.swift:62-78`).

### Claude's Discretion

Diese Themen blieben ungeklärt — Planner/Researcher entscheidet im Detail:

- **Cover-Image-Auflösung & Crop-Strategie** für non-quadratische Source-Covers (Square-Crop von Center, Letterbox mit Gradient-Fill, oder Aspect-Preserve via Scale). Empfehlung: Center-Crop auf 512×512 PNG.
- **Track-Order-Definition für "erste 4"** im Detail: Sortier-Reihenfolge ist `playlist_tracks.position ASC` (Fractional Indexing), aber Tie-Breaker bei seltenen identischen Positions undefiniert. Wenn relevant, sekundär `added_at ASC`.
- **Test-Strategie** für Phase 36 — Repository-Unit-Tests (in-memory GRDB) sind Mindestanforderung; ViewModel-Tests mit Mock-Repo + UI-Snapshot-Tests sind Stretch-Goal, Planner entscheidet basierend auf Plan-Komplexität.
- **Gradient-Algorithmus** für Mosaic-Tiles und Fallback-Cover — z.B. via dominanten Track-Cover-Farbpunkt extrahieren (CIAreaAverage) oder deterministisch aus `playlist.id` Hash. Researcher empfohlen.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Phase-36-Spec

- `.planning/ROADMAP.md` §"Phase 36: Playlists (v2.0 macOS Native)" — Goal, Depends-on, Success Criteria
- `macos-app/PLAN.md` §"Phase 6 — Playlists" — Original SwiftUI-Architektur-Skizze
- `.planning/STATE.md` — aktuelle Position; Phase 35 läuft parallel, kein Code-Overlap

### Existing-Implementation (READ before planning)

- `macos-app/MLM/Models/Playlist.swift` — `Playlist`, `PlaylistTrack`, `PlaylistTag`, `cover_image_path` Codable Mapping
- `macos-app/MLM/Database/PlaylistRepository.swift` — alle Persistenz-Operationen
- `macos-app/MLM/ViewModels/PlaylistViewModel.swift` — Grid-State + Pinned-First-Sort
- `macos-app/MLM/ViewModels/PlaylistDetailViewModel.swift` — Detail-State + Fractional-Position + M3U-Import
- `macos-app/MLM/Views/Playlists/PlaylistsView.swift` — Grid + ⌘N Popover
- `macos-app/MLM/Views/Playlists/PlaylistCard.swift` — Card mit Rename/Pin/Delete
- `macos-app/MLM/Views/Playlists/PlaylistDetailView.swift` — Detail mit Drag-Reorder + M3U-Import
- `macos-app/MLM/Views/ContentView/ContentView.swift:141-156, 222-260` — Routing-Cases + Sidebar-Section-Enum
- `macos-app/MLM/Views/Sidebar/SidebarView.swift` — wo Pinned-DisclosureGroup einzuhängen ist
- `macos-app/MLM/Views/Library/TrackContextMenu.swift:62-78, 282-296` — Add-to-Playlist Pattern (Submenu + addTracks-Call)
- `macos-app/MLM/Models/Notifications.swift` — `.playlistDidChange` (SidebarView muss observieren)

### Schema-Migration-Pfad

- `macos-app/MLM/Database/DatabaseManager.swift` (oder vergleichbare Migrations-Datei) — wo Migration v20 für `cover_is_custom` einzufügen ist. Aktueller Schema-Stand: v19 nach Phase-1-Summary in STATE.md.
- `macos-app/MLMTests/DatabaseTests/` — Migration-Test-Pattern für die neue Spalte

### Patterns-Referenz (für Cover-Generation)

- AVFoundation `AVAssetImageGenerator` / `AVMetadataItem.commonMetadata` — Embedded-Artwork-Extraction aus Audio-Files
- `macos-app/MLM/AudioPlayer.swift` (oder Pendant aus Phase 5) — Pattern für AVAudioFile/AVAsset-Zugriff
- macOS `FileManager.SearchPathDirectory.applicationSupportDirectory` — Cache-Verzeichnis-Pattern

### v1.0 Tauri-Pendant (Pattern-Inspiration, nicht 1:1)

- `.planning/phases/04-playlist-management/04-CONTEXT.md` — v1.0 Fractional-Indexing-Entscheidungen (bereits in v2.0 PlaylistDetailViewModel umgesetzt — Referenz für Konsistenz)

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets

- **`PlaylistDetailViewModel.generateNextPosition()` + `fractionalPosition(insertingAt:excluding:)`** — Fractional-Indexing-Helpers für Reorder; werden bereits genutzt und müssen NICHT neu gebaut werden
- **`PlaylistRepository.fetchTracks(playlistId:)`** — liefert Tracks in Position-Order; ideal als Datenquelle für Cover-Generator (erste 4 Tracks)
- **`PlaylistViewModel.togglePin(id:)`** — wird bereits aufgerufen; muss erweitert werden um 8-Pin-Soft-Limit-Check vor dem Repository-Call (Toast bei Block)
- **`TrackContextMenu.swift:282-296` `addToPlaylist(_:)`** — Pattern für `playlistRepo.addTracks` + Notification-Post; gleicher Mechanismus löst Cover-Regenerate via observer aus
- **`Notifications.swift` `.playlistDidChange`** — wird schon überall gepostet; SidebarView muss als neuer Observer einklinken
- **`@Environment(\.container) private var container`** + `container.playlistRepository` — Dependency-Injection-Pattern für neue ViewModels (z.B. `PlaylistCoverService`)

### Established Patterns

- **`@Observable` ViewModels** mit `@MainActor` async-Methoden — etabliert in `PlaylistViewModel` + `PlaylistDetailViewModel`. Neuer `PlaylistCoverService` sollte gleichem Pattern folgen.
- **`Color.mlmBase` / `.mlmAccent` / `.mlmInk*` Theme-Tokens** — komplette Solar-Palette in `Colors.swift`; Gradient-Fallback-Cover muss aus dieser Palette ziehen für Konsistenz.
- **`MLMFont.*` Typography-Tokens** — für Card-Initials und Fallback-Cover-Text.
- **`NotificationCenter.default.publisher(for:)` + `.onReceive`** — für Cross-View-Refresh; PlaylistsView + PlaylistDetailView nutzen das schon; SidebarView muss gleichen Observer für DisclosureGroup-Aktualisierung bekommen.
- **`.fileImporter(isPresented:...)`** SwiftUI-Sheet — für User-Cover-Upload analog zur M3U-Import-Implementierung in `PlaylistDetailView.swift:62-73`.

### Integration Points

1. **Sidebar-Erweiterung** (`Views/Sidebar/SidebarView.swift`): neue `DisclosureGroup` unter dem `Playlists` Sidebar-Item, observiert `.playlistDidChange`, lädt `playlists.filter { $0.isPinned == 1 }.prefix(8)`. Click setzt einen neuen Navigation-State der von ContentView konsumiert wird (vermutlich Erweiterung des `NavigationSection`-Enums oder Sibling-State für `selectedPlaylistId`).
2. **ContentView-Routing-Erweiterung** (`Views/ContentView/ContentView.swift:141-156`): braucht Pfad um Sidebar-Click direkt in `PlaylistDetailView` zu landen ohne `PlaylistsView`-Grid-Detour — vermutlich neue `case .playlistDetail(Int64)` oder separates `@State` mit Init-Selektion in `PlaylistsView`.
3. **PlaylistCoverService (NEU)**: zentraler Service, Dependency-injiziert via Container, mit Methoden wie `regenerateCover(playlistId:)` und `setCustomCover(playlistId:, imageURL:)`. Observiert `.playlistDidChange` und triggert Regenerate (wenn `cover_is_custom == 0`).
4. **Schema-Migration v20**: neue Spalte `cover_is_custom` mit `DEFAULT 0`, plus Index falls häufige Filter-Queries entstehen (vermutlich nicht — Single-Row-Lookups dominieren).
5. **`PlaylistCard.swift`** muss erweitert werden für: (a) Render von Mosaic-Cover wenn `coverImagePath != nil` und File existiert, (b) Drop-Target für User-Upload-Image, (c) Context-Menu-Eintrag `Reset to Auto Cover` wenn `cover_is_custom == 1`.

</code_context>

<specifics>
## Specific Ideas

- **Apple-Music-Style Sidebar-Pinned-Liste** ist die explizite Referenz (D-07, D-09) — verschachtelte Disclosure-Group, direkter Click-Navigate.
- **Spotify-2020-Gradient-Fallback** für Playlists ohne extrahierbare Artwork (D-03).
- **2×2-Mosaic-Layout** mit Gradient-Lückenfüllern statt adaptiver 1/2/3-Tile-Layouts (D-02) — visuelle Konsistenz wichtiger als ehrliche Tile-Anzahl-Darstellung.
- **Soft-Hint statt Hard-Block** für 8-Pin-Limit (D-10) — User wird informiert, nicht abgewürgt; analog zu macOS-Pattern für Sidebar-Favoriten.

</specifics>

<deferred>
## Deferred Ideas

- **Spotify-JSON-Import** — verschoben zu macos-app Phase 8 (Spotify-Integration). Auch JSON-Imports aus Drittanbieter-Tools (Soundiiz, TuneMyMusic) warten dort, um eine konsistente JSON-Schema-Behandlung in einem Phase-Scope zu haben.
- **Bulk-Add via separate Batch-Bar** — TrackContextMenu deckt Multi-Selection schon ab; zusätzliche Batch-Bar-Surface ist nicht nötig (D-13). Falls v2.0 später eine generelle Batch-Bar im LibraryTable bekommt (analog v1.4 Phase 19/32), Add-to-Playlist kann dort als Action ergänzt werden — eigene Phase.
- **Smart-Playlists / Filter-Rules** — komplett aus Scope; gehört in eine eigene Phase wenn überhaupt.
- **Playlist-Folder / Ordner für Playlists** — separate Phase.
- **Playlist-Sharing / Export außerhalb M3U** — out of scope.
- **Recent-Playlists in Sidebar** (statt nur Pinned) — explizit verworfen (D-07).
- **Pin-Reordering in Sidebar** (User-Drag in der DisclosureGroup) — bleibt vorerst Pinned-Alphabetisch (per Pin-Sort-Pattern aus `PlaylistViewModel`). Falls Bedarf später, eigene Phase.

### Reviewed Todos (not folded)

- **`.planning/todos/pending/audio-analysis-ux-cleanup.md`** — von `gsd-sdk todo.match-phase 36` als Match (Score 0.4) zurückgegeben, aber thematisch unrelated (Keyword-Match auf "gsd, button"). Bleibt im pending-Pool, weiter ein v1.3-Resume-Blocker.

</deferred>

---

*Phase: 36-Playlists (v2.0 macOS Native)*
*Context gathered: 2026-05-12*
