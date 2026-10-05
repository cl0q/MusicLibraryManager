# Authoring a B1 mockup page

Every page is plain HTML that loads `assets/mlm.css` and `assets/app.js`. No build step, no network, opens via `file://`. Read `library.html` (main-window page) and `settings.html` / `patterns-*.html` (plain pages) as examples before writing a new one.

## Skeleton

```html
<!doctype html><html lang="en"><head><meta charset="utf-8">
<title>All Tracks — MLM B1</title>
<link rel="stylesheet" href="assets/mlm.css"><script src="assets/app.js"></script></head>
<body data-screen="V-LIB" data-title="All Tracks" data-nav="tracks"
      data-states="default,empty,loading,error" data-variants="A,B" data-variant-rec="A" data-variant-dec="DEC-011">
  <div class="note"><h3>Try it</h3><p>…what to click…</p></div>
  <div id="content"> …the view that fills the content column… </div>
  <!-- hidden overlays: menus, popovers, sheets, alerts -->
  <script>document.addEventListener('mlm:ready', () => { /* MLM.table(...) etc. */ });</script>
</body></html>
```

`body` attributes:

| Attribute | Meaning |
|---|---|
| `data-screen` | Inventory / new screen ID of the page (`V-LIB`). Shown in the review bar, used in exports. |
| `data-title` | Human title. |
| `data-nav` | Which sidebar row is active: `tracks albums genres folders discover review allpl pl1 pl4 sync1 sync2`. |
| `data-shell="plain"` | No main-window shell: the page draws its own `.window` blocks or a `.cat` catalogue (Settings, Activity window, launch states, pattern pages). |
| `data-states="a,b,c"` | Adds a State switcher. Elements with `data-show="a b"` are visible only in those states; `data-hide="a"` hides. First state is the default. Event `mlm:state` (detail = name). |
| `data-variants="A,B"` + `data-variant-rec` + `data-variant-dec` | Adds a Variant switcher (`<screen>/A`). Elements with `data-variant="A"` are visible only for that variant. Event `mlm:variant`. |
| `data-selbar="off"`, `data-statusbar="off"` | Suppress the shell's selection bar / status bar. `data-status="…"` sets a fixed status-bar text. |
| `data-home="viewname"` | View the toolbar Back button returns to. |

With the main shell, `#content` is moved into a full window (sidebar, toolbar with player, trailing Info/Queue column, drive banner, selection bar, status bar). Everything else in `<body>` stays on the "desk" around it (notes, extra windows, catalogues).

## Feedback IDs — required on every meaningful element

```html
<button class="btn" data-fb-id="V-PLD.E05" data-fb-label="Play" data-fb-note="Always shown; disabled with a reason instead of hidden."
        data-fb-dec="DEC-022" data-fb-api="Button(.borderedProminent)">Play</button>
```

- `data-fb-id`: the **inventory element ID** when the element exists today (`V-PLD.E05`, `CM-PL-CARD`, `A-PL-DELETE`, `M-FILE.E03`), otherwise a new ID with `N` (`V-PLD.N01`, numbered per screen). Whole screens/sheets/alerts/menus carry their own ID on their root.
- `data-fb-label` (short name, used in the export), `data-fb-note` (what/why, one or two sentences), `data-fb-dec` (`DEC-0xx` from `THOUGHTS.md` §8), `data-fb-api` (SwiftUI API that builds it; say the macOS 26 API and the macOS 15 fallback where glass is involved).
- Annotate mode (key A) and comment mode (key C) work automatically from these attributes. Don't put IDs on every table cell — headers, rows of interest and controls are enough.

## Building blocks (classes in `mlm.css`)

- Layout: `.view` (flex column), `.scroll`, `.pad`, `.row`, `.col`, `.grow`, `.trunc`, `.t2` (secondary), `.t3`, `.caption`, `.num`.
- Headers: `.vhead > h1 + .sub`; `.scopebar > button.scope(.on) > span.n`; `.dhead` (album/playlist header with `.art`, `.kind`, `h1`, `.acts`); `.statusline`; `.banner` (`.info`, `.err`).
- Controls: `.btn` (`.primary`, `.destructive`, `.plain`, `.lg`, `.glass`), `.seg > button(.on)` (with `data-group="g"` + `data-p="x"` it switches `[data-pane="g:x"]`), `.field`, `.popup`, `.check(.on)`, `.radio(.on)`, `.toggle(.on)`, `.progress > i`, `.gauge > i`, `.spinner`, `.token`, `kbd`.
- Status in words: `<span class="status failed">…</span>` (`failed`, `missing`, `error`, `ok`), source marker `<span class="srcdot sc|yt|sp|am"></span>`.
- Lists: `MLM.table(host, opts)` for track tables (below); hand-written `<div class="table"><table>…` for other tables (`tr.sel`, `tr.group`, `tr.tall`, `td.r`, `td.dim`, `.sub2`); `.grid > .card > .art + .nm + .sb`; `.cov.c1…c6` cover placeholders.
- Forms: `.form > .group > .frow > .fl (+ small)`, `.gtitle`, `.ghelp`, `.kv` (label/value grid).
- Empty states: `.empty` with an `xl` icon, `h2`, `p`, `.acts`.
- Overlays: `.menu > a.mi(.sub .dis .hdr .destr .chk .nochk) + hr`, `.popover`, `.sheet > .sh + .sb + .sf`, `.alert > .aic + h2 + p + .ab`. Add `.static` to show one inline (catalogue pages).
- Windows on plain pages: `<div class="window auto w720"><div class="titlebar"><div class="traffic"><i></i><i></i><i></i></div><div class="wtitle">Settings</div></div>…</div>`.
- Catalogues: `.cat-h` heading, `.cat` grid of `.spec` cards (`h4` with `<code>ID</code>`, `p`, `.demo`).
- Icons: `<i data-i="name"></i>` (optionally `class="s|l|xl"`). Names: see `IC` in `app.js` (`play pause next prev queue info search note album tag folder sparkles review list device drive activity warn gear more shuffle speaker download cloud retry missing trash link check x sync video wave pencil clock disc person globe doc lines heart photo star eject filter lock share stop key plus chevl chevr chevd sidebar`). They stand in for SF Symbols.

## Behaviour attributes (no JS needed)

| Attribute | Effect |
|---|---|
| `data-goto="name"` | Shows `[data-view="name"]` and hides its sibling views (same `data-view-group`). `page.html#name` does the same on load. |
| `data-open="id"` / `data-close` | Opens the hidden `.sheet#id` or `.alert#id` over the window / closes it. A button may carry both `data-close` and `data-open` or `data-goto` to chain. |
| `data-menu="id"` | Right-click opens `.menu#id`. `data-menu-click="id"` opens it on click. |
| `data-popover="id"` | Click toggles `.popover#id` under the element. |
| `data-say="text {n}"` | Shows a confirmation with Undo in the status bar (`{n}` = selection count). |
| `.scope` with `data-status-filter="failed,missing"` | Filters the first track table by status (`""` = all). Fires `mlm:scope`. |
| `data-act="info" / "queue" / "info-open"` | Toggles the trailing column. |

## JS API

```js
const t = MLM.table('#tbl', {
  rows: MLM.tracks(600, 7),            // demo data: {title, artist, album, time, bpm, energy, dance, genre, year, format, kbps, added, status, reason, attempts, source}
  cols: ['num','title','artist','album','time','bpm','energy','genre','added','status'],  // also: dance year format kbps
  ids: { title: 'V-LIB.E07', status: 'V-LIB.E12' },  // data-fb-id per column header
  notes: { status: '…' },              // data-fb-note per column header
  sort: 'addedSort', desc: true,
  menu: 'cm-track',                    // context menu id (shell provides cm-track; define your own .menu to replace it)
  subline: t => 'second line html', rowClass: t => 'tall', onDelete: rows => {}, empty: '<div class="empty">…</div>'
});
t.setRows(rows); t.setFilter(fn); t.setCols([...]); t.selection();
MLM.say('Added 3 tracks to “Warm-up”', true);   // status bar message (+ Undo)
MLM.goto('detail'); MLM.openSheet('s-import'); MLM.icon('play'); MLM.tracks(n, seed, {allLocal:true});
```

Tables handle click / ⇧ / ⌘ selection, ↑↓, ⌘A, Space (preview in the toolbar player), Return and double-click (play; download for not-downloaded rows), right-click, sortable headers, and they dim local rows when the review bar's Drive switch is "Not connected".

## Rules for content

- UI copy in English, sentence case for sentences and Title Case only for menu items and buttons as macOS does (`Show in Finder`, `Add to Playlist`). No emoji. Glossary and state words from `THOUGHTS.md` (§3, §4, DEC-014, DEC-023) and `UI-GROUNDTRUTH.md` §1.5–1.6.
- Critical states are text (an icon may accompany). Source brand colours only as `.srcdot`.
- No custom colours: use the CSS variables / classes only. No glass on content (tables, cards, text); glass only where `THOUGHTS.md` §5 says.
- Realistic data and volume: long titles, missing artwork, mixed states.
