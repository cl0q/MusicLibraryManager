# Phase 36: Playlists (v2.0 macOS Native) - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-12
**Phase:** 36-Playlists (v2.0 macOS Native)
**Areas discussed:** Cover-Images, Sidebar-Surface

**Pre-Discussion Context:** Vor Beginn der Diskussion wurde festgestellt, dass die Playlist-Implementierung in `macos-app/MLM/` bereits zu ~85% gebaut ist (1722 LOC: Repository, Models, ViewModels, Views, Routing, Notifications, TrackContextMenu-Wiring). Die Discuss-Phase fokussiert sich auf die verbleibenden Gray Areas, nicht auf "wie baue ich Playlists".

**Routing-Vorgeschichte:** User invokierte `/gsd-discuss-phase 6 --chain`. Phase 6 in ROADMAP.md ist die alte v1.0 Desktop-UI (shipped 2026-02-05). User wählte Option "Als Phase 36 in ROADMAP eintragen" — `.planning/ROADMAP.md` wurde um einen Phase-36-Eintrag erweitert (analog Phase 35), `.planning/STATE.md` "Next: Phase 6" → "Next: Phase 36".

---

## Pre-Discussion Selection

| Option | Description | Selected |
|--------|-------------|----------|
| Phase-36-Scope-Cut | Was zählt als Ship-Kriterium? Polish + Tests reicht, oder Spotify-JSON + Cover-Images zwingend mit drin? | |
| Spotify-JSON-Import: in/out | Roadmap nennt Spotify-JSON-Import. Spotify-Integration noch nicht da. Drop / parken / einbauen? | |
| Cover-Images + Sidebar-Surface | Cover-Quelle + Sidebar-Präsenz für Pinned-Playlists | ✓ |
| Test-Strategie + Coverage | Welche Tests sind Ship-Bedingung? Repository / + ViewModel / + Snapshot? | |

**User's choice:** Nur "Cover-Images + Sidebar-Surface". Andere Areas implizit als "Default akzeptiert" — Spotify-JSON deferred, Tests Planner-Discretion, Scope-Cut nicht hinterfragt.

---

## Cover-Images

### Question 1 — Cover-Image-Quelle

| Option | Description | Selected |
|--------|-------------|----------|
| Auto vom 1. Track + User-Override | Default: artwork des chronologisch ersten Tracks (via AVAsset). User kann überschreiben. Apple-Music-Style. | |
| Auto vom 1. Track, kein Override | Nur Auto-Extract, kein User-Upload. | |
| Nur User-Upload, kein Auto | User muss explizit Cover wählen. Placeholder bis dahin. Spotify-Style. | |
| Gradient/Initials-Fallback (auto) | Deterministischer Farbgradient + Playlist-Initialen. | |

**User's choice:** Freitext — "Auto vom 1. Track + User-Override und gradient fallback. aber ich will dass von den ersten 4 liedern die album covers genommen werden und zu einem gemach werden für die playlist. aber nur bei mindestens vier liedern in der playlist. also entweder auto1 oder auto4".

**Notes:** Hybrid-Ansatz, kombiniert mehrere Optionen — auto1 bei < 4 Tracks, auto4 (2×2 Mosaic) bei ≥ 4 Tracks, Gradient-Fallback wenn keine Embedded-Artwork verfügbar, User-Override-Möglichkeit bleibt. Wird in CONTEXT.md als D-01..D-03 codifiziert.

### Question 2 — Cover-Trigger

| Option | Description | Selected |
|--------|-------------|----------|
| On-add + On-remove, gecacht | Re-generiert bei jedem addTracks/removeTracks. PNG gecacht in Application Support. | ✓ |
| Nur bei Erst-Befuellung | Einmalig generiert bei 0 → erste-Tracks. Sticky. | |
| Lazy on-render | Beim ersten Display der Card berechnet + gecacht, nie auto-invalidiert. | |
| User-Override blockiert Auto | Sticky-Lock-Mechanik (wurde in Frage 3 separat geklärt). | |

**User's choice:** On-add + On-remove, gecacht.

### Question 3 — User-Override-Verhalten

| Option | Description | Selected |
|--------|-------------|----------|
| Sticky-Lock + Reset-Option | Manuelles Cover wird gespeichert, `cover_is_custom` Flag blockiert Auto-Regenerate. Reset-Option im Card-Menu. Schema-Bump. | ✓ |
| Sticky-Lock ohne Schema-Bump | `custom://` Präfix in coverImagePath statt neuer Spalte. | |
| Kein Lock — letzte Aktion gewinnt | Manuelles Cover wird beim nächsten Add/Remove überschrieben. | |
| Override blockiert nur 24h | Time-limited Override. | |

**User's choice:** Sticky-Lock + Reset-Option (Schema-Bump akzeptiert).

### Question 4 — Mosaic-Gap-Strategie

| Option | Description | Selected |
|--------|-------------|----------|
| Mosaic mit Gradient-Tiles für Fehlende | Vorhandene Covers in Slots, fehlende mit Gradient. Bleibt 2×2. | ✓ |
| Fallback komplett auf Gradient/Initials | Binär — entweder 4 echte Covers oder reiner Gradient. | |
| Mosaic mit weniger Tiles (1, 2, 3) | Adaptive Anzahl. | |
| Wiederhole vorhandene Covers | 2×2 mit Cover-Repeats. Spotify-2017. | |

**User's choice:** Mosaic mit Gradient-Tiles für Fehlende.

### Continue-Check

User wählte "Zu Sidebar-Surface wechseln" — keine weiteren Cover-Fragen (Track-Order-Definition, Cover-Dimensions, Crop-Strategie wurden in Discretion verschoben).

---

## Sidebar-Surface

### Question 1 — Sidebar-Präsenz

| Option | Description | Selected |
|--------|-------------|----------|
| Nur Pinned (Apple-Music-Style) | `is_pinned = 1` Playlists als verschachtelte Einträge unter `Playlists`. | ✓ |
| Pinned + Recent (Top 3) | Pinned + 3 zuletzt geöffnete. Erfordert `last_opened_at`. | |
| Alle Playlists, scrollbar | Komplette Liste in Sidebar. | |
| Keine — Sidebar bleibt clean | Nur Top-Level `Playlists` Eintrag. Grid einziger Einstieg. | |

**User's choice:** Nur Pinned (Apple-Music-Style).

### Question 2 — Disclosure-Verhalten

| Option | Description | Selected |
|--------|-------------|----------|
| DisclosureGroup, default expanded | SwiftUI DisclosureGroup mit Persistenz via @AppStorage. Nativer macOS-Pattern. | ✓ |
| Always-expanded, flat unter Playlists | Eingerückt, kein Toggle. | |
| Separate Section "Pinned" | Eigene Sidebar-Section oberhalb. | |
| Nur in Hover/Aside zeigen | Auto-Hide-Submenu. | |

**User's choice:** DisclosureGroup, default expanded.

### Question 3 — Click-Verhalten

| Option | Description | Selected |
|--------|-------------|----------|
| Direkt zur PlaylistDetailView | Click springt direkt in Detail-View, kein Grid-Detour. | ✓ |
| Grid öffnet sich, Card hervorgehoben | Umweg über Grid mit Highlight. | |
| Detail öffnet, Sidebar zeigt aktive Selection | Hybrid — Detail + Sidebar-Accent. | |

**User's choice:** Direkt zur PlaylistDetailView.

### Question 4 — Pin-Limit + Context-Menu

| Option | Description | Selected |
|--------|-------------|----------|
| Kein Limit + Full Context-Menu | Unbegrenzt Pins. Rechtsklick: Unpin / Rename / Delete / Reveal. | |
| Max 8 Pins + Full Context-Menu | Soft-Limit 8 mit UI-Hinweis bei toggle. Full Menu. | ✓ |
| Kein Limit + Minimal Menu (nur Unpin) | Unbegrenzt + Unpin-only Menu. | |
| Max 8 Pins + Minimal Menu | Beides eng. | |

**User's choice:** Max 8 Pins + Full Context-Menu.

---

## Final Check

| Option | Description | Selected |
|--------|-------------|----------|
| Bereit für CONTEXT — weiter zu /gsd-plan-phase 36 | Decisions reichen. | ✓ |
| Noch Bulk-Add via Batch-Bar diskutieren | | |
| Noch Test-Strategie klären | | |
| Noch Spotify-JSON nochmal anfassen | | |

**User's choice:** Bereit für CONTEXT — weiter zu /gsd-plan-phase 36.

---

## Claude's Discretion

Folgende Punkte blieben offen und werden vom Planner/Researcher entschieden:

- **Cover-Image-Auflösung & Crop-Strategie** für non-quadratische Source-Covers — Empfehlung im CONTEXT: Center-Crop auf 512×512 PNG.
- **Tie-Breaker für "erste 4 Tracks"** bei identischen Fractional-Positions — empfohlen: `playlist_tracks.position ASC, added_at ASC`.
- **Test-Strategie + Coverage** — Repository-Unit-Tests in-memory als Minimum, ViewModel + Snapshot-Tests als Stretch-Goal.
- **Gradient-Algorithmus** für Mosaic-Lückenfüller + Fallback-Cover — Researcher-Empfehlung benötigt (CIAreaAverage vs. deterministischer Hash).

## Deferred Ideas

Notiert in `<deferred>` Section von CONTEXT.md:

- **Spotify-JSON-Import** → macos-app Phase 8 (Spotify-Integration). Auch JSON-Files aus Drittanbieter-Tools (Soundiiz, TuneMyMusic) warten dort.
- **Bulk-Add via separate Batch-Bar** → TrackContextMenu deckt Multi-Selection bereits ab; eigene Phase falls v2.0 später eine generelle Batch-Bar bekommt.
- **Smart-Playlists / Filter-Rules** → eigene Phase falls überhaupt.
- **Playlist-Folder / Ordner-Hierarchie** → separate Phase.
- **Playlist-Sharing / Export-Formate außerhalb M3U** → out of scope.
- **Recent-Playlists in Sidebar** (zusätzlich zu Pinned) → explizit verworfen.
- **Pin-Reordering per User-Drag in der DisclosureGroup** → bleibt Alphabetisch sortiert; eigene Phase wenn Bedarf entsteht.
