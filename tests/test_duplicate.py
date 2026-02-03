"""
TDD test suite for duplicate detection.

Tests cover:
- Exact metadata matching (artist + title + album, case-insensitive)
- Quality hierarchy comparison (lossless > lossy, then by bitrate)
- Finding duplicates for a given file
- Marking all duplicates in library
- Organizing duplicates in _duplicates review folder

Test cases from plan:
1. Same track, different formats (MP3 vs FLAC)
2. Same track, different bitrates (both lossy)
3. Exact same quality (earlier import wins)
4. Different titles (not duplicates)
5. No duplicates
6. Multiple duplicates of same track
7. Case-insensitive matching
"""

import pytest
import tempfile
import os
from pathlib import Path
from datetime import datetime


class TestIsDuplicate:
    """Tests for is_duplicate() function - exact metadata matching."""

    def test_exact_match_is_duplicate(self):
        """Exact artist/title/album match returns True."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        meta2 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        assert is_duplicate(meta1, meta2) is True

    def test_case_insensitive_match(self):
        """Case-insensitive matching returns True."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        meta2 = {"artist": "the beatles", "title": "hey jude", "album": "hey jude"}
        assert is_duplicate(meta1, meta2) is True

    def test_mixed_case_match(self):
        """Mixed case matching works correctly."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "THE BEATLES", "title": "HEY JUDE", "album": "HEY JUDE"}
        meta2 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        assert is_duplicate(meta1, meta2) is True

    def test_different_artist_not_duplicate(self):
        """Different artist returns False."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        meta2 = {"artist": "The Rolling Stones", "title": "Hey Jude", "album": "Hey Jude"}
        assert is_duplicate(meta1, meta2) is False

    def test_different_title_not_duplicate(self):
        """Different title returns False (Live vs Studio)."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        meta2 = {"artist": "The Beatles", "title": "Hey Jude (Live)", "album": "Hey Jude"}
        assert is_duplicate(meta1, meta2) is False

    def test_different_album_not_duplicate(self):
        """Different album returns False."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        meta2 = {"artist": "The Beatles", "title": "Hey Jude", "album": "1 (Compilation)"}
        assert is_duplicate(meta1, meta2) is False

    def test_whitespace_trimmed(self):
        """Whitespace around values is trimmed before comparison."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        meta2 = {"artist": " The Beatles ", "title": " Hey Jude ", "album": " Hey Jude "}
        assert is_duplicate(meta1, meta2) is True

    def test_none_values_handled(self):
        """None values are handled gracefully (not duplicates if either has None)."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "Hey Jude", "album": "Hey Jude"}
        meta2 = {"artist": "The Beatles", "title": None, "album": "Hey Jude"}
        assert is_duplicate(meta1, meta2) is False

    def test_empty_string_not_duplicate_of_none(self):
        """Empty string and None are not considered equal."""
        from src.library.duplicate import is_duplicate

        meta1 = {"artist": "The Beatles", "title": "", "album": "Hey Jude"}
        meta2 = {"artist": "The Beatles", "title": None, "album": "Hey Jude"}
        assert is_duplicate(meta1, meta2) is False


class TestCompareQuality:
    """Tests for compare_quality() function - quality hierarchy."""

    def test_lossless_beats_lossy(self):
        """FLAC (lossless) beats MP3 (lossy) regardless of bitrate."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "flac", "bitrate": 1000}
        meta2 = {"format": "mp3", "bitrate": 320}
        assert compare_quality(meta1, meta2) == "file1_better"

    def test_lossy_loses_to_lossless(self):
        """MP3 (lossy) loses to FLAC (lossless)."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "mp3", "bitrate": 320}
        meta2 = {"format": "flac", "bitrate": 1000}
        assert compare_quality(meta1, meta2) == "file2_better"

    def test_wav_lossless_beats_mp3(self):
        """WAV (lossless) beats MP3."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "wav", "bitrate": 1411}
        meta2 = {"format": "mp3", "bitrate": 320}
        assert compare_quality(meta1, meta2) == "file1_better"

    def test_alac_lossless_beats_aac(self):
        """ALAC (lossless) beats AAC (lossy)."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "alac", "bitrate": 1000}
        meta2 = {"format": "aac", "bitrate": 256}
        assert compare_quality(meta1, meta2) == "file1_better"

    def test_higher_bitrate_wins_same_format(self):
        """Higher bitrate MP3 beats lower bitrate MP3."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "mp3", "bitrate": 320}
        meta2 = {"format": "mp3", "bitrate": 128}
        assert compare_quality(meta1, meta2) == "file1_better"

    def test_lower_bitrate_loses_same_format(self):
        """Lower bitrate MP3 loses to higher bitrate MP3."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "mp3", "bitrate": 128}
        meta2 = {"format": "mp3", "bitrate": 320}
        assert compare_quality(meta1, meta2) == "file2_better"

    def test_equal_quality_same_format_same_bitrate(self):
        """Same format and bitrate returns equal."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "mp3", "bitrate": 320}
        meta2 = {"format": "mp3", "bitrate": 320}
        assert compare_quality(meta1, meta2) == "equal"

    def test_equal_quality_both_lossless(self):
        """Both lossless with same bitrate returns equal."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "flac", "bitrate": 1000}
        meta2 = {"format": "flac", "bitrate": 1000}
        assert compare_quality(meta1, meta2) == "equal"

    def test_case_insensitive_format(self):
        """Format comparison is case-insensitive."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "FLAC", "bitrate": 1000}
        meta2 = {"format": "mp3", "bitrate": 320}
        assert compare_quality(meta1, meta2) == "file1_better"

    def test_missing_bitrate_handled(self):
        """Missing bitrate is treated as 0."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "mp3", "bitrate": 320}
        meta2 = {"format": "mp3", "bitrate": None}
        assert compare_quality(meta1, meta2) == "file1_better"

    def test_m4a_lossy(self):
        """M4A (typically AAC container) is lossy."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "flac", "bitrate": 1000}
        meta2 = {"format": "m4a", "bitrate": 256}
        assert compare_quality(meta1, meta2) == "file1_better"

    def test_ogg_lossy(self):
        """OGG (Vorbis) is lossy."""
        from src.library.duplicate import compare_quality

        meta1 = {"format": "flac", "bitrate": 1000}
        meta2 = {"format": "ogg", "bitrate": 320}
        assert compare_quality(meta1, meta2) == "file1_better"


class TestFindDuplicates:
    """Tests for find_duplicates() function - finding duplicates of a given file."""

    @pytest.fixture
    def test_db(self, tmp_path):
        """Set up a temporary test database."""
        from src.library.database import set_db_path, init_database

        db_path = tmp_path / "test_library.db"
        set_db_path(db_path)
        init_database()
        yield db_path
        # Cleanup happens automatically with tmp_path

    def test_find_duplicate_different_formats(self, test_db):
        """Find MP3 duplicate of FLAC file."""
        from src.library.duplicate import find_duplicates
        from src.library.database import save_file_record

        # Create FLAC file (higher quality)
        file_id1 = save_file_record(
            "/test/song.flac",
            "Artist/Album/Song.flac",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "flac",
                "bitrate": 1000
            }
        )

        # Create MP3 file (lower quality, same metadata)
        file_id2 = save_file_record(
            "/test/song.mp3",
            "Artist/Album/Song.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Find duplicates of FLAC
        duplicates = find_duplicates(file_id1)

        assert len(duplicates) == 1
        assert duplicates[0][0] == file_id2  # duplicate file ID
        assert "worse_format" in duplicates[0][1]  # reason

    def test_find_duplicate_different_bitrates(self, test_db):
        """Find lower bitrate MP3 as duplicate of higher bitrate MP3."""
        from src.library.duplicate import find_duplicates
        from src.library.database import save_file_record

        # Create 320kbps MP3 (higher quality)
        file_id1 = save_file_record(
            "/test/song_320.mp3",
            "Artist/Album/Song_320.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Create 128kbps MP3 (lower quality, same metadata)
        file_id2 = save_file_record(
            "/test/song_128.mp3",
            "Artist/Album/Song_128.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 128
            }
        )

        # Find duplicates of 320kbps
        duplicates = find_duplicates(file_id1)

        assert len(duplicates) == 1
        assert duplicates[0][0] == file_id2
        assert "lower_bitrate" in duplicates[0][1]

    def test_find_duplicate_equal_quality_earlier_wins(self, test_db):
        """Earlier import is primary when quality is equal."""
        from src.library.duplicate import find_duplicates
        from src.library.database import save_file_record
        import time

        # Create first MP3 (earlier import)
        file_id1 = save_file_record(
            "/test/song_first.mp3",
            "Artist/Album/Song_first.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Small delay to ensure different timestamps
        time.sleep(0.01)

        # Create second MP3 (later import, same quality)
        file_id2 = save_file_record(
            "/test/song_second.mp3",
            "Artist/Album/Song_second.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Find duplicates of first file
        duplicates = find_duplicates(file_id1)

        assert len(duplicates) == 1
        assert duplicates[0][0] == file_id2
        assert "duplicate_of_earlier_import" in duplicates[0][1]

    def test_no_duplicates_different_title(self, test_db):
        """Different titles are not duplicates."""
        from src.library.duplicate import find_duplicates
        from src.library.database import save_file_record

        file_id1 = save_file_record(
            "/test/song.mp3",
            "Artist/Album/Song.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Different title (Live version)
        save_file_record(
            "/test/song_live.mp3",
            "Artist/Album/Song (Live).mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song (Live)",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        duplicates = find_duplicates(file_id1)
        assert len(duplicates) == 0

    def test_no_duplicates_single_file(self, test_db):
        """Single file has no duplicates."""
        from src.library.duplicate import find_duplicates
        from src.library.database import save_file_record

        file_id1 = save_file_record(
            "/test/song.mp3",
            "Artist/Album/Song.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        duplicates = find_duplicates(file_id1)
        assert len(duplicates) == 0

    def test_multiple_duplicates_of_same_track(self, test_db):
        """Find multiple duplicates of a high quality file."""
        from src.library.duplicate import find_duplicates
        from src.library.database import save_file_record

        # Create FLAC (highest quality)
        file_id1 = save_file_record(
            "/test/song.flac",
            "Artist/Album/Song.flac",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "flac",
                "bitrate": 1000
            }
        )

        # Create MP3 320kbps
        file_id2 = save_file_record(
            "/test/song_320.mp3",
            "Artist/Album/Song_320.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Create MP3 128kbps
        file_id3 = save_file_record(
            "/test/song_128.mp3",
            "Artist/Album/Song_128.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 128
            }
        )

        # Find duplicates of FLAC
        duplicates = find_duplicates(file_id1)

        assert len(duplicates) == 2
        duplicate_ids = [d[0] for d in duplicates]
        assert file_id2 in duplicate_ids
        assert file_id3 in duplicate_ids

    def test_case_insensitive_metadata_matching(self, test_db):
        """Duplicate detection is case-insensitive."""
        from src.library.duplicate import find_duplicates
        from src.library.database import save_file_record

        file_id1 = save_file_record(
            "/test/song.flac",
            "Artist/Album/Song.flac",
            False,
            {
                "artist": "The Beatles",
                "title": "Hey Jude",
                "album": "Hey Jude",
                "format": "flac",
                "bitrate": 1000
            }
        )

        file_id2 = save_file_record(
            "/test/song.mp3",
            "Artist/Album/Song.mp3",
            False,
            {
                "artist": "the beatles",
                "title": "hey jude",
                "album": "hey jude",
                "format": "mp3",
                "bitrate": 320
            }
        )

        duplicates = find_duplicates(file_id1)
        assert len(duplicates) == 1
        assert duplicates[0][0] == file_id2


class TestMarkAllDuplicates:
    """Tests for mark_all_duplicates() function - scanning entire library."""

    @pytest.fixture
    def test_db(self, tmp_path):
        """Set up a temporary test database."""
        from src.library.database import set_db_path, init_database

        db_path = tmp_path / "test_library.db"
        set_db_path(db_path)
        init_database()
        yield db_path

    def test_mark_all_duplicates_basic(self, test_db):
        """Mark all duplicates in library."""
        from src.library.duplicate import mark_all_duplicates
        from src.library.database import save_file_record, get_duplicates

        # Create FLAC and MP3 of same track
        save_file_record(
            "/test/song.flac",
            "Artist/Album/Song.flac",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "flac",
                "bitrate": 1000
            }
        )

        save_file_record(
            "/test/song.mp3",
            "Artist/Album/Song.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Mark all duplicates
        count = mark_all_duplicates()

        assert count == 1

        # Verify duplicate record created
        duplicates = get_duplicates(reviewed=False)
        assert len(duplicates) == 1

    def test_mark_all_duplicates_no_duplicates(self, test_db):
        """No duplicates returns 0."""
        from src.library.duplicate import mark_all_duplicates
        from src.library.database import save_file_record

        save_file_record(
            "/test/song1.mp3",
            "Artist1/Album1/Song1.mp3",
            False,
            {
                "artist": "Artist One",
                "title": "Song One",
                "album": "Album One",
                "format": "mp3",
                "bitrate": 320
            }
        )

        save_file_record(
            "/test/song2.mp3",
            "Artist2/Album2/Song2.mp3",
            False,
            {
                "artist": "Artist Two",
                "title": "Song Two",
                "album": "Album Two",
                "format": "mp3",
                "bitrate": 320
            }
        )

        count = mark_all_duplicates()
        assert count == 0

    def test_mark_all_duplicates_multiple_groups(self, test_db):
        """Handle multiple duplicate groups in library."""
        from src.library.duplicate import mark_all_duplicates
        from src.library.database import save_file_record, get_duplicates

        # Group 1: Two versions of Song A
        save_file_record(
            "/test/songA.flac",
            "Artist/AlbumA/SongA.flac",
            False,
            {
                "artist": "Artist",
                "title": "Song A",
                "album": "Album A",
                "format": "flac",
                "bitrate": 1000
            }
        )
        save_file_record(
            "/test/songA.mp3",
            "Artist/AlbumA/SongA.mp3",
            False,
            {
                "artist": "Artist",
                "title": "Song A",
                "album": "Album A",
                "format": "mp3",
                "bitrate": 320
            }
        )

        # Group 2: Two versions of Song B
        save_file_record(
            "/test/songB.flac",
            "Artist/AlbumB/SongB.flac",
            False,
            {
                "artist": "Artist",
                "title": "Song B",
                "album": "Album B",
                "format": "flac",
                "bitrate": 1000
            }
        )
        save_file_record(
            "/test/songB.mp3",
            "Artist/AlbumB/SongB.mp3",
            False,
            {
                "artist": "Artist",
                "title": "Song B",
                "album": "Album B",
                "format": "mp3",
                "bitrate": 320
            }
        )

        count = mark_all_duplicates()
        assert count == 2

        duplicates = get_duplicates()
        assert len(duplicates) == 2


class TestOrganizeDuplicatesForReview:
    """Tests for organize_duplicates_for_review() - creating manifest in _duplicates folder."""

    @pytest.fixture
    def test_env(self, tmp_path, monkeypatch):
        """Set up test environment with temp directories."""
        from src.library.database import set_db_path, init_database

        db_path = tmp_path / "test_library.db"
        set_db_path(db_path)
        init_database()

        # Set DUPLICATES_FOLDER to temp path
        duplicates_folder = tmp_path / "_duplicates"
        monkeypatch.setenv("DUPLICATES_FOLDER", str(duplicates_folder))

        yield {
            "db_path": db_path,
            "duplicates_folder": duplicates_folder,
            "tmp_path": tmp_path
        }

    def test_organize_creates_duplicates_folder(self, test_env):
        """Creates _duplicates folder if it doesn't exist."""
        from src.library.duplicate import organize_duplicates_for_review

        assert not test_env["duplicates_folder"].exists()

        organize_duplicates_for_review()

        assert test_env["duplicates_folder"].exists()

    def test_organize_creates_manifest(self, test_env):
        """Creates manifest file with duplicate information."""
        from src.library.duplicate import organize_duplicates_for_review, mark_all_duplicates
        from src.library.database import save_file_record

        # Create duplicate pair
        save_file_record(
            "/test/song.flac",
            "Artist/Album/Song.flac",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "flac",
                "bitrate": 1000
            }
        )

        save_file_record(
            "/test/song.mp3",
            "Artist/Album/Song.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        mark_all_duplicates()
        organize_duplicates_for_review()

        manifest = test_env["duplicates_folder"] / "duplicates_manifest.txt"
        assert manifest.exists()

    def test_manifest_contains_duplicate_info(self, test_env):
        """Manifest contains primary file, duplicate file, and reason."""
        from src.library.duplicate import organize_duplicates_for_review, mark_all_duplicates
        from src.library.database import save_file_record

        save_file_record(
            "/test/song.flac",
            "Artist/Album/Song.flac",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "flac",
                "bitrate": 1000
            }
        )

        save_file_record(
            "/test/song.mp3",
            "Artist/Album/Song.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        mark_all_duplicates()
        organize_duplicates_for_review()

        manifest = test_env["duplicates_folder"] / "duplicates_manifest.txt"
        content = manifest.read_text()

        # Should contain paths and reason
        assert "/test/song.flac" in content or "song.flac" in content  # Primary
        assert "/test/song.mp3" in content or "song.mp3" in content    # Duplicate
        assert "worse_format" in content  # Reason

    def test_manifest_groups_by_primary(self, test_env):
        """Manifest groups duplicates by their primary file."""
        from src.library.duplicate import organize_duplicates_for_review, mark_all_duplicates
        from src.library.database import save_file_record

        # FLAC with two MP3 duplicates
        save_file_record(
            "/test/song.flac",
            "Artist/Album/Song.flac",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "flac",
                "bitrate": 1000
            }
        )

        save_file_record(
            "/test/song_320.mp3",
            "Artist/Album/Song_320.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 320
            }
        )

        save_file_record(
            "/test/song_128.mp3",
            "Artist/Album/Song_128.mp3",
            False,
            {
                "artist": "Test Artist",
                "title": "Test Song",
                "album": "Test Album",
                "format": "mp3",
                "bitrate": 128
            }
        )

        mark_all_duplicates()
        organize_duplicates_for_review()

        manifest = test_env["duplicates_folder"] / "duplicates_manifest.txt"
        content = manifest.read_text()

        # Both duplicates should reference the same primary
        assert content.count("song.flac") >= 1  # Primary mentioned at least once
        assert "song_320.mp3" in content
        assert "song_128.mp3" in content


class TestGetDuplicateReason:
    """Tests for get_duplicate_reason() - generating human-readable reasons."""

    def test_reason_worse_format(self):
        """Returns 'worse_format' when lossy vs lossless."""
        from src.library.duplicate import get_duplicate_reason

        primary = {"format": "flac", "bitrate": 1000}
        duplicate = {"format": "mp3", "bitrate": 320}

        reason = get_duplicate_reason(primary, duplicate)
        assert reason == "worse_format"

    def test_reason_lower_bitrate(self):
        """Returns 'lower_bitrate' when same format, lower bitrate."""
        from src.library.duplicate import get_duplicate_reason

        primary = {"format": "mp3", "bitrate": 320}
        duplicate = {"format": "mp3", "bitrate": 128}

        reason = get_duplicate_reason(primary, duplicate)
        assert reason == "lower_bitrate"

    def test_reason_duplicate_of_earlier_import(self):
        """Returns 'duplicate_of_earlier_import' when equal quality."""
        from src.library.duplicate import get_duplicate_reason

        primary = {"format": "mp3", "bitrate": 320}
        duplicate = {"format": "mp3", "bitrate": 320}

        reason = get_duplicate_reason(primary, duplicate)
        assert reason == "duplicate_of_earlier_import"
