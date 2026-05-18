---
status: partial
phase: 38-folder-device-sync-v2-0-macos-native
source: [38-VERIFICATION.md, 38-05-PLAN.md]
started: 2026-05-18T07:50:00Z
updated: 2026-05-18T07:50:00Z
---

## Current Test

[awaiting human testing]

## Tests

### 1. Profil-Erstellung via Device-Detection
expected: "Detect device…" zeigt verfügbare Rockbox-Geräte; Auswahl füllt Output-Folder und schlägt Profilnamen vor; Toast "Rockbox iPod erkannt — Device-Defaults aktiviert" erscheint ~3s und verschwindet automatisch.
result: [pending]

### 2. Smart-Defaults nach Erstellung
expected: Generate M3U8 = AN, Transcode Mode = "248 kbps AAC", FAT32-Safe = AN, Cleanup Removed = AN voreingestellt.
result: [pending]

### 3. PlaylistPickerSheet Suche + Hinzufügen
expected: Sheet öffnet 400×500; Echtzeit-Suche filtert; "Add (N)" schließt Sheet; Playlist erscheint in Profil-Inhaltsliste.
result: [pending]

### 4. Sync-Fortschritt + globaler Toolbar-Indikator
expected: Live-Progress mit ProgressView + "N of M" + Track-Name während Sync; Toolbar-Indikator (Spinner + Counter) erscheint und bleibt von allen Routen sichtbar; Klick navigiert zu Sync.
result: [pending]

### 5. Sync-Output auf Gerät
expected: m4a-Dateien auf Gerät unter erwartetem Pfad; m3u8-Playlist im Device-Root (falls aktiviert); Ergebnis-Sektion "X synced, 0 failed".
result: [pending]

### 6. Failed-Tracks-Retry
expected: "Failed Tracks (N)" DisclosureGroup nach Sync mit Fehlern; "Retry"-Button pro Track wiederholt nur diesen Track.
result: [pending]

### 7. Context-Menu "Sync zu" (PlaylistCard + TrackContextMenu)
expected: Rechtsklick auf Playlist-Card zeigt "Sync zu ▸" Submenu mit Profilname; Klick fügt Playlist dem Profil hinzu; gleiches Verhalten in TrackContextMenu für einzelne Tracks.
result: [pending]

### 8. Cancellation während Sync
expected: Cancel-Button stoppt Sync zwischen Dateien; bereits synchronisierte Dateien verbleiben auf dem Gerät; ProgressView verschwindet.
result: [pending]

### 9. Cleanup-Removed-Files Verhalten
expected: cleanupRemovedFiles=true entfernt Tracks vom Gerät, die nicht mehr im Profil sind; cleanupRemovedFiles=false lässt sie bestehen. Sicher: nur Dateien unterhalb des Output-Folder werden gelöscht (path-prefix-validation).
result: [pending]

## Summary

total: 9
passed: 0
issues: 0
pending: 9
skipped: 0
blocked: 0

## Gaps
