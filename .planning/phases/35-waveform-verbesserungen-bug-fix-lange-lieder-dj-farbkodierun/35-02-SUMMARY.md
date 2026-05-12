---
phase: 35-waveform-verbesserungen-bug-fix-lange-lieder-dj-farbkodierun
plan: "02"
subsystem: macos-app/WaveformView
tags: [waveform, scrollview, seek, swiftui, macos]
dependency_graph:
  requires:
    - "35-01"  # WaveformHelpers (seekFraction, adaptiveBinCount, amplitudeColor)
  provides:
    - horizontales Scrollen der Waveform per 2-Finger-Trackpad
    - scroll-korrigiertes Click-to-Seek
  affects:
    - macos-app/MLM/Views/TrackDetail/WaveformView.swift
tech_stack:
  added: []
  patterns:
    - ScrollView(.horizontal) mit onScrollGeometryChange fuer Offset-Tracking
    - WaveformHelpers.seekFraction als einziger Seek-Berechnungspfad
key_files:
  created: []
  modified:
    - macos-app/MLM/Views/TrackDetail/WaveformView.swift
decisions:
  - "totalContentWidth = max(data.count * barStride, geometry.size.width) verhindert unnoetige ScrollView-Aktivierung bei kurzen Tracks"
  - "Canvas bekommt totalContentWidth als frame-Breite (nicht geometry.size.width), damit ScrollView korrekt scrollt"
  - "availableWidth bleibt im Canvas-Body fuer progressX = canvasSize.width * progress (semantisch identisch nach Umbau)"
metrics:
  duration: "~5 min"
  completed: "2026-05-12T21:28:23Z"
  tasks_completed: 1
  tasks_total: 2
---

# Phase 35 Plan 02: WaveformView ScrollView-Wrap und scroll-korrigiertes Seek — Summary

## One-liner

WaveformView in horizontale ScrollView eingebettet mit onScrollGeometryChange-basiertem Offset-Tracking und seekFraction-Korrektur fuer korrekte Seek-Positionen nach Scroll.

## Was wurde gebaut

`WaveformView.swift` wurde von einem statischen Canvas-Layout auf ein scrollbares Layout umgestellt:

1. **ScrollView-Wrap:** Der waveformCanvas ist jetzt in `ScrollView(.horizontal, showsIndicators: false)` eingebettet.

2. **Canvas-Breite:** Der Canvas erhaelt `totalContentWidth = max(CGFloat(data.count) * barStride, geometry.size.width)` als Frame-Breite — bei langen Tracks deutlich breiter als die View, was Scrollen ermoelicht.

3. **scrollOffset-Tracking:** `@State private var scrollOffset: CGFloat = 0` wird via `.onScrollGeometryChange(for: CGFloat.self)` bei jedem Scroll-Event aktualisiert.

4. **Seek-Korrektur:** DragGesture ruft `WaveformHelpers.seekFraction(tapX:scrollOffset:totalContentWidth:)` auf statt der alten unsicheren Formel `value.location.x / geometry.size.width`.

5. **Fixed-stride Layout:** `totalBarWidth: CGFloat = barStride` (3pt) und `actualBarWidth: CGFloat = barWidth` (2pt) ersetzen die fill-canvas Berechnung `availableWidth / CGFloat(totalBars)`.

## Deviations from Plan

None — Plan executed exactly as written.

## Test Results

- `swift test`: 93/93 Tests bestanden (WaveformTests.seekFractionWithScroll + alle anderen)
- Alle Done-Kriterien per grep verifiziert

## Commits

| Hash | Beschreibung |
|------|-------------|
| 3789115 | feat(35-02): WaveformView — ScrollView-Wrap, scroll-korrigiertes Seek, fixed-stride Canvas |

## Known Stubs

None.

## Threat Flags

Keine neuen Sicherheits-relevanten Surfaces ausserhalb des Threat-Modells.

## Self-Check: PASSED

- [x] macos-app/MLM/Views/TrackDetail/WaveformView.swift vorhanden und modifiziert
- [x] Commit 3789115 vorhanden
- [x] `swift test` Exit-Code 0 (93 Tests bestanden)
- [x] grep ScrollView(.horizontal — gefunden Zeile 52
- [x] grep onScrollGeometryChange — gefunden Zeile 79
- [x] grep WaveformHelpers.seekFraction — gefunden Zeilen 62 + 70
- [x] grep @State private var scrollOffset — gefunden Zeile 38
- [x] grep totalBarWidth: CGFloat = barStride — gefunden Zeile 101
- [x] grep availableWidth / CGFloat(totalBars) — nicht gefunden (entfernt)
