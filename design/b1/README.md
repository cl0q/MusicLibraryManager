# MLM B1 — design packet

Proposal for the redesign of every MLM screen, flow and interaction. Nothing here changes the app; it is the input for B2 (conventions) and B3 (implementation).

## Open it

```
open design/b1/index.html
```

Plain HTML/CSS/JS, no build step, no network, works from `file://`. Any current browser; Safari or Chrome render the glass approximation best.

## What's where

| Path | What |
|---|---|
| `THOUGHTS.md` | **Read first.** Design rationale: what MLM is for, principles, information architecture (before/after), interaction model, Liquid Glass strategy, SwiftUI toolkit map, per-area concepts, decision log (`DEC-001`…`DEC-053`), questions for Oliver. |
| `index.html` | Entry point: links to all pages by tier, how to review, Export All Feedback. |
| `*.html` | The mockups (list below). |
| `FEEDBACK.md` | Fallback feedback template: one heading per screen with its element and decision IDs as empty bullets. |
| `COVERAGE.md` | Every inventory ID → mocked / covered by pattern / unchanged / removed or merged, with totals. |
| `assets/mlm.css`, `assets/app.js` | Shared look and behaviour (shell, tables, menus, annotate/comment/export). |
| `assets/AUTHORING.md`, `assets/BRIEF.md` | How pages are built; rules for whoever (human or agent) edits or adds pages. |
| `coverage-parts/` | Per-area source data for `COVERAGE.md` (`_all-ids.tsv` = the ID list extracted from the inventory). |

## Pages and fidelity

| Tier | Pages | Fidelity |
|---|---|---|
| 1 — the daily loop | `shell` · `library` (All Tracks) · `albums` · `folders` · `playlists` · `queue` · `player` · `search` · `inspector` · `launch` (library picker, launch states, first-run setup) | **High.** Layout, copy, states and the core interactions (selection, Space preview, Return, context menus, sheets) are meant as proposed. |
| 2 — the chores | `import` · `activity` · `review` · `discover` · `sync` · `genres` · `settings` · `library-icon` | **Mid.** Structure, content, copy and states are meant; spacing and proportions are indicative. |
| 3 — catalogues | `patterns-sheets-alerts` · `patterns-context-menus` · `patterns-menus-shortcuts` · `patterns-states` · `patterns-dnd` | **Pattern.** Every inventory instance in the unified pattern. |

## Giving feedback

1. On any page: **A** = annotate (ID badges; hover = what / why / `DEC` / SwiftUI API). **C** = comment (click an element, type, save). **N** = notes panel with **Export feedback**.
2. `index.html` → **Export All Feedback** collects every page's notes into one Markdown file (copied to the clipboard and downloaded), grouped `## page` → `### SCREEN-ID — title` → `- ELEMENT-ID (label) [variant, state]: note`.
3. Or write into `FEEDBACK.md` by ID.
4. IDs are stable: inventory IDs are reused (`V-LIB.E12`), new elements have an `N` (`V-LIB.N01`), variants are `V-FOLD/A`, decisions `DEC-024`. Feedback will be worked through by ID; IDs never get renumbered.

Notes are stored in the browser's `localStorage`, per page, for the origin you opened the files from — export before switching browsers or clearing site data.

## Known approximations

- **Liquid Glass** is imitated with `backdrop-filter: blur() saturate()` and hairline edges. Real glass (refraction, specular highlights, morphing between shapes, adaptive tint) can't be reproduced in a browser. The SwiftUI API meant for each glass surface, and its macOS 15 fallback, is in the element annotations and in `THOUGHTS.md` §5.
- **SF Symbols** are not available on the web: icons are simple inline-SVG stand-ins. Symbol choice is not part of this review.
- **System colours and controls** are approximated with fixed values; the design means the semantic colours (`.primary`, `.secondary`, `.tint` = the user's accent colour) and standard controls. The accent shown is system blue.
- **Window chrome** (traffic lights, toolbar, sidebar) is drawn; in the app it is system-provided. Window size is fixed at about 1320 × 820 pt.
- **Tables** render a few hundred demo rows (state "Huge": 6,000) of generated data; names are plausible, not from the real library. Column resizing/reordering, type-to-select and real drag & drop are described, not implemented. Sorting, selection, filtering, preview/play state and context menus work.
- **Audio** is not played. Preview and playback only change the player's state.
- **Keyboard**: Space, Return, arrows, ⌘A, ⌘I and Esc are wired; other shortcuts are listed on `patterns-menus-shortcuts.html` but not live (the browser owns most ⌘-keys).
- **Menus** open as flat menus; submenus (`▸`) are indicated, not nested.
