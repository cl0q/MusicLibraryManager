# Plan 07-06 Summary: Tauri Commands & Review Queue UI

## Metadata
- **Phase:** 07-enhancements
- **Plan:** 06
- **Started:** 2026-02-05
- **Completed:** 2026-02-05
- **Duration:** ~45 minutes

## Objective
Create Tauri commands for all Phase 7 enhancement features (fingerprinting, artwork, ReplayGain, deep scan, review queue). Build review queue UI as a section in the Library Browser page. Add progress tracking for background operations. Wire sidebar badge for pending review items.

## Deliverables

### Task 1: Tauri Enhancement Commands
**Commit:** 4a62980

Created 7 Tauri commands in `src-tauri/src/commands/enhancements.rs`:

| Command | Purpose |
|---------|---------|
| `fingerprint_library_cmd` | Batch fingerprint unprocessed tracks with progress events |
| `fetch_artwork_cmd` | Batch fetch artwork from MusicBrainz/CAA with rate limiting |
| `analyze_replaygain_cmd` | Batch analyze ReplayGain with EBU R128 |
| `deep_scan_cmd` | Full library fingerprint duplicate scan |
| `get_review_queue_cmd` | Retrieve review queue entries with optional status filter |
| `resolve_review_item_cmd` | Approve/reject/dismiss review items |
| `get_review_queue_count_cmd` | Get pending count for sidebar badge |

All commands emit progress events (`{prefix}:started`, `{prefix}:progress`, `{prefix}:completed`) for real-time UI updates.

Updated `.env.example` with `ACOUSTID_API_KEY` documentation.

### Task 2: Review Queue UI & Enhancement Hooks
**Commit:** 2b5cb43

**React Hooks:**
- `useEnhancementProgress(eventPrefix)` - Listens for progress events, returns `{ isRunning, progress, result }`
- `useReviewQueue()` - Manages review queue state and actions

**Components:**
- `ReviewQueue.tsx` - Table with filter tabs (All/Pending/Approved/Rejected/Dismissed), action buttons per row
- Enhancement action buttons integrated into LibraryBrowser page

**Updated Files:**
- `ui/src/types/library.ts` - Added ReviewQueueItem and EnhancementProgress types
- `ui/src/utils/tauri-commands.ts` - Typed wrappers for all enhancement commands
- `ui/src/pages/LibraryBrowser.tsx` - Enhancement Tools section with 4 action buttons
- `ui/src/components/Sidebar/Sidebar.tsx` - Review queue badge showing pending count

### Bug Fixes During Verification
- **7f7a6a2:** Fixed UI path in tauri.conf.json (`cd ../ui` instead of `cd ui`)
- **8cb7587:** Added `.taurignore` to exclude database files from watcher
- **d4eb70e:** Added unique index on playlists(name, category) to prevent duplicates
- **de0d7ff:** Removed unused imports (TagType, PathBuf)

## Verification
- Human verification checkpoint approved
- All enhancement buttons functional (tested with empty library - "0 tracks processed")
- Review queue section visible and interactive
- Sidebar badge working
- Database watcher loop fixed
- Duplicate playlist bug fixed

## Files Modified
- `src-tauri/src/commands/enhancements.rs` (created)
- `src-tauri/src/commands/mod.rs`
- `src-tauri/src/lib.rs`
- `src-tauri/.env.example`
- `src-tauri/tauri.conf.json`
- `src-tauri/.taurignore` (created)
- `src-tauri/src/database/schema.rs`
- `src-tauri/src/replaygain/tagger.rs`
- `src-tauri/src/sync/playlist_gen.rs`
- `ui/src/components/ReviewQueue/ReviewQueue.tsx` (created)
- `ui/src/hooks/useEnhancements.ts` (created)
- `ui/src/pages/LibraryBrowser.tsx`
- `ui/src/components/Sidebar/Sidebar.tsx`
- `ui/src/utils/tauri-commands.ts`
- `ui/src/types/library.ts`

## Success Criteria
- [x] User can trigger fingerprint scan from the UI and see progress
- [x] User can trigger artwork fetch from the UI and see progress
- [x] User can trigger ReplayGain analysis from the UI and see progress
- [x] User can trigger full library deep scan from the UI
- [x] User can view and manage the review queue (approve/reject/dismiss)
- [x] Sidebar shows badge when review queue has pending items
