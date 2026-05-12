---
phase: 36
slug: playlists-v2-0-macos-native
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-05-12
---

# Phase 36 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | XCTest + Swift Testing (mixed — existing `MLMTests/` uses XCTest) |
| **Config file** | `macos-app/Package.swift` (SPM) |
| **Quick run command** | `cd macos-app && swift test --filter PlaylistRepositoryTests` |
| **Full suite command** | `cd macos-app && swift test` |
| **Estimated runtime** | ~25 seconds full suite (10 existing DB tests + ~15 new) |

---

## Sampling Rate

- **After every task commit:** Run `swift test --filter <relevant>Tests`
- **After every plan wave:** Run `swift test` (full)
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

> Populated by planner. Each PLAN.md task should declare its automated verify command in `<acceptance_criteria>`. The map below is filled in after plans are written.

| Task ID | Plan | Wave | Decision Ref (D-NN) | Test Type | Automated Command | Status |
|---------|------|------|---------------------|-----------|-------------------|--------|
| TBD | TBD | TBD | TBD | TBD | TBD | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `MLMTests/DatabaseTests/PlaylistRepositoryTests.swift` — covers D-05 (cover_is_custom column), `addTracks`, `togglePin`, fractional-position reorder
- [ ] `MLMTests/ServiceTests/PlaylistCoverServiceTests.swift` — covers D-01..D-04 (mosaic generation, gradient fallback, on-add/on-remove trigger, AVAsset artwork extraction)
- [ ] `MLMTests/Fixtures/playlist-cover-fixtures/` — sample mp3/flac/m4a with embedded artwork + one without artwork (gradient-fallback case)
- [ ] Test target wiring in `Package.swift` if any new test bundle is added (current single `MLMTests/` should suffice)

*If existing infrastructure already covers these: state "Existing `MLMTests/DatabaseTests` covers schema; new file additions only."*

---

## Manual-Only Verifications

| Behavior | Decision Ref | Why Manual | Test Instructions |
|----------|--------------|------------|-------------------|
| Sidebar DisclosureGroup default-expanded + persists across launches | D-08 | `@AppStorage` round-trip needs real `UserDefaults`; UI inspection | Launch app, collapse Pinned-DisclosureGroup, quit, relaunch, verify state preserved |
| Mosaic-cover visual quality (auto4 with mixed artwork) | D-01, D-02 | Subjective; gradient-tile fill blending isn't unit-testable | Create playlist with 4 tracks, verify 2×2 mosaic; remove artwork from 1, regen, verify gradient-tile in empty slot |
| Gradient-fallback look for 0-artwork playlists | D-03 | Visual subjective | Create playlist of remote-only tracks (no organized_path → no AVAsset artwork), verify gradient+initials card |
| User-Override sticky-lock across track add/remove | D-05, D-06 | UI-driven (drop-target on Card); verifies write-then-readback | Drop image on card, add tracks → cover unchanged; Reset to Auto → mosaic regenerates |
| Sidebar click → PlaylistDetailView direct navigation (no grid flash) | D-09 | UI navigation transition | Click pinned playlist in Sidebar, verify Detail-View renders directly with no intermediate Grid render |
| 8-pin soft-limit UI hint | D-10 | Banner UI display | Pin 8 playlists, attempt to pin 9th, verify inline banner appears + 9th doesn't pin |

*Mosaic gap-tile color quality and cover render parity will be eyeballed during UAT.*

---

## Validation Sign-Off

- [ ] All Phase 36 tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (PlaylistCoverService tests, fixture audio files)
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter once planner fills per-task map

**Approval:** pending
