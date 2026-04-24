/**
 * Compute a URL slug for an album from (album_artist, title).
 *
 * MUST match `src-tauri/src/database/albums.rs::compute_album_slug` byte-for-byte
 * for the Phase 21 Yeat corpus:
 *   1. combined = `${albumArtist} ${title}`
 *   2. strip diacritics via Unicode NFKD decomposition + combining-mark removal
 *      (ë -> e, ü -> u, ö -> o, é -> e, etc.) — browser-native, no deps
 *   3. lowercase
 *   4. collapse any run of non-alphanumeric chars to a single `-`
 *   5. trim leading/trailing `-`
 *
 * Examples (matches backend test fixtures):
 *   - ("Yeat", "AftërLyfe") -> "yeat-afterlyfe"
 *   - ("Yeat", "AftërLyfe [U]") -> "yeat-afterlyfe-u"
 *   - ("Playboi Carti", "I AM MUSIC") -> "playboi-carti-i-am-music"
 *   - ("Yeat", "4L 0.5") -> "yeat-4l-0-5"
 *   - ("Yeat", "Lyfestyle V1") -> "yeat-lyfestyle-v1"
 *
 * Known divergence boundary (accepted tech debt — see 21-04-PLAN §interfaces):
 * Rust `deunicode` and JS NFKD-combining-mark-strip are EQUIVALENT only for the
 * combining-diacritic character class (ë/ö/ü/é/etc. — the entire Phase 21 Yeat
 * corpus). They DIVERGE for precomposed transliterations:
 *   - `æ` → backend: `ae`, frontend (this impl): `a`
 *   - `ß` → backend: `ss`, frontend: (unchanged → non-alnum → `-`)
 *   - `ø` → backend: `o`, frontend: (unchanged → non-alnum → `-`)
 *   - `ł` → backend: `l`, frontend: (unchanged → non-alnum → `-`)
 *   - emoji → backend: word form, frontend: (unchanged → non-alnum → `-`)
 *
 * For any future album title containing these characters, the two pipelines
 * produce different slugs and `getAlbumDetail(slug)` silently 404s. Mitigation
 * paths when needed: (a) switch to a backend `compute_slug_cmd` Tauri helper
 * (single source of truth), or (b) replicate the full deunicode character
 * table in JS. Neither is required for Phase 21 since the Yeat corpus does
 * not reach these characters.
 *
 * Security (T-21.04-01): The slug is URL-safe by construction (only
 * `[a-z0-9-]` after normalization). It is passed verbatim to `getAlbumDetail`
 * which resolves via DB lookup, NEVER filesystem access — no path traversal
 * vector even if slug contains `../..` (those chars collapse to `-`).
 */
export function computeSlug(albumArtist: string, title: string): string {
  const combined = `${albumArtist} ${title}`;
  // NFKD decomposition: ë -> e + ̈ (combining diaeresis).
  // Then strip combining marks (Unicode block U+0300..U+036F).
  const stripped = combined.normalize("NFKD").replace(/[̀-ͯ]/g, "");
  const lowered = stripped.toLowerCase();

  let out = "";
  let lastWasDash = false;
  for (const c of lowered) {
    if (/[a-z0-9]/.test(c)) {
      out += c;
      lastWasDash = false;
    } else if (!lastWasDash) {
      out += "-";
      lastWasDash = true;
    }
  }
  return out.replace(/^-+|-+$/g, "");
}
