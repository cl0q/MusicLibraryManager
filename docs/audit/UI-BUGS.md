# UI conformance audit

Date: 2026-09-22. Scope: macOS `MLM` and supporting tests only.
**Static evidence, not rendered or interactively verified.** Severity and
confidence are independent; entries are ordered by severity, then confidence.
The binding reference is [UI-GROUNDTRUTH](../../UI-GROUNDTRUTH.md), not the
implementation or an existing source-scan test that codifies different behavior.

CRITICAL = accidental data loss/crash risk; HIGH = user-facing functional or
destructive-flow failure; MEDIUM = inconsistent state/contract/edge case;
LOW = cosmetic or copy drift. Confidence 10 means the cited control flow or
literal mismatch is unambiguous, **not** that a Mac reproduction was run.

## Statically established findings

## UI-001 - Recommendation deletion offers no recoverable escape

**HIGH | Confidence 10/10**

- **Evidence:** [DiscoveryInboxView:75-91,126-139](../../MLM/Views/DiscoveryInbox/DiscoveryInboxView.swift#L75),
  [GrooveView:248-260,1016-1033](../../MLM/Views/TrackDetail/GrooveView.swift#L248),
  [DiscoveryReviewService:37-43](../../MLM/Services/Analysis/DiscoveryReviewService.swift#L37).
- **Contract:** [sections 1.1(2), 1.7(5)](../../UI-GROUNDTRUTH.md#11-product-principles),
  [3.11](../../UI-GROUNDTRUTH.md#311-similar-tracks-sheet-ex-grooveview),
  [3.17](../../UI-GROUNDTRUTH.md#317-sheets--alerts--catalog): reversible automation,
  destructive consequence plus Trash/Undo escape.
- **Trigger / expected / actual:** Confirm deletion of a downloaded recommendation
  in Discover or Similar. A recoverable removal is required. Both surfaces do
  confirm "Delete this file from disk?", but the helper permanently removes the
  file and DB record, with no Trash or Undo. This is **not** an unconfirmed or
  silent delete; the defect is the missing recovery promised by the contract.
- **Fix:** Share one recoverable Trash-based operation, retain restoration data,
  and name the consequence/recovery in both confirmations. Verify failed Trash
  and failed DB writes before offering Undo.

## UI-002 - Playlist deletion bypasses confirmation in grid and sidebar

**HIGH | Confidence 10/10**

- **Evidence:** [PlaylistCard:256-269](../../MLM/Views/Playlists/PlaylistCard.swift#L256),
  [PlaylistsView:432-438](../../MLM/Views/Playlists/PlaylistsView.swift#L432),
  [PinnedPlaylistsDisclosure:119-123](../../MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift#L119),
  [SidebarView:81-91](../../MLM/Views/Sidebar/SidebarView.swift#L81).
- **Contract:** [3.2 Interactions](../../UI-GROUNDTRUTH.md#32-playlists-grid),
  [1.7(5)](../../UI-GROUNDTRUTH.md#17-language--copy-rules),
  [3.17](../../UI-GROUNDTRUTH.md#317-sheets--alerts--catalog), Part 6 item 15.
- **Trigger / expected / actual:** Choose Delete on a normal playlist card or a
  pinned playlist. A dialog should name the playlist and explain that music files
  remain, with Cancel. Both callbacks instead dispatch repository deletion
  immediately. The sidebar also has no visible deletion-error handling.
- **Fix:** Route both entry points through the same pending-deletion presentation;
  mutate only after confirmation, display errors, and preserve liked-playlist
  protection. Test both routes, not just a detail-view alert.

## UI-003 - Sync content removal immediately mutates the profile

**HIGH | Confidence 10/10**

- **Evidence:** [SyncContentSections:207-212,247-253,269-274,306-311](../../MLM/Views/Sync/SyncContentSections.swift#L207),
  [SyncViewModel:403-447](../../MLM/ViewModels/SyncViewModel.swift#L403).
- **Contract:** [3.17](../../UI-GROUNDTRUTH.md#317-sheets--alerts--catalog),
  [Part 6 item 15](../../UI-GROUNDTRUTH.md#part-6--acceptance-checklist-user-observable).
- **Trigger / expected / actual:** Click the row trash affordance or destructive
  context-menu item for a playlist/direct track. The user should be told that
  this content will no longer sync to the named destination and be able to
  cancel. All four paths directly start removal; no confirmation or Undo exists.
- **Fix:** Store typed pending removal and present consequence plus Cancel.
  Test row and menu paths. Explain next-sync cleanup separately from deletion of
  library originals; do not imply that this action itself trashes music.

## UI-004 - Universal text search never leaves its searching state

**HIGH | Confidence 10/10**

- **Evidence:** [UniversalSearchViewModel:132-134](../../MLM/ViewModels/UniversalSearchViewModel.swift#L132),
  [UniversalSearchView:139-150,224-233](../../MLM/Views/Search/UniversalSearchView.swift#L139).
- **Contract:** [3.13](../../UI-GROUNDTRUTH.md#313-global-search),
  [Part 6 item 16](../../UI-GROUNDTRUTH.md#part-6--acceptance-checklist-user-observable).
- **Trigger / expected / actual:** Enter plain text and press Return. Search must
  produce results, empty, or error. The `.searchText` branch only sets
  `.searching`, starts no search, and never reaches a terminal state. The result
  branch itself contains placeholder copy.
- **Fix:** Wire actual search with request identity/error handling, or make this
  surface explicitly URL-only and route text to the existing global search.
  A test that only expects `.searching` is insufficient.

## UI-005 - Universal playlist Import is an empty action

**HIGH | Confidence 10/10**

- **Evidence:** [UniversalSearchView:191-222](../../MLM/Views/Search/UniversalSearchView.swift#L191):
  the visible `Button("Import")` has an empty action.
- **Contract:** [3.6](../../UI-GROUNDTRUTH.md#36-remote-import-sheet-youtube--soundcloud-playlist-import),
  [Part 6 item 16](../../UI-GROUNDTRUTH.md#part-6--acceptance-checklist-user-observable).
- **Trigger / expected / actual:** Resolve a playlist URL, then click Import.
  The supported import preview/flow should open; nothing happens.
- **Fix:** Route the detected provider/URL to the existing import presentation
  through an explicit callback. Test that the button changes presentation state,
  rather than merely asserting that the label exists.

## UI-006 - Settings imports are missing from Activity and offer no Cancel

**HIGH | Confidence 9/10**

- **Evidence:** [ImportViewModel:76-173](../../MLM/ViewModels/ImportViewModel.swift#L76),
  [LibrarySetupView:145-215](../../MLM/Views/Settings/LibrarySetupView.swift#L145),
  [OperationsTab:48-81](../../MLM/Views/Activity/OperationsTab.swift#L48).
- **Contract:** [2.5](../../UI-GROUNDTRUTH.md#25-activity-panel),
  [3.14](../../UI-GROUNDTRUTH.md#314-settings--window-library-sources),
  [4.2(3-5)](../../UI-GROUNDTRUTH.md#42-rules), Part 6 item 12.
- **Trigger / expected / actual:** Start Import Folder or Re-scan and navigate
  away. Work should remain visible/cancellable globally. Progress exists only
  in local import state; no Activity operation or Settings Cancel is registered.
- **Fix:** Register a real cancellable Activity operation, bridge progress and
  terminal states, expose the same token in Settings. Fix service-side
  cancellation too; a button alone is not sufficient.

## UI-007 - Library does not refresh root identity or show the required offline banner

**HIGH | Confidence 9/10**

- **Evidence:** [LibraryView:39-67](../../MLM/Views/Library/LibraryView.swift#L39),
  [ImportViewModel:48-64](../../MLM/ViewModels/ImportViewModel.swift#L48).
- **Contract:** [3.1 States](../../UI-GROUNDTRUTH.md#31-library),
  [1.1(1)](../../UI-GROUNDTRUTH.md#11-product-principles).
- **Trigger / expected / actual:** Change the library root while Library remains
  mounted, or make its drive unavailable. Rows should remain browsable with
  refreshed availability and a text-bearing disconnect banner. Root-change
  notifications are not observed, the stored root snapshot stays stale, and
  this surface has no disconnected-drive banner/state.
- **Fix:** Refresh on root invalidation, publish root reachability, show the
  required banner without hiding rows, and revalidate stale selections. Real
  mount/unmount delivery remains a Mac check.

## UI-008 - Clear Pending Jobs is modeled but cannot be invoked

**MEDIUM | Confidence 10/10**

- **Evidence:** [ActivityFeed:539-568](../../MLM/Views/Activity/ActivityFeed.swift#L539),
  [OperationsTab:10-31,310-345](../../MLM/Views/Activity/OperationsTab.swift#L310).
- **Contract:** [2.5](../../UI-GROUNDTRUTH.md#25-activity-panel),
  [Part 6 item 16](../../UI-GROUNDTRUTH.md#part-6--acceptance-checklist-user-observable).
- **Trigger / expected / actual:** Pending analysis work should expose Clear,
  then confirmation. The feed produces a row `.clearAnalysisQueue` action,
  but its row renderer returns `EmptyView`. The working header renderer never
  receives the action, because the active section has no header actions.
- **Fix:** Wire a labeled row action to the existing alert. Verify action,
  confirmation, Cancel and queue mutation as one route.

## UI-009 - Eight sidebar destinations contradict the seven-destination contract

**MEDIUM | Confidence 10/10**

- **Evidence:** [SidebarView:173-235](../../MLM/Views/Sidebar/SidebarView.swift#L173),
  [ContentView:540-621](../../MLM/Views/ContentView/ContentView.swift#L540),
  [ShellInformationArchitectureTests:6-18](../../MLMTests/ViewTests/ShellInformationArchitectureTests.swift#L6).
- **Contract:** [2.2](../../UI-GROUNDTRUTH.md#22-sidebar),
  [Part 6 item 14](../../UI-GROUNDTRUTH.md#part-6--acceptance-checklist-user-observable).
- **Trigger / expected / actual:** Open the sidebar or press Command-8. The
  contract requires seven destinations plus Settings. Queue is an eighth route
  and the source test explicitly expects eight.
- **Fix:** Preserve queue capability but put its entry point in the agreed
  player/detail interaction, or deliberately revise the binding contract
  first. Do not silently remove a working feature merely to satisfy a count.
  Historical conformance PASS is not evidence for the current code.

## UI-010 - Extra globe toolbar action violates the single search entry point

**MEDIUM | Confidence 10/10**

- **Evidence:** [ContentView:236-258](../../MLM/Views/ContentView/ContentView.swift#L236).
- **Contract:** [2.1](../../UI-GROUNDTRUTH.md#21-main-window),
  [2.3](../../UI-GROUNDTRUTH.md#23-toolbar),
  [3.13(1)](../../UI-GROUNDTRUTH.md#313-global-search).
- **Trigger / expected / actual:** Inspect the trailing toolbar. It should contain
  the single global Search field and nothing else; a globe button opens another
  general search presentation alongside it.
- **Fix:** Consolidate URL resolution into the agreed search route, retaining
  capability without a competing entry point. Resolve UI-004/UI-005 rather
  than merely hiding broken functionality elsewhere.

## UI-011 - Two visible German controls remain in Reels

**MEDIUM | Confidence 10/10**

- **Evidence:** [ReelsInboxView:1115-1124](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L1115)
  (`Per Audio erkennen (Shazam)`),
  [1288-1300](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L1288) (`Kopieren`).
- **Contract:** [1.7(1)](../../UI-GROUNDTRUTH.md#17-language--copy-rules),
  [3.12](../../UI-GROUNDTRUTH.md#312-discover-recommendations--reels),
  [5.8](../../UI-GROUNDTRUTH.md#58-explicit-removals-strings-that-must-not-survive).
- **Trigger / expected / actual:** Open the relevant OCR/Shazam control or OCR
  text menu. Labels should be English but these literal strings are rendered.
- **Fix:** Use approved English labels, e.g. `Identify (Shazam)` and `Copy`.
  **Do not delete** the German social-media noise keywords at
  [1432-1444](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L1432): they are
  OCR input-normalization data, not UI copy.

## UI-012 - Playlist source and incomplete filters are absent

**MEDIUM | Confidence 10/10**

- **Evidence:** [PlaylistsView:126-204](../../MLM/Views/Playlists/PlaylistsView.swift#L126),
  [PlaylistViewModel:279-289](../../MLM/ViewModels/PlaylistViewModel.swift#L279).
- **Contract:** [3.2 Anatomy / Filter bar](../../UI-GROUNDTRUTH.md#32-playlists-grid).
- **Trigger / expected / actual:** Browse mixed local/linked/incomplete playlists.
  All, Local, available source and Incomplete filters should exist. Only
  name-search state/predicate is implemented.
- **Fix:** Model source/health filter selection, derive available sources from
  current data, and combine it with text search. Test empty filtered results
  separately from an empty collection.

## UI-013 - Pinned rename errors disappear with the edit

**MEDIUM | Confidence 10/10**

- **Evidence:** [PinnedPlaylistsDisclosure:143-163](../../MLM/Views/Sidebar/PinnedPlaylistsDisclosure.swift#L143).
- **Contract:** [2.2](../../UI-GROUNDTRUTH.md#22-sidebar),
  [1.7(4)](../../UI-GROUNDTRUTH.md#17-language--copy-rules).
- **Trigger / expected / actual:** Rename to a conflicting name or fail the DB
  write. An actionable error should retain the input. The empty catch discards
  the error and closes edit mode as though saving succeeded.
- **Fix:** Retain/focus the field on failure, show plain cause plus correction
  action, and leave edit mode only on success or explicit Cancel.

## UI-014 - Credential removal lacks consequence confirmation

**MEDIUM | Confidence 10/10**

- **Evidence:** [SourcesSetupView:54-58,112-116](../../MLM/Views/Settings/SourcesSetupView.swift#L54).
- **Contract:** [1.7(5)](../../UI-GROUNDTRUTH.md#17-language--copy-rules),
  [3.17](../../UI-GROUNDTRUTH.md#317-sheets--alerts--catalog), Part 6 item 15.
- **Trigger / expected / actual:** Clear the saved cookie or disconnect an account.
  The binding destructive-action policy calls for naming the affected source
  and reconnect consequence before committing. Both actions directly remove
  persisted state without confirmation.
- **Fix:** Add a pending action and Cancel/confirm with source-specific wording.
  This is a confirmation-policy defect, not a claim of credential compromise.

## UI-018 - Custom Universal Search bypasses semantic tokens and metrics

**MEDIUM | Confidence 10/10**

- **Evidence:** [UniversalSearchView:18-44,53-63,78-91](../../MLM/Views/Search/UniversalSearchView.swift#L18),
  [262-300,329-388](../../MLM/Views/Search/UniversalSearchView.swift#L262),
  [408-423](../../MLM/Views/Search/UniversalSearchView.swift#L408).
- **Contract:** [1.2](../../UI-GROUNDTRUTH.md#12-color-system),
  [1.3](../../UI-GROUNDTRUTH.md#13-typography),
  [1.4](../../UI-GROUNDTRUTH.md#14-spacing-metrics-iconography).
- **Trigger / expected / actual:** Open the custom search panel. It should use
  semantic ink/surface/brand colors, approved typography and 8 pt card/panel
  geometry. It instead has raw white foregrounds/opacity treatments, generic
  red/orange/green/blue source colors, numerous fixed `.system(size:)` fonts and
  20 pt panel/12 pt card corners.
- **Fix:** Map text, dividers, source labels and surfaces to their existing
  semantic roles and consolidate metrics. Coordinate its local
  `.regularMaterial` helper with the migration plan. This proves contract drift,
  **not** a measured contrast failure; Light/Dark/accessibility appearance remains
  deferred. Black scrim/video styling alone is not the basis for this finding.

## UI-015 - Reel removal neither confirms nor reports persistence failure

**MEDIUM | Confidence 9/10**

- **Evidence:** [ReelsInboxView:190-194](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L190),
  [700-711](../../MLM/Views/ReelsInbox/ReelsInboxView.swift#L700).
- **Contract:** [3.12](../../UI-GROUNDTRUTH.md#312-discover-recommendations--reels),
  [1.7(4-5)](../../UI-GROUNDTRUTH.md#17-language--copy-rules),
  [3.17](../../UI-GROUNDTRUTH.md#317-sheets--alerts--catalog).
- **Trigger / expected / actual:** Delete imported Reel rows while the DB write
  fails. Confirmed durable removal or an actionable failure is expected. Rows
  disappear immediately, `try?` ignores repository failure, and they can return
  on relaunch without explanation. No confirmation precedes removal.
- **Fix:** Clarify inbox removal versus source-video deletion, confirm, cancel
  per-reel work, await persistence and reconcile/restore UI on error.

## UI-016 - Source-load errors masquerade as disconnected or empty accounts

**MEDIUM | Confidence 9/10**

- **Evidence:** [SourcesViewModel:142-184](../../MLM/ViewModels/SourcesViewModel.swift#L142),
  [SourcesView:145-238](../../MLM/Views/Sources/SourcesView.swift#L145).
- **Contract:** [1.6 Source status](../../UI-GROUNDTRUTH.md#16-global-state-vocabulary),
  [1.7(4)](../../UI-GROUNDTRUTH.md#17-language--copy-rules),
  [3.5](../../UI-GROUNDTRUTH.md#35-sources).
- **Trigger / expected / actual:** Fail source fetch/count reads. Loading should
  become a visible Retry error while retaining known data. The catch only prints;
  loading ends and default false/zero values look like successfully loaded
  disconnected accounts.
- **Fix:** Add explicit load-error state and Retry; distinguish unknown/unloaded
  from disconnected. Do not erase successfully loaded per-source state.

## UI-017 - Pin-limit banner diverges from the binding copy

**LOW | Confidence 10/10**

- **Evidence:** [PlaylistViewModel:239-248](../../MLM/ViewModels/PlaylistViewModel.swift#L239),
  [PlaylistsView:300-330](../../MLM/Views/Playlists/PlaylistsView.swift#L300).
- **Contract:** [3.2 Edge Cases](../../UI-GROUNDTRUTH.md#32-playlists-grid).
- **Trigger / expected / actual:** Attempt a ninth pin. Required text is
  `Pin limit reached (8). Unpin one first.` Actual primary text is
  `Pinned limit reached`, with the maximum and remedy in secondary text.
  The limit is **not missing**; this is exact-copy drift, not a functional defect.
- **Fix:** Publish the approved complete message consistently, including its
  accessible presentation.

## UI-019 - Sync cards use 12 pt rather than the agreed 8 pt radius

**LOW | Confidence 10/10**

- **Evidence:** [SyncContentSections:110-112,189-191](../../MLM/Views/Sync/SyncContentSections.swift#L110),
  [SyncSettingsForm:218-220](../../MLM/Views/Sync/SyncSettingsForm.swift#L218).
- **Contract:** [1.4](../../UI-GROUNDTRUTH.md#14-spacing-metrics-iconography).
- **Trigger / expected / actual:** Open Sync profile playlists/tracks/settings
  cards. The card/panel metric is 8 pt; their backgrounds and strokes specify 12.
- **Fix:** Use one shared 8 pt metric, or deliberately amend the contract before
  retaining a different design. No functional or measured legibility failure
  is inferred from this cosmetic mismatch.

## Device-only verification - DEFERRED, not additional proven bugs

| Check ID | Contract / required Mac action | Current disposition |
|---|---|---|
| UI-D01 | Part 6 item 1: import the configured 44-track YouTube playlist, inspect individual failures/retry, close/relaunch, inspect persisted outcome | Still deferred. State fixtures cannot prove provider/download persistence. |
| UI-D02 | Part 6 item 15: trigger every destructive route, including menus, multi-selection, keyboard deletion, sync-profile deletion, Review Trash, cache relocation and rollback | Static counterexamples UI-001/002/003/014/015 disprove a blanket PASS. Native dialog reachability, Escape, effects and restoration still require Mac runs. |
| UI-D03 | Part 6 item 16: menus, disabled explanations, alerts, command routing | UI-004/005/008 prove dead paths. The remaining controls cannot be declared live from label/source presence alone. |
| UI-D04 | Sections 1.1-1.4: Light/Dark, Increased Contrast, Reduce Transparency, focus, clipping at minimum sizes | Actual contrast, material composition and text truncation are unverified. No screenshot was produced on Windows. |
| UI-D05 | Section 2.2 and Part 6 item 14: VoiceOver names/order, icon-only controls, status chips, keyboard operation and automation identifiers | Existing labels are not a VoiceOver test. Validate spoken names and stable snake_case automation hooks independently; do not replace human-readable accessibility labels with machine identifiers indiscriminately. |
| UI-D06 | Sections 3.1/3.3/3.4/3.8: real table selection, drag order, mount/unmount, folder restore, preview freshness | Exercise rapid transitions and device files, not just static happy-state screenshots. |

## Important non-findings and limits

- The source-brand palette and accent-only energy scale already implement the
  main section 1.2 separation. Literal colors are not automatically wrong:
  artwork/brand imagery and black video backgrounds need contextual assessment.
- Standard availability chips already include text. This does not prove that
  every caller supplies fresh availability; see [LOGIC-BUGS](LOGIC-BUGS.md).
- Review has Undo/Restore machinery and repository tests. No generic "Review has
  no Undo" finding survived this audit.
- Device-ingest diff preview plus an explicit Apply and Close already provide
  a deliberate review/commit/escape flow. A demand for an additional modal was
  rejected as unsupported by the contract; the separate stale-index crash in
  LOGIC-007 remains real.
- The historical [CONFORMANCE-REPORT](../../CONFORMANCE-REPORT.md) is not rewritten
  to pretend a new Mac validation happened. Several current static counterexamples
  conflict with its old PASS claims; its three live-check deferrals remain open.
- Temporary `print` calls in `body` are consolidated in the logic report as a
  cleanup finding, not duplicated here as visual corruption or measured slowness.
