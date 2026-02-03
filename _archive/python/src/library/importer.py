"""
Music file import pipeline with progress tracking and failure handling.

Implements LIB-01 import workflow:
- Scan directory recursively for music files
- Extract metadata using Mutagen
- Build organized paths using sanitizer
- Save to database with atomic operations
- Handle failures gracefully (continue import, report at end)
- Trigger duplicate detection after import completes

Reference-in-place model: files are NOT copied or moved, only tracked in database.
"""

import logging
import os
from pathlib import Path
from typing import Optional

from tqdm import tqdm

from src.library.metadata import extract_metadata, MetadataExtractionError
from src.library.sanitizer import sanitize_path
from src.library.database import save_file_record, init_database, get_all_files
from src.core.file_ops import is_audio_file

logger = logging.getLogger(__name__)

# Supported audio file extensions
AUDIO_EXTENSIONS = {'.mp3', '.flac', '.m4a', '.aac', '.ogg'}


def scan_directory(directory_path: str) -> list[str]:
    """
    Recursively scan a directory for music files.

    Args:
        directory_path: Path to the directory to scan

    Returns:
        List of absolute paths to audio files found
    """
    music_files = []
    dir_path = Path(directory_path)

    if not dir_path.exists():
        logger.warning(f"Directory does not exist: {directory_path}")
        return music_files

    if not dir_path.is_dir():
        logger.warning(f"Path is not a directory: {directory_path}")
        return music_files

    for root, _, files in os.walk(directory_path):
        for filename in files:
            file_path = os.path.join(root, filename)
            if is_audio_file(file_path):
                music_files.append(file_path)

    return sorted(music_files)  # Sort for consistent ordering


def import_directory(
    directory_path: str,
    is_soundcloud: bool = False,
    verbose: bool = False
) -> tuple[list[str], list[tuple[str, str]]]:
    """
    Import all music files from a directory into the library.

    Implements the LIB-01 import workflow:
    1. Scan directory recursively for music files
    2. For each file:
       a. Extract metadata
       b. Build organized path using sanitizer
       c. Save to database
       d. Update progress bar
       e. On failure: collect error, continue with next file
    3. After import, trigger duplicate detection
    4. Return successes and failures

    Reference-in-place model: original files are NOT copied or moved.
    The original_path is stored as-is (absolute path to existing file).

    Args:
        directory_path: Path to the directory to import
        is_soundcloud: Whether this is SoundCloud content (uses separate folder structure)
        verbose: If True, print each file being processed

    Returns:
        Tuple of (successes, failures):
        - successes: List of successfully imported file paths
        - failures: List of (file_path, error_message) tuples
    """
    # Ensure database is initialized
    init_database()

    # Scan for music files
    music_files = scan_directory(directory_path)

    if not music_files:
        logger.info(f"No music files found in: {directory_path}")
        return [], []

    successes = []
    failures = []

    # Process files with progress bar
    with tqdm(total=len(music_files), desc="Importing", unit="files") as pbar:
        for file_path in music_files:
            try:
                # Verbose mode: print each file
                if verbose:
                    tqdm.write(f"Processing: {file_path}")

                # Extract metadata
                metadata = extract_metadata(file_path)

                # Build organized path using sanitizer
                # Uses Album Artist/Album/Title structure
                extension = Path(file_path).suffix
                organized_path = sanitize_path(
                    album_artist=metadata['album_artist'],
                    album=metadata['album'],
                    title=metadata['title'],
                    extension=extension
                )

                # Save to database (reference-in-place: store original_path as-is)
                save_file_record(
                    original_path=file_path,
                    organized_path=organized_path,
                    is_soundcloud=is_soundcloud,
                    metadata_dict=metadata
                )

                successes.append(file_path)

                if verbose:
                    tqdm.write(f"  -> {organized_path}")

            except MetadataExtractionError as e:
                failures.append((file_path, e.message))
                if verbose:
                    tqdm.write(f"  ERROR: {e.message}")
            except Exception as e:
                # Catch any other errors (database, etc)
                error_msg = str(e)
                # Check for duplicate key error
                if "UNIQUE constraint failed" in error_msg:
                    error_msg = "File already imported"
                failures.append((file_path, error_msg))
                if verbose:
                    tqdm.write(f"  ERROR: {error_msg}")

            pbar.update(1)

    # Trigger duplicate detection after import completes
    duplicates_found = 0
    try:
        from src.library.duplicate import mark_all_duplicates
        duplicates_found = mark_all_duplicates()
    except ImportError:
        # duplicate module may not exist yet (executed in earlier wave)
        logger.debug("Duplicate detection module not available")
    except Exception as e:
        logger.warning(f"Duplicate detection failed: {e}")

    # Log summary
    logger.info(f"Import complete: {len(successes)} succeeded, {len(failures)} failed")
    if duplicates_found:
        logger.info(f"Duplicates found: {duplicates_found}")

    return successes, failures


def display_import_summary(
    successes: list[str],
    failures: list[tuple[str, str]],
    duplicates_count: int = 0
) -> None:
    """
    Display a summary of the import operation.

    Args:
        successes: List of successfully imported file paths
        failures: List of (file_path, error_message) tuples
        duplicates_count: Number of duplicates found
    """
    print("\n" + "=" * 60)
    print("IMPORT SUMMARY")
    print("=" * 60)

    print(f"\nSuccessfully imported: {len(successes)} files")

    if failures:
        print(f"Failed to import: {len(failures)} files")
        print("\nFailures:")
        print("-" * 40)
        for file_path, error in failures:
            filename = Path(file_path).name
            print(f"  {filename}")
            print(f"    Error: {error}")
        print("-" * 40)
    else:
        print("No failures.")

    if duplicates_count > 0:
        print(f"\nDuplicates detected: {duplicates_count}")

    print("\n" + "=" * 60)


def get_import_stats() -> dict:
    """
    Get statistics about the current library.

    Returns:
        Dictionary with stats:
        - total_files: Total number of files in library
        - formats: Dictionary of format counts
    """
    files = get_all_files()

    formats = {}
    for f in files:
        fmt = f['metadata'].get('format', 'unknown')
        formats[fmt] = formats.get(fmt, 0) + 1

    return {
        'total_files': len(files),
        'formats': formats
    }


if __name__ == "__main__":
    import sys

    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format='%(levelname)s: %(message)s'
    )

    if len(sys.argv) < 2:
        print("Usage: python -m src.library.importer <directory> [--soundcloud] [--verbose]")
        print("\nOptions:")
        print("  --soundcloud  Mark imported files as SoundCloud content")
        print("  --verbose     Show detailed progress for each file")
        sys.exit(1)

    directory = sys.argv[1]
    is_soundcloud = "--soundcloud" in sys.argv
    verbose = "--verbose" in sys.argv or "-v" in sys.argv

    print(f"Importing from: {directory}")
    if is_soundcloud:
        print("(SoundCloud mode)")

    successes, failures = import_directory(
        directory,
        is_soundcloud=is_soundcloud,
        verbose=verbose
    )

    # Get duplicate count for summary
    duplicates_count = 0
    try:
        from src.library.duplicate import mark_all_duplicates
        from src.library.database import get_duplicates
        duplicates = get_duplicates(reviewed=False)
        duplicates_count = len(duplicates)
    except (ImportError, Exception):
        pass

    display_import_summary(successes, failures, duplicates_count)

    # Show library stats
    stats = get_import_stats()
    print(f"\nLibrary now contains: {stats['total_files']} files")
    if stats['formats']:
        print("Formats:", ", ".join(f"{k}: {v}" for k, v in stats['formats'].items()))
