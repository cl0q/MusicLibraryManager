---
phase: 35-waveform-verbesserungen-bug-fix-lange-lieder-dj-farbkodierun
plan: 01
subsystem: ui
tags: [swiftui, waveform, canvas, audio, avfoundation, swift-testing]

# Dependency graph
requires:
  - phase: 05-track-detail-playback
    provides: WaveformView Canvas-Rendering, PlaybackViewModel extractWaveform(), AudioPlayer.duration

provides:
  - WaveformHelpers.swift — drei statische reine Funktionen: adaptiveBinCount, amplitudeColor, seekFraction
  - WaveformTests.swift — 11 Unit-Tests fuer alle drei WaveformHelpers-Funktionen
  - Adaptive Bin-Berechnung: 2 Bins/Sekunde, Floor 200, Cap 14400 (DJ-Mixes bis 4h)
  - DJ-Farbkodierung: amplitude-basierte HSB-Farbe pro Bar (blau still → orange laut)
  - barStride-Konstante in WaveformView fuer Plan 35-02 (ScrollView-Integration)
  - PlayerBar Zeitstempel-Labels 44pt (verhindert Clipping bei 3-stelligen Minuten)

affects:
  - 35-02-PLAN.md (nutzt WaveformHelpers.seekFraction + barStride aus diesem Plan)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Reine Hilfsfunktionen in enum WaveformHelpers isoliert — testbar ohne AppKit/SwiftUI"
    - "Amplitude-basierte HSB-Farbe: hue 0.611→0.083 (220°→30°), saturation 0.4→1.0, brightness variiert per played"
    - "Adaptive Bin-Dichte: 2 Bins/sec mit Floor 200 und Cap 14400"

key-files:
  created:
    - macos-app/MLM/Views/TrackDetail/WaveformHelpers.swift
    - macos-app/MLMTests/WaveformTests.swift
  modified:
    - macos-app/MLM/ViewModels/PlaybackViewModel.swift
    - macos-app/MLM/Views/TrackDetail/WaveformView.swift
    - macos-app/MLM/Views/Player/PlayerBar.swift

key-decisions:
  - "WaveformHelpers als enum (nicht struct/class) — keine Instanziierung, nur statische Funktionen"
  - "barStride bereits in Plan 35-01 definiert, damit Plan 35-02 keinen Merge-Konflikt hat"
  - "barOpacity fuer ungespielte Bars auf 0.55 gesetzt (statt 0.5) — passt zum amplitudeColor-Opacity-Wert"

patterns-established:
  - "WaveformHelpers-Pattern: Pure statische Funktionen fuer testbare UI-Logik"
  - "DJ-Farbkodierung: amplitudeColor(for:played:) liefert HSB-Color fuer Canvas-Loop"

requirements-completed: [WF-01, WF-02, WF-04]

# Metrics
duration: 15min
completed: 2026-05-12
---

# Phase 35 Plan 01: Waveform-Infrastruktur — Adaptive Bins, DJ-Farben, PlayerBar-Fix Summary

**WaveformHelpers.swift mit adaptiveBinCount/amplitudeColor/seekFraction extrahiert, DJ-Farbkodierung im Canvas aktiviert, PlayerBar-Zeitstempel auf 44pt verbreitert**

## Performance

- **Duration:** ca. 15 min
- **Started:** 2026-05-12T21:20:00Z
- **Completed:** 2026-05-12T21:35:00Z
- **Tasks:** 2
- **Files modified:** 5 (2 neu, 3 geaendert)

## Accomplishments

- `WaveformHelpers.swift` mit drei statischen reinen Funktionen erstellt: `adaptiveBinCount` (2 Bins/sec, Floor 200, Cap 14400), `amplitudeColor` (HSB-Farbkodierung), `seekFraction` (Scroll-aware Seek-Berechnung)
- 11 Unit-Tests in `WaveformTests.swift` — alle gruen; decken Short-Track/2h-Track/Overflow-Clamp, Crash-Safety beider Farb-Extremwerte und alle 5 seekFraction-Varianten ab
- `extractWaveform()` in PlaybackViewModel nutzt jetzt `WaveformHelpers.adaptiveBinCount(duration: audioPlayer.duration)` statt hardcoded `binCount: 200`
- WaveformView Canvas-Loop rendet DJ-Farben via `WaveformHelpers.amplitudeColor` pro Bar; `barStride`-Konstante fuer Plan 35-02 vorbereitet
- PlayerBar Zeitstempel-Labels von 34pt auf 44pt verbreitert

## Task Commits

Jeder Task wurde atomar committed:

1. **Task 1: WaveformTests.swift und WaveformHelpers.swift anlegen** - `6a0000c` (feat)
2. **Task 2: PlaybackViewModel + WaveformView + PlayerBar anpassen** - `c148263` (feat)

**Plan-Metadata:** wird in diesem Commit erfasst (docs)

## Files Created/Modified

- `macos-app/MLM/Views/TrackDetail/WaveformHelpers.swift` — Neue Datei: drei statische reine Funktionen (adaptiveBinCount, amplitudeColor, seekFraction)
- `macos-app/MLMTests/WaveformTests.swift` — Neue Datei: 11 Unit-Tests fuer WaveformHelpers
- `macos-app/MLM/ViewModels/PlaybackViewModel.swift` — extractWaveform() nutzt adaptiveBinCount statt 200
- `macos-app/MLM/Views/TrackDetail/WaveformView.swift` — DJ-Farben im Canvas-Loop, barStride-Konstante hinzugefuegt
- `macos-app/MLM/Views/Player/PlayerBar.swift` — frame(width: 34) → frame(width: 44) an beiden Zeitstempel-Labels

## Decisions Made

- `WaveformHelpers` als `enum` (nicht `struct` oder `class`) — reine statische Funktionen, keine Instanziierung moeglich, vermeidet versehentliche Zustandshaltung
- `barStride: CGFloat = 3` bereits in Plan 35-01 definiert, damit Plan 35-02 (ScrollView-Integration) keinen Merge-Konflikt verursacht
- `barOpacity` fuer ungespielte Bars auf `0.55` gesetzt (Plan spezifizierte diesen Wert explizit; entspricht `opacity: 0.55` in `amplitudeColor`)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Build lief im falschen Verzeichnis**
- **Found during:** Task 1 (Test-Verifikation)
- **Issue:** `swift test` wurde im Haupt-Repo-Pfad `/Users/olli/schenanigans/MusicLibraryManager/macos-app` ausgefuehrt, waehrend die Dateien im Worktree-Pfad liegen. Der Haupt-Repo-Build hatte vorhandene SpacebarPreviewContext-Fehler (pre-existing, nicht durch diesen Plan verursacht).
- **Fix:** Alle `swift test`-Aufrufe und Dateioperationen auf den Worktree-Pfad umgelenkt: `/Users/olli/schenanigans/MusicLibraryManager/.claude/worktrees/agent-a85f54dc29daf2ea9/macos-app`
- **Files modified:** Keine — Ausfuehrungs-Pfad-Korrektur
- **Verification:** swift test --filter WaveformTests laeuft im Worktree grueen

---

**Total deviations:** 1 auto-fixed (1 blocking — Pfad-Korrektur)
**Impact on plan:** Ausfuehrungs-Pfad-Korrektur war noetig fuer korrekten Test-Lauf. Kein Scope-Creep.

## Issues Encountered

- Der Haupt-Repo-Build hat vorhandene Fehler durch `SpacebarPreviewContext` (in `PlaylistDetailView.swift` referenziert, aber die definierenden Swift-Quelldateien fehlen im Haupt-Repo). Diese Fehler existierten vor diesem Plan und sind OUT OF SCOPE — sie wurden in `deferred-items.md` nicht festgehalten weil sie ausserhalb der Worktree-Ausfuehrung liegen. Im Worktree selbst kompiliert alles einwandfrei.

## Known Stubs

Keine — alle implementierten Funktionen sind vollstaendig und produktionsbereit.

## Threat Flags

Keine neuen Sicherheits-relevanten Flaechen eingefuehrt. Alle STRIDE-Bedrohungen aus dem Plan-Threat-Register sind wie geplant abgedeckt (T-35-01 durch Cap 14400, T-35-02/03/04 akzeptiert).

## Next Phase Readiness

- `WaveformHelpers.swift` ist fuer Plan 35-02 (ScrollView-Integration, Trackpad-Scroll) bereit: `seekFraction(tapX:scrollOffset:totalContentWidth:)` und `barStride` sind bereits definiert
- Plan 35-02 kann `WaveformHelpers.amplitudeColor` unveraendert uebernehmen
- Alle 93 Tests grueen — keine Regressionen

---
*Phase: 35-waveform-verbesserungen-bug-fix-lange-lieder-dj-farbkodierun*
*Completed: 2026-05-12*
