"""
TDD test suite for FAT32 filename sanitization.

Tests cover:
- FAT32-invalid character replacement (slashes, colons, reserved chars)
- Windows reserved names (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
- Length truncation (255 char limit per component)
- Leading dots/spaces stripped
- Full path construction from metadata
- Edge cases (empty strings, whitespace-only, unicode)
"""

import pytest
from src.library.sanitizer import sanitize_filename, sanitize_path


class TestSanitizeFilename:
    """Tests for sanitize_filename() function."""

    def test_sanitize_slashes(self):
        """Forward slashes are replaced with underscores."""
        assert sanitize_filename("AC/DC") == "AC_DC"

    def test_sanitize_backslashes(self):
        """Backslashes are replaced with underscores."""
        assert sanitize_filename("AC\\DC") == "AC_DC"

    def test_sanitize_colons(self):
        """Colons are replaced with underscores."""
        assert sanitize_filename("Artist: The Best") == "Artist_ The Best"

    def test_sanitize_reserved_chars_angle_brackets(self):
        """Angle brackets are replaced with underscores."""
        assert sanitize_filename("Song <2024>") == "Song _2024_"

    def test_sanitize_reserved_chars_pipe(self):
        """Pipe character is replaced with underscore."""
        assert sanitize_filename("Song | Remix") == "Song _ Remix"

    def test_sanitize_reserved_chars_question(self):
        """Question mark is replaced with underscore."""
        assert sanitize_filename("Why?") == "Why_"

    def test_sanitize_reserved_chars_asterisk(self):
        """Asterisk is replaced with underscore."""
        assert sanitize_filename("Best * Ever") == "Best _ Ever"

    def test_sanitize_reserved_chars_quotes(self):
        """Double quotes are replaced with underscores."""
        assert sanitize_filename('Song "Live"') == "Song _Live_"

    def test_multiple_invalid_chars(self):
        """Multiple invalid characters in sequence are each replaced."""
        assert sanitize_filename("AC/DC: <Best>") == "AC_DC_ _Best_"


class TestWindowsReservedNames:
    """Tests for Windows reserved name handling."""

    def test_reserved_name_con(self):
        """CON is prefixed with underscore."""
        assert sanitize_filename("CON") == "_CON"

    def test_reserved_name_prn(self):
        """PRN is prefixed with underscore."""
        assert sanitize_filename("PRN") == "_PRN"

    def test_reserved_name_aux(self):
        """AUX is prefixed with underscore."""
        assert sanitize_filename("AUX") == "_AUX"

    def test_reserved_name_nul(self):
        """NUL is prefixed with underscore."""
        assert sanitize_filename("NUL") == "_NUL"

    def test_reserved_name_com1(self):
        """COM1 is prefixed with underscore."""
        assert sanitize_filename("COM1") == "_COM1"

    def test_reserved_name_com9(self):
        """COM9 is prefixed with underscore."""
        assert sanitize_filename("COM9") == "_COM9"

    def test_reserved_name_lpt1(self):
        """LPT1 is prefixed with underscore."""
        assert sanitize_filename("LPT1") == "_LPT1"

    def test_reserved_name_lpt9(self):
        """LPT9 is prefixed with underscore."""
        assert sanitize_filename("LPT9") == "_LPT9"

    def test_reserved_name_case_insensitive(self):
        """Reserved names are detected case-insensitively."""
        assert sanitize_filename("con") == "_con"
        assert sanitize_filename("Con") == "_Con"

    def test_reserved_name_with_extension(self):
        """Reserved names with extensions are handled."""
        # CON.txt would still be reserved on Windows
        assert sanitize_filename("CON.txt") == "_CON.txt"


class TestNoSanitizationNeeded:
    """Tests for strings that don't need sanitization."""

    def test_normal_artist_name(self):
        """Normal artist names pass through unchanged."""
        assert sanitize_filename("The Beatles") == "The Beatles"

    def test_normal_album_name(self):
        """Normal album names pass through unchanged."""
        assert sanitize_filename("Abbey Road") == "Abbey Road"

    def test_numbers_and_letters(self):
        """Alphanumeric strings pass through unchanged."""
        assert sanitize_filename("Track 01") == "Track 01"

    def test_hyphens_allowed(self):
        """Hyphens are valid and pass through."""
        assert sanitize_filename("Song - Remix") == "Song - Remix"

    def test_parentheses_allowed(self):
        """Parentheses are valid and pass through."""
        assert sanitize_filename("Song (Live)") == "Song (Live)"

    def test_unicode_allowed(self):
        """Unicode characters are valid and pass through."""
        assert sanitize_filename("Bjork") == "Bjork"
        assert sanitize_filename("Cafe del Mar") == "Cafe del Mar"


class TestLengthTruncation:
    """Tests for filename length limits."""

    def test_length_truncation_255(self):
        """Filenames longer than 255 chars are truncated."""
        long_name = "A" * 300
        result = sanitize_filename(long_name)
        assert len(result) <= 255

    def test_exact_255_chars_unchanged(self):
        """Exactly 255 char filenames pass through."""
        exact_name = "A" * 255
        result = sanitize_filename(exact_name)
        assert len(result) == 255

    def test_short_names_unchanged(self):
        """Short filenames are not affected by truncation."""
        short_name = "Short"
        result = sanitize_filename(short_name)
        assert result == "Short"


class TestLeadingDotsAndSpaces:
    """Tests for leading dots and spaces handling."""

    def test_leading_dot_stripped(self):
        """Leading dots are stripped."""
        assert sanitize_filename(".hidden") == "hidden"

    def test_multiple_leading_dots_stripped(self):
        """Multiple leading dots are stripped."""
        assert sanitize_filename("..hidden") == "hidden"

    def test_leading_space_stripped(self):
        """Leading spaces are stripped."""
        assert sanitize_filename(" song") == "song"

    def test_trailing_space_stripped(self):
        """Trailing spaces are stripped."""
        assert sanitize_filename("song ") == "song"

    def test_trailing_dot_stripped(self):
        """Trailing dots are stripped."""
        assert sanitize_filename("song.") == "song"


class TestEdgeCases:
    """Tests for edge cases and boundary conditions."""

    def test_empty_string_returns_unknown(self):
        """Empty string returns 'unknown' placeholder."""
        assert sanitize_filename("") == "unknown"

    def test_whitespace_only_returns_unknown(self):
        """Whitespace-only string returns 'unknown' placeholder."""
        assert sanitize_filename("   ") == "unknown"

    def test_only_invalid_chars_returns_unknown(self):
        """String of only invalid chars returns 'unknown'."""
        assert sanitize_filename("/<>:") == "unknown"

    def test_none_input_handled(self):
        """None input is handled gracefully."""
        assert sanitize_filename(None) == "unknown"


class TestSanitizePath:
    """Tests for sanitize_path() full path construction."""

    def test_full_path_construction_basic(self):
        """Basic path construction from metadata."""
        result = sanitize_path("AC/DC", "Back in Black", "Thunderstruck", ".mp3")
        assert result == "AC_DC/Back in Black/Thunderstruck.mp3"

    def test_full_path_with_colons(self):
        """Path construction with colons in album."""
        result = sanitize_path(
            "Various Artists",
            "Compilation: The Best",
            "Track 1",
            ".mp3"
        )
        assert result == "Various Artists/Compilation_ The Best/Track 1.mp3"

    def test_full_path_default_extension(self):
        """Default extension is .mp3."""
        result = sanitize_path("Artist", "Album", "Title")
        assert result == "Artist/Album/Title.mp3"

    def test_full_path_with_flac_extension(self):
        """Custom extension works."""
        result = sanitize_path("Artist", "Album", "Title", ".flac")
        assert result == "Artist/Album/Title.flac"

    def test_full_path_all_components_sanitized(self):
        """All path components are sanitized."""
        result = sanitize_path(
            "Artist/Name",
            "Album: Best",
            "Song <Live>",
            ".mp3"
        )
        assert result == "Artist_Name/Album_ Best/Song _Live_.mp3"

    def test_full_path_with_reserved_names(self):
        """Reserved names in components are handled."""
        result = sanitize_path("CON", "AUX", "NUL", ".mp3")
        assert result == "_CON/_AUX/_NUL.mp3"

    def test_full_path_preserves_extension(self):
        """Extension is not sanitized (dots allowed in extension)."""
        result = sanitize_path("Artist", "Album", "Title", ".m4a")
        assert result == "Artist/Album/Title.m4a"
