---
phase: 12
slug: import-external-playlists
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-03-29
---

# Phase 12 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | vitest (UI) / cargo test (Rust) |
| **Config file** | `ui/vitest.config.ts` / `src-tauri/Cargo.toml` |
| **Quick run command** | `cd ui && npx vitest run --reporter=verbose` |
| **Full suite command** | `cd ui && npx vitest run && cd ../src-tauri && cargo test` |
| **Estimated runtime** | ~30 seconds |

---

## Sampling Rate

- **After every task commit:** Run `cd ui && npx vitest run --reporter=verbose`
- **After every plan wave:** Run `cd ui && npx vitest run && cd ../src-tauri && cargo test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|-----------|-------------------|-------------|--------|
| 12-01-01 | 01 | 1 | TBD | unit | `cargo test playlist_import` | ❌ W0 | ⬜ pending |
| 12-01-02 | 01 | 1 | TBD | unit | `cargo test m3u_parser` | ❌ W0 | ⬜ pending |
| 12-02-01 | 02 | 2 | TBD | unit | `cd ui && npx vitest run import` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `src-tauri/tests/playlist_import_test.rs` — stubs for playlist import parsing
- [ ] `src-tauri/tests/m3u_parser_test.rs` — stubs for M3U parsing
- [ ] `ui/src/components/__tests__/PlaylistImport.test.tsx` — stubs for import UI

*Existing test infrastructure (vitest + cargo test) covers framework needs.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| File dialog opens and selects playlist files | TBD | Requires native OS dialog interaction | Open import dialog, select .m3u file, verify file path populated |
| Match preview displays correctly | TBD | Visual layout verification | Import playlist with mixed matches, verify preview shows matched/unmatched tracks |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
