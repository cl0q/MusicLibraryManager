# Phase 38: Folder & Device Sync (v2.0 macOS Native) - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-05-17
**Phase:** 38-folder-device-sync-v2-0-macos-native
**Areas discussed:** Profile-Modell (Folder vs Device), Content hinzufügen (Add-to-Profile UX), Rockbox-iPod Auto-Detection UX, Sync-Execution (Progress, Cancel, Deletion). Filter-Rules vorab als Out-of-Scope geklärt.

---

## Filter-Rules (Gate-Question vor Area-Discussion)

| Option | Description | Selected |
|--------|-------------|----------|
| Out-of-Scope — Phase 38 ist „manual selection only" (Empfohlen) | Modell + DB-Spalten bleiben, aber keine UI. Phase 38 schippert mit „füge Playlists/Tracks explizit hinzu". | ✓ |
| In-Scope — Phase 38 inkludiert simple Filter-Rules-UI | Chip-basierter Rule-Editor im Profile-Detail. | |

**User's choice:** Out-of-Scope.
**Notes:** Manual selection (D-05/D-07) reicht für den Daily-Driver-Loop. Rules werden Folge-Phase wenn der Bedarf entsteht.

---

## Area 1 — Profile-Modell (Folder vs Device)

### Q1.1: Wie wird Folder vs Device modelliert?

| Option | Description | Selected |
|--------|-------------|----------|
| Ein Profile-Typ + ein `kind`-Feld + Settings-Section pro Kind | `kind: folder|device` treibt Defaults (M3U8 on, Transcode 248k, FAT32-safe). | |
| Ein Profile-Typ, alle Optionen explizit toggleable | Kein `kind`, stattdessen direkte Toggles für `generate_m3u8`, `transcode_mode`, `fat32_safe_paths`, `cleanup_removed_files`. | ✓ |
| Zwei separate Tabellen: folder_profiles + device_profiles | Komplette DB-Trennung; höhere Migrations-Komplexität. | |

**User's choice:** Toggles, kein `kind`-Feld.
**Notes:** Preview zeigt explizit `Transcode [Keep originals ∨ 248k AAC ∨ 320k AAC]` als gewählte Mode-Optionen. Lock-in für D-01/D-02.

### Q1.2: Defaults beim Create eines neuen Profils

| Option | Description | Selected |
|--------|-------------|----------|
| Conservative — Keep originals, no M3U8, FAT32-safe on | „Einfache Folder-Kopie" als Default. | |
| Smart-detect — Wenn Output-Folder ein .rockbox-Volume ist, schalt Device-Defaults automatisch ein | DeviceDetector checkt beim Create, Toast bestätigt. | ✓ |
| Aggressive — Default ist 248k AAC + M3U8 + FAT32 on | Aktuelles Verhalten beibehalten. | |

**User's choice:** Smart-detect mit Toast.
**Notes:** Lock-in für D-03.

### Q1.3: Was bedeutet `cleanup_removed_files`?

| Option | Description | Selected |
|--------|-------------|----------|
| Toggle steuert Disk-Deletion — wenn on, lösche m4a-Files vom Zielordner; wenn off, nur sync_state-Row clearen | Beide Modi sinnvoll. Default on. | ✓ |
| Immer disk-deletion — Profile-Eintrag entfernen = File entfernen | Mirror-Semantik fest, kein Toggle. | |
| Nie disk-deletion — User-manual-cleanup | Sicherheits-konservativ, File bleibt liegen. | |

**User's choice:** Toggle, Default on.
**Notes:** Fixt aktuelles Bug-/Quirk-Verhalten in `SyncService.executeSync` Z. 161-169. Lock-in für D-04.

---

## Area 2 — Content hinzufügen (Add-to-Profile UX)

### Q2.1: Wie kommen Playlists/Tracks in ein Sync-Profil? (multiSelect)

| Option | Description | Selected |
|--------|-------------|----------|
| Picker-Sheet im Profile-Detail — „Add Playlists…" / „Add Tracks…" | Buttons öffnen Multi-Select-Sheet. | ✓ |
| Context-Menu an der Quelle — „Sync to ▸ \<Profile\>" | Submenu in PlaylistCard + TrackContextMenu. | ✓ |
| Drag-and-Drop — Playlist auf Profile-Card droppen | Niedrige Discoverability, Polish-Layer. | ✓ |
| Bulk-Bar Action — Multi-Select Tracks → „Add to Sync Profile ▸" | Erweiterung der Phase-19-Batch-Bar. | ✓ |

**User's choice:** Alle vier ausgewählt — Follow-up zur Priorisierung gestellt.

### Q2.2: Welche zwei sind MUST-have für Phase 38 ship? (multiSelect)

| Option | Description | Selected |
|--------|-------------|----------|
| Picker-Sheet im Profile-Detail | Foundational. | ✓ |
| Context-Menu „Sync to …" an Quelle | Schneller Daily-Driver-Flow. | ✓ |
| Drag-and-Drop Playlist auf Profile-Card | Polish-Layer. | |
| Bulk-Bar Action „Add selection to Sync Profile" | Klein, aber bewusst deferred. | |

**User's choice:** Picker-Sheet + Context-Menu MUST-have. Drag/Drop + Bulk-Bar → Polish-Folge.
**Notes:** Lock-in für D-05 (MUST) und D-06 (deferred).

### Q2.3: Wie entfernt der User Content aus einem Profil?

| Option | Description | Selected |
|--------|-------------|----------|
| Inline Trash-Icon + Multi-Select im Profile-Detail | Klassisches macOS Pattern. | ✓ |
| Beidseitig — inline + Context-Menu Toggle-Off mit Checkmark | Apple-Music-Style. | |
| Nur im Profile-Detail — Quelle hat keine „Remove from Sync" | Minimal. Add-only an Quelle. | |

**User's choice:** Inline im Profile-Detail (Option 3 quasi — ContextMenu-Submenu an Quelle ist Add-only).
**Notes:** Lock-in für D-07.

---

## Area 3 — Rockbox-iPod Auto-Detection UX

### Q3.1: Wann/wie wird der DeviceDetector gerunnt und sichtbar?

| Option | Description | Selected |
|--------|-------------|----------|
| On-demand im Create-Sheet — Button „Detect connected device" | Dropdown im Sheet, kein Background-Polling. | ✓ |
| Sidebar-Indicator + Banner „iPod erkannt: Touring" | NSWorkspace.didMountNotification observer + reactive Banner. | |
| Dedicated „Devices"-Sidebar-Section (Apple Music / Finder Style) | Sidebar-Top-Level mit erkannten Volumes. | |

**User's choice:** On-demand im Create-Sheet.
**Notes:** Lock-in für D-09. Dedicated Devices-Section und Background-Observer sind bewusst deferred (D-18).

---

## Area 4 — Sync-Execution (Progress, Cancel, Errors)

### Q4.1: Live-Feedback während des Sync-Runs

| Option | Description | Selected |
|--------|-------------|----------|
| Inline Progress-Bar im Profile-Detail + Cancel-Button | Ersetzt Preview-Stats während isSyncing. | |
| Toolbar-Indikator (analog Phase 37 Artwork-Backfill) — dezent, klick öffnet Detail | Visible über alle Routes, Background-Run möglich. | ✓ |
| Modal Sheet mit Progress — blockt UI bis fertig | Explizite Modal mit Progress + Cancel. | |

**User's choice:** Toolbar-Indikator (Phase-37-Pattern).
**Notes:** Im Profile-Detail wird Live-Progress trotzdem inline gezeigt (D-12). Lock-in für D-11.

### Q4.2: Verhalten bei Sync-Fehlern (failed tracks)

| Option | Description | Selected |
|--------|-------------|----------|
| Result-Section mit ausklappbarer Failed-Liste + Retry-pro-Track | Explizite Retry-UI nach Run. | ✓ |
| Failed tracks bleiben implicit — nächster Sync versucht es nochmal | Kein expliziter Retry, nur Count. | ✓ |
| Failed tracks logging-only — Toast + AppLogger | Minimal-UX. | |

**User's choice:** „beides" — explizit Retry-UI + implizit Auto-Retry beim nächsten Sync.
**Notes:** Beide Mechanismen sind kompatibel. Lock-in für D-13.

---

## Claude's Discretion

Folgende Themen sind absichtlich offen geblieben — Researcher/Planner entscheidet:

- Migration-Versionsnummer und exaktes Spalten-Naming für die neuen `sync_profiles`-Spalten
- Cancellation-Granularität exakt — ffmpeg-Subprocess-Kill mid-transcode oder nur „nach jedem File"
- Toolbar-Indicator Pixel-Look + Animation (Phase 37 als Vorbild)
- Test-Strategie (SyncService Unit-Tests Pflicht, Snapshot-Tests Stretch)
- „Add Tracks…"-Picker UX bei großer Library (Search-Filter Pflicht, virtualisierte Liste vs Pagination)
- `addPlaylist`-Idempotenz UI-Feedback („3 added, 1 already in profile")
- Toolbar-Indicator-Hosting in globaler vs route-lokaler Toolbar
- Cancel-Verhalten bei mid-Transcode in `TranscodeService` (cleaner Stop nach File-Fertig empfohlen)

## Deferred Ideas

Aus der Diskussion in `<deferred>` von CONTEXT.md übernommen:

- Filter-Rules-UI (`SyncProfileRule`) — eigene Folge-Phase
- Drag-and-Drop „Playlist auf Profile-Card droppen" — Polish-Layer
- Bulk-Bar Action „Add selection to Sync Profile" — Phase-19-Bar-Erweiterung
- Dedicated „Devices"-Sidebar-Section + NSWorkspace-Mount-Observer
- Auto-Sync bei Playlist-Change (Background-Service)
- Cloud-Sync-Targets (Dropbox, iCloud, S3)
- Per-Track-Sync-Status-Badge in der LibraryTable
- Transcode-Formate jenseits AAC (Opus, MP3, FLAC-Passthrough)
- Smart-Playlist-Sync (Rule-based)

Sowie ein Todo-Match, der reviewed-but-not-folded blieb:

- `audio-analysis-ux-cleanup.md` (Score 0.6) — generic keyword-match, thematisch unrelated (Loudness/Fingerprinting domain).
