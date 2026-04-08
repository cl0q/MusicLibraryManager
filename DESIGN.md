# MusicLibraryManager — Design System

## Philosophy: "Studio Console"

Inspired by professional audio tools (Ableton, Rekordbox, Logic Pro). Dense, information-rich, always showing what's happening. Dark-first because this is a music tool, not a web app.

### Principles

1. **The table is the app.** Library browser is the home page and dominates the screen.
2. **Always-on status.** Downloads, sync, and operations are always visible in the bottom activity panel.
3. **Minimal navigation.** 5 sidebar items instead of 8. Library + Remote are tabs, not separate pages.
4. **One accent color.** Amber. Everything else is neutral. Color communicates meaning (status).
5. **No decoration.** No gradients, no glassmorphism, no card grids with icons. Just data.

---

## Color System

Custom Tailwind theme tokens defined in `ui/src/index.css` via `@theme`.

### Backgrounds

| Token       | Hex       | Tailwind class | Usage                              |
|-------------|-----------|----------------|------------------------------------|
| `base`      | `#0c0c12` | `bg-base`      | Page background, deepest layer     |
| `surface`   | `#14141c` | `bg-surface`   | Cards, panels, sidebar             |
| `raised`    | `#1c1c26` | `bg-raised`    | Hover states, elevated elements    |
| `overlay`   | `#24242e` | `bg-overlay`   | Tooltips, dropdowns, modals        |

### Borders

| Token         | Hex       | Tailwind class       | Usage            |
|---------------|-----------|----------------------|------------------|
| `edge`        | `#2a2a36` | `border-edge`        | Standard borders |
| `edge-subtle` | `#1e1e28` | `border-edge-subtle` | Subtle dividers  |

### Text

| Token           | Hex       | Tailwind class       | Usage                |
|-----------------|-----------|----------------------|----------------------|
| `ink`           | `#e8e8f0` | `text-ink`           | Primary text         |
| `ink-secondary` | `#8888a0` | `text-ink-secondary` | Secondary labels     |
| `ink-muted`     | `#55556a` | `text-ink-muted`     | Disabled, hints      |

### Accent

| Token            | Hex       | Tailwind class        | Usage                        |
|------------------|-----------|-----------------------|------------------------------|
| `accent`         | `#d4940c` | `text-accent`         | Active nav, links, primary   |
| `accent-bright`  | `#f0a818` | `text-accent-bright`  | Hover state for accent items |

### Status Colors (Tailwind defaults)

| Meaning  | Class          | Usage                     |
|----------|----------------|---------------------------|
| Success  | `emerald-400`  | Completed, connected      |
| Error    | `rose-400`     | Failed, disconnected      |
| Active   | `sky-400`      | Downloading, in-progress  |
| Warning  | `amber-400`    | Warnings, attention       |

---

## Typography

- **Font family:** Inter (UI), SF Mono / Fira Code (data, code)
- **Section labels:** `text-xs font-semibold uppercase tracking-wide text-ink-secondary`
- **Body text:** `text-sm text-ink`
- **Data values:** `text-sm font-mono tabular-nums text-ink`
- **Muted hints:** `text-xs text-ink-muted`

---

## Spacing

Compact throughout. Music apps are information-dense.

| Element                  | Value      |
|--------------------------|------------|
| Page padding             | `p-4`     |
| Card padding             | `p-3`     |
| Section gap              | `gap-3`   |
| Table row height         | 36px       |
| Sidebar width            | 192px      |
| Activity panel collapsed | 36px       |
| Activity panel expanded  | 320px      |

---

## Navigation Architecture

### Sidebar (5 items)

| Item       | Route        | Notes                               |
|------------|--------------|-------------------------------------|
| Library    | `/`          | Active for `/`, `/remote`, `/library/:id` |
| Playlists  | `/playlists` |                                     |
| Sync       | `/sync`      | Device sync profiles                |
| Sources    | `/sources`   | Spotify, SoundCloud, local import   |
| Settings   | `/settings`  | Pinned to sidebar bottom            |

### Library Tabs

Inside the Library page, a tab bar switches between views:

- **Local** (`/`) — downloaded tracks in the library
- **Remote** (`/remote`) — streaming tracks not yet downloaded

### Activity Panel

Always-visible bottom panel. Replaces the old StatusBar and Downloads page.

- **Collapsed:** 36px summary bar — operation counts, pulsing indicator when active
- **Expanded:** Full operation list with progress bars, speed, ETA, errors

---

## Component Patterns

### Buttons

```
Primary:   bg-accent hover:bg-accent-bright text-base font-medium px-3 py-1.5 rounded
Secondary: bg-raised hover:bg-overlay text-ink font-medium px-3 py-1.5 rounded border border-edge
Ghost:     hover:bg-raised text-ink-secondary hover:text-ink px-3 py-1.5 rounded
Danger:    bg-rose-500/10 hover:bg-rose-500/20 text-rose-400 px-3 py-1.5 rounded
```

### Cards / Panels

```
bg-surface border border-edge rounded-lg
```

### Table Headers

```
bg-surface text-xs font-medium uppercase tracking-wider text-ink-muted
```

### Active Nav Item

```
bg-raised text-accent font-medium
```

### Status Indicators

- Active: pulsing `sky-400` dot
- Success: `emerald-400` checkmark
- Error: `rose-400` x-mark
- Warning: `amber-400` exclamation

### Progress Bars

```
Container: h-1 bg-edge rounded-full overflow-hidden
Fill:      h-full bg-sky-500 rounded-full (active) / bg-emerald-500 (complete)
```

---

## Removed from Old Design

- **Dashboard page** — useless stat cards and hardcoded "Library Health: Good"
- **Downloads page** — folded into always-visible Activity Panel
- **Rainbow buttons** — replaced with single accent color + ghost buttons
- **`dark:` prefix pattern** — app is dark-only, no light mode toggle
- **Heading + subtitle on every page** — removed in favor of structural clarity
- **Enhancement tools block** — moved to compact toolbar buttons in Library header
