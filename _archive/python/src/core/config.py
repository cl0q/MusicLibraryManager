"""
Configuration module for music library paths and settings.

Manages library paths, search settings, and other configuration.
Uses environment variables with fallback defaults.
Loads .env file if present (python-dotenv).

Directory structure:
- LIBRARY_ROOT: Base directory for all library files
- SOUNDCLOUD_FOLDER: Separate folder for SoundCloud content (playlist-based organization)
- ARCHIVE_FOLDER: Original files organized by Album Artist/Album/Track
- DUPLICATES_FOLDER: Lower quality duplicates moved here for review
- WHOOSH_INDEX_DIR: Full-text search index location
"""

import os
from pathlib import Path

# Try to load .env file if python-dotenv is available
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    # python-dotenv not installed, continue with environment variables only
    pass


# Library paths
LIBRARY_ROOT = Path(os.getenv(
    "LIBRARY_ROOT",
    os.path.expanduser("~/Music/MusicLibrary")
))

# Database location
LIBRARY_DB_PATH = Path(os.getenv(
    "LIBRARY_DB_PATH",
    str(LIBRARY_ROOT / "library.db")
))

# SoundCloud content lives in separate folder structure
# (organized by playlists, order, genre rather than Artist/Album)
SOUNDCLOUD_FOLDER = Path(os.getenv(
    "SOUNDCLOUD_FOLDER",
    str(LIBRARY_ROOT / "SoundCloud")
))

# Original files organized by Album Artist/Album/Track
ARCHIVE_FOLDER = Path(os.getenv(
    "ARCHIVE_FOLDER",
    str(LIBRARY_ROOT / "Archive")
))

# Lower quality duplicates moved here for review (not auto-deleted)
DUPLICATES_FOLDER = Path(os.getenv(
    "DUPLICATES_FOLDER",
    str(LIBRARY_ROOT / "_duplicates")
))

# Full-text search index (Whoosh) location
WHOOSH_INDEX_DIR = Path(os.getenv(
    "WHOOSH_INDEX_DIR",
    str(LIBRARY_ROOT / ".index")
))


# Search settings
# RapidFuzz matching threshold (0-100)
# Recommended: 80 for typo tolerance without too many false positives
SEARCH_FUZZY_THRESHOLD = int(os.getenv("SEARCH_FUZZY_THRESHOLD", "80"))

# Instant search debounce delay in milliseconds
# Recommended: 200ms for responsive feel without excessive queries
SEARCH_DEBOUNCE_MS = int(os.getenv("SEARCH_DEBOUNCE_MS", "200"))


# Quality hierarchy for duplicate resolution
# Higher index = higher quality
FORMAT_QUALITY_ORDER = [
    'mp3',      # Lossy
    'aac',      # Lossy (better at same bitrate)
    'm4a',      # Lossy (AAC container)
    'ogg',      # Lossy (Vorbis)
    'opus',     # Lossy (very efficient)
    'flac',     # Lossless
    'alac',     # Lossless (Apple)
    'wav',      # Lossless (uncompressed)
    'aiff',     # Lossless (uncompressed)
]


def init_directories() -> None:
    """
    Ensure all configured directories exist.
    Creates directories recursively if they don't exist.
    Safe to call multiple times.
    """
    for path in [
        LIBRARY_ROOT,
        SOUNDCLOUD_FOLDER,
        ARCHIVE_FOLDER,
        DUPLICATES_FOLDER,
        WHOOSH_INDEX_DIR
    ]:
        path.mkdir(parents=True, exist_ok=True)


def init_config() -> None:
    """
    Initialize configuration: create directories and set database path.
    Call this at application startup.
    """
    init_directories()

    # Set database path in database module
    try:
        from src.library.database import set_db_path
        set_db_path(LIBRARY_DB_PATH)
    except ImportError:
        # Database module not available yet
        pass


def get_format_quality(format_str: str) -> int:
    """
    Get quality score for a format (higher = better).

    Args:
        format_str: Format string (e.g., 'mp3', 'flac')

    Returns:
        Quality score (index in FORMAT_QUALITY_ORDER, or -1 if unknown)
    """
    format_lower = format_str.lower() if format_str else ''
    try:
        return FORMAT_QUALITY_ORDER.index(format_lower)
    except ValueError:
        return -1


def compare_quality(
    format1: str, bitrate1: int,
    format2: str, bitrate2: int
) -> int:
    """
    Compare quality of two audio files.

    Quality hierarchy:
    1. Lossless > Lossy
    2. Among same type, higher bitrate wins

    Args:
        format1: Format of first file
        bitrate1: Bitrate of first file
        format2: Format of second file
        bitrate2: Bitrate of second file

    Returns:
        1 if first is higher quality
        -1 if second is higher quality
        0 if equal quality
    """
    quality1 = get_format_quality(format1)
    quality2 = get_format_quality(format2)

    # Compare format quality first
    if quality1 > quality2:
        return 1
    elif quality1 < quality2:
        return -1

    # Same format type, compare bitrate
    br1 = bitrate1 or 0
    br2 = bitrate2 or 0

    if br1 > br2:
        return 1
    elif br1 < br2:
        return -1

    return 0


# Initialize directories on import (creates if not exist)
# This ensures the library structure exists before any operations
init_directories()
