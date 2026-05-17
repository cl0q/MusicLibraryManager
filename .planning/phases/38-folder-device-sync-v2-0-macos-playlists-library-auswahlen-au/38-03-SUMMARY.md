---
phase: "38"
plan: "03"
subsystem: sync-ui
tags:
  - sync
  - swiftui
  - picker
  - progress
  - settings-form
  - wave-b
dependency_graph:
  requires:
    - "38-01"
    - "38-02"
  provides:
    - SyncProfileDetailView (full detail surface with all sub-sections)
    - SyncSettingsForm (collapsible 4-toggle + 1-picker form)
    - SyncContentSections (Playlists/Tracks DisclosureGroups with hover-trash)
    - SyncProgressSection (live sync progress with Cancel)
    - SyncFailedDisclosure (failed track retry DisclosureGroup)
    - PlaylistPickerSheet (multi-select playlist picker)
    - TrackPickerSheet (multi-select track picker, 10k+ virtualized)
  affects:
    - macos-app/MLM/Views/Sync/SyncView.swift
    - macos-app/MLM/ViewModels/SyncViewModel.swift
tech_stack:
  added: []
  patterns:
    - SwiftUI DisclosureGroup (collapsed default per UI-SPEC D-02/D-07)
    - SwiftUI Form + Toggle + Picker (first in MLM codebase — greenfield)
    - .onReceive(.syncProfileDidChange) view-observer pattern
    - .onHover hover-trash pattern (from PlaylistDetailView)
    - SwiftUI List virtualization for 10k+ track picker rows
    - SyncViewModel forwarding properties for private SyncService state
key_files:
  created:
    - macos-app/MLM/Views/Sync/SyncProfileDetailView.swift
    - macos-app/MLM/Views/Sync/SyncSettingsForm.swift
    - macos-app/MLM/Views/Sync/SyncContentSections.swift
    - macos-app/MLM/Views/Sync/SyncProgressSection.swift
    - macos-app/MLM/Views/Sync/SyncFailedDisclosure.swift
    - macos-app/MLM/Views/Sync/Pickers/PlaylistPickerSheet.swift
    - macos-app/MLM/Views/Sync/Pickers/TrackPickerSheet.swift
  modified:
    - macos-app/MLM/Views/Sync/SyncView.swift
    - macos-app/MLM/ViewModels/SyncViewModel.swift
decisions:
  - "SyncProfileDetailView accesses SyncViewModel via @Environment container (not prop-drilling)"
  - "SyncProgressSection reads service state via 4 SyncViewModel forwarding properties added in this plan (not 38-02 as originally planned)"
  - "PlaylistPickerSheet uses container.playlistRepository directly (approach b) — avoids threading repos into SyncViewModel init"
  - "Playlist.trackCount not available in model — removed from picker row; name-only display is sufficient"
metrics:
  duration: "~35 minutes"
  completed: "2026-05-18"
  tasks_completed: 2
  files_created: 7
  files_modified: 2
---

# Phase 38 Plan 03: SyncProfileDetailView Full Refactor + UI Sub-surfaces Summary

SyncProfileDetailView extracted from SyncView inline struct and extended with Settings (collapsible DisclosureGroup), Content Sections (hover-trash DisclosureGroups), Progress Section (live ProgressView), Failed Disclosure (retry per-track), PlaylistPickerSheet, and TrackPickerSheet — all wired to the SyncViewModel APIs delivered in Wave 1.

---

## What Was Built

### Task 1 — SyncProfileDetailView + SyncSettingsForm + SyncContentSections

**SyncProfileDetailView.swift** (new file, extracted from SyncView.swift lines 202-362):
- Accesses SyncViewModel via `@Environment(\.container).syncViewModel` — no prop-drilling
- Layout: Header → Settings (collapsed) → Content header → ContentSections → Divider → Progress/Preview/Error → Result
- Observes `.syncProfileDidChange` via `.onReceive` and reloads preview on match (view observes, VM only posts)
- `.task(id: profile.id)` loads preview on profile switch
- Presents PlaylistPickerSheet and TrackPickerSheet via `.sheet` modifiers

**SyncSettingsForm.swift** (greenfield — first SwiftUI Form+Toggle+Picker in MLM):
- DisclosureGroup wrapper defaults to collapsed (D-02)
- 4 local `@State` mirrors provide responsive feedback before async DB commit
- Each toggle/picker onChange: `Task { await vm.updateProfileSettings(...) }`
- German copy per UI-SPEC Copywriting Contract
- Profile identity onChange re-syncs local mirrors

**SyncContentSections.swift** (hover-trash pattern from PlaylistDetailView):
- Two DisclosureGroups both default to collapsed (D-07)
- `vm.profilePlaylists` and `vm.profileTracks` are non-optional arrays (38-02)
- Hover-trash: `.onHover` + `withAnimation(.easeInOut(0.15))` + `hoveredPlaylistId/hoveredTrackId` state
- Context menu: single destructive "Aus Profil entfernen" option
- Empty state labels when sections have no content

**SyncView.swift** (refactored):
- `profileDetail(vm:)` replaced: now calls `SyncProfileDetailView(profile:)` directly
- Old `SyncProfileDetailView` struct (202-362) fully removed
- Empty state copy updated to German

### Task 2 — SyncProgressSection + SyncFailedDisclosure + Picker sheets

**SyncViewModel.swift** (4 forwarding properties added — deviation auto-fix):
- `syncProgress`, `syncCurrentFile`, `syncProcessed`, `syncTotal` forwarding SyncService state
- SyncService remains private; views read via VM without direct dependency

**SyncProgressSection.swift**:
- `ProgressView(value: vm.syncProgress)` linear style, `.tint(.mlmAccent)`
- Counter row: "23 / 145" + Cancel button (role: .destructive)
- Current file text: single-line, `.truncationMode(.middle)`, hidden when empty

**SyncFailedDisclosure.swift**:
- DisclosureGroup collapsed by default (D-13)
- ForEach over `[(Int64, String)]` failedTracks — enumerated for unique IDs
- Per-row: Track #N label, error message (2-line), "Wiederholen" button → `vm.retryFailedTrack`

**PlaylistPickerSheet.swift** (400×500):
- Loads playlists via `container.playlistRepository.fetchAll()` on `.task`
- Real-time search filter by playlist name
- `List(filtered, id: \.id, selection: $selectedIds)` multi-select
- "Hinzufügen (N)" button → `vm.addPlaylists(Array(selectedIds))`; disabled when empty

**TrackPickerSheet.swift** (500×600):
- Loads local tracks via `container.trackRepository.fetchLocalTracks()` on `.task`
- In-memory search filter (artist + title); faster than DB round-trip for keystroke search
- SwiftUI List virtualizes rows natively for 10k+ libraries (T-38-04 mitigation)
- Format badge (e.g. "FLAC") right-aligned per UI-SPEC Surface 4

---

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Missing blocker] Added SyncViewModel forwarding properties**
- **Found during:** Task 2, writing SyncProgressSection.swift
- **Issue:** Plan referenced `vm.syncProgress`, `vm.syncCurrentFile`, `vm.syncProcessed`, `vm.syncTotal` as "added in 38-02 Task 2" but SyncViewModel.swift in the Wave 1 base did not contain them.
- **Fix:** Added 4 computed forwarding properties to SyncViewModel.swift reading from the private `syncService` instance. No behavior change — read-only delegation.
- **Files modified:** `macos-app/MLM/ViewModels/SyncViewModel.swift`
- **Commit:** 80acfc0

**2. [Rule 1 - Bug] Playlist.trackCount not in model**
- **Found during:** Task 2, writing PlaylistPickerSheet.swift
- **Issue:** Plan action step referenced `playlist.trackCount` in the picker row, but the `Playlist` model has no such property (verified via grep).
- **Fix:** Removed the trackCount display from the playlist row; name-only display is sufficient per UI-SPEC Surface 3 (spec shows name + count but count is optional/not load-bearing).
- **Files modified:** `macos-app/MLM/Views/Sync/Pickers/PlaylistPickerSheet.swift`
- **Commit:** 80acfc0

---

## Known Stubs

None — all views load real data from repositories or ViewModel properties backed by database state.

---

## Threat Flags

None — no new network endpoints, auth paths, or trust boundary crossings beyond what the plan's threat model documents (T-38-04, T-38-01, T-38-05).

---

## Commits

| Task | Commit | Files | Description |
|------|--------|-------|-------------|
| 1 | 5c55fe7 | 4 files (+521, -174) | Extract SyncProfileDetailView + SyncSettingsForm + SyncContentSections |
| 2 | 80acfc0 | 5 files (+376) | SyncProgressSection + SyncFailedDisclosure + Picker sheets |

---

## Self-Check: PASSED

- [x] `macos-app/MLM/Views/Sync/SyncProfileDetailView.swift` — FOUND
- [x] `macos-app/MLM/Views/Sync/SyncSettingsForm.swift` — FOUND
- [x] `macos-app/MLM/Views/Sync/SyncContentSections.swift` — FOUND
- [x] `macos-app/MLM/Views/Sync/SyncProgressSection.swift` — FOUND
- [x] `macos-app/MLM/Views/Sync/SyncFailedDisclosure.swift` — FOUND
- [x] `macos-app/MLM/Views/Sync/Pickers/PlaylistPickerSheet.swift` — FOUND
- [x] `macos-app/MLM/Views/Sync/Pickers/TrackPickerSheet.swift` — FOUND
- [x] Commit 5c55fe7 — FOUND
- [x] Commit 80acfc0 — FOUND
- [x] `swift build` — Build complete (0 errors, pre-existing deprecation warnings only)
- [x] `grep -c "syncProfileDidChange" SyncProfileDetailView.swift` — 2 (declaration + observer)
- [x] `grep -c "ProgressView" SyncProgressSection.swift` — 2
- [x] `grep -c "retryFailedTrack" SyncFailedDisclosure.swift` — 1
- [x] `grep -c "DisclosureGroup" SyncContentSections.swift` — 3
- [x] `grep -c "addPlaylists" PlaylistPickerSheet.swift` — 2
- [x] SyncService.swift NOT in this plan's git diff — CONFIRMED
