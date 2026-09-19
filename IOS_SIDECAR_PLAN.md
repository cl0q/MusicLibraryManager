# MLM iOS Sidecar — Implementation Plan & Protocol Spec

> Decisions locked 2026-09-04: file protocol first (LAN later) · embedded UUID identity ·
> diff-preview merge · v1 = full player + playlists + likes · transport-agnostic file movement
> (iCloud Drive / SMB / manual, no primary) · embedded artwork only (no exported artwork files).
> This document is the **source of truth** for all work packages. Do not deviate from the
> protocol formats below without updating this file.

---

## Goal

An iOS companion app that plugs into the MLM sync ecosystem: playlists and likes flow
Mac → device → Mac without delete-and-reimport, MP3-player m3u8 edits can be absorbed back
into MLM, and the iPhone becomes a first-class playback device for the synced library.

## Work packages & waves

| WP | Package | Side | Wave | Depends on |
|----|---------|------|------|-----------|
| WP1 | UUID identity: `mlm_uuid` migration, generation, tag embedding on sync | MLM | 1 | — |
| WP5 | iOS scaffold `MLMMobile/`: project, SyncFolder, LibraryIndexer, Library UI | iOS | 1 | — |
| WP2 | `.ios` m3u8 dialect + `mlm-library.json` manifest export | MLM | 2 | WP1 |
| WP3 | Ingest engine: snapshots table, `PlaylistIngestService`, 3-way diff | MLM | 2 | WP1 |
| WP6 | iOS `PlaylistEngine` (incremental diff/apply) + Likes / `Liked.m3u8` | iOS | 2 | WP5 |
| WP4 | Ingest UI: diff-preview sheet, import triggers, `importM3U` delegation | MLM | 3 | WP3 |
| WP7 | iOS playback: AVQueuePlayer service, lock-screen controls, player UI | iOS | 3 | WP5 |

Each wave runs one MLM agent and one iOS agent in parallel (disjoint build trees).

---

## Protocol spec (source of truth)

### 1. Identity

- `tracks.mlm_uuid TEXT` and `playlists.mlm_uuid TEXT` — nullable, lazily generated
  (UUIDv4 uppercase string) at first sync/export if unset. A backfill helper generates them
  for all rows; uniqueness enforced in code (not a UNIQUE constraint, to keep migration cheap).
- **Tag embedding during device sync** (`SyncService.syncSingleFile` path):
  - mp3 → ID3 user text frame: `TXXX` with description `MLM_UUID`, value = uuid
    (empirically verified: written and read back via ffmpeg `-metadata "TXXX:MLM_UUID=<uuid>"`)
  - m4a/aac/mp4 → standard comment field (`©cmt`) with value `MLM_UUID:<uuid>`.
    A pre-existing user comment is preserved as `MLM_UUID:<uuid>|||<existing comment>`
    (read-existing-first, idempotent on re-embed). Freeform `----` atoms are NOT used:
    ffmpeg silently drops them on write AND strips them on any remux/re-encode.
  - **Read-back** (ingest of loose files): `TXXX:MLM_UUID` for mp3; comment field
    parsed for the `MLM_UUID:` prefix for m4a/aac/mp4 (ffprobe or AVMetadataItem).
  - Embedding failures must not fail the sync (log + continue).

### 2. `.ios` m3u8 dialect

New `PlaylistFormat.ios` case. Generated like the existing dialects (see
`SyncService.generatePlaylists`), with:

```
#EXTM3U
#EXTMLM-PLAYLIST:<playlist-uuid>
#EXTINF:<duration>,<Artist> - <Title>
#EXTMLM:<track-uuid>
<relative/path/from/profile/root>
```

- UTF-8, NFC-normalized (`precomposedStringWithCanonicalMapping`), `.m3u8` extension,
  filename via `PathSanitizer.sanitizeComponent(name)`.
- `.ios` profiles use a fixed output layout (independent of `playlist_path_prefix`):
  audio under `<root>/Music/<Artist>/<Album>/<file>`, playlist files under
  `<root>/Playlists/<Name>.m3u8`, manifest at `<root>/mlm-library.json`.
- Paths inside the m3u8 are relative to the profile output root (i.e. include the
  `Music/` prefix), no leading slash.
- Manifest `path` values are relative to `<root>/Music/` (NO `Music/` prefix) — the
  iOS client joins them onto its music root.
- `#EXTMLM-PLAYLIST` header identifies the playlist across renames.
- `#EXTMLM` line precedes the path line of the track it identifies.
- Unknown `#EXT*` comments from other tools must be preserved on re-write by iOS clients.

### 3. Library manifest `mlm-library.json`

Written to the profile output root on every sync:

```json
{
  "schema": 1,
  "profile": "<profile name>",
  "generated_at": "<ISO8601>",
  "tracks": [
    {
      "uuid": "...", "title": "...", "artist": "...", "album_artist": "...",
      "album": "...", "duration": 254, "path": "Artist/Album/File.m4a",
      "energy_bucket": 3, "lufs_i": -14.2
    }
  ],
  "playlists": [ { "uuid": "...", "name": "...", "file": "Name.m3u8" } ]
}
```

### 4. Ingest (device → MLM)

- New table `playlist_sync_snapshots`
  (`id, profile_id, playlist_id, playlist_uuid, snapshot_json, written_at`);
  `snapshot_json` = ordered `[{"uuid": "...", "path": "..."}]`.
- Snapshot written after every export AND after every applied ingest.
- `PlaylistIngestService` flow:
  1. Parse m3u8; resolve entries by `#EXTMLM` uuid → `tracks.mlm_uuid`.
  2. Fallback: filename-suffix matching (existing `findTrackByPath` semantics,
     case-insensitive, generalized into the repository layer).
  3. Unresolved entries are collected and reported, never silently applied.
  4. Diff incoming list vs latest snapshot → `IngestPreview`
     (added / removed / reordered counts + entry details, target playlist resolved via
     `#EXTMLM-PLAYLIST` header, then filename).
  5. Apply through `PlaylistRepository` with `FractionalIndexer` positions.
- `Liked.m3u8` ingests into the `isLiked = 1` playlist (create if missing).
- Existing append-only `importM3U` (PlaylistDetailViewModel) delegates to the engine;
  append behavior = diff against empty snapshot.

### 5. iOS app `MLMMobile/`

- Separate Xcode project, iOS 17+, SwiftUI, GRDB (same dependency as MLM),
  buildable for the iOS Simulator with `CODE_SIGNING_ALLOWED=NO`.
- Documents layout (visible in the Files app: `UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`):

  ```
  MLMMobile Documents/
    Music/<Artist>/<Album>/<file>      (mirrors profile layout)
    Playlists/<Name>.m3u8
    Playlists/Liked.m3u8               (always written, header-only when empty)
    mlm-library.json
  ```

- Transport-agnostic `SyncFolder`: read from iCloud Drive folder, SMB-connected folder,
  or files imported through the document picker; never assume one transport.
- `LibraryIndexer`: manifest → local GRDB index, incremental by `generated_at`/hash.
- `PlaylistEngine`: parse/write the `.ios` dialect; applies diffs incrementally to the
  local playlist state (no delete-and-reimport); preserves unknown comments; keeps uuids.
- `LikesService`: heart toggles → local set, materialized as `Liked.m3u8` in the dialect.
- `PlaybackService`: AVQueuePlayer, background audio entitlement, MPRemoteCommandCenter,
  artwork read from file tags at runtime (embedded-only decision).
- Library UI: search + energy-bucket filter; Playlist list/detail with reorder; player
  mini-bar + full-screen view.

## Verification

- `swift test` green for all new MLM tests (migration idempotency, uuid generation,
  dialect output, manifest schema, ingest diff cases incl. fallback + unknown entries,
  export → ingest → export roundtrip idempotency).
- `xcodebuild -project MLMMobile/... -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` green.
- Manual E2E: sync profile with `.ios` format → hand-edit an m3u8 (simulate phone/player)
  → ingest → preview shows correct diff → apply → DB rows correct.

## Parking lot (not in this implementation)

LAN/Bonjour sync transport · push iOS likes to Spotify/SoundCloud · smart playlists
read-only on phone · auto file-watch on profile folder · playback history sync.
