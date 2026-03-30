---
phase: 12-import-external-playlists
plan: 02
status: complete
started: 2026-03-30
completed: 2026-03-30
---

# Plan 12-02 Summary: Frontend Playlist Import

## What was built

- **tauri-commands.ts** — Added `ImportPlaylistResult` interface and `importPlaylistFromFile()` invoke wrapper
- **MatchPreview.tsx** — Shows matched/unmatched counts, match rate %, and unmatched track list with "No match" labels
- **ImportModal.tsx** — Two-step flow: select file + name → preview matches → create playlist
  - Native file dialog filtered to .m3u, .m3u8, .json
  - Auto-fills playlist name from filename
  - Disables Create button when 0 matches
  - Backdrop click / Cancel to close
- **PlaylistList.tsx** — Added "Import" button next to "+ Create", wired to ImportModal with loadPlaylists refresh on success

## Key decisions

- Used project's existing design tokens (bg-raised, border-edge, text-ink-muted, bg-accent) to match app style
- Import calls backend which creates the playlist atomically — no separate "preview" API needed; the command does parse + match + create in one call
- Modal closes and refreshes playlist list on successful creation

## Files changed

- `ui/src/utils/tauri-commands.ts` — Added interface + function
- `ui/src/components/PlaylistImport/MatchPreview.tsx` — New
- `ui/src/components/PlaylistImport/ImportModal.tsx` — New
- `ui/src/components/Playlists/PlaylistList.tsx` — Added import + modal wiring
