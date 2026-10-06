# MLM — instructions for every agent

MLM is a native macOS music library manager: SwiftUI (+ AppKit where SwiftUI has no equivalent), SwiftPM, GRDB/SQLite, deployment target **macOS 27**. The approved redesign is implemented on branch `redesign/b3` (2026-10-06; tag `v0.9` = state before the redesign). `B3-CONFORMANCE.md` is the status (verdict per inventory ID, residual differences, Oliver's launch checklist) and `B3-PLAN.md` §4 holds the decisions (`IMP-001` … `IMP-124`).

## Read before you write UI code

1. **`UI-CONVENTIONS.md`** — the binding rulebook (rule IDs `UC-<AREA>-<nn>`). Cite rule IDs in reviews and commits. Its §22 "Never" list is the review checklist.
2. **`design/b1/`** — the approved design packet. `THOUGHTS.md` is the design; **its §10 "Oliver's answers" is binding and overrides everything else, including the mockups** (Space = preview only, never Play/Pause, no Space-bar setting; macOS 27 only — Liquid Glass APIs used unconditionally, no `#available`, no `MLMGlass`, no macOS 15 fallbacks; Activity = toolbar item + popover + window; Eject in the sync-profile menu). The `*.html` mockups give rules, copy, order and states — not code. `COVERAGE.md` is the definition of done per inventory ID.
3. **`B3-PLAN.md`** — work packages, owners, dependencies, the migration register (§3) and implementation decisions `IMP-nnn` (§4).
4. Background: `design/B1-UI-INVENTORY.md` and `design/inventory/*.md` (what exists today and its problems), `ROADMAP.md`, `A0-LIBRARY-DEFINITION.md`. `UI-GROUNDTRUTH.md` is superseded (history only).

Precedence: `THOUGHTS.md` §10 > `UI-CONVENTIONS.md` > rest of `THOUGHTS.md` > mockups. If something is unspecified, choose what fits the principles and the nearest pattern, and record it as `IMP-nnn` in `B3-PLAN.md` §4.

## Standing constraints (no exceptions)

- **Foreign keys stay disabled** (`config.foreignKeysEnabled = false`, test-locked). Write manual cascades.
- **Never inspect a live database with `sqlite3 -readonly`** (WAL; stale snapshot). In agent work, don't touch the live database at all.
- **`swift test` prints two runner summaries** (Swift Testing + XCTest). Verify new suites by name, not by the total count.
- **Verify with `swift build` + `swift test` only.** No app launch, no screenshots, no AppleScript / UI scripting.
- **Never read** `~/Library/Application Support/MLM/.env` or anything under `~/Library/Application Support/com.musiclibrary.app/`.
- **Never touch the live library or `/Volumes/Lexxar`.** Tests use temporary databases and temporary library folders/files.
- **Every schema change is a new numbered GRDB migration**; never edit an existing one. Migration numbers are assigned by the coordinator in `B3-PLAN.md` §3. Pre-migration backups must keep working.
- **Commits:** `feat(scope): …` / `fix(scope): …` (also `docs`, `test`, `refactor`). **No `Co-Authored-By` lines.** Work on a branch off `redesign/b3` (`b3/<package-id>`); never commit to `main`; never move tag `v0.9`.
- **Fix — don't port — known logic bugs** on the surfaces you touch, and say so in the commit message.
- Shared files (`MLM/App/MLMApp.swift`, the navigation model, `DependencyContainer.swift`, `DatabaseManager.swift`, `Notifications.swift`) are edited only by their owning package or the coordinator.
- Native toolbar stays: no `.hiddenTitleBar`, no custom window chrome, no floating player.
- UI copy is English only, no emoji, glossary words only (`UI-CONVENTIONS.md` §16–17).
