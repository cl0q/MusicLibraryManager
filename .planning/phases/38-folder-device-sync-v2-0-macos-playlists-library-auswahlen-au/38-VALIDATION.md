---
phase: 38
slug: folder-device-sync-v2-0-macos-native
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-05-17
---

# Phase 38 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution. Filled by planner during Phase 38 PLAN.md writes; see 38-RESEARCH.md §"Validation Architecture" for the source mapping.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Swift Testing (Xcode 16+, in-project, same as Phase 37) |
| **Config file** | `macos-app/MLM.xcodeproj` (test target `MLMTests`) |
| **Quick run command** | `xcodebuild test -project macos-app/MLM.xcodeproj -scheme MLM -only-testing:MLMTests/SyncServiceTests` |
| **Full suite command** | `xcodebuild test -project macos-app/MLM.xcodeproj -scheme MLM` |
| **Estimated runtime** | ~45–90 seconds (full suite); ~10s (quick run on SyncServiceTests only) |

---

## Sampling Rate

- **After every task commit:** Run `xcodebuild test … -only-testing:MLMTests/{relevant-suite}`
- **After every plan wave:** Run full suite
- **Before `/gsd-verify-work`:** Full suite green + manual UAT (actual iPod or fake `.rockbox` volume)
- **Max feedback latency:** ~90 seconds (full suite)

---

## Per-Task Verification Map

*Filled by planner per PLAN.md. Each task references a SYNC-v2-NN ID from RESEARCH.md §"Proposed Requirements", a test file under `macos-app/MLMTests/`, and an `automated` command of the form above. Wave 0 (planner-defined) installs missing test files marked ❌.*

| Task ID (TBD) | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---|---|---|---|---|---|---|---|---|---|
| 38-01-XX | 01 | A | SYNC-v2-01..10 | — | Migration v_sync_toggles idempotent + columns present | unit | `xcodebuild test … -only-testing:MLMTests/MigrationTests` | ❌ W0 | ⬜ |
| 38-02-XX | 02 | A | SYNC-v2-11..14 | — | SyncViewModel add/remove/update mutations + .syncProfileDidChange | unit | `xcodebuild test … -only-testing:MLMTests/SyncViewModelTests` | ❌ W0 | ⬜ |
| 38-03-XX | 03 | A | SYNC-v2-15..18 | — | cancelSync flag-based stop + cleanup-deletion branch + m3u8-gate + transcode-mode branch | unit | `xcodebuild test … -only-testing:MLMTests/SyncServiceTests` | ✅ extend existing | ⬜ |
| 38-04-XX | 04 | B | SYNC-v2-19 | — | PlaylistPickerSheet / TrackPickerSheet renders + multi-select + idempotent add | snapshot+unit | `xcodebuild test … -only-testing:MLMTests/PickerSheetTests` | ❌ W0 | ⬜ |
| 38-05-XX | 05 | B | SYNC-v2-20 | — | "Sync to ▸" submenu in TrackContextMenu + PlaylistCard | manual+unit | `xcodebuild test … -only-testing:MLMTests/SyncContextMenuTests` | ❌ W0 | ⬜ |
| 38-06-XX | 06 | B | SYNC-v2-21 | — | createProfileSheet "Detect device ▸" dropdown + smart-defaults application | unit | `xcodebuild test … -only-testing:MLMTests/DeviceDetectorTests` | ❌ W0 | ⬜ |
| 38-07-XX | 07 | B | SYNC-v2-22 | — | Toolbar indicator visible across routes during isRunning | manual | UAT script | manual | ⬜ |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `macos-app/MLMTests/MigrationTests.swift` — v_sync_toggles migration (assert columns exist, defaults correct, idempotent re-run)
- [ ] `macos-app/MLMTests/SyncViewModelTests.swift` — addPlaylists/addTracks/removePlaylists/removeTracks/updateProfileSettings + .syncProfileDidChange posting
- [ ] `macos-app/MLMTests/SyncServiceTests.swift` — extend existing: cancellation mid-run, cleanup_removed_files toggle on/off, transcode_mode branches, generate_m3u8 toggle, hardlink-then-copy fallback (cross-FS smoke test)
- [ ] `macos-app/MLMTests/PickerSheetTests.swift` — playlist/track picker behavior (multi-select, search, idempotent commit)
- [ ] `macos-app/MLMTests/SyncContextMenuTests.swift` — submenu construction, profile listing
- [ ] `macos-app/MLMTests/DeviceDetectorTests.swift` — `.rockbox` mock scan, empty-state, smart-default application
- [ ] No new framework install — Swift Testing + Xcode test target already in use (Phase 37 pattern)

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| iPod end-to-end sync | SYNC-v2-22 (UAT) | Requires real hardware (Rockbox iPod) or a hand-mounted FAT32 volume with `.rockbox` directory | (1) Mount iPod or create `mkdir /Volumes/TestPod/.rockbox`; (2) Create profile via Detect-device-Dropdown, assert smart-defaults; (3) Add playlist; (4) Sync Now; (5) Verify m4a files at destination + M3U8 playlist; (6) Open on iPod, play track. |
| Toolbar indicator visibility | SYNC-v2-22 | Requires running across multiple routes (Library, Playlists, Sync) and observing global toolbar state during a real `isRunning=true` window | Start sync via Sync route, navigate to Library, confirm toolbar indicator persists; click it, confirm navigates back to Sync with active profile selected. |
| Toast "Rockbox erkannt — Device-Defaults aktiviert" | D-03 | Visual placement + animation timing | Trigger create-from-detected-device path; observe toast appears non-blocking, dismisses after ~3s. |
| Cross-FS hardlink → copy fallback | SYNC-v2-17 (validation gap from RESEARCH) | Difficult to unit-test cleanly; requires actual cross-filesystem mounts | Run sync to a FAT32-formatted USB drive; verify all m4a files arrive (copy path exercised); compare checksum to cache entry. |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (6 new test files)
- [ ] No watch-mode flags
- [ ] Feedback latency < 90s
- [ ] `nyquist_compliant: true` set in frontmatter (after planner fills concrete task IDs)

**Approval:** pending
