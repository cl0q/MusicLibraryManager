"""
Mutagen metadata extraction wrapper for audio file metadata reading.

Provides a unified interface for extracting metadata from various audio formats:
- MP3 (ID3v2 tags)
- FLAC (Vorbis comments)
- AAC/M4A (MP4 tags)
- OGG (Vorbis comments)

Uses Mutagen's auto-detection for format handling while providing consistent
metadata field names across all formats.
"""

import logging
from pathlib import Path
from typing import Optional

import mutagen
from mutagen.id3 import ID3
from mutagen.flac import FLAC
from mutagen.mp4 import MP4
from mutagen.oggvorbis import OggVorbis

logger = logging.getLogger(__name__)


class MetadataExtractionError(Exception):
    """Raised when metadata extraction fails for a file."""

    def __init__(self, file_path: str, message: str, original_error: Optional[Exception] = None):
        self.file_path = file_path
        self.message = message
        self.original_error = original_error
        super().__init__(f"Failed to extract metadata from '{file_path}': {message}")


# Format extension mapping
FORMAT_EXTENSIONS = {
    '.mp3': 'mp3',
    '.flac': 'flac',
    '.m4a': 'aac',
    '.aac': 'aac',
    '.ogg': 'ogg',
}


def _get_format_from_path(file_path: str) -> str:
    """Determine audio format from file extension."""
    ext = Path(file_path).suffix.lower()
    return FORMAT_EXTENSIONS.get(ext, 'unknown')


def _extract_year(year_value) -> Optional[int]:
    """
    Extract year as integer from various formats.

    Handles:
    - ID3v2 TDRC frame (ID3TimeStamp or string like "2020-01-15")
    - Vorbis DATE field (string like "2020" or "2020-01-15")
    - MP4 date (string)
    """
    if year_value is None:
        return None

    # Convert to string if needed
    year_str = str(year_value)

    # Handle empty strings
    if not year_str.strip():
        return None

    # Extract first 4 digits (year portion)
    # Handles formats like "2020", "2020-01-15", "2020-01-15T00:00:00"
    try:
        # Try to get the year portion
        if '-' in year_str:
            year_str = year_str.split('-')[0]
        elif '/' in year_str:
            year_str = year_str.split('/')[0]

        year_int = int(year_str[:4])
        # Sanity check: year should be reasonable (1900-2100)
        if 1900 <= year_int <= 2100:
            return year_int
        return None
    except (ValueError, IndexError):
        return None


def _get_id3_text(audio, frame_id: str) -> Optional[str]:
    """Get text value from ID3 frame, handling missing frames gracefully."""
    frame = audio.get(frame_id)
    if frame is None:
        return None

    # ID3 frames contain text as a list
    if hasattr(frame, 'text') and frame.text:
        return str(frame.text[0])

    return str(frame) if frame else None


def _get_vorbis_text(audio, key: str) -> Optional[str]:
    """Get text value from Vorbis/FLAC comment, handling missing keys gracefully."""
    values = audio.get(key)
    if values and len(values) > 0:
        return str(values[0])
    return None


def _get_mp4_text(audio, key: str) -> Optional[str]:
    """Get text value from MP4 tag, handling missing keys gracefully."""
    values = audio.get(key)
    if values and len(values) > 0:
        return str(values[0])
    return None


def _extract_from_id3(audio: ID3, file_path: str) -> dict:
    """Extract metadata from ID3v2 tags (MP3 files)."""
    artist = _get_id3_text(audio, 'TPE1')
    album_artist = _get_id3_text(audio, 'TPE2')
    album = _get_id3_text(audio, 'TALB')
    title = _get_id3_text(audio, 'TIT2')
    genre = _get_id3_text(audio, 'TCON')

    # Year from TDRC (recording date) frame
    year = None
    tdrc = audio.get('TDRC')
    if tdrc:
        year = _extract_year(tdrc.text[0] if hasattr(tdrc, 'text') and tdrc.text else tdrc)

    return {
        'artist': artist,
        'album_artist': album_artist,
        'album': album,
        'title': title,
        'genre': genre,
        'year': year,
    }


def _extract_from_vorbis(audio, file_path: str) -> dict:
    """Extract metadata from Vorbis comments (FLAC, OGG files)."""
    artist = _get_vorbis_text(audio, 'artist')
    album_artist = _get_vorbis_text(audio, 'albumartist')
    album = _get_vorbis_text(audio, 'album')
    title = _get_vorbis_text(audio, 'title')
    genre = _get_vorbis_text(audio, 'genre')

    # Year from date field
    date_str = _get_vorbis_text(audio, 'date')
    year = _extract_year(date_str)

    return {
        'artist': artist,
        'album_artist': album_artist,
        'album': album,
        'title': title,
        'genre': genre,
        'year': year,
    }


def _extract_from_mp4(audio: MP4, file_path: str) -> dict:
    """Extract metadata from MP4 tags (AAC/M4A files)."""
    # MP4 uses different key format
    artist = _get_mp4_text(audio, '\xa9ART')  # Artist
    album_artist = _get_mp4_text(audio, 'aART')  # Album Artist
    album = _get_mp4_text(audio, '\xa9alb')  # Album
    title = _get_mp4_text(audio, '\xa9nam')  # Name/Title
    genre = _get_mp4_text(audio, '\xa9gen')  # Genre

    # Year from date field
    date_str = _get_mp4_text(audio, '\xa9day')
    year = _extract_year(date_str)

    return {
        'artist': artist,
        'album_artist': album_artist,
        'album': album,
        'title': title,
        'genre': genre,
        'year': year,
    }


def extract_metadata(file_path: str) -> dict:
    """
    Extract metadata from an audio file.

    Supports MP3 (ID3v2), FLAC (Vorbis), AAC/M4A (MP4), and OGG (Vorbis) formats.
    Uses Mutagen's auto-detection for format handling.

    Args:
        file_path: Path to the audio file

    Returns:
        dict with fields:
        - artist: Main performer (TPE1 for ID3v2)
        - album_artist: Album artist (TPE2 for ID3v2), defaults to artist if missing
        - album: Album name
        - title: Track title, defaults to filename if missing
        - genre: Music genre (can be None)
        - year: Recording year as integer (can be None)
        - bitrate: Audio bitrate in kbps
        - format: Audio format (mp3, flac, aac, ogg)
        - duration: Track duration in seconds

    Raises:
        MetadataExtractionError: If the file is unsupported or corrupted
    """
    file_path_str = str(file_path)
    path = Path(file_path)

    if not path.exists():
        raise MetadataExtractionError(file_path_str, "File does not exist")

    try:
        # Use Mutagen's auto-detection
        audio = mutagen.File(file_path_str)

        if audio is None:
            raise MetadataExtractionError(file_path_str, "Unsupported format")

        # Determine format from extension (more reliable than Mutagen's type)
        audio_format = _get_format_from_path(file_path_str)

        # Extract format-specific metadata
        if isinstance(audio.tags, ID3) or hasattr(audio, 'ID3'):
            # MP3 with ID3 tags
            try:
                id3_audio = ID3(file_path_str)
                metadata = _extract_from_id3(id3_audio, file_path_str)
            except Exception:
                # Fallback to generic tag reading
                metadata = _extract_from_id3(audio.tags, file_path_str) if audio.tags else {}
        elif isinstance(audio, FLAC) or isinstance(audio, OggVorbis):
            # FLAC or OGG with Vorbis comments
            metadata = _extract_from_vorbis(audio, file_path_str)
        elif isinstance(audio, MP4):
            # AAC/M4A
            metadata = _extract_from_mp4(audio, file_path_str)
        else:
            # Try Vorbis-style extraction as fallback
            metadata = _extract_from_vorbis(audio, file_path_str)

        # Get audio info (bitrate, duration)
        bitrate = None
        duration = None

        if hasattr(audio, 'info'):
            info = audio.info
            if hasattr(info, 'bitrate'):
                bitrate = info.bitrate // 1000 if info.bitrate else None  # Convert to kbps
            if hasattr(info, 'length'):
                duration = int(info.length) if info.length else None

        # Apply fallbacks for missing critical fields
        artist = metadata.get('artist')
        album_artist = metadata.get('album_artist')
        album = metadata.get('album')
        title = metadata.get('title')

        # album_artist defaults to artist if missing, then "Various Artists"
        if not album_artist:
            album_artist = artist if artist else "Various Artists"

        # title defaults to filename without extension if missing
        if not title:
            title = path.stem
            logger.warning(f"Missing title metadata, using filename: {title}")

        # album defaults to "Unknown Album" if missing
        if not album:
            album = "Unknown Album"
            logger.warning(f"Missing album metadata for '{file_path_str}'")

        # Log warning for missing artist (critical field)
        if not artist:
            logger.warning(f"Missing artist metadata for '{file_path_str}'")

        return {
            'artist': artist,
            'album_artist': album_artist,
            'album': album,
            'title': title,
            'genre': metadata.get('genre'),
            'year': metadata.get('year'),
            'bitrate': bitrate,
            'format': audio_format,
            'duration': duration,
        }

    except MetadataExtractionError:
        raise
    except Exception as e:
        raise MetadataExtractionError(file_path_str, str(e), original_error=e)
