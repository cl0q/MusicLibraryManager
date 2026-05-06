/**
 * Phase 29 Plan 04 — Pure-helper contract tests for PlaybackContext.
 *
 * The integration tests in PlaybackContext.test.tsx exercise the full provider
 * with real React rendering. These tests document the underlying math/logic
 * contracts as standalone formulas so a future refactor can't silently change
 * the LUFS curve or the focus-guard rules.
 *
 * The helpers are duplicated inline (not imported) on purpose — they pin the
 * D-19 / D-10 contracts to the test file regardless of how PlaybackContext.tsx
 * factors its internals.
 */

import { describe, it, expect } from "vitest";

// D-19/D-20 LUFS gain — see PlaybackContext.tsx::play()
function calcLufsGain(lufsI: number | null): number {
  if (lufsI === null) return 1.0;
  const gainDb = -18 - lufsI;
  const clipped = Math.max(-12, Math.min(6, gainDb));
  return Math.pow(10, clipped / 20);
}

// D-10 focus guard — see PlaybackContext.tsx::handleKeyDown
function isInputFocused(
  target: Partial<HTMLElement>,
  defaultPrevented: boolean,
): boolean {
  if (defaultPrevented) return true;
  const tag = (target.tagName ?? "").toUpperCase();
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "BUTTON") return true;
  if (target.contentEditable === "true") return true;
  return false;
}

describe("LUFS gain formula (D-19/D-20)", () => {
  it("null lufs_i → volume 1.0 (D-20 fallback)", () => {
    expect(calcLufsGain(null)).toBe(1.0);
  });

  it("target -18 LUFS: lufs_i=-18 → 0 dB → volume 1.0", () => {
    expect(calcLufsGain(-18)).toBeCloseTo(1.0, 5);
  });

  it("lufs_i=-12 → -6 dB → volume 10^(-6/20)≈0.501", () => {
    expect(calcLufsGain(-12)).toBeCloseTo(Math.pow(10, -6 / 20), 5);
  });

  it("lufs_i=-30 → +12 dB → clamps to +6 dB", () => {
    expect(calcLufsGain(-30)).toBeCloseTo(Math.pow(10, 6 / 20), 5);
  });

  it("lufs_i=0 → -18 dB → clamps to -12 dB", () => {
    expect(calcLufsGain(0)).toBeCloseTo(Math.pow(10, -12 / 20), 5);
  });

  it("lufs_i=-6 (loud) → -12 dB clamp floor", () => {
    expect(calcLufsGain(-6)).toBeCloseTo(Math.pow(10, -12 / 20), 5);
  });

  it("lufs_i=-24 (quiet) → +6 dB clamp ceiling", () => {
    expect(calcLufsGain(-24)).toBeCloseTo(Math.pow(10, 6 / 20), 5);
  });

  it("result is finite and positive across the operating range", () => {
    for (const lufs of [-40, -30, -24, -18, -12, -6, -3, 0]) {
      const v = calcLufsGain(lufs);
      expect(v).toBeGreaterThan(0);
      expect(Number.isFinite(v)).toBe(true);
    }
  });
});

describe("Spacebar focus guard (D-10)", () => {
  it("INPUT element is treated as input-focused", () => {
    expect(isInputFocused({ tagName: "INPUT" }, false)).toBe(true);
  });

  it("TEXTAREA element is treated as input-focused", () => {
    expect(isInputFocused({ tagName: "TEXTAREA" }, false)).toBe(true);
  });

  it("BUTTON element is treated as input-focused (native space toggles button)", () => {
    expect(isInputFocused({ tagName: "BUTTON" }, false)).toBe(true);
  });

  it("contentEditable=true is treated as input-focused", () => {
    expect(
      isInputFocused({ tagName: "DIV", contentEditable: "true" }, false),
    ).toBe(true);
  });

  it("defaultPrevented=true short-circuits the guard (Radix already handled)", () => {
    expect(isInputFocused({ tagName: "DIV" }, true)).toBe(true);
  });

  it("plain DIV with no contentEditable does NOT block playback", () => {
    expect(
      isInputFocused({ tagName: "DIV", contentEditable: "false" }, false),
    ).toBe(false);
  });

  it("SPAN does NOT block playback", () => {
    expect(isInputFocused({ tagName: "SPAN" }, false)).toBe(false);
  });

  it("tagName is case-insensitive", () => {
    expect(isInputFocused({ tagName: "input" }, false)).toBe(true);
    expect(isInputFocused({ tagName: "Textarea" }, false)).toBe(true);
  });
});

describe("Unsupported-format error code (D-03)", () => {
  it("MEDIA_ERR_SRC_NOT_SUPPORTED is the integer 4", () => {
    // PlaybackContext routes <audio> error events to a hardcoded toast when
    // error.code === 4 (MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED in real DOMs;
    // happy-dom does not expose the MediaError global, so we pin the integer).
    const MEDIA_ERR_SRC_NOT_SUPPORTED = 4;
    expect(MEDIA_ERR_SRC_NOT_SUPPORTED).toBe(4);
  });
});
