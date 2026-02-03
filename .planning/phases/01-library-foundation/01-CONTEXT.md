# Phase 1: Library Foundation - Context

**Gathered:** 2026-02-03
**Status:** Ready for planning

<domain>
## Phase Boundary

Establish the core library infrastructure: database schema, atomic file operations, local file import, and library search. Users can import existing music files, the system organizes them into a directory structure, and users can search their library. Downloading from external sources and device sync are separate phases.

</domain>

<decisions>
## Implementation Decisions

### Import Workflow
- Support both folder picker AND drag-and-drop for selecting files to import
- Reference files in place (don't copy to managed folder) — library tracks file locations
- On import failure (corrupted/unsupported files): finish import, then present all failures for review
- Progress feedback: progress bar by default, expandable to see detailed log of each file being processed

### Directory Structure
- Use Album Artist tag for folder organization — compilations go under "Various Artists"
- SoundCloud content lives in separate folder structure (not Artist/Album) because it's organized by playlists, order, and genre rather than traditional album structure
- SoundCloud tracks organized by playlist/set — folder per playlist, tracks in order
- Filename sanitization for FAT32: Claude's discretion on approach

### Duplicate Detection
- Trigger: exact metadata match (artist + title + album)
- Action: automatically keep higher quality version
- Quality hierarchy: lossless > lossy, then by bitrate
- Lower quality duplicate goes to '_duplicates' review folder (not discarded)

### Search Behavior
- Searchable fields: all metadata (artist, album, title, genre, year, comments, etc.)
- Instant search (as-you-type with debounce)
- Fuzzy matching enabled (typo tolerance)
- Results displayed as flat track list

### Claude's Discretion
- FAT32 filename sanitization approach (underscore replacement vs removal)
- Search debounce timing
- Fuzzy matching algorithm/threshold
- Exact metadata fields to index

</decisions>

<specifics>
## Specific Ideas

- SoundCloud separation rationale: "the structure there is less about the different artists and more about the order of the songs and the specific genre of the music. it won't fit well in artist/title/album"
- Reference-in-place model chosen — library tracks locations rather than copying files

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-library-foundation*
*Context gathered: 2026-02-03*
