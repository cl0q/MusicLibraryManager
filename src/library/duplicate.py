"""
Duplicate detection logic for music library.

Implements duplicate detection based on:
- Exact metadata matching (artist + title + album, case-insensitive)
- Quality hierarchy: lossless > lossy, then by bitrate
- Organizing duplicates in _duplicates review folder

Functions:
- is_duplicate(): Check if two files have matching metadata
- compare_quality(): Compare quality of two files
- get_duplicate_reason(): Get human-readable reason for duplicate marking
- find_duplicates(): Find all duplicates of a given file
- mark_all_duplicates(): Scan entire library for duplicates
- organize_duplicates_for_review(): Create manifest in _duplicates folder
"""

import os
from pathlib import Path
from typing import Optional

from src.library.database import (
    get_all_files,
    get_file_by_id,
    get_duplicates,
    mark_as_duplicate,
)


# Lossless formats (higher quality tier)
LOSSLESS_FORMATS = frozenset(['flac', 'wav', 'alac', 'aiff'])

# Lossy formats (lower quality tier)
LOSSY_FORMATS = frozenset(['mp3', 'aac', 'm4a', 'ogg', 'opus'])


def _normalize_string(value: Optional[str]) -> Optional[str]:
    """
    Normalize a string for comparison.

    - Strips whitespace
    - Converts to lowercase
    - Returns None if value is None

    Args:
        value: String to normalize

    Returns:
        Normalized string or None
    """
    if value is None:
        return None
    return value.strip().lower()


def is_duplicate(meta1: dict, meta2: dict) -> bool:
    """
    Check if two files have matching metadata (exact match).

    Matching criteria: artist + title + album must match exactly (case-insensitive).

    Args:
        meta1: First file's metadata dict with 'artist', 'title', 'album'
        meta2: Second file's metadata dict with 'artist', 'title', 'album'

    Returns:
        True if exact metadata match, False otherwise
    """
    # Get and normalize values
    artist1 = _normalize_string(meta1.get('artist'))
    artist2 = _normalize_string(meta2.get('artist'))
    title1 = _normalize_string(meta1.get('title'))
    title2 = _normalize_string(meta2.get('title'))
    album1 = _normalize_string(meta1.get('album'))
    album2 = _normalize_string(meta2.get('album'))

    # Any None value means not a duplicate (incomplete metadata)
    if None in (artist1, artist2, title1, title2, album1, album2):
        return False

    # Empty strings are not equal to each other for duplicate purposes
    # (they indicate missing metadata, not matching metadata)
    if '' in (artist1, artist2, title1, title2, album1, album2):
        return False

    # All three must match
    return artist1 == artist2 and title1 == title2 and album1 == album2


def compare_quality(meta1: dict, meta2: dict) -> str:
    """
    Compare quality of two audio files.

    Quality hierarchy:
    1. Format tier: lossless > lossy
    2. Within same tier: higher bitrate wins

    Args:
        meta1: First file's metadata with 'format' and 'bitrate'
        meta2: Second file's metadata with 'format' and 'bitrate'

    Returns:
        "file1_better" if first file is higher quality
        "file2_better" if second file is higher quality
        "equal" if same quality
    """
    format1 = (meta1.get('format') or '').lower()
    format2 = (meta2.get('format') or '').lower()

    # Determine format tiers
    is_lossless1 = format1 in LOSSLESS_FORMATS
    is_lossless2 = format2 in LOSSLESS_FORMATS

    # Lossless beats lossy
    if is_lossless1 and not is_lossless2:
        return "file1_better"
    elif is_lossless2 and not is_lossless1:
        return "file2_better"

    # Same format tier - compare bitrate
    bitrate1 = meta1.get('bitrate') or 0
    bitrate2 = meta2.get('bitrate') or 0

    if bitrate1 > bitrate2:
        return "file1_better"
    elif bitrate2 > bitrate1:
        return "file2_better"

    return "equal"


def get_duplicate_reason(primary_meta: dict, duplicate_meta: dict) -> str:
    """
    Generate human-readable reason for why a file is marked as duplicate.

    Args:
        primary_meta: Primary (higher quality) file's metadata
        duplicate_meta: Duplicate (lower quality) file's metadata

    Returns:
        Reason string: "worse_format", "lower_bitrate", or "duplicate_of_earlier_import"
    """
    primary_format = (primary_meta.get('format') or '').lower()
    duplicate_format = (duplicate_meta.get('format') or '').lower()

    is_primary_lossless = primary_format in LOSSLESS_FORMATS
    is_duplicate_lossless = duplicate_format in LOSSLESS_FORMATS

    # Format difference
    if is_primary_lossless and not is_duplicate_lossless:
        return "worse_format"

    # Bitrate difference
    primary_bitrate = primary_meta.get('bitrate') or 0
    duplicate_bitrate = duplicate_meta.get('bitrate') or 0

    if primary_bitrate > duplicate_bitrate:
        return "lower_bitrate"

    # Same quality - later import is duplicate
    return "duplicate_of_earlier_import"


def find_duplicates(file_id: int) -> list[tuple[int, str]]:
    """
    Find all duplicates of a given file.

    Returns files that match the given file's metadata (artist + title + album)
    but are lower quality or were imported later.

    Args:
        file_id: ID of the file to find duplicates of

    Returns:
        List of (duplicate_file_id, reason) tuples
    """
    # Get the target file
    target_file = get_file_by_id(file_id)
    if target_file is None:
        return []

    target_meta = target_file['metadata']
    target_imported_at = target_file.get('imported_at')

    # Get all files
    all_files = get_all_files()

    duplicates = []

    for file_record in all_files:
        # Skip the target file itself
        if file_record['id'] == file_id:
            continue

        other_meta = file_record['metadata']

        # Check if metadata matches
        if not is_duplicate(target_meta, other_meta):
            continue

        # Compare quality
        quality_comparison = compare_quality(target_meta, other_meta)

        if quality_comparison == "file1_better":
            # Target is better - other file is duplicate
            reason = get_duplicate_reason(target_meta, other_meta)
            duplicates.append((file_record['id'], reason))

        elif quality_comparison == "equal":
            # Same quality - earlier import wins
            other_imported_at = file_record.get('imported_at')

            # Compare timestamps (earlier import is primary)
            # If timestamps are equal (SQLite has second precision), use file ID as tiebreaker
            if target_imported_at and other_imported_at:
                if target_imported_at < other_imported_at:
                    # Target was imported first - other is duplicate
                    duplicates.append((file_record['id'], "duplicate_of_earlier_import"))
                elif target_imported_at == other_imported_at and file_id < file_record['id']:
                    # Same timestamp, lower ID = earlier import
                    duplicates.append((file_record['id'], "duplicate_of_earlier_import"))
                # If other was imported first (or has lower ID), target would be the duplicate,
                # but we're finding duplicates OF target, so skip

        # If file2_better, the target file would be the duplicate, not the other file
        # So we don't add anything

    return duplicates


def mark_all_duplicates() -> int:
    """
    Scan entire library for duplicates and mark them.

    For each group of files with matching metadata:
    - Identifies the highest quality version as primary
    - Marks all lower quality versions as duplicates

    Returns:
        Number of duplicates marked
    """
    all_files = get_all_files()

    # Group files by normalized metadata key
    groups: dict[tuple, list[dict]] = {}

    for file_record in all_files:
        meta = file_record['metadata']
        artist = _normalize_string(meta.get('artist'))
        title = _normalize_string(meta.get('title'))
        album = _normalize_string(meta.get('album'))

        # Skip files with incomplete metadata
        if None in (artist, title, album) or '' in (artist, title, album):
            continue

        key = (artist, title, album)
        if key not in groups:
            groups[key] = []
        groups[key].append(file_record)

    duplicates_marked = 0

    # Process each group
    for key, file_group in groups.items():
        # Skip groups with single file (no duplicates)
        if len(file_group) < 2:
            continue

        # Sort by quality (best first), then by import time (earliest first)
        def quality_sort_key(f):
            meta = f['metadata']
            format_str = (meta.get('format') or '').lower()
            is_lossless = format_str in LOSSLESS_FORMATS
            bitrate = meta.get('bitrate') or 0
            imported_at = f.get('imported_at') or ''

            # Higher tier = lossless (1 > 0)
            # Higher bitrate = better
            # Earlier import = better (smaller string comparison)
            # Negate bitrate since we want descending order
            return (not is_lossless, -bitrate, imported_at)

        sorted_files = sorted(file_group, key=quality_sort_key)

        # First file is primary (best quality / earliest import)
        primary_file = sorted_files[0]
        primary_meta = primary_file['metadata']

        # Rest are duplicates
        for dup_file in sorted_files[1:]:
            dup_meta = dup_file['metadata']
            reason = get_duplicate_reason(primary_meta, dup_meta)

            mark_as_duplicate(
                primary_file_id=primary_file['id'],
                duplicate_file_id=dup_file['id'],
                reason=reason
            )
            duplicates_marked += 1

    return duplicates_marked


def _get_duplicates_folder() -> Path:
    """
    Get the duplicates folder path from environment or use default.

    Returns:
        Path to duplicates folder
    """
    # Environment variable takes precedence (for testing)
    env_path = os.environ.get('DUPLICATES_FOLDER')
    if env_path:
        return Path(env_path)

    # Try to get from config module
    try:
        from src.core.config import DUPLICATES_FOLDER
        return Path(DUPLICATES_FOLDER)
    except ImportError:
        pass

    # Default fallback
    return Path.home() / "Music" / "MusicLibrary" / "_duplicates"


def organize_duplicates_for_review() -> None:
    """
    Create manifest file in _duplicates folder for user review.

    Creates a text file listing all duplicates with:
    - Primary file path
    - Duplicate file path
    - Reason for marking as duplicate

    Groups duplicates by their primary file.
    """
    duplicates_folder = _get_duplicates_folder()

    # Create folder if doesn't exist
    duplicates_folder.mkdir(parents=True, exist_ok=True)

    # Get all unreviewed duplicates
    duplicates = get_duplicates(reviewed=False)

    # Group by primary file
    by_primary: dict[int, list[dict]] = {}
    for dup in duplicates:
        primary_id = dup['primary']['id']
        if primary_id not in by_primary:
            by_primary[primary_id] = []
        by_primary[primary_id].append(dup)

    # Create manifest
    manifest_path = duplicates_folder / "duplicates_manifest.txt"

    with open(manifest_path, 'w', encoding='utf-8') as f:
        f.write("# Duplicate Files Manifest\n")
        f.write("# Generated for user review\n")
        f.write("# Primary files are higher quality; duplicates can be safely removed\n")
        f.write("#\n")
        f.write("=" * 80 + "\n\n")

        for primary_id, dup_list in by_primary.items():
            # Get primary file info (from first duplicate entry)
            primary_info = dup_list[0]['primary']

            f.write(f"PRIMARY: {primary_info['original_path']}\n")
            f.write(f"  Artist: {primary_info['artist']}\n")
            f.write(f"  Title: {primary_info['title']}\n")
            f.write(f"  Format: {primary_info['format']} @ {primary_info['bitrate']}kbps\n")
            f.write("\n")

            for dup in dup_list:
                dup_info = dup['duplicate']
                f.write(f"  DUPLICATE: {dup_info['original_path']}\n")
                f.write(f"    Format: {dup_info['format']} @ {dup_info['bitrate']}kbps\n")
                f.write(f"    Reason: {dup['reason']}\n")
                f.write("\n")

            f.write("-" * 80 + "\n\n")

        if not by_primary:
            f.write("No duplicates found.\n")
