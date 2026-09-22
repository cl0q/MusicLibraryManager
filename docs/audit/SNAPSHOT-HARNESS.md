# macOS XCTest snapshot harness

Date: 2026-09-22. **Statically written on Windows; compile and run on the
user's Mac.** No reference PNG was generated or visually approved here.
No external package was added.

## 1. Reality check and delivered coverage

"Every View" is not the same as the supplied 62-file inventory: it includes
models/helpers, nested views, native representables and runtime-dependent
screens. Nor is one screenshot equivalent to every possible state.

This implementation provides **30 fixture cases x Light/Dark = 60 intended
reference PNGs**, rendering production types from **24/62 source files**.
Another **8 entries are non-View helpers/models**; **30 remain explicitly
deferred**. Some of the 24 are **child-only** coverage, not their whole screen.
This is not a claim of complete application-screen coverage. The table below
accounts for all 62 and names the missing seams needed for expansion.

The harness has actual seeded/populated Library, shared track, Playlist and
Folder tables, a preloaded Library screen, empty/error presentations, status
chips, sheet content, waveform and missing-file diagnostics. It does **not**
create screenshot-shaped mock replacements for unavailable production screens.
Fully isolating the remaining sync/player/analysis/account screens needs further
presentation/service seams; that larger refactor was not silently performed.

## 2. Files and build integration

| File | Responsibility |
|---|---|
| [SnapshotHarnessTests.swift](../../MLMTests/Snapshots/SnapshotHarnessTests.swift) | `SnapshotsTests`, both renderers, normalized pixels, record/compare, attachments and diagnostics |
| [SnapshotFixtures.swift](../../MLMTests/Snapshots/SnapshotFixtures.swift) | Throwing production-view factories, backend/readiness metadata, exact 62-file registry |
| [SnapshotFixtureStore.swift](../../MLMTests/Snapshots/SnapshotFixtureStore.swift) | In-memory GRDB seeds and typed lookup errors |
| [__Snapshots__](../../MLMTests/Snapshots/__Snapshots__) | Tracked reference location; initially only a placeholder |
| [Package.swift](../../Package.swift) | Excludes generated reference PNGs from SwiftPM source discovery; tests use source-relative paths deliberately |

Diagnostics are written under `.build/mlm-snapshot-failures/<set>/`, already
ignored by the existing repository rules. References live under
`MLMTests/Snapshots/__Snapshots__/<set>/`. No reference is bundled as an SPM
resource: recording must update reviewable files in the checkout.

## 3. Exact Mac execution

Use a logged-in macOS GUI session with Xcode selected and the package's
dependencies available. Run from the repository root containing
[Package.swift](../../Package.swift), **not** an obsolete `macos-app` subdirectory.
Keep macOS deployment support at 15; use an SDK/toolchain compatible with the
current repository and GRDB. Swift tools 5.10 is not a promise that any old
Xcode installation can build all modern source.

```sh
# Record the environment in the run log.
sw_vers
xcodebuild -version
swift --version

swift build
swift test --filter Snapshots

# Pick one label for this exact OS/Xcode/architecture combination.
export MLM_SNAPSHOT_SET=macos15-xcode16-arm64

# FIRST render pass: intentionally creates/replaces references.
MLM_SNAPSHOTS=1 MLM_SNAPSHOT_RECORD=1 swift test --filter Snapshots

# Inspect every image before treating it as a valid reference.
open "MLMTests/Snapshots/__Snapshots__/$MLM_SNAPSHOT_SET"

# SECOND render pass: compare; no reference updates.
MLM_SNAPSHOTS=1 swift test --filter Snapshots

# Inspect actual/diff images when comparison fails.
open ".build/mlm-snapshot-failures/$MLM_SNAPSHOT_SET"
```

For a separate 26+ lane choose, for example,
`MLM_SNAPSHOT_SET=macos26-xcode26-arm64`; include more precise build versions
in the label/run log where necessary. Use the same set for record and compare.
The optional set defaults to `default`; labels allow only letters, digits,
hyphens and underscores (maximum 80 characters), preventing path traversal.

**Record overwrites references intentionally.** Do not record automatically in
CI and do not blindly accept an SDK's changed output. If the normal app has a
known UI defect, its image is evidence for review, not approval of that defect.
After fixture validation, run the ordinary full suite on the Mac for integration.

### Tests and opt-in behavior

Four tests run without rendering opt-in:

1. Registry versus actual production file paths, unique fixture IDs and coverage
   counts; this detects inventory drift, not just a hardcoded total.
2. Normalized pixels: equal, differing, dimensions changed, valid difference
   image and rejected malformed pixel buffer.
3. Real PNG file record/compare, missing reference, compare-does-not-overwrite,
   corrupt-reference failure and targeted temporary-file cleanup.
4. Valid/invalid baseline-set labels.

Three tests require `MLM_SNAPSHOTS=1`:

1. Seed counts/identity and every factory, without starting playback/network/auth.
2. Both renderer 2x dimensions, a one-row native readiness probe, nonblank output
   and PNG round-trip.
3. All 30 fixtures in both appearances, record or compare.

The normal suite skips these three before constructing the fixture container or
views. Pure image/file tests still use AppKit/CoreGraphics encoding on macOS;
they do not initialize the app, a music library, playback or network services.

## 4. Rendering, readiness and comparison

### SwiftUI backend

[`ImageRenderer`](https://developer.apple.com/documentation/swiftui/imagerenderer)
(Apple documents macOS 13+) captures eligible synchronous SwiftUI content via
`cgImage`. It is **not** a general snapshot of all platform-backed views.

Each case uses a fixed size, 2x pixels, Aqua/Dark Aqua drawing appearance **and**
SwiftUI color scheme, `en_US_POSIX`, UTC/Gregorian calendar, fixed accent/tint,
opaque semantic window background and disabled explicit transaction animations.
Null output throws; no blank-image fallback succeeds.

### Native table backend

`NSHostingView` in an offscreen borderless `NSWindow` uses
[`cacheDisplay(in:to:)`](https://developer.apple.com/documentation/appkit/nsview/cachedisplay(in:to:)).
The bitmap is initialized before capture. The native AppKit appearance is set
on host/window as well as the SwiftUI content.

Library/Playlist table row wrappers are populated in their production `.task`.
The harness therefore **awaits an observable readiness predicate**:
an `NSTableView` descendant must report the fixture's expected row count.
It checks at 10 ms intervals up to 3 seconds, allowing the main actor to yield.
This is not a blind settling sleep. Timeout throws even in record mode rather
than recording an empty/loading table as success. AppKit internals can change:
if no matching table is exposed on the selected SDK, improve the readiness
adapter on the Mac; do not remove the assertion merely to get PNGs.

This still does not prove row pixels/column clipping are visually correct.
Inspect all native-table images on first record. The host is not ordered on
screen; no screen-capture permission or real user window is used.

### Pixel comparison and failure output

Images normalize into 8-bit premultiplied **sRGB RGBA**. Comparison uses exact
dimensions/pixels, not PNG metadata or compressed bytes. CoreGraphics buffer
access stays inside its safe pointer-lifetime closure. There is no percentage
tolerance that could hide missing text.

- Missing references fail with the intended path and record command.
- Pixel/dimension differences write actual and magenta diff PNGs and attach
  actual/expected/diff data to XCTest.
- Dimension-change diff uses the larger canvas and marks missing pixels.
- Unreadable files, failed encoding, render/readiness failure and write failures
  throw explicit errors, never pass or re-record automatically.
- Attachment display depends on the test runner; diagnostic files remain the
  inspectable output for command-line runs.

## 5. Fixtures and isolation

Each rendered case/appearance gets a **fresh** in-memory store:

- Five tracks: local metadata, failed import with placeholder metadata, missing
  file, remote/not downloaded, long Unicode metadata.
- Two playlists: populated and empty; two real membership rows.
- Fixed dates, valid deterministic UUID strings, deterministic ordering.
- Playlist table fetches actual seeded membership, not every track in the store.
- Explicit presentation availability maps distinguish intended Local from File
  missing. `/fixtures/...` paths are descriptive only; no real audio file is read
  or claimed to exist.

[DependencyContainer's snapshot constructor](../../MLM/App/DependencyContainer.swift#L94)
only wires repositories. It does not call normal initialization. The search
coordinator is passive; playback/audio, mounts, OAuth, token storage, remote
search, download and sync workers remain absent.

Artwork loading is disabled via the additive default-on
`trackArtworkLoadingEnabled` environment value in
[TrackCoverView](../../MLM/Views/Shared/TrackCoverView.swift). Fixture IDs remain
their true seeded IDs; no negative-ID convention changes production semantics.
The gate prevents global artwork cache reads/invalidation and filesystem lookup
while rendering placeholders. Normal callers inherit `true`.

[PlaylistCard](../../MLM/Views/Playlists/PlaylistCard.swift#L135) returns before
resolving Application Support cover storage when its path is nil; fixtures use
nil paths. The normal nil-cover visual result is unchanged.

Discovery fixtures capture their deterministic initial empty content; any
repository task targets only the in-memory data. They are not proof of async
loading completion. Review uses a preloaded model and its existing load guard.
First-run captures Welcome only; its absent import service prevents setup work.
Debug captures the preloaded no-local-file state, so its existing `hasRun` guard
prevents subprocess diagnostics. No buttons are activated by this harness.

Only **visible** determinism is claimed: random non-rendered IDs inside an
unresolved ingest entry do not appear in pixels. Transactions do not freeze
`Date()`, `TimelineView` or indeterminate spinners; those states are not fixtures.
The device-ingest fixture renders the real diff row, not an unstable loading
spinner. Native glass/focus animations and system fonts still need a pinned OS.

### Minimal production seams

| Change | Why / preserved default |
|---|---|
| Repository-only container initializer | In-memory composition, normal singleton initialization unchanged |
| [AlbumRepository](../../MLM/Database/AlbumRepository.swift) accepts `any DatabaseWriter` | Same read/write calls with production `DatabasePool`, now also `DatabaseQueue` |
| [LibraryViewModel](../../MLM/ViewModels/LibraryViewModel.swift), [PlaylistDetailViewModel](../../MLM/ViewModels/PlaylistDetailViewModel.swift) preloaded initializers | Deterministic presentation without repository loading; existing initializers unchanged |
| [LibraryView](../../MLM/Views/Library/LibraryView.swift), [ReviewQueueView](../../MLM/Views/ReviewQueue/ReviewQueueView.swift) preloaded input | Default nil preserves normal loading; supplied state is not overwritten by startup task |
| [TrackCoverView](../../MLM/Views/Shared/TrackCoverView.swift) artwork environment gate | Default true; fixtures opt out of side effects while retaining actual placeholder rendering |
| [PlaylistCard](../../MLM/Views/Playlists/PlaylistCard.swift) nil-path fast path | Same fallback, no needless global cover-directory resolution |
| [DebugTabView](../../MLM/Views/TrackDetail/DebugTabView.swift) initial no-file state | Default false preserves normal diagnostics path |
| [DeviceIngestFileRow](../../MLM/Views/Sync/DeviceIngestResultsView.swift#L121) internal visibility | No rendering/behavior change; permits real row fixture |

FK enforcement is intentionally **off in production/custom-path/in-memory
DatabaseManager configurations**, not a fixture mismatch. Seeds still create
parents before memberships. See LOGIC-026 for the separate real deletion issue.

## 6. Complete inventory

**Rendered** means at least the explicitly named production content below.
**Non-view** entries are not independent screenshot targets.
**Deferred** is a remaining coverage gap, not a claim of inherent impossibility.

| Source file under MLM/Views | Disposition / actual fixture or required seam |
|---|---|
| `Activity/ActivityFeed.swift` | Non-view: feed model |
| `Activity/ActivityFeedAdapters.swift` | Non-view: model adapters |
| `Activity/ActivityPanel.swift` | Deferred: inject isolated AppStorage/preferences and passive operation feed |
| `Activity/LogFeed.swift` | Non-view: log query model |
| `Activity/LogsTab.swift` | Deferred: inject fixed attributed logs rather than global logger; host text representable |
| `Activity/LogTextRenderer.swift` | Non-view: attributed-text helper |
| `Activity/OperationsTab.swift` | Deferred: replace direct shared queue reads with passive feed injection |
| `ContentView/ContentView.swift` | Deferred: shell initialization, routing, toolbar/inspector require app-level composition |
| `Discover/DiscoverView.swift` | Rendered: `discover-screen`, Recommendations initial empty branch only |
| `DiscoveryInbox/DiscoveryInboxView.swift` | Rendered: `discovery-inbox-empty`, not populated/loading/error transitions |
| `Folders/FoldersView.swift` | Rendered child only: `FolderTracksTable`, `folder-tracks-populated`; filesystem/tree root deferred |
| `Folders/FolderTreeView.swift` | Deferred: native outline delegate/expansion readiness needs its own host predicate |
| `Library/DanceabilitySteps.swift` | Rendered: `danceability`, fixed 0.78 |
| `Library/EnergyBars.swift` | Rendered: `energy-bars`, fixed level 4 |
| `Library/LibraryTable.swift` | Rendered: `library-table-populated`, native host, five seeded rows |
| `Library/LibraryView.swift` | Rendered: `library-screen-local`, preloaded local three-row screen |
| `Library/TrackContextMenu.swift` | Deferred: context menus require explicit interactive menu presentation, not bitmap-only content |
| `Library/TrackTable.swift` | Rendered: `track-table-populated`, `track-table-empty`, `track-table-error` |
| `Player/PlayerBar.swift` | Deferred: concrete playback VM owns audio/timer/media state; needs passive transport seam |
| `Playlists/PlaylistCard.swift` | Rendered: `playlist-card`, nil-cover populated playlist |
| `Playlists/PlaylistDetailView.swift` | Deferred: async detail/source/cover lifecycle not covered by table-only fixture |
| `Playlists/PlaylistDetailViewLoader.swift` | Deferred: inject controlled ready/not-found/error loader outcomes |
| `Playlists/PlaylistTable.swift` | Rendered: `playlist-table-populated`, two actual members |
| `Playlists/PlaylistsView.swift` | Deferred: preloaded grid/cover composition still needed |
| `Queue/PlaybackQueueView.swift` | Rendered: `playback-queue-unavailable`, only no-player state |
| `ReelsInbox/ReelsInboxView.swift` | Deferred: AVKit/Shazam/Vision/detached tasks need passive services/clock |
| `ReviewQueue/ReviewQueueView.swift` | Rendered: `review-queue-empty`, preloaded model; resolution/history flows deferred |
| `Search/GlobalSearchPresentationView.swift` | Deferred: inject preloaded presentation VM instead of constructing real search clients |
| `Search/UniversalSearchView.swift` | Rendered: `universal-search-idle`; no submit/network or result artwork |
| `Settings/LibrarySetupView.swift` | Deferred: inert import/filesystem model and folder-panel adapters |
| `Settings/MaintenanceView.swift` | Deferred: shared batch/maintenance state and filesystem paths need injection |
| `Settings/SettingsView.swift` | Deferred: AppStorage selection and playback preferences read real defaults |
| `Settings/SourcesSetupView.swift` | Deferred: isolated cookie preferences and inert credential/account state |
| `Shared/DownloadRetryBudget.swift` | Non-view: retry-budget helper |
| `Shared/FirstRunWizard.swift` | Rendered: `first-run-welcome`; setup/import/completion deferred |
| `Shared/SelectionCreationSheets.swift` | Rendered: `new-playlist-sheet`, `new-sync-profile-sheet`; form bodies, no submission |
| `Shared/SpringLoadableHover.swift` | Rendered modifier host: `spring-hover-resting`; drag/timer/pulse deferred |
| `Shared/StatusChip.swift` | Rendered: `status-chip-failed` (file missing), `status-chip-download-failed`, `status-chip-remote` |
| `Shared/TrackCoverView.swift` | Rendered: `track-cover-placeholder`; real artwork lookup intentionally disabled |
| `Shared/TrackMetadataPresentation.swift` | Rendered: `metadata-normal`, `metadata-placeholder` |
| `Shared/TrackPresentationAvailability.swift` | Non-view: mapper; selected outputs supplied to real table/chip fixtures |
| `Sidebar/PinnedPlaylistsDisclosure.swift` | Deferred: preloaded pinned state and native list readiness |
| `Sidebar/SidebarView.swift` | Deferred: live badges/pins need passive presentation state |
| `Sources/RemotePlaylistsView.swift` | Deferred: provider fetch on presentation needs mock provider seam |
| `Sources/SourcesView.swift` | Deferred: OAuth/token account model needs inert composition |
| `Sync/DeviceIngestResultsView.swift` | Rendered child only: `DeviceIngestFileRow`, `device-ingest-preview-row`; root scan/error states deferred |
| `Sync/IngestPreviewView.swift` | Rendered: `ingest-preview`, added/unresolved review content |
| `Sync/Pickers/PlaylistPickerModel.swift` | Non-view: picker selection model |
| `Sync/Pickers/PlaylistPickerSheet.swift` | Deferred: concrete Sync VM requires TranscodeCache filesystem and SyncService defaults; inject passive picker state/actions |
| `Sync/SyncContentSections.swift` | Deferred: concrete Sync VM boundary; inject expanded contents/action callbacks |
| `Sync/SyncFailedDisclosure.swift` | Deferred: concrete Sync VM and async track lookup; inject failures/rows |
| `Sync/SyncProfileDetailView.swift` | Deferred: live device checks, preview/cache age and tasks need filesystem/clock seams |
| `Sync/SyncSettingsForm.swift` | Deferred: service-owned preference access; inject settings bindings/actions |
| `Sync/SyncToast.swift` | Rendered: `sync-toast`, fixed message/visible state |
| `Sync/SyncView.swift` | Deferred: profiles/devices/previews require inert coordinator |
| `TrackDetail/DebugTabView.swift` | Rendered: `debug-no-local-file`; no real ffmpeg/process call |
| `TrackDetail/GrooveStudioView.swift` | Deferred: preview decks, export/model services and random placeholders need passive state |
| `TrackDetail/GrooveView.swift` | Deferred: recommendation/audio providers and randomness need controlled inputs |
| `TrackDetail/MetadataPanel.swift` | Deferred: track-scoped tasks/defaults/shared analysis state need preloaded tab model |
| `TrackDetail/TrackDetailView.swift` | Deferred: playback/waveform/metadata composition not proven by child fixtures |
| `TrackDetail/WaveformHelpers.swift` | Non-view: math/color helpers; exercised through waveform content |
| `TrackDetail/WaveformView.swift` | Rendered: `waveform`, fixed bins/progress/controls; no random placeholder |

## 7. Mac-only acceptance and next expansion

1. Compile and run all seven harness tests as appropriate; fix any SDK/type
   discrepancy. Windows structural checks are not Swift type checking.
2. Record **60** PNGs, reject blank/native-placeholder/clipped outputs, inspect
   Light and Dark, then compare a second clean run with the same set.
3. Verify the five native-table readiness checks (row counts 5, 5, 2, 5, 3);
   failing readiness is an explicit blocker, not a skip.
4. Validate existing behavior after the additive initializers/artwork gate with
   the full suite and actual app startup.
5. Expand remaining screens by injecting **passive presentation state and
   callbacks**, not spinning up real services to satisfy initializer types.
   Prioritize sync/picker/Activity and root Playlist/Inspector after Mac baseline
   validation; do not solve this by a global "disable every task" flag.
6. Use separate real-window/interaction captures for native toolbar, popovers,
   menus, focus, VoiceOver and WindowServer Liquid Glass. Neither backend claims
   to capture composited glass, other application windows or real device effects.
