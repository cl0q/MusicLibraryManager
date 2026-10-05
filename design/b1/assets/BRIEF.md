# Brief for mockup page authors (B1)

You are building HTML mockup pages for the B1 design session of MLM (native macOS music library manager, SwiftUI). The design is already decided; your job is to express it faithfully and completely for your assigned screens.

## Read first, in this order
1. `design/b1/THOUGHTS.md` — the design. Binding. §3 (IA), §4 (interaction model), §5 (glass), §7 (your area's concept), §8 (decision log — reference DEC IDs).
2. `design/b1/assets/AUTHORING.md` — how pages are built. Binding.
3. `design/b1/library.html` — the reference page (and `assets/app.js` / `assets/mlm.css` if you need to know what exists).
4. The inventory area file(s) named in your assignment under `design/inventory/` — they list every element (`X.E01`), context menu, sheet, alert, shortcut, drag & drop and pain point of today's app. Use these IDs. Also skim the index `design/B1-UI-INVENTORY.md` §8 (global states) and §9 (the flows `F-xx` touching your screens).

## Hard rules
- Write ONLY inside `design/b1/`. Create only the files named in your assignment. Do NOT edit `assets/app.js`, `assets/mlm.css`, `THOUGHTS.md`, `library.html` or other agents' pages. If you need extra CSS, put a small `<style>` in your page using the existing CSS variables (no new colours, no hex values). If the framework lacks something, work around it in page JS and mention it in your final report.
- Never touch `MLM/`, `MLMTests/`, `scripts/`; never launch MLM; no screenshots of MLM; no AppleScript; never read `~/Library/Application Support/MLM/.env` or `~/Library/Application Support/com.musiclibrary.app/`. Do not commit.
- Don't read Swift code unless the inventory leaves a specific question open.
- Native macOS look: system-like controls from `mlm.css`, no custom palette, no glass on content. Native toolbar stays; no floating overlays other than system popovers/menus/sheets and the selection bar. UI copy English, no emoji, critical states as text. Use glossary/state words exactly (THOUGHTS §4.9, DEC-014, DEC-023; `UI-GROUNDTRUTH.md` §1.5–1.6): `Not downloaded`, `Download failed`, `File missing`, `Drive not connected` (window-level), `Importing · n of m`, `Incomplete · n failed`, `Linked to ‹Source›`, `Refresh from ‹Source›` (never "Sync" for playlists), `Show in Finder`, `Library file`, `Library folder`, `Sign-in expired`, `Connected`, `Disconnected`, `Recommendation`, `Similar`.
- Realistic data at realistic volume (the library has ~13k tracks, 48 % without album, an often-unplugged external drive "Lexxar", long background jobs). Long titles, missing artwork, mixed states.
- Every meaningful element carries `data-fb-id` (+ `data-fb-label`, `data-fb-note`, `data-fb-dec`, `data-fb-api`). Reuse inventory element IDs wherever an element continues to exist (even if moved or reworded); new elements get `<SCREEN>.N01…`. Sheets/alerts/menus keep their inventory IDs on their root element when they continue to exist. Notes should say what it is and why it is designed this way; `data-fb-api` names the SwiftUI API (and for glass the macOS 26 API + macOS 15 fallback).
- Clickable where it helps: navigation between views of your page (`data-goto`), opening sheets/alerts/menus/popovers, state switches (`data-states`: include `empty`, `loading`, `error` and other states that matter for your screens; drive-offline is handled by the shell's Drive switch but add screen-specific offline content where the concept needs it), variants where THOUGHTS lists them. Each page starts with a `.note` block: tier, what to try, which decisions.
- Open variants: use `data-variants` with the recommended one marked, tied to its DEC.
- Quality bar: each page must load without console errors. Check inline scripts for syntax (e.g. extract and run `node --check`), check that every `data-open`/`data-menu`/`data-popover`/`data-goto` target id exists, and that links point to files in this list: index.html library.html albums.html genres.html folders.html playlists.html queue.html player.html search.html inspector.html shell.html import.html activity.html review.html discover.html sync.html settings.html launch.html library-icon.html patterns-sheets-alerts.html patterns-context-menus.html patterns-menus-shortcuts.html patterns-states.html patterns-dnd.html. A static server may be running at http://localhost:8765/ (serves design/b1) if you have browser tools; view only your own pages.

## Coverage part (required)
Besides your pages, write `design/b1/coverage-parts/<your-part>.tsv` (tab-separated, no header): one line for EVERY ID defined in your assigned inventory area file(s) — all `W- V- P- ST- S- A- CM- M- K- D-` IDs (surface IDs, not each `.E` element; for menus `M-…` one line per menu) including the "expected, missing" `D-`/`K-` ones:
`ID <TAB> status <TAB> where <TAB> reason`
- status ∈ `mocked` (where = `page.html` or `page.html#view`) · `pattern` (covered by a Tier 3 pattern page: where = one of patterns-sheets-alerts.html / patterns-context-menus.html / patterns-menus-shortcuts.html / patterns-states.html / patterns-dnd.html — use this for sheets/alerts/menus/shortcuts/drag-drop you did not mock interactively yourself) · `unchanged` (reason required) · `removed` or `merged` (reason required, name the DEC and what replaces it).
Get the exact ID list from the index registers (`design/B1-UI-INVENTORY.md` §3–§7: rows whose Area column is your area) so none is missed.

## Final report (your reply to me)
Short: files written, per page the views/states/variants/overlays it contains, any deviation from THOUGHTS.md you found necessary (with reason), open questions, framework gaps.
