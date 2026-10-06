# MLM — Roadmap

**Status:** Planning document. Sequences the five workstreams from `todo_dump.md`.
**Written:** 2026-10-04. Every number below was read off the live code or the live database on that date; re-verify before acting on it.
**Design authority (updated 2026-10-06):** `UI-CONVENTIONS.md` and `design/b1/` (`THOUGHTS.md` §10 first) are binding; `UI-GROUNDTRUTH.md` is superseded (history only). Track B is done: the redesign is implemented on `redesign/b3`; `B3-CONFORMANCE.md` is the status and `B3-PLAN.md` §4 the decisions.

---

## 0. Corrections to the premises in `todo_dump.md`

Three of the five items assume a starting state that is not the current state. Fixing the record first, because it changes the scope of each.

### 0.1 "The main db is saved within the .app" — not true today

| Claim | Verified state |
|---|---|
| DB lives inside `MLM.app`, so deleting the app destroys it | `find /Applications/MLM.app -name "*.db"` → **no results**. The bundle contains only `Contents/MacOS/MLM`, `Contents/MacOS/mlm-auth`, `AppIcon.icns`, `MLM_MLM.bundle` |
| DB location is opaque | `DatabaseManager.defaultDatabasePath()` (`MLM/Database/DatabaseManager.swift:81-88`) → `~/Library/Application Support/com.musiclibrary.app/music_library.db`. Live: 130,834,432 bytes, plus `-wal` 3,036,472 bytes and `-shm` |

**The likely real source of the anecdote.** Two pieces of evidence point at an older, cwd-relative build rather than the bundle:

- Stray databases in the working tree: `music_library.db` (15,994,880 bytes, May 10) and `macos-app/music_library.db` (0 bytes, May 11). A path resolved against the working directory produces exactly this. *(Both removed by 2026-10-04; `*.db` is gitignored.)*
- A **stale doc comment** at `MLM/Database/DatabaseManager.swift:11-12` states the path is `~/Library/Application Support/com.mlm.music-library-manager/music_library.db`. The code says `com.musiclibrary.app`. That directory does not exist on this machine. A rename of the Application Support folder is the other way a library "vanishes" — the app opens a fresh empty path and the old one looks deleted.

**Consequence for scope:** Track A is not a rescue operation, it is a hardening and control operation. The data-loss risk from `.app` deletion is already closed. The risk that remains is the one with no mitigation at all: **there is no backup code** (see 0.4).

### 0.2 "Albums need to be introduced" — the backend already exists, with no UI and no ordering

- `albums` table created in migration `v16_albums`, refined by `v17_album_remediation`
- **8,020 album rows** already in the live DB; `tracks.album_id` FK present, **11,039 of 12,935 tracks linked** (1,896 unlinked)
- Variant system already built: `albums.variant_of`, `albums.variant_kind`, and a `user_album_variant_pref` table keyed `(user_id, base_album_id)`
- `MLM/Database/AlbumRepository.swift` and `MLM/Models/Album.swift` exist

**What is genuinely missing:**

1. **No track ordering.** `tracks` has no `track_number` or `disc_number` column, and there is no `album_tracks` join table — the relationship is a bare 1:N through `tracks.album_id`. This is the core of the ask ("their own trackorder that needs to be respected") and it does not exist in any form.
2. **No UI at all.** `grep -rl "AlbumRepository\|AlbumView" MLM/Views MLM/ViewModels` → **zero matches**. Albums are dead backend code. There is no `Albums` directory under `MLM/Views`.

**Consequence for scope:** Track C is schema-extension + UI-from-scratch, not greenfield entity design. The variant-preference machinery is a gift — reuse it rather than designing around it.

### 0.3 "Remove the source-as-album" — confirmed, and the write site is one switch statement

`MLM/Views/ContentView/ContentView.swift:400-407` literally assigns the source name into the album field at download time:

```swift
case .youtube: albumName = "YouTube"
case .soundcloud: albumName = "SoundCloud"
case .directAudio: albumName = "Downloads"
case .genericWeb: albumName = "Web"
```

Live-data scale of the problem:

| Condition | Tracks | Share of 12,935 |
|---|---|---|
| `album = 'unknown album'` | 6,209 | **48.0%** |
| `album` is literally a source name (`SoundCloud`, `YouTube`, `Downloads`, `Web`, `Unknown`, `''`) or a URL | 132 | 1.0% |
| `album = 'SoundCloud Likes'` | 298 | 2.3% |
| `album = 'german top100 single charts'` | 177 | 1.4% |
| `album = 'german top50 odc'` | 109 | 0.8% |
| Distinct `album` strings overall | 1,616 | — |

Note the fragmentation signal: **8,020 album rows back only 1,616 distinct album strings** — average ~1.6 tracks per album. Album deduplication is a separate problem from source-removal and belongs in Track C's open questions.

**Consequence for scope:** the 132 literal-source tracks are trivial. The 6,209 `unknown album` tracks are the actual work, and they cannot be fixed by a code change — they need external metadata resolution, which is where the YouTube problem in `todo_dump.md` bites.

### 0.4 "Backup functionality" — genuinely nothing exists

`grep -rn "VACUUM INTO\|createBackup\|DatabaseBackup\|backup-"` across all Swift → **zero matches**. The single backup file present (`music_library.backup-20260509-161954.db`, 15,994,880 bytes, 2026-05-09) was created by hand, and its name is the only existing convention to honour or replace.

### 0.5 Multi-library is closer than it looks

Already in place:

- `app_config.library_id` = `f1c9d287-7c19-4e62-ad81-eef851bf751f` — **a library identity already exists**
- `app_config.library_root` = `/Volumes/Lexxar/Music`
- `organized_path` is stored **relative** to `library_root` (migration `v12_strip_absolute_paths`; confirmed by the comment at `MLM/ViewModels/DownloadViewModel.swift:900-901`) — so moving the music folder does not break track paths
- `MountObserver` (`MLM/Services/Mount/MountObserver.swift`) already watches the library volume and derives `libraryVolumePath`; `DependencyContainer` already exposes `hasLibraryRoot` and `isLibraryDriveMounted`

**The one structural blocker:** `library_root` and `library_id` live *inside* the database (`app_config`), while the database path is hardcoded. To choose a library you must read config, but config is in the DB you are trying to choose. Multi-library therefore **requires a registry outside the database** — that is the keystone of Track A3, and everything else in A3 follows from it.

The other blocker is `DependencyContainer`: `static let shared` (`MLM/App/DependencyContainer.swift:12`), 475 lines, ~40 `private(set)` services, constructing `DatabaseManager()` with no path argument at line 145. Switching libraries at runtime means either rebuilding this container or making it library-scoped.

---

## 1. Verified inventory

### 1.1 Every location MLM writes data

| What | Where | Configurable today? |
|---|---|---|
| Main database + `-wal`/`-shm` | `~/Library/Application Support/com.musiclibrary.app/music_library.db` | **No** — hardcoded |
| Playlist covers | `~/Library/Application Support/com.musiclibrary.app/playlist-covers/` (36 entries) | No |
| OAuth tokens | macOS **Keychain**, one item per service, via the `mlm-auth` helper (`TokenStorage.swift`) — there is no `tokens/` directory | No |
| Credentials | `~/Library/Application Support/MLM/.env` | No (path fixed, file user-editable) |
| Transcode cache | `app_config.transcode_cache_path` when set (live value 2026-10-04: `/Volumes/Lexxar/Music/.mlm_transcode_cache`), else `~/Library/Caches/com.mlm.transcode_cache` (`DependencyContainer.swift:331-334`) | Yes — Settings → Maintenance |
| Audio files | `/Volumes/Lexxar/Music` | Yes — `app_config.library_root` |
| ~~Stray dev DBs~~ | ~~repo root, `macos-app/`~~ | Gone — both deleted, `*.db` gitignored (`.gitignore:5`) |

**Track A1's deliverable is this table, surfaced in the UI** — done: Settings → Storage Location shows every row (tokens as text only). The app is not sandboxed, so plain paths work without security-scoped bookmarks. Backups (A2) add one more location: `BackupService` destination, default in Application Support, configurable in Settings → Backup.

### 1.2 Schema scale

27 application tables (`_migrations` excluded), 44 registered migrations, `v41_remote_provider_identity` latest. Foreign keys are **deliberately disabled** (`config.foreignKeysEnabled = false` at all three connection sites) and locked by two tests — every `ON DELETE CASCADE` in the schema is inert and manual cascades are the correct pattern. **Do not "fix" this during Track A or C.**

### 1.3 UI surface the design session must cover

`MLM/Views` directories (17): Activity, ContentView, Discover, DiscoveryInbox, Folders, Library, Player, Playlists, Queue, ReelsInbox, ReviewQueue, Search, Settings, Shared, Sidebar, Sources, Sync, TrackDetail.

Sidebar sections (`MLM/Views/ContentView/ContentView.swift:524-532`): `library`, `playlists`, `playlistDetail(Int64)`, `folders`, `sync`, `sources`, `review`, `discover`, `queue`.

Plus non-sidebar surfaces: toolbar, player bar, Activity panel, Settings window, menu bar (⌘1–⌘7 Navigate, Playback commands), Spotlight-style search, empty/unmounted-drive states.

Codebase size: 183 Swift files in `MLM/`, 134 in `MLMTests/`.

Existing sketches (`sketches/`, untracked, 2026-09-19): `sketch_a_spotlight.html`, `sketch_b_dashboard.html`, `sketch_c_glass.html`, `sketch_d_feed.html`. Four concept sketches — roughly 5% of the "every view, every flow, every element" pass described in `todo_dump.md`.

---

## 2. Track A — Storage: transparency, relocation, backup, multi-library

**Why first:** it is the only track guarding against irreversible loss, and it is independent of the design work.

### A1 — Data-location transparency *(small)* — ✔ DONE 2026-10-04 (CODE-VERIFIED / UI-UNVERIFIED)
- ✔ Settings → **Storage Location** tab (`DataLocationsView` + `DataLocationsViewModel`) listing every location from §1.1 with live paths, sizes, and `Show in Finder` (UI-GROUNDTRUTH §5.6 — not "Reveal in Finder")
- ✔ DB size with WAL shown separately, last-backup time from `BackupService`; library folder size only on request (`Calculate size`, stored in `app_config` until recalculated)
- ✔ Doc comment in `DatabaseManager.swift` is correct (`com.musiclibrary.app`)
- ✔ Stray repo DBs gone; `*.db` gitignored
- ✔ One accessor for the covers folder: `DatabaseManager.playlistCoversDirectory` / `.defaultPlaylistCoversDirectory`
- Follow-up: "Reveal in Finder" strings remain in `LibrarySetupView.swift`, `TrackContextMenu.swift`, `SyncFailedDisclosure.swift` (§5.6 violations)

### A2 — Backup *(medium, highest value per unit of effort)* — ✔ DONE 2026-10-04 (`6d01fd8`, `6b5ec72`; Backup pane UI-UNVERIFIED)
- `VACUUM INTO` — the only correct online-backup primitive for a WAL database; a file copy of `music_library.db` alone silently loses everything in the 3 MB WAL
- Retention policy, configurable interval, destination
- **Back up before every migration run**, not just on schedule — 44 migrations against a 130 MB DB is the real danger window
- Restore path + first-launch recovery
- Open question: default destination. Application Support survives `.app` deletion but not a user purge of `~/Library`; the external disk survives that but is frequently unmounted

### A3 — Relocatable database + multi-library *(large, keystone)* — ✔ IMPLEMENTED 2026-10-05 (`48b1620` W0, `e5e7b62` W1, `3800530` W2, `d675e85` W3, `800af9d` W4; CODE-VERIFIED / UI-UNVERIFIED — live adoption runs on Oliver's first launch)
- **Library registry outside the DB** — `libraries.json` in Application Support; schema fixed by A0 D5, resolves the chicken-and-egg in §0.5
- **Library = `.mlibm` package** — settled by A0 D1/D9 (a `com.apple.package` directory Finder treats as one file: manifest + DB + covers, dedicated static icon). A3 implements the UTI/document-type registration, open-file handler, manifest + registry read/write, and rename re-point logic
- `DatabaseManager(path:)` already exists (line 57) — the plumbing is half-built
- Make `DependencyContainer` library-scoped, or rebuildable on switch (A0 D4: single active library, rebuild-on-switch)
- Menu bar item: Open Library / Open Recent
- Setting: "Remember last opened library" (registry-level, A0 D5)
- Empty state when off: disc-icon view asking which library to open (this screen must enter the Track B design session)
- Unmounted-volume handling already partly exists via `MountObserver`
- Auto-adopt the legacy install into a `.mlibm` package (A0 D7 + migration guide): back up first, atomic-or-resumable, deferrable
- Move the auxiliary data per A0: `playlist-covers/` into the package (D1); the transcode cache stays on the audio volume and remains per-library via `app_config.transcode_cache_path` (D2); tokens and `.env` stay global — they are credentials, not library content (D3)

#### A3 Step 0 — decisions (Oliver, 2026-10-05)
- Wave 0 done (uncommitted at time of writing): every Finder action reads `Show in Finder`; `FinderActionCopyTests` guards it.
1. **Switching = relaunch** (v1): write `last_active_library_id`, relaunch via `BackupService.relaunchApp()`; the launch resolver picks the library before `DependencyContainer.initialize`. In-process rebuild deferred.
2. **`library_id`**: live DB has `f1c9d287-7c19-4e62-ad81-eef851bf751f` (checked 2026-10-05, plain SELECT). Existing ID is kept; only if missing, a UUID is generated once (after the backup) and written to `app_config` + manifest + registry. Every open checks all three; a mismatch is shown, never repaired silently.
3. **Tauri compatibility dropped**; remove the "shares the same DB" comments.
4. **Backups per library**: default `…/backups/<library_id>/`; custom `backup_destination` stays per DB; list/prune/restore only see bundles with matching `libraryId`; legacy bundles with empty `libraryId` count as the adopted library's; restore never crosses libraries. New reason `.preAdoption` → `Before library file setup`.
5. **Caches namespaced** by `library_id` (`…/waveforms/<id>/`, `…/com.mlm.transcode_cache/<id>/` when no custom path); old unnamespaced caches are left orphaned, untouched.
6. **Adoption = copy, then retire**: journal → backup → `VACUUM INTO` `libraries/<name>.mlibm.partial/` + covers copy → `library.json` → verify (`quick_check`, id, track count) → rename → registry → re-point PathMigrations manifests → move legacy into `legacy-adopted-<ts>/` (never delete). Crash before rename: drop `.partial`, legacy intact. From rename on: resume idempotently. Runs before the container opens any DB.
7. **Glossary**: "Library" = the collection, stored in one **"Library file"** (`.mlibm`) — Apple Music model; sidebar unchanged.
8. **UI copy** approved as written into `UI-GROUNDTRUTH.md` §1.5, §2.6, §3.14, §3.16, §3.17, §5.6 (File menu items, adoption sheet, New Library sheet, switch alert, no-library / can't-be-opened states, Library-tab toggle `Open the last library at launch`, Storage Location `Library file` row + new footer).
9. **First run** without legacy or registry: `New Library` sheet ("Main Library") before the unchanged wizard.
10. **Registry recovery**: missing/unparsable `libraries.json` → rename to `libraries.json.corrupt-<ts>`, rebuild by scanning `libraries/*.mlibm`.
11. **Icon**: no custom `.icns` yet (macOS composes a document icon from the app icon); real icon is a B1 asset (TODO in `scripts/run.sh`).
12. **Finder copy of a library** (same `library_id`, both files exist; decided after Wave 1): opening the copy asks, then writes a new `library_id` into the copy (DB + manifest) and registers it as its own library. Copy for that prompt still needs approval (Wave 4, open-file handling).
13. **Follow-ups after A3 (2026-10-05):** `Reveal in destination` → `Show in Finder` (it opens Finder); `Reveal in Grid` stays (§2.2, not a Finder action); unused `revealSelectedInFinder` removed. Known, left as is: on a Mac still on the old layout, the adoption sheet is offered at every launch and `Not now` opens the old database even if other libraries exist — only matters for a not-yet-adopted install.

### A-track open questions — RESOLVED by A0 (2026-10-04)
All four settled in `A0-LIBRARY-DEFINITION.md` (binding for A2/A3/B1):
1. A library is a **`.mlibm` file package** — a `com.apple.package` directory (manifest `library.json` + DB + `playlist-covers/`) that Finder treats as one movable file, with a dedicated static icon; audio is referenced via `library_root`, never contained (D1/D2/D9).
2. Credentials are **global**, shared by all libraries, never backed up or deleted with one (D3).
3. **Single active library**; switching rebuilds the container (D4).
4. Dev/subset libraries **deferred**; no `derived_from` field in manifest v1 (D8).

Also fixed by A0: registry schema `libraries.json` outside any DB (D5), manifest schema (D6), auto-adopt-with-backup migration for the existing install plus a user-facing legacy migration guide (D7).

---

## 3. Track B — Design session, then conventions

**Why gated:** `todo_dump.md` is explicit that conventions must *not* be derived from the current design. So the session runs first and the conventions are its output. `UI-GROUNDTRUTH.md` stays binding in the meantime — code written before B3 lands must still conform to it.

### B1 — Design session *(large, interactive)* — ✔ APPROVED 2026-10-05 (`design/b1/`; `THOUGHTS.md` §10 holds Oliver's binding answers)
HTML/CSS/JS mockups, continuing `sketches/`. Scope from `todo_dump.md` is every view, flow, and element. Concretely, the checklist is §1.3: 17 view directories, 9 sidebar sections, plus toolbar, player bar, Activity panel, Settings, menu bar, search, and all empty/error/unmounted states. Add the new screens Track A3 and Track C2 introduce:
- Library picker + "remember last library" empty state
- Album list, album detail with fixed track order, album-variant chooser
- Backup/restore pane, data-locations pane

Decisions recorded as they are made — a running decision log, not a post-hoc summary. Liquid Glass is where this should shine; `docs/audit/LIQUID-GLASS-PLAN.md` and `sketch_c_glass.html` are prior art.

**Constraint carried forward from settled decisions:** the native macOS toolbar is the accepted chrome. Custom `.windowStyle(.hiddenTitleBar)` / floating-player experiments were rejected repeatedly. Any redesign keeps the native toolbar; `.principal` centers between leading and trailing groups, not in the window.

### B2 — Conventions *(medium)* — ✔ DONE 2026-10-05 (`UI-CONVENTIONS.md`, rule IDs `UC-<AREA>-<nn>`; extended 2026-10-06 with the sentences introduced during B3 and §25 Decisions during B3)
Output of B1, replacing `UI-GROUNDTRUTH.md` section by section:
- Design tokens, typography, spacing, iconography
- Per-pattern rules: tables, cards, logs, settings, sheets, alerts, menu items
- State vocabulary — `UI-GROUNDTRUTH.md` §1.6 already establishes this well; carry it forward unless B1 overturns it
- Written as agent-consumable rules, since `todo_dump.md` explicitly wants "guidelines for any agent that works in this code"

### B3 — Implementation conformance *(large, follows B1/B2)* — ✔ IMPLEMENTED 2026-10-05 … 2026-10-06 on `redesign/b3` (tag `v0.9` = state before)
Work packages, owners and decisions (`IMP-001` … `IMP-124`) are in `B3-PLAN.md`; the per-ID verdicts against `design/b1/COVERAGE.md` are in `B3-CONFORMANCE.md`.
- **Wave 0** (2026-10-05): branch, design packet, `UI-CONVENTIONS.md`, macOS 27 deployment target, plan.
- **Wave 1** (2026-10-05): navigation model, sidebar, toolbar, scaffolding; Settings scene and menu bar.
- **Wave 2** (2026-10-05): undo center, shared track table with persisted availability, All Tracks, playback and Space preview, queue panel, Info, selection bar, drag and drop, search.
- **Wave 3** (2026-10-05 … 2026-10-06): playlists, Folders, Activity, launch and libraries, Settings, Add and import, Sync, Review, Discover and Reels, Genres.
- **Wave 4** (2026-10-06): Albums — see Track C.
- **Wave 5** (2026-10-06): conformance — dead code and theme tokens removed, follow-ups, audit (374 IDs), gap fixes, menu bar and Dock completed, three TipKit tips, snapshot baselines re-recorded for macOS 27 (27 fixtures, 54 images).

### B-track open questions
1. Does B2 keep the foundations of `UI-GROUNDTRUTH.md` (color tokens, glossary, state vocabulary) and redesign only screens/shell, or start clean? Carrying the foundations forward saves the most time; the glossary and state vocabulary are design-independent and already good.
2. ~~Snapshot baselines~~ — answered 2026-10-05: the 60 old baselines were deleted (recoverable from `v0.9`); 54 new ones (27 fixtures, Light and Dark) were recorded for `macos27-arm64` in W5-5.

---

## 4. Track C — Albums, and removal of source-as-album

### C1 — Album track ordering *(medium)* — ✔ DONE 2026-10-06 (W4-1: `album_tracks` v50, album dedup v51, fix round)
- `tracks` has no `track_number`/`disc_number`; no `album_tracks` join exists
- Two options: (a) add `track_number` + `disc_number` to `tracks`, (b) add an `album_tracks` join mirroring `playlist_tracks`, which already uses a **fractional-index `position TEXT`** for stable ordering
- Recommendation: (b) if album membership must stay independent of the file's own tags, (a) if the tag is authoritative. Decide in design — this is the "extensive thinking" `todo_dump.md` calls for
- Cover art: `albums.cover_path` exists; the `artwork` table and `ArtworkResolver` already resolve remote artwork

### C2 — Album UI *(large, gated on B1)* — ✔ DONE 2026-10-06 (W4-2 grid, page, Go to Album, edit order; W4-2b Edit Album Info, Merge with Another Album, Use a Track from the Library…, album picker)
Album list, album detail with respected ordering, variant chooser wired to the existing `user_album_variant_pref`. Cannot be designed before B1 — the screens do not exist yet.

### C3 — Source removal + metadata backfill *(large, gated on C1)* — ✔ DONE except the online lookup (2026-10-06, W4-3: v52 album suggestions, Review ▸ Albums, `No album`, source-as-album writes stopped, `Clear Source Names from Album…`; lookup provider is the local `TagAlbumSuggester` behind the `AlbumSuggesting` seam — an online provider waits for `B3-PLAN.md` §5 Q2, no MusicBrainz client exists)
- Stop writing source names into `album` — `ContentView.swift:400-407`
- Persist provenance in `track_sources` (19,596 rows, ~1.5 per track) instead of the album field. **Provenance must survive** — `todo_dump.md` wants it hidden when sharing, not deleted
- Backfill real album metadata for the 132 literal-source tracks and the 6,209 `unknown album` tracks
- Available assets: `SpotifyClient`, `SoundCloudClient`, `URLDetector`, `ArtworkResolver`
- MusicBrainz as a candidate — no client exists yet

### C-track open questions (the hard ones)
1. **YouTube videos that were never on an album.** A mix, a live set, a video-only upload — what album does it belong to? Options: a synthesized "singles/non-album" bucket, leave album empty, or store the channel as album artist with no album. This decision determines whether the 48% `unknown album` population is even fixable.
2. Is `unknown album` a *sentinel* or a *value*? 6,209 tracks share it. If it becomes a real album row it will be the largest album in the library and will look like a bug. Recommendation: `NULL`, rendered as "No album" per the state vocabulary — never a real album entity.
3. Album deduplication: 8,020 rows for 1,616 distinct titles. Separate cleanup pass, or folded into C3?
4. Sharing: what exactly is stripped when an MP3 is shared — the album tag, the `track_sources` rows, or both? `todo_dump.md` says "when i share an mp3, i dont want to share where i got it from", which implies a tag-writing path, not just a UI-hiding path.

---

## 5. Sequencing

```
A0  Define "what is a library"  ✔ DONE ─┐  (A0-LIBRARY-DEFINITION.md; blocks A3 + B1 picker)
                                        │
        ┌───────────────────────────────┴───────────────────────────┐
        │                                                            │
Track A (storage)                                        Track B (design)
  A1 transparency ──► A2 backup ──► A3 multi-library        B1 session ──► B2 conventions
        │                                                            │
        └────────────────────────────┬───────────────────────────────┘
                                     ▼
                            Track C (albums/sources)
                     C1 ordering ──► C3 source removal + backfill
                              └────► C2 album UI  (needs B1)
```

**Rationale**
- **A0 first, alone. ✔ Done 2026-10-04.** Settled in `A0-LIBRARY-DEFINITION.md`; the Track-A open questions are all resolved and the definition now gates A3 and the B1 picker.
- **A2 before A3.** Backups must exist *before* a multi-library refactor touches a 130 MB DB with 44 migrations. Doing A3 first means doing it unprotected. A2's backup unit is the library directory from A0 D1.
- **A and B in parallel.** They share no files. A is backend/storage — well-suited to autonomous TDD workers with clear test contracts. B is aesthetic and open-ended — interactive, human-steered. Do not try to swarm B.
- **C last.** C2 needs B1's screens; C3 needs C1's schema. C1 can start earlier if the ordering question is settled, but nothing in C is urgent against A2.

**State (2026-10-06):** A0–A3, B1–B3 and C1–C3 are done (C3 except the online lookup). Remaining: Oliver's launch checklist in `B3-CONFORMANCE.md` (what no agent can verify without starting the app), the open questions in `B3-PLAN.md` §5 (Q2 album lookup source, Q4 Activity history, Q5 add-only refresh, Q6 tag writing default), and the online album lookup behind the `AlbumSuggesting` seam.

---

## 6. Standing constraints

Carried from settled decisions; they apply to every track.

1. **Foreign keys stay disabled.** `config.foreignKeysEnabled = false` is deliberate and test-locked by `foreignKeysRemainDisabledForSharedSchemaCompatibility()` and `inMemoryDatabaseDoesNotEnableForeignKeys()`. Flipping it breaks 7 tests. Manual cascades are the correct pattern.
2. **Native toolbar stays.** No custom window chrome, no floating player overlays.
3. **Live DB inspection must not use `sqlite3 -readonly`.** The DB runs in WAL mode while the app holds connections; a readonly connection cannot recover the 3 MB WAL and silently returns a stale snapshot. Use a plain connection with SELECT-only statements.
4. **`swift test` prints two runner summaries.** Verify new XCTest suites by name, not by total count.
5. **No shotty / screenshots / app-launch verification** in delegated agent work.
6. **`UI-GROUNDTRUTH.md` is binding** until B2 supersedes it.
