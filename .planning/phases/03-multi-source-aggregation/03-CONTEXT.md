# Phase 3: Multi-Source Aggregation - Context

**Gathered:** 2026-02-03
**Status:** Ready for planning

<domain>
## Phase Boundary

Integrate Spotify and SoundCloud APIs to fetch user's liked songs, playlists, and track provenance. Track which source each track came from (many-to-many relationship). Detect duplicates across sources and prevent duplicate downloads.

User has registered OAuth apps for both Spotify and SoundCloud.

</domain>

<decisions>
## Implementation Decisions

### Authentication Flow
- OAuth with localhost redirect URI (user has registered apps for both services)
- Tokens stored in **system keychain** (macOS Keychain, Windows Credential Manager)
- **Silent refresh** using refresh tokens — user never sees token expiration
- Standard OAuth Authorization Code flow for both services

### Source Priority for Downloads
- **Spotify tracks** → DAB (FLAC) → YouTube fallback
- **SoundCloud tracks** → SoundCloud direct download first → DAB → YouTube fallback
- Source tagged in database for provenance tracking
- Rationale: SoundCloud tracks may be exclusives not on DAB (remixes, DJ sets)

### Sync Behavior
- **Incremental sync** — only fetch tracks added since last sync
- **Auto-sync on app open** — check for new tracks when app starts
- **Removed tracks stay** — once downloaded, track stays in library (ownership model)
- User can manually delete, but removed likes don't auto-delete
- Claude's discretion: sync detection method based on API capabilities (timestamps vs ID comparison)

### Duplicate Matching
- **Normalized matching** — ignore case, punctuation, whitespace differences
- **Normalize "feat." variations** — 'feat.', 'ft.', '(feat. X)', '& X' treated as equivalent
- **Group variants** — remixes, edits, live versions are related but distinct tracks
- **Data model: `variant_of` field** — tracks can reference a "canonical" version
- When duplicate detected across sources: **download best quality version**, replace if better

### Claude's Discretion
- Exact OAuth implementation details (PKCE, state parameter handling)
- Sync detection method (timestamps vs ID diff)
- Normalization rules for edge cases
- Variant detection heuristics (how to identify "Radio Edit" vs different song)

</decisions>

<specifics>
## Specific Ideas

- Variant grouping UI (collapsible triangle to show remixes/edits under original) — **deferred to Phase 6**, but data model needs `variant_of` relationship now
- User explicitly noted: "wherever an item is element of a similarity group it has a triangle before its list item"

</specifics>

<deferred>
## Deferred Ideas

- **Variant grouping UI** (Phase 6) — collapsible disclosure triangle showing related versions
- **Apple Music integration** — mentioned in roadmap but requires MusicKit investigation

</deferred>

---

*Phase: 03-multi-source-aggregation*
*Context gathered: 2026-02-03*
