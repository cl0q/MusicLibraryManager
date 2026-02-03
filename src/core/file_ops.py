"""
Atomic file operations wrapper for safe file handling.

Provides atomicity guarantees for critical operations using atomicwrites library.
Implements DL-05 requirement for atomic operations to prevent data corruption.

Functions:
- atomic_write_database: Wrap database writes in atomic transaction
- safe_file_exists: Check if file exists and is readable
- get_file_size: Get file size in bytes
"""

import logging
from pathlib import Path
from typing import Callable, Any

from atomicwrites import atomic_write

logger = logging.getLogger(__name__)


def atomic_write_database(db_path: str, write_func: Callable[[Any], None]) -> None:
    """
    Wrap database/file writes in an atomic transaction.

    Uses atomicwrites to ensure writes are atomic:
    - Write to temporary file
    - Flush and sync to disk
    - Atomic rename to target path

    This prevents corrupt files from interrupted writes (power failure, crash).

    Note: SQLite already provides ACID transactions via BEGIN/COMMIT, but this
    function provides additional atomicity for:
    - Complete database file replacement
    - Critical file operations outside SQLite

    Args:
        db_path: Path to the database/file to write
        write_func: Function that takes a file handle and performs the write

    Raises:
        Exception: Re-raises any exception from write_func after cleanup
    """
    try:
        with atomic_write(db_path, mode='wb', overwrite=True) as f:
            write_func(f)
        logger.debug(f"Atomic write completed: {db_path}")
    except Exception as e:
        logger.error(f"Atomic write failed for {db_path}: {e}")
        raise


def safe_file_exists(file_path: str) -> bool:
    """
    Check if a file exists and is readable.

    Handles permission errors gracefully, returning False instead of raising.

    Args:
        file_path: Path to the file to check

    Returns:
        True if file exists and is a regular file, False otherwise
    """
    try:
        path = Path(file_path)
        return path.exists() and path.is_file()
    except (PermissionError, OSError) as e:
        logger.debug(f"Cannot access file {file_path}: {e}")
        return False


def get_file_size(file_path: str) -> int:
    """
    Get the size of a file in bytes.

    Args:
        file_path: Path to the file

    Returns:
        File size in bytes, or 0 if file doesn't exist or is inaccessible
    """
    try:
        path = Path(file_path)
        if path.exists() and path.is_file():
            return path.stat().st_size
        return 0
    except (PermissionError, OSError) as e:
        logger.debug(f"Cannot get size of {file_path}: {e}")
        return 0


def ensure_directory(dir_path: str) -> bool:
    """
    Ensure a directory exists, creating it if necessary.

    Args:
        dir_path: Path to the directory

    Returns:
        True if directory exists or was created, False on failure
    """
    try:
        path = Path(dir_path)
        path.mkdir(parents=True, exist_ok=True)
        return True
    except (PermissionError, OSError) as e:
        logger.error(f"Cannot create directory {dir_path}: {e}")
        return False


def is_audio_file(file_path: str) -> bool:
    """
    Check if a file appears to be an audio file based on extension.

    Args:
        file_path: Path to the file

    Returns:
        True if file has a supported audio extension
    """
    audio_extensions = {'.mp3', '.flac', '.m4a', '.aac', '.ogg'}
    ext = Path(file_path).suffix.lower()
    return ext in audio_extensions
