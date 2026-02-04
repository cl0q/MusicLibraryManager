# Phase 5: Device Sync - Context

**Gathered:** 2026-02-04
**Status:** Ready for planning

<domain>
## Phase Boundary

Sync transcoded AAC files and M3U8 playlists to devices via curated sync profiles. Users create profiles that define which tracks to include (manual picks, playlists, rules), the system maintains a shared transcode cache and per-profile output folders. Transfer to physical devices is manual (user copies folder to iPod SD card, iPhone via Files, etc.).

**Expanded from original roadmap scope:** Multi-device sync profiles included per user decision — this is core to the workflow, not a single-iPod-only feature.

</domain>

<decisions>
## Implementation Decisions

### Sync profile model
- Multiple sync profiles supported (e.g., "iPod", "iPhone", "Jazz Collection")
- Each profile defines its content via three methods (union of all):
  - Manually added individual tracks
  - Entire playlists (all tracks in selected playlists included)
  - Rules (query builder with arbitrary filters: genre, source, date added, artist, bitrate, tags)
- Profile folder always mirrors current state — stale tracks auto-removed on sync

### Transcode cache
- Shared central AAC cache for all transcoded files — transcode once, reuse across profiles
- Each profile gets its own output folder with files from the cache
- Cache persists locally (not deleted after sync)

### iPod file layout
- Mirror library structure on device: Artist/Album/Track.m4a
- M3U8 playlists in root Playlists/ folder (iPod:/Playlists/*.m3u8)
- Filenames same as library (sanitized names from Phase 1)

### Sync behavior
- Sync triggered: auto-detect iPod connection (via .rockbox directory) with confirmation prompt
- Dry run preview: detailed — each file with size, total transfer size, available device space
- Space constraints: block and warn if device doesn't have enough space (don't partial-sync)
- Interruption recovery: track sync progress, resume where left off on next sync
- No auto-copy to devices — all profiles produce local folders, user handles transfer

### Device detection
- Auto-detect Rockbox iPod via .rockbox directory on mounted volumes
- Detection triggers sync confirmation flow (not auto-start)
- Non-iPod devices: no detection needed, profiles just maintain local folders

### Claude's Discretion
- Symlinks vs copies from shared cache to profile folders (platform considerations)
- M3U8 path format (relative paths for Rockbox compatibility)
- Sync progress tracking persistence format
- Rule query builder implementation details
- FAT32 filename edge case handling

</decisions>

<specifics>
## Specific Ideas

- "Instead of a single staging area there are multiple libraries I can put together. One for the iPod, one for my iPhone, preset libs that only contain certain genres."
- "Syncing means also transcoding — it makes sense to save transcodes so I can reuse them across devices without re-transcoding or slow SD card copying."
- Transcode cache avoids the problem of transcodes only existing on one device — can serve multiple device profiles from the same cache.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope (multi-device was pulled into scope as a core requirement).

</deferred>

---

*Phase: 05-device-sync*
*Context gathered: 2026-02-04*
