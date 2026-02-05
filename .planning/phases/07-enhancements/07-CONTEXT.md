# Phase 7: Enhancements - Context

**Gathered:** 2026-02-05
**Status:** Ready for planning

<domain>
## Phase Boundary

Add acoustic fingerprinting (AcoustID/Chromaprint) for track identification and improved duplicate detection, automatic album artwork fetching and embedding, and ReplayGain volume normalization. These enhance existing library tracks — no new source integrations or UI pages.

</domain>

<decisions>
## Implementation Decisions

### Fingerprint integration
- Fingerprint on import (auto) AND manual batch on demand
- Use AcoustID for online lookup (MusicBrainz ID resolution) + Chromaprint for local fingerprint comparison
- When fingerprint matches an existing track but metadata differs: flag for user review (don't auto-merge)
- Background processing for large libraries — UI shows progress, library remains usable during analysis
- Incremental: only fingerprint new/changed tracks unless user triggers full library scan

### ReplayGain behavior
- Calculate both track gain and album gain; default to track gain (Rockbox can switch per-playlist)
- Analyze on sync to device — library files stay untouched until sync
- Always recalculate gain values (overwrite existing tags for consistency)
- Write gain values to file tags (standard ReplayGain tags) so Rockbox reads them directly

### Dedup upgrade path
- Fingerprint dedup supplements existing metadata-based dedup (both run, fingerprint breaks ties)
- Auto-check on import + user-triggered "deep scan" for full library
- Auto-keep best quality file when duplicates found, but log all decisions in a review queue user can inspect later
- Retroactive: run fingerprint dedup across entire existing library to catch what metadata missed

### Claude's Discretion
- Artwork sourcing strategy (MusicBrainz, Spotify API, Discogs — pick best available)
- Artwork resolution and embedding format
- AcoustID API key management
- Chromaprint binary/library integration approach
- ReplayGain analysis tool selection (ffmpeg, ebur128 crate, etc.)
- Review queue UI design and placement

</decisions>

<specifics>
## Specific Ideas

- Fingerprint conflicts should be flagged, not auto-resolved — user wants control over metadata disagreements
- ReplayGain should not modify library files, only synced copies — keep originals pristine
- Dedup review queue lets user audit auto-decisions after the fact (trust but verify pattern)
- Full library re-scan should be available as a one-time migration action when fingerprinting ships

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 07-enhancements*
*Context gathered: 2026-02-05*
