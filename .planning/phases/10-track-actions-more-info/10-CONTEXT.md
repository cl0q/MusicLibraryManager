# Phase 10: Track Actions & More Info - Context

**Gathered:** 2026-02-07
**Status:** Ready for planning

<domain>
## Phase Boundary

Context menu actions work correctly for local tracks. More Info shows real file data (fingerprint, waveform, spectrogram, ffprobe output). Add to playlist and add to sync profile work for local tracks. Open in file manager works for local tracks. No destructive actions (delete/remove) in this phase.

</domain>

<decisions>
## Implementation Decisions

### More Info Panel
- Side panel that slides in from the right (not a page or modal)
- Track overview first: artwork, title, artist, album, format up top
- Technical data (ffprobe, format info) in collapsible sections below overview
- Light data (ffprobe/format info) loads automatically when panel opens
- Heavy analysis (waveform, spectrogram, fingerprint) is on-demand via buttons
- Panel follows track selection — clicking a different track in the table updates the panel
- No pin functionality needed

### Playlist & Sync Actions
- "Add to playlist" shows a submenu listing all playlists, click to add instantly
- "Add to sync profile" also uses submenu pattern listing sync profiles
- Inline confirmation on the row (brief checkmark/highlight) after adding — no toast popup
- Multi-track selection supported for ALL context menu actions (playlist, sync, etc.)
- Select multiple rows, right-click, action applies to entire selection

### File Manager Integration
- "Reveal in file manager" opens the file manager with the file selected/highlighted
- File manager should be configurable — not hardcoded to Finder (user uses Forklift 4)
- Research needed: how macOS handles default file manager overrides, `open` command alternatives, Forklift integration
- "Copy file path" as a separate context menu action alongside reveal
- File-related actions (reveal, copy path) hidden entirely for remote/non-downloaded tracks

### Context Menu Design
- One menu structure with conditional items based on track type (local vs remote)
- Items show/hide based on context — local gets file actions, remote gets download action
- Action grouping order: Add to playlist → Add to sync → separator → File actions (reveal, copy path) → More Info → separator (no destructive actions this phase)
- No keyboard shortcuts for context menu actions yet — future polish
- No "Remove from library" or destructive actions in this phase

### Claude's Discretion
- Side panel width and animation
- Exact collapsible section design for technical data
- Inline confirmation visual treatment (checkmark style, highlight duration)
- How multi-select interacts with More Info panel (show info for first selected? disable?)
- Submenu styling and positioning

</decisions>

<specifics>
## Specific Ideas

- User uses Forklift 4 instead of Finder — file manager reveal must be configurable or respect macOS default file manager settings
- Actions-first menu ordering: the things you DO most (add to playlist/sync) come first, info/file actions are secondary
- Inline confirmation over toasts — keep it subtle, don't interrupt flow

</specifics>

<deferred>
## Deferred Ideas

- "Remove from library" / delete track — future phase (destructive actions)
- Keyboard shortcuts for context menu actions — future polish
- Pin option for More Info panel — not needed now

</deferred>

---

*Phase: 10-track-actions-more-info*
*Context gathered: 2026-02-07*
