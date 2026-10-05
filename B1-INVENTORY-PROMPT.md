You are preparing the ground for **B1 — the design session** of MLM, a native macOS music library manager at `/Users/olli/schenanigans/MusicLibraryManager` (SwiftUI, SwiftPM package, GRDB; no Xcode project). A separate design agent ("Fable") will later redesign every screen of the app. Fable must spend its time on **design thinking and mockups**, not on digging through Swift code. Your job is the digging: produce one complete, verified, user-centred inventory of **everything a user can see and do in MLM** — every window, view, tab, panel, sheet, alert, context menu, menu-bar command, keyboard shortcut, drag-and-drop target, state, and end-to-end flow — and, for each, **what the user wants to do there and what they want to see there**.

You do **not** design. You do not propose layouts, colours or components. You describe the territory, its purpose, its users' goals, its states and its problems, so that a designer who has never seen the code can understand the app completely.

Answer Oliver (the owner and only user) in **German**. Write the inventory itself in **English** (repo convention; UI copy is English).

---

## 1. Output

`design/B1-UI-INVENTORY.md` (create the `design/` folder). One file is preferred. If it would exceed ~3,000 lines, write `design/B1-UI-INVENTORY.md` as the index (sections 0–2 and 8–12 below) plus one file per area in `design/inventory/` (e.g. `library.md`, `playlists.md`, `settings.md`), each linked from the index.

Do **not** change any code, test, script or existing document. Do not commit anything unless Oliver asks; the new files stay untracked.

## 2. Hard constraints

1. **Read, don't run.** Never launch MLM, never take screenshots, never use shotty or AppleScript. Everything comes from reading code and docs.
2. **Never touch the live install or live data**: no reads of `~/Library/Application Support/com.musiclibrary.app/`, `~/Library/Application Support/MLM/` (contains `.env` credentials — never read it), `~/Library/Caches/com.mlm.transcode_cache`, `/Volumes/Lexxar`. For data scale use the numbers already written in `ROADMAP.md` §0–§1 (e.g. 12,935 tracks, 8,020 album rows, 6,209 "unknown album" tracks).
3. **Verify against code.** Every surface entry cites the implementing file(s) with line ranges. Where `UI-GROUNDTRUTH.md` (written Aug 2026, partly aspirational) and the code disagree, describe what the **code does today** and record the discrepancy (section 11). Don't present the ground truth's plans as existing behaviour.
4. User-scratch folders `.opencode/`, `.qwen/`, `graphify-out/`, `sketches/`, `test.log`, `todo_dump.md` may be **read** but never modified.
5. Use read-only sub-agents (e.g. `Explore`) in parallel to cover areas quickly — but you own the result: merge, de-duplicate, re-check citations, and run the coverage proof (section 12) yourself.

## 3. Read first

1. `todo_dump.md` — Oliver's own words on what the design session should cover ("every view, every flow, every element"), and his wishes (albums, track order, source-as-album removal, sharing without provenance, multi-library, backups).
2. `ROADMAP.md` — §0 (corrected premises, data scale), §1.3 (UI surface list), §3 (Track B: B1/B2/B3, constraints carried forward), §4 (album work — C2 screens don't exist yet and must be designed in B1), §6 standing constraints.
3. `A0-LIBRARY-DEFINITION.md` — what a "library" / library file (`.mlibm`) is; the library picker, library file icon and missing/not-connected states are B1 work.
4. `UI-GROUNDTRUTH.md` — current binding UI reference: §1 foundations (principles, glossary §1.5, state vocabulary §1.6, copy rules §1.7), Part 2 shell, Part 3 screens, Part 5 copy deck. Treat its "Changes vs. current" boxes as **evidence of known problems**, not as done.
5. `docs/audit/UI-BUGS.md`, `docs/audit/LOGIC-BUGS.md`, `docs/audit/SUMMARY.md`, `docs/audit/LIQUID-GLASS-PLAN.md`, `docs/audit/SNAPSHOT-HARNESS.md` — known issues and prior Liquid Glass thinking.
6. `sketches/*.html` — four earlier concept sketches (prior art; list what each explored, briefly).
7. `.planning/` if present (milestones, seeds, todos) — skim for user intents and deferred ideas that touch the UI (e.g. the "daily-driver loop": folder explorer + native playlists + spacebar preview, multi-select bulk actions).
8. Code: `MLM/App/` (scenes, menus, `AppDelegate`, `DependencyContainer`, `LibraryCommands.swift`), `MLM/Views/**` (67 view files in 18 folders), the view models in `MLM/ViewModels/`, and `MLM/Utilities/Notifications.swift` (cross-view triggers).

## 4. Product context you must capture (section 1 of the inventory)

- Who uses it and how: one power user (Oliver), DJ-ish music collector, ~13k tracks on an external disk, sources SoundCloud / YouTube / Spotify / Apple Music / direct downloads, syncs to devices (e.g. Rockbox/iPod), wants MLM to become the app he **lives in daily** (navigate + listen in one surface), not just a manager.
- Platform facts that matter to a designer: macOS deployment target (read `Package.swift` — currently `.macOS("15.0")`), SDK in use (macOS 27), therefore which Liquid Glass / new SwiftUI APIs need availability fallbacks; single main window (a `Window` scene since A3 — no second windows); the Settings window and the remote-playlists window are AppKit-managed `NSWindow`s (`AppDelegate`).
- Locked decisions a designer must respect (cite source): native macOS look only — system colours, materials and containers, no custom theme or palette (Oliver's standing feedback; reference apps: Apple Music, Mail, System Settings, Little Snitch, Reeder); native toolbar stays — no `.hiddenTitleBar`, no floating player overlays (`ROADMAP.md` §3); English UI only; one meaning per word (glossary); critical states are always text, never icon-only; one active library per window/process (A0 D4).
- Data realities that shape the UI: library size, remote vs local tracks, the 48 % "unknown album" problem, external drive that is often unmounted, long-running background work (downloads, analysis, sync, transcoding).

## 5. What to inventory (sections 2–10)

Go wide first (list every surface), then deep (fill the template). Find surfaces mechanically, not from memory — at minimum grep `MLM/` for: `WindowGroup|Window(|Settings|NSWindow`, `NavigationSplitView|SidebarSection`, `.toolbar`, `.inspector`, `.sheet(`, `.popover(`, `.alert(`, `.confirmationDialog(`, `.contextMenu`, `CommandMenu|CommandGroup|.keyboardShortcut|onKeyPress`, `.onDrop|.draggable|.dropDestination|onDrag`, `.searchable`, `ContentUnavailableView`, `ProgressView`, `NSOpenPanel|NSSavePanel`, `NotificationCenter.default.post` (cross-view triggers), `Toast|Banner`, and `@AppStorage` (persisted UI state).

### Surface entry template (use it for every view, panel, sheet and window)

```
### <ID> — <Name as the user sees it>
- Reached via: (sidebar item / shortcut / menu / context menu / button in <ID> …)  ·  Leads to: <IDs>
- Code: `path:lines` (view), `path:lines` (view model)
- Purpose: one sentence, in the user's terms.
- User goals (jobs to be done), each tagged daily / weekly / rare:
  1. …
- What the user wants to see, in priority order (information, not layout):
  1. …
- Elements today: <ID>.E01 … — what each is and does (labels verbatim).
- Interactions: click · double-click · right-click (→ CM-ids) · keyboard (→ K-ids) · drag & drop (→ D-ids) · multi-select · hover/tooltips.
- States: default · empty · loading · error · offline/drive not connected · filtered-empty · huge data · in-progress background work — what the code shows for each today ("not handled" is a valid answer).
- Data scale / performance notes.
- Pain points today (evidence: `file:line`, UI-GROUNDTRUTH §, audit doc, todo_dump line).
- Related flows: F-ids.
- Constraints / locked decisions that apply.
- Open questions for the designer (questions only — no answers, no solutions).
```

### ID scheme (stable — Oliver and Fable will reference these in feedback)

`W-` windows/scenes · `V-` sidebar sections and main views · `P-` persistent panels (sidebar, toolbar, player bar, activity panel, inspector) · `ST-` settings tabs · `S-` sheets/popovers/panels · `A-` alerts/confirmations · `CM-` context menus · `M-` menu-bar menus · `K-` keyboard shortcuts · `D-` drag & drop · `F-` flows · `G-` global states. Elements: `<ID>.E01`. Example: `V-LIB.E04` = the Status column of the Library table. Never renumber once written.

### Required sections

0. **How to read this** — ID scheme, legend for daily/weekly/rare, how citations work.
1. **Product context** — section 4 above.
2. **App map** — the navigation tree (window → sidebar sections → detail views → inspectors/sheets), as a Mermaid diagram plus an indented list with IDs.
3. **Surfaces** — every `W-`, `V-`, `P-`, `ST-` entry with the full template. Include the A3 library surfaces (launch placeholder "No library open", "can't be opened", library-file copy prompt, adoption sheet "Set up your library file", New Library sheet, switch alert, File-menu library items, Library tab "Library file" section, Storage Location tab), the Backup tab, the first-run wizard, Global search / universal search, the remote-playlists window, the track inspector and all its tabs, Discover/Reels/Discovery inbox, Review (duplicates & conflicts), Sync (profiles, detail, pickers, device ingest), Sources, Folders, Queue, Playlists grid/detail, Library, Activity panel (operations + logs), player bar, toolbar, sidebar (incl. pinned playlists), Dock menu.
4. **Context menus** — every `CM-`: where it appears, every item verbatim in order, enabled/disabled rules (e.g. single vs multi selection, local vs remote tracks), what each item does.
5. **Sheets, popovers, panels, alerts** — every `S-`/`A-`: trigger, content, buttons verbatim, consequence, cancel path.
6. **Menu bar & keyboard** — every `M-` item and every `K-` shortcut, with scope (global / focused view) and conflicts.
7. **Drag & drop** — every `D-`: source, target, payload, what happens; also places where a user would expect drag & drop but it doesn't exist (mark as "expected, missing").
8. **Global states & vocabulary** — `G-` entries: drive not connected, source disconnected/expired, library loading/failed, background processing, track availability states (UI-GROUNDTRUTH §1.6), how/where each is shown today.
9. **End-to-end flows** — 15–25 `F-` journeys, each as numbered steps with surface IDs and the user's intent at each step, plus where it breaks or feels bad today. At least: first launch with no library; daily listening session (browse → preview with space → play → queue); find a track fast (search); import a YouTube/SoundCloud playlist and download it; fix failed downloads; create and fill a playlist by drag & drop and multi-select; organize via folders; sync a profile to a device and handle failures; review duplicates; edit metadata in the inspector; discover/recommendations; back up and restore; switch / create / open a library file (incl. Finder double-click); external drive unplugged mid-session; settings changes (library folder, sources sign-in, transcode cache); albums (today: none — describe what the user wants per `todo_dump.md`/ROADMAP §4 as a "future flow").
10. **Background work visible to the user** — downloads, imports, analysis pipeline, sync, transcoding, backups, path migration: where progress/results/errors appear today, how the user controls them.
11. **Known pain points & doc-vs-code discrepancies** — one table: ID · problem · evidence · severity for daily use. Include missing features the user explicitly wants (from `todo_dump.md`, `.planning/`), marked as wishes, not bugs.
12. **Coverage proof** — (a) every file under `MLM/Views/**` mapped to ≥1 ID (table: file → IDs; non-view helpers marked "helper"); (b) every hit of the greps in section 5 mapped to an ID (table: `file:line` → ID). The count of rows must equal the grep counts; state both numbers. Nothing may be "unmapped".

## 6. Quality bar

- Specific, not generic: "wants to see which of the 44 tracks failed and why, without leaving the playlist" — not "wants good feedback".
- User goals come from evidence (code paths that exist, todo_dump, planning docs, audit docs, UI-GROUNDTRUTH purposes) — mark any inference as *(inferred)*.
- Labels, menu items and messages are quoted verbatim from code.
- No design proposals anywhere. If you notice a design idea, turn it into an "open question for the designer".

## 7. Finish

1. Re-run the greps and check the coverage tables are complete.
2. Report to Oliver in German: where the file(s) are, how many surfaces / context menus / sheets / shortcuts / flows you documented, the coverage numbers, the 10 biggest pain points in one line each, and any area you could not fully resolve from code (with why).
