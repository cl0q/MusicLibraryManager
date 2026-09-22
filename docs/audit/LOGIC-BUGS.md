# Logic correctness audit

Date: 2026-09-22. Baseline: `5476738`; initial worktree clean.
Scope: macOS `MLM` and supporting `MLMTests`. No mobile/helper audit.

**All findings are static evidence. No Swift build/test, Mac reproduction,
filesystem failure injection or screenshot rendering was executed.** Confidence
describes how directly source establishes the defect; it is not runtime proof.
Suggested fixes are sketches, not changes made by this audit.

Severity: CRITICAL = data loss or reachable crash; HIGH = functional failure;
MEDIUM = narrower state/edge-case failure; LOW = cleanup. Ordered by severity,
then confidence. Findings with a shared user symptom but different root causes
remain separate; identical instrumentation findings are consolidated.

## LOGIC-001 - Artwork replacement can permanently remove the audio file

**CRITICAL | Confidence 10/10**

- **Evidence:** [ArtworkService:278-335](../../MLM/Services/Analysis/ArtworkService.swift#L278),
  especially removal/replacement at [328-329](../../MLM/Services/Analysis/ArtworkService.swift#L328);
  [DownloadOrchestrator:1262-1266](../../MLM/Services/Download/DownloadOrchestrator.swift#L1262)
  discards the returned Boolean.
- **Trigger:** Artwork embedding succeeds in ffmpeg, then moving the generated
  output to the original path fails due to an I/O, permission or volume change.
- **Expected / actual:** The original audio must survive failed optional artwork
  processing. Instead the original is removed **before** the fallible move;
  the catch reports failure and temporary-directory cleanup removes the remaining
  generated copy.
- **Root cause:** Delete-then-move is not a failure-atomic replacement.
- **Fix / regression:** Stage on the destination volume, validate output, use a
  recoverable replacement/backup protocol and retain recovery material until
  success. Inject failure specifically between removal/replacement; assert the
  original or recoverable replacement survives and the caller sees failure.

## LOGIC-002 - Detached OCR/Shazam completion can address a deleted Reel index

**CRITICAL | Confidence 10/10**

- **Evidence:** [ReelsInboxView:700-711](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L700),
  [1540-1650](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L1540),
  [1654-1815](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L1654).
- **Trigger:** Start OCR or identification; delete that Reel or an earlier row
  before the detached work finishes.
- **Expected / actual:** Completion should find the stable Reel UUID or discard
  a deleted request. It instead retains a mutable array index and later accesses
  `importedReels[index]`. A shortened array can trap; a shifted index can write
  another Reel's recognition metadata.
- **Root cause:** Collection position crosses long asynchronous work without
  stable identity or task-lifetime ownership.
- **Fix / regression:** Key retained tasks by Reel UUID, cancel on deletion,
  re-resolve identity on the main actor after every await, and ignore stale
  generations. Test deleting the last/preceding row while completion is gated.

## LOGIC-007 - Concurrent device-ingest Apply can crash or remove the wrong row

**CRITICAL | Confidence 10/10**

- **Evidence:** [DeviceIngestResultsView:100-112,174-179](../../MLM/Views/Sync/DeviceIngestResultsView.swift#L100),
  [SyncViewModel:657-670](../../MLM/ViewModels/SyncViewModel.swift#L657).
- **Trigger:** With several results, apply two different rows before the first
  ingest await returns.
- **Expected / actual:** Exactly the applied results should disappear. Each
  invocation retains an array index across `await ingest`; the first removal
  shifts the second index. With two results, index 0 completing first leaves
  index 1 out of bounds: unguarded `remove(at:)` at line 665 traps. With more
  results it can remove an unprocessed row instead. The catch path also accesses
  the retained index without a post-await guard.
- **Root cause:** Mutable position is used as request identity across reentrancy.
- **Fix / regression:** Use a stable scan-result ID/path, track applying IDs,
  and remove by identity after success. Test reverse completion orders and
  deletion/re-scan while applying; bounds checks alone do not fix wrong identity.

## LOGIC-025 - A rejected DAB stream URL traps instead of entering fallback

**CRITICAL | Confidence 9/10**

- **Evidence:** [DABClient:166-174](../../MLM/Services/Download/DABClient.swift#L166),
  [204-220](../../MLM/Services/Download/DABClient.swift#L204),
  [DownloadOrchestrator:890-928](../../MLM/Services/Download/DownloadOrchestrator.swift#L890).
- **Trigger:** A provider/mirror returns a decoded stream URL string that
  Foundation's `URL(string:)` cannot represent.
- **Expected / actual:** Malformed provider output should become a classified
  error and permit fallback. `URL(string: streamURL)!` instead traps before a
  `DownloadResult` can reach the fallback classifier.
- **Root cause:** An externally supplied string is treated as a proven URL.
  Modern Foundation may encode spaces/percent characters, and an empty or
  relative string is not automatically nil; those are **not** asserted crash
  fixtures here. The precise rejected-input case needs a Mac regression test.
- **Fix / regression:** Use optional binding plus allowed scheme/host validation,
  return a typed provider-output failure, and test both a genuinely rejected URL
  and a constructible but unsupported relative/scheme URL.

## LOGIC-003 - Startup failure never reaches the existing error screen

**HIGH | Confidence 10/10**

- **Evidence:** [AppDelegate:35-43](../../MLM/App/AppDelegate.swift#L35),
  [DependencyContainer:76-77](../../MLM/App/DependencyContainer.swift#L76),
  [ContentView:59-97](../../MLM/Views/ContentView/ContentView.swift#L59).
- **Trigger:** DB migration/open or application-support setup throws.
- **Expected / actual:** Initialization should terminate in an actionable error.
  The launch catch only prints; the observable `initializationError` is never
  assigned on that path and `isInitialized` remains false, so loading persists.
- **Root cause:** Bootstrap failure is disconnected from presentation state.
- **Fix / regression:** Publish failure through an actor-safe container API,
  log with the existing logger and offer explicit recovery. Inject a failing
  initializer and assert error, not an indefinitely loading root.

## LOGIC-004 - Library DB deletion proceeds after a failed Trash operation

**HIGH | Confidence 10/10**

- **Evidence:** [TrackContextMenu:218-243](../../MLM/Views/Library/TrackContextMenu.swift#L218).
- **Trigger:** Confirm Move to Trash for a local file whose volume becomes
  unavailable, permission is denied or trashing otherwise fails.
- **Expected / actual:** Failed files should remain represented with a visible
  error. `try? trashItem` discards failure, then repository deletion removes
  records/memberships anyway; the untrashed file can remain on disk unindexed.
- **Root cause:** A destructive file operation's success is not required before
  its corresponding DB mutation.
- **Fix / regression:** Resolve and trash per item, collect successful IDs,
  preserve failed items, report partial outcomes and retain restoration data.
  Also handle DB failure after successful trashing. Test both failure boundaries.

## LOGIC-005 - Uncached sync profile B displays profile A's preview

**HIGH | Confidence 10/10**

- **Evidence:** [SyncViewModel:216-230,276-293](../../MLM/ViewModels/SyncViewModel.swift#L216),
  [SyncProfileDetailView:63-67,117-160](../../MLM/Views/Sync/SyncProfileDetailView.swift#L63).
- **Trigger:** Select cached A, then B with no valid preview cache.
- **Expected / actual:** B must not expose A's counts/free-space/eligibility.
  Content is cleared, but `preview` and `previewComputedAt` are not.
  `presentCachedPreview` returns on a cache miss, leaving A visible until B
  finishes refreshing.
- **Root cause:** Published preview is not associated with its owning profile.
  The completion UUID guard does not invalidate already-published old state.
- **Fix / regression:** Publish a profile-tagged preview or clear all preview
  state on cache miss. Test A-cached to B-uncached and changed-connectivity cases.

## LOGIC-006 - Late sync content fetch overwrites the selected profile

**HIGH | Confidence 10/10**

- **Evidence:** [SyncViewModel:216-229,334-344](../../MLM/ViewModels/SyncViewModel.swift#L216),
  [SyncContentSections:40,133](../../MLM/Views/Sync/SyncContentSections.swift#L40).
- **Trigger:** Select A then B while A's playlists/tracks reads are suspended.
- **Expected / actual:** Only B's content should publish. An untracked A task
  assigns global arrays after awaits without validating the selected profile;
  its late results can populate B.
- **Root cause:** Content loading lacks the generation/identity protection used
  by preview refresh.
- **Fix / regression:** Retain/cancel the content task, fetch into local values,
  commit atomically only for the current profile/request. Test delayed A with
  immediate B and ensure neither array mixes profiles.

## LOGIC-008 - Library row cache ignores changed track values

**HIGH | Confidence 10/10**

- **Evidence:** [LibraryTable:69-88](../../MLM/Views/Library/LibraryTable.swift#L69).
- **Trigger:** Refresh changes metadata or a middle row while count and first/last
  IDs remain equal.
- **Expected / actual:** Cells should reflect new `Track` values. The cache guard
  only compares `(count, firstID, lastID)` and retains complete old row snapshots.
  Even changed middle membership can pass this fingerprint.
- **Root cause:** A membership-endpoint heuristic is used to validate value data.
- **Fix / regression:** Rebuild on displayed-track revision/change, or key every
  relevant value/order. Test title/format updates and middle-row replacement with
  unchanged endpoints, not only sorting or count changes.

## LOGIC-009 - Playlist row cache preserves stale metadata and failure dimming

**HIGH | Confidence 10/10**

- **Evidence:** [PlaylistTable:252-287](../../MLM/Views/Playlists/PlaylistTable.swift#L252).
- **Trigger:** Change track fields or failed-to-local availability without
  changing ordered IDs or the availability-map count.
- **Expected / actual:** Refreshed cells and opacity should update. The rolling
  ID hash plus availability **count** still match; `cachedRows` keeps old
  `Track` structs and cached `isFailed`. The status chip itself reads the live
  availability map, so it may update while the row remains incorrectly dimmed.
- **Root cause:** Cache invalidation omits values it stores.
- **Fix / regression:** Rebuild on data revision, or make row presentation derive
  current values. Test same-ID title changes and same-size failed-to-local maps.
  Calling the rebuild helper is not proof that its early return is correct.

## LOGIC-010 - Maintenance cancellation does not stop queued workers or tools

**HIGH | Confidence 10/10**

- **Evidence:** [ReplayGainAnalyzer:76-112](../../MLM/Services/Analysis/ReplayGainAnalyzer.swift#L76),
  [FingerprintService:76-112](../../MLM/Services/Analysis/FingerprintService.swift#L76),
  [GrooveBatchAnalyzer:30-65](../../MLM/Services/Analysis/GrooveBatchAnalyzer.swift#L30),
  [DanceabilityAnalyzer:337-371](../../MLM/Services/Analysis/DanceabilityAnalyzer.swift#L337),
  [ArtworkService:84-113](../../MLM/Services/Analysis/ArtworkService.swift#L84),
  [ArtworkBackfillService:258-311](../../MLM/Services/Artwork/ArtworkBackfillService.swift#L258),
  [ConcurrencyLimiter:31-39](../../MLM/Services/Common/ConcurrencyLimiter.swift#L31),
  [ProcessRunner:66-158,205-303](../../MLM/Utilities/ProcessRunner.swift#L66).
- **Trigger:** Queue more analysis children than permits, start ffmpeg/fpcalc,
  then Cancel.
- **Expected / actual:** Waiting work should not start and active work should stop
  promptly. Children check the tracker **before** semaphore waiting, not after
  acquiring; breaking result collection does not cancel them. Process continuations
  have no cancellation handler, so running tools can continue and later writes
  can occur. These callers also do not supply a timeout for a hung tool.
- **Root cause:** Cancellation does not propagate through every admission,
  process-lifetime and persistence boundary.
- **Fix / regression:** Cancel the task group, make waiting cancellation-aware,
  re-check before work/writes, and implement single-resume process cancellation
  with termination/escalation and bounded timeout. Test the real queued-worker
  path; existing cooperative toy-worker tests do not prove it.

## LOGIC-011 - Universal Search permits stale submissions to win

**HIGH | Confidence 10/10**

- **Evidence:** [UniversalSearchView:56-70](../../MLM/Views/Search/UniversalSearchView.swift#L56),
  [UniversalSearchViewModel:35-142](../../MLM/ViewModels/UniversalSearchViewModel.swift#L35).
- **Trigger:** Submit slow URL A, then URL B; A finishes last. Clear while a
  request is pending is the related invalidation case.
- **Expected / actual:** Only the newest input owns results/error/loading.
  Independent submit tasks have no generation check and overwrite shared state
  on completion.
- **Root cause:** Request identity is missing in this VM, unlike the separate
  global-search presentation VM.
- **Fix / regression:** Capture input/request identity, retain/cancel task, guard
  post-await assignments, invalidate on Clear. Test reversed success/error
  completion orders with deterministic suspended clients.

## LOGIC-012 - Playlist-scoped global search drops the playlist ID

**HIGH | Confidence 10/10**

- **Evidence:** [ContentView:174-190](../../MLM/Views/ContentView/ContentView.swift#L174),
  [context bridge:301-328](../../MLM/Views/ContentView/ContentView.swift#L301),
  [GlobalSearchPresentationView:195-206](../../MLM/Views/Search/GlobalSearchPresentationView.swift#L195),
  [GlobalSearchPresentationViewModel:81-88](../../MLM/ViewModels/GlobalSearchPresentationViewModel.swift#L81),
  [SearchResultsMerger:6-13](../../MLM/Services/Search/SearchResultsMerger.swift#L6).
- **Trigger:** Search from an opened pinned playlist context.
- **Expected / actual:** Matching context-playlist tracks should be fetched/ranked
  as the coordinator promises. `.playlist(id)` is reduced to an id-less merger
  context; `contextPlaylistID` is never assigned, so its fetch guard fails.
- **Root cause:** Identity is lost across the coordinator/presentation adapter.
- **Fix / regression:** Carry the ID in presentation context or assign it along
  with the enum on construction and changes. Test end-to-end propagation and
  ordering, not just independent merger behavior.

## LOGIC-013 - Activity Cancel reports cancellation while non-cancellable work continues

**HIGH | Confidence 10/10**

- **Evidence:** [ActivityViewModel:146-174,254-279](../../MLM/ViewModels/ActivityViewModel.swift#L146),
  [ActivityFeed:300-330](../../MLM/Views/Activity/ActivityFeed.swift#L300),
  [OperationsTab:292-306](../../MLM/Views/Activity/OperationsTab.swift#L292),
  [DependencyContainer:400-457](../../MLM/App/DependencyContainer.swift#L400).
- **Trigger:** Start transcode-cache relocation, then click its Activity Cancel.
- **Expected / actual:** Cancellation should either stop side effects or not be
  offered. Feed generation offers Cancel for every running operation without
  checking `isCancellable`. Cancellation archives a token-less operation, while
  relocation continues copying/removing cache originals and saving the new path.
- **Root cause:** UI action capability and terminalization ignore the operation's
  cancellation contract.
- **Fix / regression:** Gate both action and command by actual cancellability.
  Implement cooperative cancellation/recovery before exposing it for relocation.
  Verify the worker, not merely that the Activity row disappears.

## LOGIC-026 - Parent deletion leaves relationships orphaned with foreign keys disabled

**HIGH | Confidence 10/10**

- **Evidence:** [TrackRepository:483-496](../../MLM/Database/TrackRepository.swift#L483),
  [PlaylistRepository:87-94](../../MLM/Database/PlaylistRepository.swift#L87),
  [DatabaseManager:35-39,61-67](../../MLM/Database/DatabaseManager.swift#L35);
  contrast the explicit cleanup in [SyncRepository:43-59](../../MLM/Database/SyncRepository.swift#L43).
- **Trigger:** Delete a track with playlist/source/analysis/sync relationships,
  or an ordinary playlist with memberships.
- **Expected / actual:** Dependent state must be reconciled transactionally.
  General track/playlist deletion deletes only the parent; declared SQL cascades
  do not run. For example [SourceRepository.countTracks:129-135](../../MLM/Database/SourceRepository.swift#L129)
  counts source-link rows without joining existing tracks, so a deleted track
  still inflates the account's visible track count.
- **Root cause:** FK enforcement is intentionally **off in production and in-memory
  databases alike** for legacy compatibility, but these repositories lack the
  application-level cascade already implemented for sync profiles.
- **Fix / regression:** Enumerate actual relationships and their actual foreign
  key columns, implement transactional cleanup/reconciliation for each deletion
  API, and test populated parents under FK-off configuration. Do not enable FKs
  without a separately validated cleanup/migration of historical data.

## LOGIC-031 - Failed playback changes queue/history while controls still refer to the prior track

**HIGH | Confidence 10/10**

- **Evidence:** [PlaybackViewModel:98-105,133-169,239-243](../../MLM/ViewModels/PlaybackViewModel.swift#L98),
  [PlayerBar:35-69,114-146](../../MLM/Views/Player/PlayerBar.swift#L35),
  [AudioPlayer:122-126,306-320](../../MLM/Services/Audio/AudioPlayer.swift#L122).
- **Trigger:** Play A, then attempt missing B and Retry.
- **Expected / actual:** Either reject B while clearly retaining A, or transition
  coherently to B's unavailable state. The missing-file branch leaves A playing,
  but generic error presentation hides A's identity while transports still
  control it. `playTrack(B)` already clears the context queue and records B in
  history; Retry repeats those side effects without successful playback.
- **Root cause:** Attempted/retry target, now-playing state and successful queue
  advancement are conflated.
- **Fix / regression:** Choose and document one rejection policy; name B in its
  error, retain A coherently or stop/clear it, and commit history/queue advancement
  only on actual playback. For a *throwing load*, `AudioPlayer.loadFile` already
  stops A; do not claim it continues. Still reconcile its retained file/current
  track state before offering Play. Test both failure branches and Retry.

## LOGIC-014 - Download batch admission is reentrant

**HIGH | Confidence 9/10**

- **Evidence:** [DownloadViewModel:183-348](../../MLM/ViewModels/DownloadViewModel.swift#L183),
  [TrackContextMenu:35-47](../../MLM/Views/Library/TrackContextMenu.swift#L35),
  [RemotePlaylistsViewModel:112-115](../../MLM/ViewModels/RemotePlaylistsViewModel.swift#L112),
  [DownloadOrchestrator:381-420](../../MLM/Services/Download/DownloadOrchestrator.swift#L381).
- **Trigger:** Start a second request during the first entry-point suspension or
  from another surface without a matching disabled gate.
- **Expected / actual:** One owner should retain its batch rows/counts/callbacks,
  or requests should queue independently. `downloadTracks` has no busy guard and
  awaits before setting `isDownloading`; another invocation can replace the
  same queue/progress state.
- **Root cause:** Global batch state has no exclusive admission or batch identity.
  The orchestrator also merely sets `isRunning`; it does not reject/serialize a
  second batch, so the lower layer does not repair the caller's race.
- **Fix / regression:** Establish ownership before any await on a single actor,
  reject visibly or enqueue, and validate callback/finalization batch IDs.
  Test overlapping starts and independent results. Do not rely on a button's
  disabled state as synchronization.

## LOGIC-015 - Add to Playlist uses unordered IDs and a fixed append position

**HIGH | Confidence 9/10**

- **Evidence:** [TrackContextMenu:307-326](../../MLM/Views/Library/TrackContextMenu.swift#L307),
  [PlaylistRepository:265-287](../../MLM/Database/PlaylistRepository.swift#L265).
- **Trigger:** Add multiple selected rows, especially to a playlist whose tail
  already sorts after the fixed starting position.
- **Expected / actual:** Selection should append in display order. Converting a
  `Set` to `Array` loses that order, and `"999000"` is supplied without reading
  the actual destination tail. Repeated batches can interleave or sort earlier.
- **Root cause:** Context-menu append bypasses the repository's ordering invariant.
- **Fix / regression:** Derive ordered IDs from the displayed snapshot; provide
  an atomic append API that reads the true tail and allocates positions within
  one write transaction. Test repeated and concurrent multi-add batches.

## LOGIC-016 - Folder restore can leave the newly configured library root

**HIGH | Confidence 9/10**

- **Evidence:** [FolderViewModel:14-33,112-145](../../MLM/ViewModels/FolderViewModel.swift#L14).
- **Trigger:** Save selection beneath root A, configure root B while A still
  exists, then reopen/refresh Folders.
- **Expected / actual:** Selection should belong to B. Restore checks only that
  the saved directory exists, then scans/imports the old A location.
- **Root cause:** Persisted selection is global and has no root identity or
  component-aware containment validation.
- **Fix / regression:** Store root identity plus a relative selection, reject
  stale/out-of-root paths and reset on root change. Validate standardized path
  components rather than naive string prefix (`Music2` is not inside `Music`).

## LOGIC-017 - Earlier folder selection can overwrite newer rows

**HIGH | Confidence 9/10**

- **Evidence:** [FolderViewModel:48-70,150-224](../../MLM/ViewModels/FolderViewModel.swift#L48).
- **Trigger:** Select slow folder A then fast B.
- **Expected / actual:** B's rows, availability and unindexed count should remain.
  Each selection launches untracked work; late A results assign shared state
  while `selectedFolderPath` is B.
- **Root cause:** No captured path/generation check at asynchronous commit points.
- **Fix / regression:** Cancel superseded task, capture requested root/path and
  generation, publish a coherent result only if still current. Test both completion
  orders and root changes during an outstanding directory scan.

## LOGIC-018 - Auto cover regeneration can overwrite a newer custom cover

**HIGH | Confidence 9/10**

- **Evidence:** [PlaylistCoverService:102-191,201-227](../../MLM/Services/Playlists/PlaylistCoverService.swift#L102).
- **Trigger:** Auto regeneration checks the custom lock, suspends, then the user
  sets a custom image before auto work finishes.
- **Expected / actual:** User choice should win. Custom setting does not join the
  auto-only `inFlight` gate; old auto work later overwrites the same PNG and
  persists `isCustom: false`, removing both the image and its lock.
- **Root cause:** Mutations share a file but not per-playlist serialization or
  generation ownership.
- **Fix / regression:** Serialize all cover operations per ID or validate a
  generation immediately before committing staged image/DB state. Test a gated
  regenerate/custom interleaving; testing an already-custom cover is insufficient.

## LOGIC-019 - Similar provider requests publish under a newer selected source

**HIGH | Confidence 9/10**

- **Evidence:** [GrooveView:515-528,853-902](../../MLM/Views/TrackDetail/GrooveView.swift#L515).
- **Trigger:** Switch Last.fm to SoundCloud rapidly, or refresh/load more while
  another recommendation request is pending.
- **Expected / actual:** Rows/error/loading should belong to the selected
  `(source, limit, request)`. Untracked tasks read mutable state and publish
  unconditionally; late old results or errors replace the current provider.
- **Root cause:** Source identity and generation are not carried through awaits.
- **Fix / regression:** Capture request parameters, cancel superseded work and
  guard every commit, including local-status refresh. Test old failure/new success
  and old success/new success with reversed completion.

## LOGIC-027 - Concurrent remote materialization creates duplicate source identities

**HIGH | Confidence 9/10**

- **Evidence:** [RemoteTrackMaterializer:16-62](../../MLM/Services/Search/RemoteTrackMaterializer.swift#L16),
  [DatabaseManager:128-137](../../MLM/Database/DatabaseManager.swift#L128),
  [SourceRepository:105-115](../../MLM/Database/SourceRepository.swift#L105).
- **Trigger:** Materialize duplicate `(source, externalId)` results concurrently,
  including duplicates within one task-group input.
- **Expected / actual:** All callers should receive the same canonical track.
  Independent read-then-insert operations can each see absence and create a
  different track/link. The final migrated schema has only the link's
  `(track_id, source_id)` primary key, not unique source/external identity.
  `INSERT OR IGNORE` therefore does not prevent this collision.
- **Root cause:** Cross-task uniqueness relies on a non-atomic existence check
  without a database invariant.
- **Fix / regression:** Reconcile historical duplicates first; define a unique
  provider-identity constraint with an explicit policy for absent IDs and do
  insert/get atomically in a writer transaction. Deduplicate in-flight input too.
  Test concurrent callers and repeated IDs, including dependent-row reconciliation.

## LOGIC-030 - Inspector availability survives a change to a different track

**HIGH | Confidence 9/10**

- **Evidence:** [MetadataPanel:121-175,1096-1110](../../MLM/Views/TrackDetail/MetadataPanel.swift#L121),
  [ContentView:218-233](../../MLM/Views/ContentView/ContentView.swift#L218).
- **Trigger:** Inspect missing/remote A, then select local B while the inspector
  remains open.
- **Expected / actual:** File status should belong to B. An unkeyed initial task
  loads availability, but the track-change handler only reloads other metadata.
  The parent retains the same view identity, so `@State` still contains A's status.
- **Root cause:** Track-scoped state is not invalidated on input identity change;
  the parent does not recreate it with `.id(track.id)`.
- **Fix / regression:** Key/reload availability by track identity, reset stale
  state and guard late completion. Test A-to-B with both immediate and delayed
  old reads and verify the File tab's label.

## LOGIC-020 - Missing discovery dependencies leave a permanently queued item

**MEDIUM | Confidence 10/10**

- **Evidence:** [DownloadViewModel:647-677](../../MLM/ViewModels/DownloadViewModel.swift#L647).
- **Trigger:** Request discovery download before a library root configures the
  orchestrator, or when its optional repository is absent.
- **Expected / actual:** A visible configuration failure should allow a later
  retry. The request is marked queued first; worker admission then returns on
  missing dependencies without terminalizing it. Future taps see queued and exit.
- **Root cause:** Admission validation occurs after publishing nonterminal state.
- **Fix / regression:** Validate before enqueueing or explicitly fail/drain
  affected requests with recovery text. Test missing dependencies, subsequent
  setup and successful retry of the same request.

## LOGIC-021 - Artwork backfill rejects the original-path fallback it needs

**MEDIUM | Confidence 10/10**

- **Evidence:** [ArtworkBackfillService:308-337](../../MLM/Services/Artwork/ArtworkBackfillService.swift#L308).
- **Trigger:** A local/legacy track has a valid absolute original path but
  nil/empty `organizedPath` and no artwork.
- **Expected / actual:** Resolve the original file and advance progress once.
  The initial organized-path guard returns before the later original-path
  fallback, sentinel and progress update. The same track can be retried forever.
- **Root cause:** Entry precondition contradicts the method's fallback strategy.
- **Fix / regression:** Guard identity, then build valid organized/original
  candidates. Terminalize every examined row exactly once, including no-file
  cases. Test nil and empty organized paths with a readable original.

## LOGIC-022 - Discovery queue can start multiple processors

**MEDIUM | Confidence 9/10**

- **Evidence:** [DownloadViewModel:665-708](../../MLM/ViewModels/DownloadViewModel.swift#L665).
- **Trigger:** Enqueue two recommendations before the first scheduled worker
  executes.
- **Expected / actual:** A single FIFO worker should own the queue. Both calls
  observe `isProcessingDiscoveryQueue == false`; it is set only inside the
  scheduled task. Two workers can consume and mutate queue/progress concurrently.
- **Root cause:** Check/set is separated by task scheduling and lacks isolated
  ownership.
- **Fix / regression:** Claim worker ownership before spawning, reset with
  structured cleanup, and isolate all queue state. Test two enqueues in one turn
  and assert a single worker and ordered outcomes.

## LOGIC-023 - Import cancellation is ignored during batch saving

**MEDIUM | Confidence 9/10**

- **Evidence:** [ImportService:218-227,243-262](../../MLM/Services/Import/ImportService.swift#L218).
- **Trigger:** Cancel a multi-batch import during/after the first 500-track save.
- **Expected / actual:** Already committed work may remain, but subsequent
  transactions and analysis enqueueing should stop with an explicit partial
  cancellation result. The nonthrowing save loop has no cancellation checks
  between batches; enqueueing after it also proceeds.
- **Root cause:** Cooperative cancellation covers extraction, not later
  persistence and follow-on work.
- **Fix / regression:** Check cancellation before each transaction and enqueue
  boundary; make partial committed counts explicit. Test cancellation during a
  gated first transaction and assert no second save/analysis scheduling.

## LOGIC-028 - Retry-queue persistence failures are suppressed

**MEDIUM | Confidence 9/10**

- **Evidence:** [DownloadQueue:137-153](../../MLM/Services/Download/DownloadQueue.swift#L137),
  [DownloadOrchestrator:480-500,568-604](../../MLM/Services/Download/DownloadOrchestrator.swift#L480).
- **Trigger:** Enqueue/dequeue/clear while the library drive is full, unmounted or
  read-only, or replacement of the temporary queue file fails.
- **Expected / actual:** The caller must distinguish in-memory mutation from
  durable success and retain recoverable old JSON. `save()` returns no failure,
  suppresses directory/fallback-write errors, and falls back to direct writing.
  Relaunch can lose new retries or resurrect supposedly dequeued entries.
- **Root cause:** Persistence outcome is absent from the queue mutation contract.
- **Fix / regression:** Use recoverable atomic replacement and propagate/log
  failure to callers; commit/reconcile the in-memory outcome deliberately.
  Test unwritable storage and failed replacement with an existing valid queue.
  This is separate from the already-fixed normal DB-persist-before-dequeue order.

## LOGIC-029 - Authenticated pagination does not validate the destination origin

**MEDIUM | Confidence 8/10**

- **Evidence:** [SoundCloudClient:327-343](../../MLM/Services/Sources/SoundCloudClient.swift#L327),
  [479-508](../../MLM/Services/Sources/SoundCloudClient.swift#L479),
  intended API origin at [97-99](../../MLM/Services/Sources/SoundCloudClient.swift#L97).
- **Trigger / assumption:** An upstream/mirror response contains an unexpected
  off-origin or non-HTTPS absolute `next_href`. This audit does **not** establish
  that an ordinary attacker can alter a genuine TLS-protected provider response.
- **Expected / actual:** Provider credentials should only authorize the approved
  HTTPS API origin. The full response URL is accepted and receives Authorization;
  the refresh/retry path reuses that destination.
- **Root cause:** A response-supplied URL crosses the authenticated-request
  boundary without scheme/host/port validation.
- **Fix / regression:** Validate approved origins at the request boundary, handle
  relative pagination explicitly, and verify redirect/header behavior with a
  controlled session. Test off-origin/HTTP URLs cause no authorized request.
  This is a concrete trust-boundary hardening defect, not a proven CRITICAL
  exploit or evidence of an observed credential leak.

## LOGIC-024 - Temporary navigation prints execute in render paths

**LOW | Confidence 10/10**

- **Evidence:** [ContentView:174-190](../../MLM/Views/ContentView/ContentView.swift#L174),
  [body construction:311-314,342-343](../../MLM/Views/ContentView/ContentView.swift#L311),
  [LibraryHost:519-521](../../MLM/Views/ContentView/ContentView.swift#L519),
  [LibraryView:30](../../MLM/Views/Library/LibraryView.swift#L30),
  [PlaylistsView:33](../../MLM/Views/Playlists/PlaylistsView.swift#L33),
  [PlaylistDetailViewLoader:25](../../MLM/Views/Playlists/PlaylistDetailViewLoader.swift#L25),
  [FoldersView:17](../../MLM/Views/Folders/FoldersView.swift#L17),
  [SyncView:22-23](../../MLM/Views/Sync/SyncView.swift#L22),
  [SourcesView:26-27](../../MLM/Views/Sources/SourcesView.swift#L26),
  [DiscoverView:16-17](../../MLM/Views/Discover/DiscoverView.swift#L16),
  [ReviewQueueView:32-34](../../MLM/Views/ReviewQueue/ReviewQueueView.swift#L32),
  [SidebarView:91-103](../../MLM/Views/Sidebar/SidebarView.swift#L91),
  [PlaybackQueueView:12-15](../../MLM/Views/Queue/PlaybackQueueView.swift#L12).
- **Trigger / expected / actual:** Routine body evaluation/navigation should not
  run temporary diagnostic output. Ungated `[navperf]` prints, some explicitly
  marked temporary, run from view construction and load paths.
- **Root cause:** Measurement scaffolding was left in production code.
- **Fix / regression:** Remove it or move deliberately enabled logging/signposts
  outside `body`. No frame-rate/CPU impact is quantified here; this is a verified
  side-effect/cleanup issue, not a claim that printing explains all slowness.

## Rejected seeds and limits

- `SyncViewModel` no longer contains the alleged seven nil force unwraps.
  Boolean negation is not optional force-unwrapping.
- Discovery metadata force unwraps guarded by `metadata?.field.isEmpty == false`
  are not nil crash paths: nil cannot make that condition true.
- A fixed regex `try!`, an optional accessed only inside its non-nil branch,
  and a compositor precondition satisfied by the caller are not demonstrated
  runtime bugs merely because a grep finds `!`.
- Optional `Track.id` force unwraps in repository-backed Groove/Genre Workshop
  rows were not retained as crash findings: no production nil-ID caller was
  established. Explicit identity types/guards remain possible hardening.
- Genre Workshop's internal `syncTurboLevel` name does not indicate a second
  setting. It reads the same shared Background processing preference written
  by Settings; the functional policy-divergence hypothesis was rejected.
- Missing-file existence checks and a Retry UI already exist. Their presence
  alone does not verify every playback transition.
- Ordinary thrown operations release limiter permits; cancellation waiting is
  the separate defect in LOGIC-010.
- In-memory foreign-key behavior is not an accidental test-only mismatch.
  FK-off is deliberate in both configurations. LOGIC-026 concerns missing
  compensating deletion logic, not the pragma choice itself.
- Phase 39's ordinary retry path persists downloaded state before dequeue, and
  SoundCloud's one-refresh/one-retry credential-preservation guard exists.
  Neither is re-reported as an unfixed seed.
- Playlist reorder has transaction and insertion-index protections; the
  independent context-menu append defect is LOGIC-015.
- Source-scan tests are useful architecture checks, not substitutes for
  asynchronous ordering, cancellation, file-failure or rendered-state tests.

### LOGIC-D01 - Import symlink traversal semantics need a Mac check

The import scanner at [ImportService:69-106](../../MLM/Services/Import/ImportService.swift#L69)
does not explicitly request/check `isSymbolicLinkKey`, unlike the folder scanner.
However, the audit did not establish that Foundation's `isDirectory` resource
value follows directory symlinks here. A claimed infinite-recursion bug was
therefore **withdrawn from the scored findings** (confidence 3/10).
Test self-links, ancestor links and out-of-root links on macOS before deciding
whether a cycle/containment fix is needed; do not present an assumed API semantic
as a reproduced crash.
