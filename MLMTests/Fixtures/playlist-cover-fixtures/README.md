# Playlist Cover Fixtures

This directory hosts small audio + image fixtures used by `PlaylistCoverServiceTests`.

## Expected files

| File | Purpose |
|------|---------|
| `track_with_cover.mp3` | MP3 with embedded APIC artwork (small JPEG, ≤50 KB) |
| `track_no_cover.mp3` | MP3 without embedded artwork |
| `custom_cover.png` | 256×256 PNG used to exercise `setCustomCover` |

## Authoring

The tests currently exercise the fallback + custom-cover paths which don't require
real audio fixtures (fallback test: empty playlist; custom-cover test: PNG-only input).
Tests that need real embedded artwork would be guarded with `try #require(fixturesAvailable)`
and skip cleanly when fixtures aren't present.

To generate fixtures:
- `track_with_cover.mp3`: any short MP3 with a JPEG embedded via lofty / mid3v2 / Music app
- `track_no_cover.mp3`: re-encode the above through `ffmpeg -i in.mp3 -map 0:a -c:a copy out.mp3`
- `custom_cover.png`: any 256×256 PNG (`sips -z 256 256 source.png -s format png`)

## Skip behavior

Tests that need real audio artwork are gated with `try #require(...)` and print
a skip message but pass when fixtures aren't committed. This keeps CI green
without committing binary fixtures (most cases — fixtures are optional for the
Phase 36 acceptance gates which exercise the fallback + custom paths only).
