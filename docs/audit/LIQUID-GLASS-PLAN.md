# Liquid Glass migration plan

Status: research and static source assessment, 2026-09-22. No macOS build,
render, accessibility inspection, or performance measurement was performed.
This document is a plan, not an implemented visual redesign.

## 1. Decisions

1. Keep macOS 15.0 as the deployment target for now. Build the eventual
   migration with an SDK that declares the macOS 26 APIs; use runtime
   availability checks for custom glass. Raising the deployment target is a
   separate product decision, not a prerequisite for adopting glass on newer
   systems.
2. Rebuild and inspect native controls **before** adding custom effects.
   Liquid Glass is a navigation/control layer, not a replacement for every
   content background.
3. Preserve the [ground truth](../../UI-GROUNDTRUTH.md#12-color-system):
   semantic text, status meanings, labeled failures, dense readable tables.
   A material change must not change the meaning of a status.
4. Baseline source behavior and UI states before changing appearance. The
   [snapshot harness](SNAPSHOT-HARNESS.md) is a content-regression aid, not
   proof of WindowServer-composited glass or interactive conformance.
5. Do not block on a speculative "macOS 27 glass API". The relevant custom
   SwiftUI APIs already have documented **macOS 26.0** availability.

## 2. Verified Apple API facts

The following facts were checked against Apple's documentation and its
DocC JSON metadata on 2026-09-22. Availability here is from the symbol's own
`metadata.platforms`, not inferred from a marketing article or another
platform. The checked macOS 26 symbols were not marked deprecated or beta.
This is not a claim that every API in a future SDK has been audited.

| API | Verified applicability | Decision for MLM |
|---|---|---|
| [`View.glassEffect(_:in:)`](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)) | macOS 26.0+. Signature: `glassEffect(_ glass: Glass = .regular, in shape: some Shape = DefaultGlassEffectShape()) -> some View` | Use sparingly for custom floating controls; padding/layout precede the effect. |
| [`GlassEffectContainer`](https://developer.apple.com/documentation/swiftui/glasseffectcontainer) | macOS 26.0+; combines related glass shapes and enables their interaction/morphing | Only for a group of actual glass controls, not a wrapper for all screen content. |
| [`Glass.interactive(_:)`](https://developer.apple.com/documentation/swiftui/glass/interactive(_:)) | macOS 26.0+; default argument is `true` | For interactive custom surfaces; it does not turn a decorative view into an accessible button. |
| [`PrimitiveButtonStyle.glass`](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass) / [`GlassButtonStyle`](https://developer.apple.com/documentation/swiftui/glassbuttonstyle) | macOS 26.0+ | `.buttonStyle(.glass)` is real. This is **not** evidence for `.background(.glass)` as a `Material`. |
| [`glassBackgroundEffect(displayMode:)`](https://developer.apple.com/documentation/swiftui/view/glassbackgroundeffect(displaymode:)) | The checked symbol lists **visionOS 1.0**, not macOS | Do not use this visionOS API for the macOS migration. |
| [`Material`](https://developer.apple.com/documentation/swiftui/material) | Documents `ultraThin`, `thin`, `regular`, `thick`, `ultraThick`, `bar` | Existing `.regularMaterial`/`.ultraThinMaterial` are not aliases for Liquid Glass. No blanket text replacement to `.glass`. |
| [`ImageRenderer`](https://developer.apple.com/documentation/swiftui/imagerenderer) | macOS 13.0+; `nsImage` is main-actor-isolated and optional | Suitable for eligible SwiftUI content, not a promise to capture all native/platform-hosted surfaces. |

Official guidance:

- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass):
  rebuilding standard SwiftUI/AppKit components with a new SDK and running on
  the new OS brings the new appearance; custom backgrounds can obscure it;
  test reduced transparency/motion and avoid overuse.
- [Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views):
  effect shape, modifier ordering, container grouping and interactive behavior.

For reproducibility, the corresponding machine-readable sources are
`https://developer.apple.com/tutorials/data/documentation/` followed by the
documentation path after `/documentation/` and `.json`. These sources were
queried read-only; no repository data was sent to an external service.

### SDK versus runtime versus Swift language mode

[Package.swift](../../Package.swift#L1) declares Swift tools 5.10 and
[macOS 15.0](../../Package.swift#L7). The tools-version line is a minimum
package-tooling/language-mode declaration, not an instruction to use an old
SDK forever. Keep Swift 5 language compatibility initially; do not conflate
the glass migration with a Swift 6 strict-concurrency migration.

`if #available(macOS 26.0, *)` protects **execution**, not compilation with an
SDK that does not declare the symbol. The glass branch needs Xcode/SDK 26+
(or a subsequently verified newer SDK). An old-SDK build must exclude that
source/configuration entirely; scattering speculative compiler-version
checks is not a good substitute. Verify exact supported Xcode versions on
the Mac before changing CI/toolchain requirements.

The "27" line is a forward-compatibility test lane. No 27-only API or
deprecation is assumed in this plan.

## 3. Current token/material architecture

### Centralized foundations worth keeping

- [Colors.swift:10-45](../../MLM/Theme/Colors.swift#L10) maps backgrounds,
  separators and text to semantic AppKit/SwiftUI roles. These are a sound
  macOS 15 fallback and should not be replaced by literal white/black.
- [Status colors:48-58](../../MLM/Theme/Colors.swift#L48) already separate
  active, success, error and attention. Glass tint must not repurpose these
  as decorative brand or data colors.
- [Energy opacity:63-66](../../MLM/Theme/Colors.swift#L63) uses the accent
  ramp required by ground-truth section 1.2.
- [Brand tokens:71-99](../../MLM/Theme/Colors.swift#L71) have light/dark
  variants, separate from status aliases. Their provider checks light/dark
  appearance, not an explicit high-contrast palette. Contrast on translucent
  backgrounds remains a visual validation item, not a proven defect.
- [Typography.swift](../../MLM/Theme/Typography.swift#L9) uses native
  semantic fonts. It still exposes extra aliases such as `title2`, `title3`,
  `tableHeader`, `miniPlayerTitle` in addition to the reduced contract set.
  Consolidate usage by semantic role; avoid an unrelated font redesign.

### Gaps

The two-file theme is a color/font vocabulary, **not** a centralized
material or geometry layer. There is no theme-owned surface-role policy
or shared implementation of the [section 1.4 metrics](../../UI-GROUNDTRUTH.md#14-spacing-metrics-iconography).
An additive, small surface modifier and metrics namespace are preferable
to a new design-system package. Do not globally change `mlmSurface` to
glass: a `Color` token cannot express a contextual, availability-gated
view effect, and content surfaces should remain content surfaces.

## 4. Readiness by surface

| Surface / entry point | Native benefit | Manual work / risk |
|---|---|---|
| [ContentView:233-257](../../MLM/Views/ContentView/ContentView.swift#L233), [SidebarView:48-57](../../MLM/Views/Sidebar/SidebarView.swift#L48) | Navigation split view, `.principal` player toolbar item and inspector provide the right native structure | Root uses `mlmBase`, sidebar uses `mlmSurface`; custom search field uses `mlmSurface` and 6 pt radius ([642-718](../../MLM/Views/ContentView/ContentView.swift#L642)). Review background overrides and toolbar width on the real OS. |
| [PlayerBar:20-31](../../MLM/Views/Player/PlayerBar.swift#L20) | Hosted in system chrome, standard controls can benefit | Already wraps itself in `.regularMaterial`, 8 pt rounding and a separator stroke. This is a specific double-material risk inside a new native toolbar. Cover popover ([91-111](../../MLM/Views/Player/PlayerBar.swift#L91)) uses `.presentationBackground(.clear)` and custom shadow; validate separately. |
| [ActivityPanel:27-48](../../MLM/Views/Activity/ActivityPanel.swift#L27), [132-226](../../MLM/Views/Activity/ActivityPanel.swift#L132) | Standard child controls can update | `mlmSurface`, custom separators/resize handle, no glass. Expanded logs and operations are dense content. Preserve the 36 pt collapsed and adjustable expanded geometry. |
| [UniversalSearchView:18-44](../../MLM/Views/Search/UniversalSearchView.swift#L18), [408-423](../../MLM/Views/Search/UniversalSearchView.swift#L408) | Standard inputs can gain native appearance | Custom black scrim, white-opacity accents, shadow and 20 pt local `glassBackground` helper; the helper actually uses `.regularMaterial`. Correct its macOS 27 TODO to verified 26 APIs, but first decide whether the custom overlay is needed alongside global search. |
| [PlaylistCard:72-99](../../MLM/Views/Playlists/PlaylistCard.swift#L72), [156-168](../../MLM/Views/Playlists/PlaylistCard.swift#L156) and [TrackTable:96-244](../../MLM/Views/Library/TrackTable.swift#L96) | Native table selection/focus behavior remains useful | Cards use `mlmSurface`/hover `mlmRaised`, 8 pt corners, border; no material. Keep artwork/provenance/status readable. No glass per row or chip. |
| [SettingsView:11-39](../../MLM/Views/Settings/SettingsView.swift#L11), [FirstRunWizard:31-44](../../MLM/Views/Shared/FirstRunWizard.swift#L31), [selection sheets:18-83](../../MLM/Views/Shared/SelectionCreationSheets.swift#L18) | Native Form/TabView/sheet/popover/control treatment can update automatically | Settings is mostly native. Wizard/selection sheets add `mlmSurface`, rounded cards and wizard shadow; avoid double framing at presentation boundaries. Destructive semantics remain independent of material. |
| [FoldersView:61-143](../../MLM/Views/Folders/FoldersView.swift#L61), [214-239](../../MLM/Views/Folders/FoldersView.swift#L214) | Native list/tree/table structure | `mlmBase` root, `mlmSurface` breadcrumb/search header, `mlmRaised` pills, attention-tinted unindexed warning. Preserve the text-bearing warning, not glass-tinted decoration. |
| [PlaylistDetailView:382-506](../../MLM/Views/Playlists/PlaylistDetailView.swift#L382) | Standard bordered actions, system detail navigation | Header is cover + spacing + divider, not a material plate. Preserve hierarchy instead of adding a new backdrop. |
| [TrackDetailView](../../MLM/Views/TrackDetail/TrackDetailView.swift), waveform and Similar | Native inspector/sheet presentation is valuable | Custom opaque metadata cards, Canvas plots and dense Similar/Genre Workshop panels are content. Keep them readable; any inspector-boundary treatment requires real-window verification. |

"Automatic" means eligible system-owned chrome when **both built against the
new SDK and run on the new system**. It does not mean every custom `VStack`,
background, AppKit representable, menu or captured bitmap is transformed.

## 5. Proposed phases (not changes to the current roadmap)

The current [state](../../.planning/STATE.md#L35) still has phase 39 macOS
verification pending. Finish that reliability gate before starting a
visual migration. The labels below are plan sketches, not assigned GSD
phase numbers and not claims that planning artifacts were updated.

### LG-A: Reproducible baseline and critical correctness

Dependencies: phase 39-07 Mac checks; top-priority audit correctness fixes.

- Compile this audit's test additions on the Mac. Execute the harness
  record pass, inspect every produced image, then execute comparison mode.
- Record old appearance and failure/empty states before introducing glass.
  Preserve OS/SDK-specific baselines, not one mixed reference directory.
- Close verified destructive/dead-control defects from
  [UI-BUGS](UI-BUGS.md); run the remaining interactive Part 6 checks.
- Capture actual app windows for toolbar, menus, sheets, focus and
  accessibility states omitted from isolated snapshots.

Exit: a reviewed baseline with explicit covered/deferred surfaces and a
working compare pass. A skipped opt-in snapshot suite is not this gate.

### LG-B: New-SDK native-only adoption

Dependencies: LG-A.

- Build with the selected 26+ SDK while retaining deployment target 15.
- Do not add `glassEffect` yet. Inspect standard toolbar/sidebar/sheets
  against native behavior on 15 and 26; add a 27 test lane only when an
  actual supported SDK/runtime is available.
- Remove *proven conflicting* custom backgrounds at chrome boundaries
  individually, gated/reversible. Keep content surfaces intact.
- Verify narrow-window behavior at 900x600, default 1200x800, expanded
  activity and inspector, long titles, and active playback/search.

Exit: standard chrome looks native without hiding actions/status or
regressing macOS 15.

### LG-C: Minimal surface policy and custom-control pilot

Dependencies: LG-B.

- Add shared metrics for the existing section 1.4 values and a small
  availability-gated surface modifier for a deliberately selected custom
  floating control. Do not make all existing backgrounds conditional.
- Pilot at the custom search/control boundary, not on table rows.
- Use `.buttonStyle(.glass)` on genuine buttons only when justified.
  Add `GlassEffectContainer` only if several related glass effects really
  need grouping; use its spacing intentionally.
- Preserve labels, focus rings, hit targets, Reduce Transparency and
  Reduce Motion behavior. Never rely on the material to communicate state.

Illustrative policy sketch, **statically written; compile/run on the
user's Mac with a 26+ SDK**. This is intentionally not applied to production
views in this audit:

```swift
private struct OptionalControlGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            if reduceTransparency {
                content.background(
                    Color.mlmSurface,
                    in: RoundedRectangle(cornerRadius: 8)
                )
            } else {
                content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content.background(
                Color.mlmSurface,
                in: RoundedRectangle(cornerRadius: 8)
            )
        }
    }
}
```

This is a deliberately conservative opaque fallback for custom chrome,
not a prescription to override native system accessibility adaptation.
The caller controls padding, size and placement. Native controls should
normally keep their system-provided adaptation.

Exit: reviewed pilot with equivalent semantics and a rollback switch or
small isolated commit (only when the user authorizes commits).

### LG-D: Measured expansion and contract consolidation

Dependencies: LG-C.

- Expand only to surfaces where real screenshots show a benefit.
- Map custom font/metric usages to existing semantic roles; update the
  ground truth only for deliberate accepted design changes.
- Remove the outdated search TODO and temporary navigation logging as
  separate, reviewable cleanup, not bundled with behavioral changes.
- Profile scrolling, playback while navigating, and expanded Activity
  with Instruments on hardware. This Windows audit makes no frame-rate
  or CPU claims.

Exit: stable performance, complete state coverage for changed surfaces,
and documented acceptance on supported runtimes.

## 6. Test and acceptance matrix

| Dimension | Automated contribution | Required Mac/device verification |
|---|---|---|
| Light + Dark, fixed geometry, English, long/Unicode metadata | Harness content PNG pairs and registry checks | Native chrome, actual window clipping and text readability |
| Populated / empty / missing-file / failed states | Explicit fixture cases only, as listed in harness report | Real transitions, retries, persisted failures after restart |
| macOS 15 / 26 / future verified 27 | Separate baseline sets per OS + SDK/toolchain | Real builds/runs; availability fallback and native adoption |
| Reduce Transparency / Increased Contrast / Reduce Motion | Add explicit fixture variants when migrating each surface | Native settings, glass compositing, focus and animation behavior |
| Input/accessibility | Existing logic/source tests are supporting evidence only | VoiceOver labels and order, keyboard navigation, Escape, menus, disabled reasons |
| Destructive actions / source expiry / 44-track import | State fixtures help inspect text | Part 6 live consequences, cancel/undo, disconnect/reconnect, relaunch |
| Performance | No Windows proxy measurement | Instruments: scrolling, layout churn, energy use and active workloads |

Never accept new baselines blindly after an SDK upgrade. Review the
actual/reference/diff images; document intentional platform changes.
Offscreen snapshots may omit native windows, presentation chrome or
background-dependent glass. They cannot close those deferred checks.

## 7. Anti-patterns and rollback rules

- No glass on every row/card, no nested glass over system glass, no
  vibrancy/blur stack to imitate a newer OS on macOS 15.
- No transparent fallback that erases separation or makes status text
  dependent on the wallpaper/artwork behind it.
- No replacing status or source text with colored effects.
- No speculative `.background(.glass)` or macOS `glassBackgroundEffect`.
- No massive availability checks sprinkled across 62 files: isolate the
  small custom policy and keep the default native path.
- No visual redesign mixed with database, playback or download fixes.
- Roll back a custom effect if it harms readability, accessibility,
  state legibility or responsiveness; retain the native SDK upgrade and
  tested macOS 15 fallback independently.
