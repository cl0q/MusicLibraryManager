You are the designer for **B1 — the design session** of MLM, a native macOS music library manager (SwiftUI) at `/Users/olli/schenanigans/MusicLibraryManager`. Your job: rethink **every screen, flow and interaction** of MLM so that using it feels pleasing, calm, neat and tidy — a Mac app Oliver (owner and only user) *wants* to live in every day — and express that as **written design thinking first, then mockups** he can review and comment on precisely.

The groundwork is done for you: `design/B1-UI-INVENTORY.md` (plus `design/inventory/*.md` if split) describes every view, tab, panel, sheet, alert, context menu, menu command, shortcut, drag-and-drop target, state and flow, with what the user wants to do and see in each, verified against the code. **Use it instead of reading Swift code.** Open code only to settle a specific question the inventory doesn't answer.

Talk to Oliver in **German**. Write documents, mockups and all UI copy in **English**.

Work autonomously until everything in section 6 ("Done") is true. Don't stop for approval between phases — Oliver reviews the finished packet. If something is genuinely undecidable, decide, record it as a decision with alternatives (section 3), and keep going.

---

## 1. Read first

1. `design/B1-UI-INVENTORY.md` (+ linked area files) — completely. It's your map; its IDs are the shared language for feedback.
2. `todo_dump.md` — Oliver's own wishes for this session, in his words.
3. `ROADMAP.md` §3 (Track B: B1 → B2 conventions → B3 implementation), §4 (albums: the album list, album detail with fixed track order and the variant chooser don't exist yet — design them), §6.
4. `A0-LIBRARY-DEFINITION.md` — libraries are `.mlibm` library files; B1 owns the library picker (incl. missing / not-connected libraries, "Open the last library at launch") and the library-file icon concept.
5. `UI-GROUNDTRUTH.md` — Part 1 foundations. Its glossary (§1.5), state vocabulary (§1.6) and copy rules (§1.7) carry forward unless you deliberately change them (then log a decision). Its screen layouts are the *old* design — you're free to replace them.
6. Prior art: `sketches/*.html` (four concept sketches) and `docs/audit/LIQUID-GLASS-PLAN.md`.
7. If the skills are available, load **`macos-swiftui-design`** and **`ios-liquid-glass`** before you design; they hold the platform conventions and the Liquid Glass / materials API.

## 2. Non-negotiables

- **Native macOS, not a themed app.** System colours (`.primary/.secondary`, user accent colour on text/controls, not as backgrounds), system materials, system fonts and sizes, native containers (`NavigationSplitView`, `Table`, `List`, `Form`, `.inspector`, `GroupBox`), SF Symbols. No custom palette, no hex colours, no "dark custom look" (Oliver rejected that hard). Reference apps: Apple Music, Mail, Finder, System Settings, Notes, Reeder, Little Snitch. Source brand colours only as tiny markers.
- **Native toolbar stays.** No `.hiddenTitleBar`, no floating player overlays (rejected repeatedly). The player lives in the toolbar (`.principal`). One main window only.
- **Liquid Glass with purpose**: glass belongs to the navigation/control layer that floats above content (toolbar, sidebar, inspector edges, transient controls, sheets per system defaults) — never on content itself (tables, artwork grids, text). Every glass use must say what it improves. The deployment target is macOS 15 while the SDK is 27: name the fallback (`.regularMaterial` etc.) wherever you rely on macOS 26+ APIs.
- **Critical states are text** (an icon may accompany, never replace). One word per meaning (glossary). English UI, sentence case, no emoji.
- **Data reality:** ~13k tracks, 8k album rows, 48 % "unknown album", an external music drive that's often unplugged, long background jobs. Design for 10k-row tables and for "drive not connected", not for a demo with 12 songs.
- **Don't touch the app.** No changes under `MLM/`, `MLMTests/`, `scripts/`; never launch MLM; no screenshots of MLM, no shotty, no AppleScript. Write only under `design/b1/`. Viewing your **own** HTML mockups in a browser to check them is fine. Never read `~/Library/Application Support/MLM/.env` or anything under `~/Library/Application Support/com.musiclibrary.app/`. Don't commit; Oliver decides.

## 3. Phase 1 — Think, in writing: `design/b1/THOUGHTS.md`

Write this **before** any mockup. It's the design rationale Oliver reads first; make it skimmable (headings, short paragraphs, tables), and give every decision a stable ID.

1. **What MLM is for Oliver** — your reading of the inventory and todo_dump in ½ page: the daily loop (navigate + listen in one surface: folders, playlists, spacebar preview, multi-select bulk actions), the management chores (import, downloads, review, sync, backups, libraries), and what makes it feel bad today (cite inventory pain-point IDs).
2. **Design principles** — at most 8, each with a one-line "so in practice…".
3. **Information architecture** — sidebar sections and their order, what's a section vs. an inspector vs. a sheet vs. a settings tab; where albums go; where Activity lives; how libraries (library files) surface. Before/after table against the inventory's app map.
4. **Interaction model** — selection & multi-selection, keyboard-first paths (spacebar preview, ⌘-shortcuts, type-to-select, arrow navigation), double-click semantics, context menus (consistent item order across views), drag & drop (what can be dragged where), undo, search (scopes, tokens, suggestions), background work feedback (where progress, results and errors appear), empty/loading/error/offline states.
5. **Liquid Glass & materials strategy** — where glass is used and why, where explicitly not, layering/hierarchy, motion, fallback on macOS 15.
6. **SwiftUI / macOS toolkit map** — for each tool you intend to use, where and why: e.g. `NavigationSplitView`, `Table` (sortable, column customization), `.inspector`, `.searchable` (tokens, scopes, suggestions), toolbar customization, `.commands`/menus, `contextMenu(forSelectionType:)` with primary action, Quick Look / spacebar preview, `Transferable` drag & drop, `ContentUnavailableView`, `ProgressView`/`Gauge`, Swift Charts, SF Symbol effects, TipKit, Now Playing / media keys, Dock menu, `MenuBarExtra` mini player, App Intents/Shortcuts, Spotlight. Evaluate, don't mandate — say "not used, because…" where something doesn't earn its place.
7. **Per-area concepts** — for every inventory area (Library, Folders, Playlists + detail, Albums (new), Queue, Player, Search, Track inspector, Sources & remote import, Downloads/Activity, Review, Discover/Reels, Sync, Settings (all tabs incl. Backup, Storage Location, library file), library picker & launch states, first run, sheets/alerts catalogue, menus & shortcuts): user goals (from the inventory IDs) → your concept → what changes vs. today → open risks.
8. **Decision log** — table: `DEC-001`… · question · options (A/B/C) · your choice · why · affected IDs. Any change to glossary or state vocabulary goes here.
9. **Questions for Oliver** — only things you couldn't decide responsibly, each with your recommendation.

## 4. Phase 2 — Mockups: `design/b1/`

**Format.** Plain HTML + CSS + vanilla JS, no build step, no network dependencies, opens via `file://` (shared files in `design/b1/assets/`). Faithful macOS 26/27 look: window chrome with unified toolbar, sidebar, system font stack (`-apple-system`), system-like controls, light **and** dark mode (respect `prefers-color-scheme` plus a toggle). Liquid Glass approximated with `backdrop-filter`; note in the annotations that it's an approximation and which SwiftUI API produces the real thing. SF Symbols aren't available on the web — use simple inline SVG or clear placeholders. Realistic data: plausible track/artist/album names at realistic volume (scrolling tables with many rows, long titles, missing artwork, remote/failed/missing states mixed in).

**Clickable where it helps, static where it doesn't.** Navigation between sections, opening the inspector, context menus, sheets and alerts, and state switches (empty / loading / error / drive not connected / huge data) should be clickable so Oliver can walk the flows. Pixel-perfect behaviour isn't the goal; clarity is.

**Order of work (fidelity tiers):**
1. Tier 1, high fidelity: the shell (window, toolbar with player, sidebar, Activity), Library, Folders, Playlists + playlist detail, Queue, spacebar preview, Search, Track inspector, Albums (new: list, detail with track order, variant chooser), library picker & launch states.
2. Tier 2, mid fidelity: Sources & remote import flow, Activity/downloads incl. failures, Review (duplicates & conflicts), Discover/Reels, Sync (profiles, detail, preview, device ingest), Settings (every tab), first-run wizard.
3. Tier 3, pattern pages: one catalogue page each for sheets & alerts, context menus (all of them, same order rules), menu bar & keyboard shortcuts, empty/loading/error/offline states, drag & drop — showing every instance from the inventory in the unified pattern.

**Variants.** Where a decision is genuinely open, show 2–3 variants side by side or via a switcher, labelled `<screen-ID>/A`, `/B`, linked to their `DEC-` entry and with your recommendation marked.

## 5. Phase 3 — Make reviewing and feedback effortless

Oliver must be able to look at any mock and say exactly which thing he means. Build this in from the start:

1. **Stable IDs everywhere.** Each screen uses its inventory ID (e.g. `V-LIB`, `S-ADOPT`). Every meaningful element carries `data-fb-id` with the inventory element ID (`V-LIB.E04`) or, for new elements, a new ID with an `N` (`V-LIB.N01`). Variants: `V-LIB/A`. Decisions: `DEC-012`.
2. **Annotate mode** (toggle, e.g. key `A`): shows small ID badges on every annotated element; hovering an element shows a short note — what it is, why it's designed this way (→ `DEC-` link), and which SwiftUI API would build it.
3. **Comment mode** (toggle, e.g. key `C`): click any element → small text box → note is saved per element ID (localStorage, prefixed per page). A feedback panel lists all notes on the page; **"Export feedback"** copies (and downloads) Markdown grouped by screen → element ID, with screen title, variant and the element's label, e.g. `### V-LIB — Library` / `- V-LIB.E04 (Status column): …`. A global "Export all" on the index page collects every page.
4. **`design/b1/index.html`** — the entry point: links to every page grouped by area and tier, a light/dark switch, a short "how to review" (annotate/comment keys, export), and links to THOUGHTS.md sections.
5. **`design/b1/FEEDBACK.md`** — a pre-filled fallback template: one heading per screen ID, with its element IDs and decision IDs as empty bullet lines, so Oliver can also answer in plain Markdown.
6. **`design/b1/COVERAGE.md`** — every inventory ID (all `W- V- P- ST- S- A- CM- M- K- D- F- G-`) → status: *mocked* (page link) · *covered by pattern* (pattern page link) · *unchanged, reason* · *removed/merged, reason*. Nothing may be missing; state the totals.
7. **`design/b1/README.md`** — what's where, how to open, how to give feedback, what's high vs. mid fidelity, known approximations (glass, symbols).

## 6. Done

- `THOUGHTS.md` complete (sections 1–9), every decision has a `DEC-` ID.
- All Tier 1 and Tier 2 screens and all Tier 3 pattern pages exist; every flow in the inventory (`F-`) can be followed through the mockups, or COVERAGE.md says why not.
- Annotate mode, comment mode and export work on every page (open each page and check: no console errors, toggles work, export produces the Markdown described above, links on `index.html` all resolve).
- `COVERAGE.md` has zero unmapped inventory IDs; `FEEDBACK.md`, `README.md`, `index.html` exist.
- Final message to Oliver in German: how to open the packet (`open design/b1/index.html`), the 5–10 most important design decisions in one line each, the questions for him (with recommendations), what is approximated, and what you'd do in the next iteration after his feedback.

When Oliver later sends feedback (exported Markdown or FEEDBACK.md), work through it by ID: update the affected pages and THOUGHTS/decision log, keep IDs stable, and list per feedback item what you changed.
