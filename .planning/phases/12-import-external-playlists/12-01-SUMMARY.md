---
phase: 12-import-external-playlists
plan: 01
status: complete
started: 2026-03-30
completed: 2026-03-30
---

# Plan 12-01 Summary: Backend Playlist Import

## What was built

- **playlist_importer.rs** — Full parsing + matching + import pipeline
  - `parse_m3u_file()` — Parses M3U/M3U8 via m3u8-rs, splits "Artist - Title" EXTINF tags
  - `parse_spotify_json_str()` — Handles both direct and nested Spotify JSON schemas
  - `find_best_match()` — Fuzzy matching via jaro_winkler (0.7 title + 0.3 artist, threshold 0.75), queries all tracks (local + remote)
  - `import_playlist_from_file()` — Atomic transaction: parse file, match tracks, create playlist, add matched tracks
- **import_playlist_command** — Tauri command registered in lib.rs, callable from frontend

## Key decisions

- Used `rusqlite::Connection::transaction()` instead of raw BEGIN/COMMIT to avoid nesting with `create_playlist`'s internal transaction
- Wrote playlist INSERT SQL directly in transaction rather than calling `create_playlist`
- Candidate search uses LIKE with first 3+ chars for pre-filtering before jaro_winkler scoring

## Test results

6 unit tests pass: M3U parsing (2), Spotify JSON parsing (3), empty library match (1)

## Files changed

- `src-tauri/Cargo.toml` — Added `m3u8-rs = "6"`
- `src-tauri/src/import/playlist_importer.rs` — New (252 lines)
- `src-tauri/src/import/mod.rs` — Added module + re-exports
- `src-tauri/src/commands/import.rs` — Added `import_playlist_command`
- `src-tauri/src/commands/mod.rs` — Added re-export
- `src-tauri/src/lib.rs` — Registered in invoke_handler
