---
phase: 01-library-foundation
plan: 02
subsystem: library
tags: [fat32, sanitization, pathvalidate, tdd, filesystem]

# Dependency graph
requires:
  - phase: none
    provides: standalone module
provides:
  - FAT32-safe filename sanitization via sanitize_filename()
  - Organized path construction via sanitize_path()
  - TDD test suite for sanitization edge cases
affects: [01-03-importer, file organization, device sync]

# Tech tracking
tech-stack:
  added: [pathvalidate]
  patterns: [TDD red-green-refactor, underscore replacement for invalid chars]

key-files:
  created:
    - src/library/sanitizer.py
    - tests/test_sanitizer.py
    - tests/__init__.py
  modified: []

key-decisions:
  - "Underscore prefix for Windows reserved names (not suffix)"
  - "Return 'unknown' placeholder for empty/invalid-only input"
  - "Underscore replacement for invalid chars (more readable than removal)"

patterns-established:
  - "TDD workflow: write failing tests first, implement to pass, refactor"
  - "FAT32 sanitization: use pathvalidate with platform='universal'"

# Metrics
duration: 4min
completed: 2026-02-03
---

# Phase 01 Plan 02: FAT32 Filename Sanitization Summary

**TDD-driven FAT32 filename sanitizer using pathvalidate with underscore replacement, Windows reserved name handling, and organized path construction from metadata**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-02-03T12:15:00Z
- **Completed:** 2026-02-03T12:18:45Z
- **Tasks:** 3 (RED, GREEN, REFACTOR)
- **Files created:** 3

## Accomplishments
- Implemented sanitize_filename() handling all FAT32 constraints (invalid chars, reserved names, length limits)
- Implemented sanitize_path() for building organized Artist/Album/Title.ext paths
- Created comprehensive TDD test suite with 44 test cases covering edge cases
- Established TDD workflow pattern for future development

## Task Commits

Each task was committed atomically:

1. **RED: Add failing tests** - `6c4302c` (test)
2. **GREEN: Implement sanitization** - `7fd5606` (feat)
3. **REFACTOR: Extract constants and helper** - `902f589` (refactor)

## Files Created/Modified
- `src/library/sanitizer.py` - FAT32-safe filename sanitization (173 lines)
- `tests/test_sanitizer.py` - TDD test suite for sanitization (244 lines)
- `tests/__init__.py` - Test suite init

## Decisions Made
- **Underscore prefix for reserved names:** Windows reserved names (CON, PRN, etc.) are prefixed with underscore (_CON) rather than suffixed (CON_) for consistency and readability
- **'unknown' placeholder:** Empty, None, whitespace-only, or invalid-only inputs return "unknown" placeholder instead of raising exception
- **Underscore replacement:** FAT32-invalid characters are replaced with underscore (more readable than removal or other chars)
- **pathvalidate platform='universal':** Covers FAT32 constraints while being cross-platform compatible

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
- **pathvalidate suffix behavior:** pathvalidate adds underscore suffix to reserved names (e.g., "CON_") but we wanted prefix ("_CON"). Fixed by detecting reserved names before pathvalidate processing and applying custom prefix logic.
- **Reserved names with extensions:** "CON.txt" becomes "CON_.txt" with pathvalidate; needed special handling to strip suffix from base name before adding prefix ("_CON.txt").

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Sanitization module ready for integration into importer (01-03)
- Pattern established: import from `src.library.sanitizer import sanitize_path`
- All edge cases tested and documented

---
*Phase: 01-library-foundation*
*Completed: 2026-02-03*
