import { describe, expect, it } from "vitest";
import { computeSlug } from "./slug";

/**
 * Parity tests: the frontend `computeSlug` MUST produce byte-identical output
 * to the backend `src-tauri/src/database/albums.rs::compute_album_slug` for the
 * Phase 21 Yeat corpus. Any divergence causes `getAlbumDetail(slug)` to silently
 * 404 when the user clicks through from the LibraryTable dev-entry.
 *
 * Fixtures MUST stay in sync with Rust tests. Boundary: JS NFKD-combining-mark
 * stripping is equivalent to Rust `deunicode` only for combining-diacritic
 * characters (ë / ü / ö / é / etc.). Precomposed transliterations (æ→ae, ß→ss,
 * ø→o, ł→l, emoji→word) DIVERGE — see SUMMARY Divergences & Follow-ups.
 */
describe("computeSlug — parity with backend compute_album_slug", () => {
  const cases: Array<[string, string, string]> = [
    ["Yeat", "AftërLyfe", "yeat-afterlyfe"],
    ["Yeat", "AftërLyfe [U]", "yeat-afterlyfe-u"],
    ["Playboi Carti", "I AM MUSIC", "playboi-carti-i-am-music"],
    ["Yeat", "4L 0.5", "yeat-4l-0-5"],
    ["Yeat", "Lyfestyle V1", "yeat-lyfestyle-v1"],
    ["Yeat", "Up 2 Më", "yeat-up-2-me"],
  ];

  it.each(cases)("slug(%s, %s) === %s", (artist, title, expected) => {
    expect(computeSlug(artist, title)).toBe(expected);
  });

  it("trims leading and trailing hyphens", () => {
    // Whitespace-only prefix / suffix collapses to a single dash each, then
    // trim removes them. "  Yeat  " + " " + " AftërLyfe " → "yeat-afterlyfe".
    expect(computeSlug("  Yeat  ", " AftërLyfe ")).toBe("yeat-afterlyfe");
  });

  it("collapses runs of non-alphanumeric chars to a single hyphen", () => {
    // Multiple punctuation in a row must not produce "--" or "---".
    expect(computeSlug("Yeat", "??? !!! AftërLyfe")).toBe("yeat-afterlyfe");
  });
});
