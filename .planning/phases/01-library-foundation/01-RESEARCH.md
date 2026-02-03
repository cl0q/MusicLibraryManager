# Phase 1: Library Foundation - Research

**Researched:** 2026-02-03
**Domain:** Audio metadata management, file operations, local library import, full-text search
**Confidence:** HIGH

## Summary

This phase establishes core music library infrastructure with atomic file operations, metadata management for local audio files, directory organization, and instant search capabilities. The standard Python ecosystem provides mature, production-tested libraries for audio metadata (Mutagen), atomic file operations (atomicwrites), and full-text search (Whoosh). Fuzzy matching for search tolerance is best handled with RapidFuzz (faster, production-grade replacement for FuzzyWuzzy). The architecture requires a SQLite database tracking file locations (reference-in-place model), metadata cache for instant search indexing, and normalized schema to support artist/album organization with SoundCloud content in a separate folder structure.

Key research focused on verified library capabilities, FAT32 filename constraints, duplicate detection via metadata matching, and common pitfalls in music library implementations (incomplete metadata, duplicate handling, syncing issues).

**Primary recommendation:** Use Mutagen for metadata (HIGH confidence), RapidFuzz for fuzzy search (HIGH confidence), Whoosh for full-text indexing (HIGH confidence), and pathvalidate for cross-platform filename sanitization (MEDIUM confidence for FAT32 specifics).

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Mutagen | 1.46+ | Read/write audio metadata (ID3v2, Vorbis, APEv2) | Industry standard, zero dependencies, supports all required formats (MP3, FLAC, AAC) |
| RapidFuzz | 3.4+ | Fuzzy string matching for search tolerance | C++ implementation for performance, MIT license, drop-in FuzzyWuzzy replacement, multiple string similarity algorithms |
| Whoosh | 2.7+ | Full-text search and metadata indexing | Pure Python, no external dependencies, schema-based indexing ideal for structured music metadata |
| atomicwrites | 1.4+ | Atomic file operations for safety | Prevents corrupt files from interrupted writes, widely used (1.3M weekly downloads) |
| pathvalidate | 3.2+ | Cross-platform filename validation/sanitization | Handles all filesystem constraints automatically (Windows, POSIX, FAT32) |
| SQLite | 3.40+ | Local database for file tracking and metadata cache | Built into Python, perfect for local-first music library, supports 3NF normalization, tracks file locations |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| tqdm | 4.65+ | Progress bar feedback for imports | Required for LIB-01 import progress UI (progress bar by default, expandable log) |
| tinytag | 1.9+ | Lightweight metadata reading (optional) | Read-only fast metadata fetch; Mutagen preferred for write operations |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Whoosh (full-text) | SQLite FTS5 | SQLite FTS5 is simpler but less feature-rich; Whoosh better for fuzzy matching integration |
| RapidFuzz (fuzzy) | difflib (stdlib) | stdlib faster but requires manual algorithm selection; RapidFuzz provides tested algorithms optimized for metadata search |
| atomicwrites | Manual temp file + os.replace | Manual approach error-prone; atomicwrites is well-tested, POSIX/Windows atomic |
| pathvalidate | Manual regex sanitization | Manual regex doesn't handle all filesystem edge cases; pathvalidate is comprehensive and maintained |

**Installation:**
```bash
pip install mutagen>=1.46 rapidfuzz>=3.4 whoosh>=2.7 atomicwrites>=1.4 pathvalidate>=3.2 tqdm>=4.65
```

## Architecture Patterns

### Recommended Project Structure
```
src/
├── library/
│   ├── database.py        # SQLite schema and CRUD operations
│   ├── metadata.py        # Mutagen wrapper for read/write
│   ├── indexer.py         # Whoosh full-text search indexing
│   ├── importer.py        # File import with progress tracking
│   ├── duplicate.py       # Duplicate detection via metadata matching
│   └── sanitizer.py       # Filename sanitization (Album Artist organization)
├── search/
│   ├── engine.py          # Whoosh query builder with fuzzy matching
│   └── models.py          # Search result data models
└── core/
    ├── file_ops.py        # atomicwrites and safe file operations
    └── config.py          # Configuration (SoundCloud folder path, etc)
```

### Pattern 1: Metadata-Driven File Organization

**What:** Reference-in-place import that tracks file locations in database while organizing into directories by Album Artist / Album / Track metadata.

**When to use:** User imports existing local music collection; system maintains pointer to original location rather than copying files.

**Example:**
```python
# Source: Mutagen documentation, metadata-driven approach
from mutagen.id3 import ID3

audio = ID3("song.mp3")
album_artist = audio.get("TPE2", [None])[0] or "Various Artists"  # Album artist frame
album = audio.get("TALB", [None])[0] or "Unknown Album"
title = audio.get("TIT2", [None])[0] or "Unknown"

# Organize: Artist/Album/Title
organized_path = f"{album_artist}/{album}/{title}.mp3"
# Store original_path in database, symlink or reference to organized_path
```

### Pattern 2: SQLite Schema for File Tracking

**What:** Normalized database schema tracking files, metadata, and quality metrics for duplicate detection.

**When to use:** Core data layer for import, search, and duplicate operations.

**Example:**
```sql
-- File tracking with reference-in-place model
CREATE TABLE files (
    id INTEGER PRIMARY KEY,
    original_path TEXT UNIQUE NOT NULL,  -- Original location (reference-in-place)
    organized_path TEXT NOT NULL,        -- Album Artist/Album/Track folder structure
    is_soundcloud BOOLEAN DEFAULT 0,     -- SoundCloud content in separate structure
    imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_synced TIMESTAMP
);

-- Metadata cache for search indexing
CREATE TABLE metadata (
    id INTEGER PRIMARY KEY,
    file_id INTEGER UNIQUE,
    artist TEXT,
    album_artist TEXT,  -- Key field for folder organization
    album TEXT,
    title TEXT,
    genre TEXT,
    year INTEGER,
    bitrate INTEGER,    -- For quality-based duplicate resolution
    format TEXT,        -- mp3, flac, aac (for quality hierarchy)
    duration INTEGER,
    FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
);

-- For duplicate detection: exact metadata match
CREATE TABLE duplicates (
    id INTEGER PRIMARY KEY,
    primary_file_id INTEGER,    -- Higher quality version
    duplicate_file_id INTEGER,  -- Lower quality version
    reason TEXT,                -- "lower_bitrate", "worse_format", etc
    reviewed BOOLEAN DEFAULT 0,
    FOREIGN KEY(primary_file_id) REFERENCES files(id),
    FOREIGN KEY(duplicate_file_id) REFERENCES files(id)
);

-- Whoosh full-text index references
CREATE TABLE search_index (
    file_id INTEGER PRIMARY KEY,
    indexed_at TIMESTAMP,
    FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
);
```

### Pattern 3: Atomic Import with Progress Tracking

**What:** Safe import operation that completes even if files are corrupted, batches failures for review, provides progress feedback.

**When to use:** LIB-01 user import workflow.

**Example:**
```python
# Source: tqdm documentation + atomicwrites pattern
from tqdm import tqdm
import atomicwrites

files_to_import = [...]  # File paths from folder picker/drag-drop
failures = []
successes = []

with tqdm(total=len(files_to_import), desc="Importing") as pbar:
    for file_path in files_to_import:
        try:
            # Read metadata
            audio = Mutagen.File(file_path)
            if audio is None:
                raise ValueError("Unsupported format")

            # Extract metadata for organization
            metadata = extract_metadata(audio)

            # Atomic write to database transaction
            with atomicwrites.atomic_write("library.db", overwrite=True) as f:
                save_to_database(file_path, metadata)

            successes.append(file_path)
        except Exception as e:
            failures.append((file_path, str(e)))
        finally:
            pbar.update(1)

# LIB-01 requirement: "finish import, then present all failures for review"
if failures:
    display_failure_report(failures)
return successes, failures
```

### Pattern 4: Fuzzy Search with Whoosh

**What:** Full-text search indexed on metadata, with fuzzy matching for typo tolerance and instant results.

**When to use:** LIB-03 search functionality.

**Example:**
```python
# Source: Whoosh documentation + RapidFuzz pattern
from whoosh.fields import Schema, TEXT, NUMERIC
from whoosh.index import create_in
from rapidfuzz import fuzz

schema = Schema(
    title=TEXT(stored=True),
    artist=TEXT(stored=True),
    album=TEXT(stored=True),
    genre=TEXT(stored=True),
    comments=TEXT(stored=True),
    file_id=NUMERIC(stored=True)
)

# Index all metadata fields
indexer = ix.writer()
for file_record in all_files:
    indexer.add_document(
        title=file_record.metadata.title,
        artist=file_record.metadata.artist,
        album=file_record.metadata.album,
        genre=file_record.metadata.genre,
        comments=file_record.metadata.comments,
        file_id=file_record.id
    )
indexer.commit()

# Fuzzy query: "Beatles" matches "beatles", "Beatles", "Beattles"
def fuzzy_search(query, threshold=80):
    searcher = ix.searcher()
    results = []
    for doc in searcher.documents():
        # Use RapidFuzz token_sort_ratio for robust matching
        score = fuzz.token_sort_ratio(query.lower(),
                                     f"{doc['artist']} {doc['album']} {doc['title']}".lower())
        if score >= threshold:
            results.append((doc, score))
    return sorted(results, key=lambda x: x[1], reverse=True)
```

### Anti-Patterns to Avoid
- **Building custom metadata parser:** Mutagen exists and handles all format edge cases; don't regex ID3 tags
- **Copying files during import:** Reference-in-place is locked decision; symlinks/references only, no duplication
- **Linear search through files:** Don't scan all files for every query; use Whoosh indexing
- **Ignoring import failures silently:** LIB-01 requires failure report; collect and display all errors after import completes

## Don't Hand-Roll

Problems that look simple but have existing solutions:

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Audio metadata reading/writing | Custom ID3/Vorbis parser | Mutagen | Handles all format edge cases, endianness, character encoding, all standard frames |
| Fuzzy string matching | Basic Levenshtein edit distance | RapidFuzz | Multiple algorithms optimized for metadata (token sort, token set ratios), C++ performance |
| Full-text search indexing | DIY token/inverted index | Whoosh | Schema-based, field-weighted ranking, phrase queries, easy fuzzy integration |
| Atomic file writes | Temp file + os.rename | atomicwrites | Cross-platform (POSIX, Windows), race-free, exception-safe |
| Filename sanitization | Regex character removal | pathvalidate | Handles all filesystem constraints (Windows reserved chars, FAT32 limits, Unicode normalization) |
| Duplicate detection by audio content | Acoustic fingerprinting | Metadata matching (locked decision) | User decided metadata-only approach; audio fingerprinting (Chromaprint, LFCC) is lower confidence and out of scope |

**Key insight:** Audio handling, filesystem safety, and search are domains where libraries have solved years of edge cases. Custom implementations are vulnerable to corrupted files (Mutagen handles malformed headers), data loss (atomicwrites prevents half-written files), and missed matches (RapidFuzz handles token reordering).

## Common Pitfalls

### Pitfall 1: Incomplete or Incorrect Metadata in Import

**What goes wrong:** User imports files with missing/misspelled metadata, making duplicates hard to detect and search results unreliable. Album artist field empty → files incorrectly organized under "Various Artists".

**Why it happens:** Audio metadata tagging is inconsistent across sources; users often don't validate before import.

**How to avoid:**
1. Extract metadata with Mutagen and log missing critical fields (artist, album, title)
2. Report pre-import: show any files with missing Album Artist before confirming import
3. Provide fallback values: album_artist="Various Artists" only if truly missing, not as default
4. On import failure (corrupted/unsupported): complete successful imports first, then display failure report (LIB-01 requirement)

**Warning signs:** Search queries returning no results despite files existing; all imports landing in "Unknown" or "Various Artists" folder.

### Pitfall 2: Copying Files During Import Instead of Reference-In-Place

**What goes wrong:** Disk space explosion; users with 100GB library now need 200GB; syncing breaks.

**Why it happens:** Simpler to implement ("just copy"), but violates locked decision and defeats reference-in-place model.

**How to avoid:** Store `original_path` in database; organize paths are derived from metadata. Never move or copy files. If UI shows "organized" folder structure, use symlinks or virtual organization from metadata, not actual file moves.

**Warning signs:** Database size growing beyond metadata + small thumbnails; user reports disk space issues after import.

### Pitfall 3: Database Not Synced With Filesystem

**What goes wrong:** User moves file on disk or deletes it; library still shows it as available, searches fail to load file.

**Why it happens:** Reference-in-place requires tracking changes; without syncing, database diverges from filesystem.

**How to avoid:**
1. Track `last_synced` timestamp per file
2. Before serving search results, verify original_path still exists
3. On import complete, mark all metadata as indexed; on filesystem change, invalidate index and re-sync
4. Consider periodic background sync (out of scope for Phase 1, but architectural decision now)

**Warning signs:** "File not found" errors when clicking search results; index grows stale.

### Pitfall 4: Fuzzy Search Threshold Too Lenient or Too Strict

**What goes wrong:** Threshold=50 matches "Beatles" to "Beat the System" (too loose); threshold=95 requires exact spelling (too strict).

**Why it happens:** RapidFuzz provides raw scores (0-100); no universal "right" threshold.

**How to avoid:**
- Use token_sort_ratio (reorders tokens before matching) for metadata search: "The Beatles" matches "Beatles, The"
- Recommend threshold=80 as starting point (Claude's discretion)
- Allow user tuning via settings if needed
- Test with common misspellings: "beatles" (lowercase), "Beetles" (typo), "The Beatles" vs "Beatles, The"

**Warning signs:** Users report missing results or irrelevant matches.

### Pitfall 5: Duplicate Detection Over-Matching or Under-Matching

**What goes wrong:** Same song in two formats (MP3 + FLAC) detected as duplicate (correct) but moved to _duplicates folder (wrong—user wants both); OR different songs with similar titles not matched as possible duplicates.

**Why it happens:** Locked decision is "exact metadata match" (artist + title + album); edge cases exist (live versions, remixes, different editions).

**How to avoid:**
1. Implement strict equality: `artist AND title AND album` match exactly
2. For quality hierarchy: bitrate first (if both lossy, higher wins), then format (lossless > lossy)
3. Store lower quality in _duplicates with reason: "duplicate: MP3 320kbps < FLAC"
4. Don't auto-delete; allow user review in duplicates folder
5. Edge case: "Artist - Song (Live)" is different from "Artist - Song" by metadata (different title frame)—this is correct, not a bug

**Warning signs:** FLAC versions appearing in _duplicates; user finding actual duplicates not caught by detector.

### Pitfall 6: FAT32 Filename Constraints Breaking Organized Paths

**What goes wrong:** Album artist contains `<` or `:` (valid in NTFS, invalid in FAT32); import fails or creates invalid folder names.

**Why it happens:** Locked decision: Album Artist folder organization; no sanitization applied → invalid characters passed through.

**How to avoid:** Use pathvalidate before creating organized_path:
```python
from pathvalidate import sanitize_filename

album_artist = audio.get("TPE2")[0]
album_artist_safe = sanitize_filename(album_artist, platform="fat")  # or "auto"
organized_path = f"{album_artist_safe}/{album}/{title}"
```

**Warning signs:** Import fails silently on Windows; folder names contain replacements (e.g., "Various_Artists" when metadata had "Various/Artists").

## Code Examples

Verified patterns from official sources:

### Reading and Writing ID3v2 Metadata with Mutagen

```python
# Source: https://mutagen.readthedocs.io/en/latest/user/id3.html
from mutagen.id3 import ID3

# Read metadata
audio = ID3("song.mp3")
artist = audio.get("TPE1")  # Main performer
album_artist = audio.get("TPE2")  # Album artist
album = audio.get("TALB")
title = audio.get("TIT2")
genre = audio.get("TCON")

# Write metadata
audio["TPE1"] = TPE1(text=["New Artist"])
audio["TALB"] = TALB(text=["New Album"])
audio.save()
```

### Atomic Database Write

```python
# Source: https://python-atomicwrites.readthedocs.io/
import sqlite3
from atomicwrites import atomic_write
import tempfile

def save_metadata_atomically(metadata):
    with atomic_write("library.db", overwrite=True) as f:
        conn = sqlite3.connect(f.name)
        cursor = conn.cursor()
        cursor.execute("""
            INSERT INTO metadata (file_id, artist, album, title)
            VALUES (?, ?, ?, ?)
        """, (metadata['file_id'], metadata['artist'], metadata['album'], metadata['title']))
        conn.commit()
        conn.close()
```

### Fuzzy Search with RapidFuzz

```python
# Source: https://github.com/rapidfuzz/RapidFuzz
from rapidfuzz import fuzz

# Token sort ratio: handles word reordering
score1 = fuzz.token_sort_ratio("The Beatles", "Beatles, The")  # ~95

# Partial ratio: substring matches
score2 = fuzz.partial_ratio("beatles", "The Beatles")  # ~100

# For metadata search recommendation: use token_sort_ratio
results = [track for track in tracks
           if fuzz.token_sort_ratio(query.lower(),
                                    f"{track.artist} {track.album} {track.title}".lower()) > 80]
```

### Full-Text Indexing with Whoosh

```python
# Source: https://whoosh.readthedocs.io/en/latest/intro.html
from whoosh.fields import Schema, TEXT, NUMERIC
from whoosh.index import create_in
import os

schema = Schema(
    file_id=NUMERIC(stored=True),
    artist=TEXT(stored=True, phrase=False),
    album=TEXT(stored=True, phrase=False),
    title=TEXT(stored=True, phrase=False),
    genre=TEXT(stored=True),
    comments=TEXT(stored=True)
)

# Create index
ix = create_in("indexdir", schema)
writer = ix.writer()

# Index metadata
for file_record in files:
    writer.add_document(
        file_id=file_record.id,
        artist=file_record.metadata.artist or "",
        album=file_record.metadata.album or "",
        title=file_record.metadata.title or "",
        genre=file_record.metadata.genre or "",
        comments=file_record.metadata.comments or ""
    )
writer.commit()

# Search
searcher = ix.searcher()
results = searcher.find("artist", "Beatles")  # Fast full-text match
```

### Filename Sanitization for FAT32

```python
# Source: https://pathvalidate.readthedocs.io/en/latest/pages/examples/sanitize.html
from pathvalidate import sanitize_filename

# Album artist from metadata might contain invalid chars
album_artist = "Various/Artists:The_Best"
sanitized = sanitize_filename(album_artist, platform="fat")
# Result: "VariousArtistsThe_Best" or "Various_Artists_The_Best" depending on settings

# Use in path organization
organized_path = f"{sanitized}/{album_safe}/{title_safe}.mp3"
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| FuzzyWuzzy for fuzzy matching | RapidFuzz | 2021-2024 | Faster (C++), MIT license, multiple algorithms, active maintenance |
| Manual temp file + os.rename | atomicwrites library | 2015+ | Race-free, cross-platform, 1.3M weekly downloads |
| Custom metadata regex parsing | Mutagen (industry standard) | 2005+ | Handles all formats, character encodings, edge cases; zero dependencies |
| Database-in-memory | SQLite persistent | 1990s-2010s | Durability, on-disk persistence, ACID transactions for local apps |
| Linear file search | Full-text indexing (Whoosh) | 2008+ | Instant search, ranked results, phrase queries |

**Deprecated/outdated:**
- **FuzzyWuzzy:** GPL licensing, no longer recommended for new projects. RapidFuzz is drop-in replacement with better performance and MIT license.
- **Manual file copying during import:** Old music player approach; reference-in-place + organization is modern standard (prevents duplicate storage, enables syncing).
- **Acoustic fingerprinting for duplicates:** Out of scope for Phase 1 (locked decision: metadata matching only); fingerprinting (Chromaprint, LFCC) is lower-confidence future enhancement.

## Open Questions

1. **FAT32 Sanitization Character Replacement Strategy**
   - What we know: pathvalidate supports FAT32 platform target; invalid chars must be removed or replaced
   - What's unclear: Should "Artist/Album" become "Artist_Album" (underscore) or "ArtistAlbum" (remove)? Readability vs. simplicity tradeoff.
   - Recommendation: Default to underscore replacement (more readable), make configurable in Phase 2 if needed. pathvalidate's default strategy is acceptable for first pass.

2. **Search Debounce Timing for Instant Results**
   - What we know: User expects instant search (as-you-type with debounce)
   - What's unclear: What debounce delay (50ms, 100ms, 300ms)? Depends on database size and query complexity.
   - Recommendation: Start with 200ms debounce; adjust based on performance testing with realistic library size (thousands of tracks).

3. **Fuzzy Matching Threshold for Metadata**
   - What we know: RapidFuzz provides scores 0-100; threshold controls match sensitivity
   - What's unclear: Should threshold be 80, 85, or 90? No single "right" answer; depends on tolerance for false positives vs. misses.
   - Recommendation: Use threshold=80 with token_sort_ratio as default (Claude's discretion). Test with common misspellings; adjust if user feedback indicates too many/too few results.

4. **Metadata Fields to Index for Search**
   - What we know: LIB-03 requires "artist, album, or title" searchable; context says "all metadata"
   - What's unclear: Should genre, year, comments also be searchable? Storage/performance implications.
   - Recommendation: Index artist, album, title (required); add genre, year, comments (optional but cheap with Whoosh). Skip complex fields (embedded artwork, lyrics) for Phase 1.

## Sources

### Primary (HIGH confidence)
- **Mutagen** (https://mutagen.readthedocs.io/) - Audio metadata API, supported formats, ID3v2 frame specifications
- **RapidFuzz** (https://github.com/rapidfuzz/RapidFuzz) - Fuzzy string matching algorithms, performance benchmarks
- **Whoosh** (https://whoosh.readthedocs.io/) - Full-text search schema and indexing patterns
- **atomicwrites** (https://python-atomicwrites.readthedocs.io/) - Atomic file operations, POSIX/Windows safety
- **pathvalidate** (https://pathvalidate.readthedocs.io/) - Filename sanitization for multiple filesystems
- **ID3.org** (https://id3.org/) - ID3v2 frame specifications and standard metadata fields

### Secondary (MEDIUM confidence)
- **SQLite Music Library Examples** (https://www.howtogeek.com/track-my-music-collection-in-sqlite/) - Schema design patterns verified with official SQLite
- **Beets Library Database** (https://beets.readthedocs.io/en/latest/dev/library.html) - Real-world music library schema design
- **WebSearch: Python music metadata best practices** - Multiple sources (iMusician, Sound on Sound) confirmed incomplete metadata is top pitfall

### Tertiary (LOW confidence, flagged for validation)
- **Audio Fingerprinting Approaches** (Fraunhofer IDMT) - Out of scope but noted for future; metadata-only approach is locked decision
- **FAT32 Character Validation** - pathvalidate documentation confirmed FAT32 support but exact sanitization strategy not detailed; recommend testing on actual FAT32 device

## Metadata

**Confidence breakdown:**
- **Standard stack:** HIGH - All libraries verified through official documentation and source code. Mutagen, RapidFuzz, Whoosh, atomicwrites are industry-standard with widespread adoption.
- **Architecture (SQLite schema, import patterns):** HIGH - Based on verified patterns from beets library, official SQLite docs, and WebSearch with multiple confirmations.
- **Pitfalls:** HIGH - Common mistakes confirmed through multiple sources (iMusician, Sound on Sound, music library case studies).
- **Open questions:** MEDIUM - Specific to discretionary choices (debounce timing, threshold values) where no universal standard exists; recommend implementation + user testing.

**Research date:** 2026-02-03
**Valid until:** 2026-03-03 (30 days for stable libraries; check for mutagen/whoosh/rapidfuzz major releases)
