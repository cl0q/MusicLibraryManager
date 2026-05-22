---
phase: 38-folder-device-sync-v2-0-macos-native
plan: "05"
subsystem: macos-app/testing
tags:
  - sync
  - tests
  - picker-sheet
  - context-menu
  - tdd
  - uat

# Dependency graph
requires:
  - phase: 38-04
    provides: SyncViewModel.addPlaylists, addTracks, profiles, createProfile, loadProfiles — all tested here
provides:
  - PickerSheetTests.swift — 4 tests covering idempotent add, empty-query fetch, case-insensitive filter, notification post
  - SyncContextMenuTests.swift — 4 tests covering empty profiles, profiles after create, add via context menu action, toggle column defaults
  - All 6 Wave-0 test suites present and passing (MigrationTests, SyncViewModelTests, SyncServiceTests, DeviceDetectorTests, PickerSheetTests, SyncContextMenuTests)
affects:
  - Phase 38 UAT (38-HUMAN-UAT.md) — UAT items auto-approved in chain mode; persisted for later /gsd-verify-work

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "INSERT OR IGNORE idempotence test: double-add same ID, assert COUNT(*) == 1"
    - "NotificationCenter expectation in Swift Testing: addObserver with boolean flag, defer removeObserver"
    - "In-memory DB tests via DatabaseManager.inMemory() — same makeVM() pattern established in SyncViewModelTests"

key-files:
  created:
    - macos-app/MLMTests/PickerSheetTests.swift
    - macos-app/MLMTests/SyncContextMenuTests.swift
  modified: []

key-decisions:
  - "allPlaylistsReturnedOnEmptyQuery validates the DB layer directly (Playlist.fetchAll) — not via VM.allAvailablePlaylists — because PlaylistPickerSheet.loadPlaylists goes to the container.playlistRepository, not SyncViewModel"
  - "SyncContextMenuTests.syncProfilesHaveNewToggleColumnDefaults verifies D-01 migration defaults (generateM3U8=false, transcodeMode=keep_originals, fat32SafePaths=true, cleanupRemovedFiles=true) are persisted correctly"
  - "Task 2 (UAT) auto-approved in auto-mode chain; UAT items persisted to 38-HUMAN-UAT.md by orchestrator for later /gsd-verify-work — no blocking the chain on hardware availability"

patterns-established:
  - "Wave-0 test pattern: all 6 suites use DatabaseManager.inMemory() + SyncService 4-param constructor; tests are @MainActor @Suite"

requirements-completed:
  - SYNC-v2-21

# Metrics
duration: 10min
completed: "2026-05-18"
---

# Phase 38 Plan 05: PickerSheetTests + SyncContextMenuTests + UAT Checkpoint Summary

8 neue Swift Testing Tests schliessen die 6 Wave-0-Test-Suites ab; UAT im Auto-Mode auto-approved und zur manuellen Verifikation persistiert.

## Performance

- **Duration:** ~10 min
- **Started:** 2026-05-18T00:00:00Z
- **Completed:** 2026-05-18T00:10:00Z
- **Tasks:** 2 (Task 1 autonom ausgeführt, Task 2 UAT-Checkpoint auto-approved)
- **Files modified:** 2 (beide neu erstellt)

## Accomplishments

- `PickerSheetTests.swift` erstellt mit 4 Tests: idempotentes addPlaylists, leere Suche liefert alle Playlists, case-insensitive Filter, addTracks postet `.syncProfileDidChange`
- `SyncContextMenuTests.swift` erstellt mit 4 Tests: profiles anfangs leer, profiles nach createProfile vorhanden, Playlist via Kontextmenü-Aktion hinzufügen, DB-Toggle-Spalten-Defaults korrekt (D-01)
- Alle 6 Wave-0-Test-Suites aus VALIDATION.md sind jetzt vorhanden: MigrationTests, SyncViewModelTests, SyncServiceTests, DeviceDetectorTests, PickerSheetTests, SyncContextMenuTests
- UAT-Checkpoint (Task 2) im Auto-Mode auto-approved — iPod-Sync-Szenario wird via `38-HUMAN-UAT.md` für späteren `/gsd-verify-work`-Durchlauf persistiert

## Task Commits

Jeder Task wurde atomar committed:

1. **Task 1: PickerSheetTests + SyncContextMenuTests Wave-0 stubs** - `0039462` (test)
2. **Task 2: UAT checkpoint** - auto-approved in auto-mode; kein separater Commit erforderlich

**Plan metadata:** _(dieser SUMMARY-Commit)_

## Files Created/Modified

- `macos-app/MLMTests/PickerSheetTests.swift` — 4 Tests: addPlaylistsIsIdempotent, allPlaylistsReturnedOnEmptyQuery, searchFilterMatchesCaseInsensitive, addTracksPostsNotification
- `macos-app/MLMTests/SyncContextMenuTests.swift` — 4 Tests: profilesEmptyInitially, profilesPopulatedAfterCreate, addPlaylistToProfileViaContextMenuAction, syncProfilesHaveNewToggleColumnDefaults

## Decisions Made

- `allPlaylistsReturnedOnEmptyQuery` testet `Playlist.fetchAll(db)` direkt statt via VM, weil `PlaylistPickerSheet` den `container.playlistRepository` nutzt — nicht `SyncViewModel.allAvailablePlaylists`
- `syncProfilesHaveNewToggleColumnDefaults` verifiziert explizit die D-01-Migrations-Defaults (`generateM3U8=false`, `transcodeMode="keep_originals"`, `fat32SafePaths=true`, `cleanupRemovedFiles=true`)
- UAT auto-approved: Hardware-Checkpoint blockiert den Auto-Mode-Chain nicht; Orchestrator persistiert UAT-Items als `38-HUMAN-UAT.md` für späteren manuellen Durchlauf

## Deviations from Plan

None — Plan exakt wie geschrieben ausgeführt. Task 1 Commit `0039462` entspricht dem geplanten Inhalt. Task 2 ist ein `checkpoint:human-verify` der im Auto-Mode regulär auto-approved wird.

## Issues Encountered

**Pre-existing:** Phase-37 `testObservesLibraryDidImport` Flake — bekannte Race-Condition aus Phase 37, in isolierten Läufen bestanden. Nicht durch Plan 05 verursacht, kein Fix erforderlich.

## User Setup Required

**UAT — iPod Sync Szenario** (zu einem späteren Zeitpunkt manuell ausführen via `/gsd-verify-work`):

1. Rockbox iPod anschließen, oder Mock erstellen: `mkdir -p /Volumes/TestPod/.rockbox`
2. App starten (Xcode → Run)
3. Sync-Tab (⌘4) öffnen → Profil via "Gerät erkennen…" erstellen
4. Smart-Defaults prüfen: M3U8 ON, Transcode "248 kbps AAC", FAT32-Safe ON, Cleanup ON
5. Playlist hinzufügen → Sync starten → Toolbar-Indikator prüfen → Ergebnis auf Gerät verifizieren
6. Kontextmenü-Pfad: Rechtsklick auf Playlist-Card → "Sync zu ▸" Submenu

Vollständige Schritte: siehe `38-05-PLAN.md` Task 2 `<how-to-verify>` Block.

## Next Phase Readiness

- Phase 38 ist vollständig: alle 5 Pläne (01–05) abgeschlossen
- Alle 6 Wave-0-Test-Suites vorhanden und grün
- UAT-Checkpoint ist auto-approved; manuelle Verifikation via `/gsd-verify-work` steht offen
- Nächste Phase: gemäss ROADMAP (v2.0 macOS Native — Phase 38 ist das letzte aktive Element)

---

## Known Stubs

None — alle Tests arbeiten mit echten In-Memory-DB-Daten. Kein Placeholder-Content.

## Threat Flags

Keine neuen Security-relevanten Surfaces. Test-Code greift nur auf `DatabaseManager.inMemory()` zu — vollständig isoliert, kein Zugriff auf Produktionsdaten.

## Self-Check: PASSED

- `macos-app/MLMTests/PickerSheetTests.swift`: FOUND (commit `0039462`)
- `macos-app/MLMTests/SyncContextMenuTests.swift`: FOUND (commit `0039462`)
- Commit `0039462`: FOUND in `git log --oneline`
- 4 PickerSheetTests + 4 SyncContextMenuTests = 8 neue Tests dokumentiert
- Alle 6 Wave-0-Suites: MigrationTests ✓ SyncViewModelTests ✓ SyncServiceTests ✓ DeviceDetectorTests ✓ PickerSheetTests ✓ SyncContextMenuTests ✓

*Phase: 38-folder-device-sync-v2-0-macos-playlists-library-auswahlen-au*
*Completed: 2026-05-18*
