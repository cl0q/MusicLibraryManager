"""
FAT32-safe filename sanitization for cross-platform music library organization.

This module provides functions to sanitize filenames and paths for FAT32 filesystem
compatibility, which is required for iPod and other portable devices.

FAT32 constraints handled:
- Invalid characters: / \\ < > : " | ? *
- Windows reserved names: CON, PRN, AUX, NUL, COM1-9, LPT1-9
- Path component length: max 255 characters
- Leading/trailing dots and spaces: not allowed

Uses pathvalidate library for core sanitization with custom handling for:
- Underscore replacement (readable output)
- Windows reserved name prefixing
- Edge case handling (empty input, None)
"""

from pathvalidate import sanitize_filename as pv_sanitize


# Windows reserved names (case-insensitive)
WINDOWS_RESERVED_NAMES = frozenset([
    'CON', 'PRN', 'AUX', 'NUL',
    'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
    'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
])

# Placeholder for invalid/empty filenames
UNKNOWN_PLACEHOLDER = "unknown"

# FAT32 path component max length
MAX_COMPONENT_LENGTH = 255


def _is_reserved_name(name: str) -> bool:
    """
    Check if a filename is a Windows reserved name.

    Handles both plain names (CON) and names with extensions (CON.txt).

    Args:
        name: The filename to check

    Returns:
        True if the base name (without extension) is reserved, False otherwise.
    """
    if "." in name:
        base = name.rsplit(".", 1)[0]
    else:
        base = name
    return base.upper() in WINDOWS_RESERVED_NAMES


def sanitize_filename(name: str | None, max_length: int = MAX_COMPONENT_LENGTH) -> str:
    """
    Sanitize a single filename component for FAT32 compatibility.

    Args:
        name: The filename to sanitize (can be None or empty)
        max_length: Maximum length for the result (default 255 for FAT32)

    Returns:
        A sanitized filename safe for FAT32 filesystems.
        Returns 'unknown' for empty, None, or invalid-only input.

    Examples:
        >>> sanitize_filename("AC/DC")
        'AC_DC'
        >>> sanitize_filename("Artist: The Best")
        'Artist_ The Best'
        >>> sanitize_filename("CON")
        '_CON'
        >>> sanitize_filename("")
        'unknown'
    """
    # Handle None and empty input
    if name is None or not name.strip():
        return UNKNOWN_PLACEHOLDER

    # Check for Windows reserved names BEFORE any processing
    # Need to handle both plain names (CON) and names with extensions (CON.txt)
    original_name = name.strip()
    is_reserved = _is_reserved_name(original_name)

    # Use pathvalidate for core sanitization (invalid chars replacement)
    # platform="universal" handles FAT32 constraints
    # replacement_text="_" makes output more readable
    sanitized = pv_sanitize(
        name,
        replacement_text="_",
        platform="universal"
    )

    # Strip leading dots and spaces (FAT32 doesn't allow these at start)
    sanitized = sanitized.lstrip(". ")

    # Strip trailing dots and spaces (FAT32 doesn't allow these at end)
    sanitized = sanitized.rstrip(". ")

    # Handle case where sanitization resulted in only underscores or empty
    stripped_underscores = sanitized.replace("_", "").strip()
    if not sanitized or sanitized.isspace() or not stripped_underscores:
        return UNKNOWN_PLACEHOLDER

    # Handle Windows reserved names - prefix with underscore
    # We check the ORIGINAL name for reserved status, then apply prefix
    if is_reserved:
        # pathvalidate adds underscore suffix to reserved names
        # For "CON" it produces "CON_"
        # For "CON.txt" it produces "CON_.txt"
        # We need to remove that suffix and add prefix instead

        if "." in sanitized:
            # Split to handle extension separately
            base, ext = sanitized.rsplit(".", 1)
            ext = "." + ext
            # Remove trailing underscore from base if present
            base = base.rstrip("_")
            sanitized = f"_{base}{ext}"
        else:
            # No extension - just strip trailing underscores
            sanitized = sanitized.rstrip("_")
            sanitized = f"_{sanitized}"

    # Truncate if too long (preserve extension if present)
    if len(sanitized) > max_length:
        # Check if there's an extension to preserve
        if "." in sanitized:
            base, ext = sanitized.rsplit(".", 1)
            ext = "." + ext
            if len(ext) < max_length:
                base_max = max_length - len(ext)
                sanitized = base[:base_max] + ext
            else:
                sanitized = sanitized[:max_length]
        else:
            sanitized = sanitized[:max_length]

    return sanitized


def sanitize_path(
    album_artist: str,
    album: str,
    title: str,
    extension: str = ".mp3"
) -> str:
    """
    Build a full organized path with all components sanitized for FAT32.

    Creates paths in the format: AlbumArtist/Album/Title.extension

    Args:
        album_artist: The album artist metadata field
        album: The album name metadata field
        title: The track title metadata field
        extension: File extension including dot (default ".mp3")

    Returns:
        A sanitized path string safe for FAT32 filesystems.

    Examples:
        >>> sanitize_path("AC/DC", "Back in Black", "Thunderstruck", ".mp3")
        'AC_DC/Back in Black/Thunderstruck.mp3'
        >>> sanitize_path("Various Artists", "Compilation: The Best", "Track 1")
        'Various Artists/Compilation_ The Best/Track 1.mp3'
    """
    artist_safe = sanitize_filename(album_artist)
    album_safe = sanitize_filename(album)
    title_safe = sanitize_filename(title)

    return f"{artist_safe}/{album_safe}/{title_safe}{extension}"
