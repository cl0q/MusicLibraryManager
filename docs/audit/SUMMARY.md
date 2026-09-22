# MLM macOS audit - executive summary

Date: 2026-09-22. Baseline commit: `5476738`. The worktree was clean at start.
Only the macOS app and its tests were in scope. No commit or push was made.

## What this audit establishes

The main problem is not a lack of visual effects. Multiple asynchronous
operations publish results without checking which selection/request still owns
them; some caches ignore the very values they store; cancellation and destructive
actions do not consistently match what the UI promises. A glass redesign before
these fixes would make unreliable states look different rather than fix them.

**Evidence level:** static source/control-flow review and Windows structural
checks only. All added Swift is **statically written; compile and run on the
user's Mac**. No new claim of passing `swift build`, `swift test`, native UI
interaction, screenshots, VoiceOver or device tests is made.

### Retained findings after reconciliation

| Report | CRITICAL | HIGH | MEDIUM | LOW | Total |
|---|---:|---:|---:|---:|---:|
| Logic | 4 | 20 | 6 | 1 | 31 |
| UI | 0 | 7 | 10 | 2 | 19 |
| **Combined** | **4** | **27** | **16** | **3** | **50** |

Counts exclude deferred checks and rejected hypotheses. Notably rejected:
the alleged Sync force-unwrap cluster, a nil-ID Groove crash without a reachable
caller, an assumed import symlink cycle, a supposed second export concurrency
setting, and a demand for a second modal after the device-ingest preview.
UI-001 is HIGH rather than CRITICAL because deletion is explicitly confirmed:
its defect is lack of required recovery, not an undisclosed delete.

The older [conformance report](../../CONFORMANCE-REPORT.md) records a historical
build/test result. It is not current evidence; its seven-destination and
English-only conclusions have concrete counterexamples. The current
[planning state](../../.planning/STATE.md#L35) itself still leaves phase 39 Mac
verification pending. The prompt's historical test-count estimate is not
presented here as a freshly measured suite result.

## Deliverables

| Artifact | Purpose |
|---|---|
| [LOGIC-BUGS.md](LOGIC-BUGS.md) | Severity/confidence-ranked correctness findings, triggers, expected/actual behavior, source evidence and fix/test sketches |
| [UI-BUGS.md](UI-BUGS.md) | Binding ground-truth deviations; static findings separated from device-only checks |
| [LIQUID-GLASS-PLAN.md](LIQUID-GLASS-PLAN.md) | Current chrome/token inventory, verified Apple APIs, deployment strategy and phased migration |
| [SNAPSHOT-HARNESS.md](SNAPSHOT-HARNESS.md) | Actual fixture coverage and exceptions, architecture, Mac record/compare instructions |
| [Snapshot sources](../../MLMTests/Snapshots) | XCTest rendering/fixture infrastructure; not pre-generated reference screenshots |

## Top 10 to address first

This is an implementation-priority list: severity, confidence and blast radius.
The full reports retain the precise severity/confidence ordering.

| Priority | Finding | Severity / confidence | Why first |
|---|---|---|---|
| 1 | [LOGIC-001](LOGIC-BUGS.md#logic-001---artwork-replacement-can-permanently-remove-the-audio-file) - unsafe artwork file replacement | CRITICAL / 10 | A failed optional enhancement can delete the user's audio. |
| 2 | [LOGIC-002](LOGIC-BUGS.md#logic-002---detached-ocrshazam-completion-can-address-a-deleted-reel-index) - stale Reel index after detached work | CRITICAL / 10 | Deletion during OCR/Shazam can crash or write to a different Reel. |
| 3 | [LOGIC-007](LOGIC-BUGS.md#logic-007---concurrent-device-ingest-apply-can-crash-or-remove-the-wrong-row) - concurrent device-ingest indices | CRITICAL / 10 | Two Apply completions can access an index removed by the first. |
| 4 | [LOGIC-025](LOGIC-BUGS.md#logic-025---a-rejected-dab-stream-url-traps-instead-of-entering-fallback) - force-unwrapped provider URL | CRITICAL / 9 | Truly unrepresentable provider input can crash instead of reaching fallback. |
| 5 | [LOGIC-003](LOGIC-BUGS.md#logic-003---startup-failure-never-reaches-the-existing-error-screen) - swallowed initialization failure | HIGH / 10 | A broken database/setup leaves the entire app loading indefinitely. |
| 6 | [LOGIC-004](LOGIC-BUGS.md#logic-004---library-db-deletion-proceeds-after-a-failed-trash-operation) - DB removal after Trash failure | HIGH / 10 | The file operation and library/membership state diverge at a destructive boundary. |
| 7 | [LOGIC-013](LOGIC-BUGS.md#logic-013---activity-cancel-reports-cancellation-while-non-cancellable-work-continues) - false Activity cancellation | HIGH / 10 | The UI says cancelled while cache relocation continues removing/moving files. |
| 8 | [LOGIC-026](LOGIC-BUGS.md#logic-026---parent-deletion-leaves-relationships-orphaned-with-foreign-keys-disabled) - missing application-level cascade | HIGH / 10 | Track/playlist removal leaves persistent orphan relationships under the deliberate FK-off policy. |
| 9 | [LOGIC-010](LOGIC-BUGS.md#logic-010---maintenance-cancellation-does-not-stop-queued-workers-or-tools) - ineffective analysis cancellation | HIGH / 10 | Queued workers/tools can keep running and persisting after Cancel. |
| 10 | [UI-002](UI-BUGS.md#ui-002---playlist-deletion-bypasses-confirmation-in-grid-and-sidebar) - unconfirmed playlist deletion | HIGH / 10 | Both grid and sidebar can remove playlists immediately. |

## Root-cause clusters

### 1. Async work needs identity, not just a busy Boolean

Profile content/preview, folder selection, Universal Search, Similar source
selection, cover regeneration and Reel recognition have distinct race paths.
The shared rule for fixes is: capture stable input identity and generation,
retain/cancel superseded work, revalidate after suspension, and publish one
coherent result. Cancellation alone is insufficient when a callee ignores it.
Do not solve all these with a sweeping architecture rewrite; fix each boundary
with a deterministic interleaving regression test.

### 2. Derived-state caching is invalidated by too little information

Library hashes count and endpoints; Playlist hashes IDs and availability count.
Neither fingerprint represents the value-bearing rows being cached. Refresh
notifications and calls to a rebuild helper are not enough if the helper returns
early. Prefer explicit snapshot revisions or value-aware invalidation, then
measure before restoring an optimization.

### 3. Destructive consequence, persistence and recovery are separate obligations

Confirmation alone does not make permanent deletion recoverable. Trashing alone
does not make a later DB failure consistent. The reports distinguish:
unconfirmed actions, confirmed but unrecoverable recommendation deletion,
ignored file failures, and optimistic UI removal that ignores DB failure.
Use one shared operation per semantic action, retaining recovery data and
reporting partial failure; wire every menu/row/keyboard entry point.

### 4. A Cancel button is not cancellation

One defect is offering Cancel for work with no cancellation token; another is
workers passing a tracker check before waiting for permits, then continuing
after cancellation. Import's save phase is a third boundary. Tests must assert
that new side effects stop, not just that flags or Activity rows change.

### 5. Some tests codify scaffolding rather than the contract

The sidebar test expects eight destinations despite the required seven. A search
test accepts entering `.searching` without proving a terminal result. Source-scan
tests are valuable for architecture, but they cannot establish button reachability,
dialog effects, native rendering or concurrency ordering.

### 6. Cleanup and design drift are real, but not the first safety work

Temporary `print` calls inside `body` are verified; no CPU/frame-rate attribution
is claimed. The German OCR-noise seed is not user copy, but two other German
control labels are. Queue/globe navigation, filter coverage and copy drift need
an explicit contract decision, not an indiscriminate grep cleanup.

## Recommended execution order

1. **Safety and runtime gate:** On a disposable fixture/library copy, compile
   the added Swift, finish the pending phase 39 Mac checks, then fix artwork
   replacement, Reel task identity and failed-trash/DB sequencing with failure
   injection. Do not use the real music library for destructive regression tests.
2. **State truthfulness:** Fix startup error propagation, cross-profile/folder/
   search identity, row-cache invalidation and batch ownership.
3. **Real cancellation:** Align capability flags, task-group/semaphore/process
   lifetimes and save boundaries; integrate imports into Activity.
4. **Destructive and dead UI routes:** Shared confirmations/recovery, functional
   search/import/clear controls, visible errors; exercise Part 6 items 15 and 16.
5. **Baseline review:** Record Light/Dark fixture images, inspect every baseline,
   compare a second run, and perform the documented real-window/deferred checks.
   A reference image must not bless a known incorrect state.
6. **Liquid Glass:** Follow LG-A through LG-D. Keep macOS 15 support initially;
   rebuild against a verified 26+ SDK before adding custom glass. Do not put
   glass behind every table row, metadata card or status chip.

## Important realism checks

- **Harness scope: 30 cases / 60 intended Light-Dark PNGs, covering production
  content in 24/62 files.** Eight entries are non-View helpers; 30 remain
  explicitly deferred with the missing injection/capture boundary named.
  Several captured files have child-only coverage. No PNGs exist yet and
  complete application-screen coverage is **not** delivered or claimed.
- **62 is a file inventory, not 62 standalone Views.** Adapters, models, helpers,
  representables, menus and multiple nested View types are mixed in it. Coverage
  must say what actual production content is rendered, composed, non-renderable
  or deferred. It cannot mean every possible state/input combination.
- An in-memory GRDB fixture is acceptable isolation; the user's production DB,
  accounts, devices, playback engine and network are not.
- Isolated images cannot verify actual WindowServer glass, menus, toolbar
  presentation, VoiceOver, event handling or restart persistence.
- `glassEffect`, `GlassEffectContainer` and `.buttonStyle(.glass)` have verified
  macOS **26.0** availability. The checked `glassBackgroundEffect(displayMode:)`
  is **visionOS-only**. There is no need to invent a macOS 27 `.glass` material.
- Existing optional/force-like syntax is not automatically a bug. Findings require
  a reachable data shape or interleaving; rejected hypotheses are documented.

## Change policy

Audit findings were documented, not auto-fixed. Production edits in this
deliverable are limited to the snapshot testability boundary described in
[SNAPSHOT-HARNESS.md](SNAPSHOT-HARNESS.md). No mobile/AuthHelper changes,
new snapshot dependency, Liquid Glass rollout, mass refactor, commit or push
is authorized by this audit.

## Verification record

- Windows: patch whitespace, five requested report files, stable/unique finding
  IDs and severity ordering, local link targets/line bounds, exact 62-file
  inventory/coverage partition, 30 fixture IDs and production-scope checks.
- Static code review corrected initial harness defects: missing GRDB import,
  unsafe bitmap pointer lifetime, dimension-diff failure, incorrectly scoped
  fixture error type, ignored preloaded factories, real artwork-cache collisions,
  and table readiness that could otherwise record empty rows.
- Added seven XCTest tests, including record/compare/error behavior and
  row-count readiness. They are **not executed on this Windows host**.
- Mac build/test/rendering and review of the 60 intended images remain the
  required next gate. No audit bug fix or screenshot baseline is certified by
  a structural source check.
