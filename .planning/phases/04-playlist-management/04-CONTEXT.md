# Phase 4: Playlist Management - Context

**Gathered:** 2026-02-04
**Status:** Ready for planning

<domain>
## Phase Boundary

User can create, edit, and reorder playlists with order preservation guaranteed across all operations (download, transcode, sync). Includes importing playlists from connected sources, managing liked/favorites playlists per source, and smart auto-generated playlists. Device sync mechanics and UI chrome belong in later phases.

</domain>

<decisions>
## Implementation Decisions

### Source playlist handling
- User picks which source playlists to import (not auto-import all)
- Imported playlists are mirrored for additions only — new tracks from source are pulled on refresh, but removals on the source do NOT delete locally. Once downloaded, a track stays
- New tracks from refresh are inserted at their source position (match source order)
- Cross-source duplicates: one library track, referenced from multiple playlists (shared reference, no duplicate files)
- Auto-pull playlist metadata from source when available (name, description, cover image) — Spotify exposes playlist images via `/playlists/{id}/images`

### Playlist structure
- Flat list (no folders/nesting)
- Playlists have freeform text tags for categorization/filtering
- Duplicate playlist names allowed
- Playlist metadata: name, tags, optional description, optional cover image
- Users can create playlists from scratch and add any library track
- Three playlist categories with distinct UI sections:
  - **Liked playlists** — pinned to top with special icon (heart), per-source + local likes
  - **Smart playlists** — own section, auto-generated
  - **Regular playlists** — user-created and imported source playlists

### Smart playlists
- **Recently Added** — tracks added in last N days
- **Most Played** — sorted by play count (data comes from Rockbox stats in Phase 5; playlist definition exists in Phase 4, populated once sync provides play counts)
- Smart playlists and liked playlists are always present once created — cannot be deleted or hidden

### Order preservation
- Local reordering is independent from source — changes don't push back to Spotify/SoundCloud
- On mirrored playlist refresh: new tracks inserted at source position, but existing manual reordering is preserved
- Adding tracks to user-created playlists appends to end (user can drag to reorder after)
- M3U8 playlists on iPod reflect exact local order including manual reordering (Phase 5 concern, but order contract is established here)

### Liked/Favorites behavior
- Per-source liked playlists: "Spotify Likes", "SoundCloud Likes", etc.
- Created on first import (not on source connect)
- Default sort: date-added descending, but user can manually reorder
- Users can "like" any local track — goes into a "Local Likes" playlist
- Track can appear in multiple liked playlists (e.g., both "Local Likes" and "Spotify Likes") — shared reference
- Liked playlists get special treatment: pinned to top, heart icon or similar distinction

### Claude's Discretion
- Database schema for playlist ordering (gap-based positions, fractional indexing, or sequential — choose what's most robust)
- Tag storage implementation (separate table vs JSON column)
- Smart playlist query implementation
- Cover image storage approach (file path vs embedded blob)
- Exact "Recently Added" time window (30 days, configurable, etc.)

</decisions>

<specifics>
## Specific Ideas

- Rockbox stores playback stats in `.scrobbler.log` (Audioscrobbler 1.1 format, TSV) and `/.rockbox/database_changelog.txt` (ASCII runtime data). Phase 5 sync should read these to populate play counts for the "Most Played" smart playlist
- Playlist sections in UI: Liked (pinned top, heart icon) > Smart (own section) > Regular (below)
- Mirrored playlists are "additive mirrors" — they grow but never shrink from source changes

</specifics>

<deferred>
## Deferred Ideas

- **Vibe-matching / mood playlists** — auto-generate playlists by sonic similarity (like Spotify's algorithmic playlists). Would require audio feature extraction (Spotify Audio Features API for Spotify tracks, local analysis via essentia/aubio for others). Substantial capability — own phase after Phase 7
- **Push reordering back to source** — currently local-only; could be a future enhancement
- **Combined "All Likes" playlist** — user chose per-source only; could add unified view later

</deferred>

---

*Phase: 04-playlist-management*
*Context gathered: 2026-02-04*
