"""
SQLite database schema and CRUD operations for music library.

Implements the data layer with normalized tables for:
- files: Track file locations (reference-in-place model)
- metadata: Cache metadata for search indexing
- duplicates: Track duplicate relationships with quality hierarchy
- search_index: Track Whoosh indexing status
"""

import sqlite3
from contextlib import contextmanager
from datetime import datetime
from pathlib import Path
from typing import Optional

# Database path - will be set by config module
_db_path: Optional[Path] = None


def set_db_path(path: Path) -> None:
    """Set the database path. Called by config module on import."""
    global _db_path
    _db_path = path


def get_db_path() -> Path:
    """Get the current database path."""
    if _db_path is None:
        # Default fallback for testing
        return Path("library.db")
    return _db_path


@contextmanager
def get_connection():
    """
    Context manager for database connections.
    Ensures proper connection handling and enables foreign keys.
    """
    conn = sqlite3.connect(get_db_path())
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
    finally:
        conn.close()


def init_database() -> None:
    """
    Initialize the database schema.
    Creates all tables if they don't exist.
    Safe to call multiple times (uses IF NOT EXISTS).
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        # Files table: Store file tracking with reference-in-place model
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS files (
                id INTEGER PRIMARY KEY,
                original_path TEXT UNIQUE NOT NULL,
                organized_path TEXT NOT NULL,
                is_soundcloud BOOLEAN DEFAULT 0,
                imported_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                last_synced TIMESTAMP
            )
        """)

        # Metadata table: Cache metadata for search indexing
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS metadata (
                id INTEGER PRIMARY KEY,
                file_id INTEGER UNIQUE,
                artist TEXT,
                album_artist TEXT,
                album TEXT,
                title TEXT,
                genre TEXT,
                year INTEGER,
                bitrate INTEGER,
                format TEXT,
                duration INTEGER,
                FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
            )
        """)

        # Duplicates table: Track duplicate relationships
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS duplicates (
                id INTEGER PRIMARY KEY,
                primary_file_id INTEGER,
                duplicate_file_id INTEGER,
                reason TEXT,
                reviewed BOOLEAN DEFAULT 0,
                FOREIGN KEY(primary_file_id) REFERENCES files(id),
                FOREIGN KEY(duplicate_file_id) REFERENCES files(id)
            )
        """)

        # Search index table: Track Whoosh indexing status
        cursor.execute("""
            CREATE TABLE IF NOT EXISTS search_index (
                file_id INTEGER PRIMARY KEY,
                indexed_at TIMESTAMP,
                FOREIGN KEY(file_id) REFERENCES files(id) ON DELETE CASCADE
            )
        """)

        # Create indexes for fast queries
        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_metadata_search
            ON metadata(artist, album_artist, album, title)
        """)

        cursor.execute("""
            CREATE INDEX IF NOT EXISTS idx_files_original_path
            ON files(original_path)
        """)

        conn.commit()


def save_file_record(
    original_path: str,
    organized_path: str,
    is_soundcloud: bool,
    metadata_dict: dict
) -> int:
    """
    Save a file record with its metadata.

    Args:
        original_path: Original location of the file (reference-in-place)
        organized_path: Album Artist/Album/Track folder structure path
        is_soundcloud: Whether this is SoundCloud content (separate folder structure)
        metadata_dict: Dictionary of metadata fields (artist, album, title, etc.)

    Returns:
        file_id: The ID of the created file record

    Raises:
        sqlite3.IntegrityError: If original_path already exists
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        # Use transaction for atomicity (DL-05 requirement)
        try:
            # Insert file record
            cursor.execute("""
                INSERT INTO files (original_path, organized_path, is_soundcloud)
                VALUES (?, ?, ?)
            """, (original_path, organized_path, is_soundcloud))

            file_id = cursor.lastrowid

            # Insert metadata record
            cursor.execute("""
                INSERT INTO metadata (
                    file_id, artist, album_artist, album, title,
                    genre, year, bitrate, format, duration
                )
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, (
                file_id,
                metadata_dict.get('artist'),
                metadata_dict.get('album_artist'),
                metadata_dict.get('album'),
                metadata_dict.get('title'),
                metadata_dict.get('genre'),
                metadata_dict.get('year'),
                metadata_dict.get('bitrate'),
                metadata_dict.get('format'),
                metadata_dict.get('duration')
            ))

            conn.commit()
            return file_id

        except Exception:
            conn.rollback()
            raise


def get_file_by_path(original_path: str) -> Optional[dict]:
    """
    Get a file record by its original path.

    Args:
        original_path: The original location of the file

    Returns:
        dict with file and metadata fields, or None if not found
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                f.id, f.original_path, f.organized_path, f.is_soundcloud,
                f.imported_at, f.last_synced,
                m.artist, m.album_artist, m.album, m.title,
                m.genre, m.year, m.bitrate, m.format, m.duration
            FROM files f
            LEFT JOIN metadata m ON f.id = m.file_id
            WHERE f.original_path = ?
        """, (original_path,))

        row = cursor.fetchone()
        if row is None:
            return None

        return {
            'id': row['id'],
            'original_path': row['original_path'],
            'organized_path': row['organized_path'],
            'is_soundcloud': bool(row['is_soundcloud']),
            'imported_at': row['imported_at'],
            'last_synced': row['last_synced'],
            'metadata': {
                'artist': row['artist'],
                'album_artist': row['album_artist'],
                'album': row['album'],
                'title': row['title'],
                'genre': row['genre'],
                'year': row['year'],
                'bitrate': row['bitrate'],
                'format': row['format'],
                'duration': row['duration']
            }
        }


def get_file_by_id(file_id: int) -> Optional[dict]:
    """
    Get a file record by its ID.

    Args:
        file_id: The ID of the file record

    Returns:
        dict with file and metadata fields, or None if not found
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                f.id, f.original_path, f.organized_path, f.is_soundcloud,
                f.imported_at, f.last_synced,
                m.artist, m.album_artist, m.album, m.title,
                m.genre, m.year, m.bitrate, m.format, m.duration
            FROM files f
            LEFT JOIN metadata m ON f.id = m.file_id
            WHERE f.id = ?
        """, (file_id,))

        row = cursor.fetchone()
        if row is None:
            return None

        return {
            'id': row['id'],
            'original_path': row['original_path'],
            'organized_path': row['organized_path'],
            'is_soundcloud': bool(row['is_soundcloud']),
            'imported_at': row['imported_at'],
            'last_synced': row['last_synced'],
            'metadata': {
                'artist': row['artist'],
                'album_artist': row['album_artist'],
                'album': row['album'],
                'title': row['title'],
                'genre': row['genre'],
                'year': row['year'],
                'bitrate': row['bitrate'],
                'format': row['format'],
                'duration': row['duration']
            }
        }


def get_all_files() -> list[dict]:
    """
    Get all file records with their metadata.

    Returns:
        List of dicts, each containing file and metadata fields
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                f.id, f.original_path, f.organized_path, f.is_soundcloud,
                f.imported_at, f.last_synced,
                m.artist, m.album_artist, m.album, m.title,
                m.genre, m.year, m.bitrate, m.format, m.duration
            FROM files f
            LEFT JOIN metadata m ON f.id = m.file_id
            ORDER BY f.id
        """)

        results = []
        for row in cursor.fetchall():
            results.append({
                'id': row['id'],
                'original_path': row['original_path'],
                'organized_path': row['organized_path'],
                'is_soundcloud': bool(row['is_soundcloud']),
                'imported_at': row['imported_at'],
                'last_synced': row['last_synced'],
                'metadata': {
                    'artist': row['artist'],
                    'album_artist': row['album_artist'],
                    'album': row['album'],
                    'title': row['title'],
                    'genre': row['genre'],
                    'year': row['year'],
                    'bitrate': row['bitrate'],
                    'format': row['format'],
                    'duration': row['duration']
                }
            })

        return results


def find_potential_duplicates(artist: str, title: str, album: str) -> list[dict]:
    """
    Find files with matching artist, title, and album (exact match).
    Used for duplicate detection.

    Args:
        artist: Artist name to match
        title: Track title to match
        album: Album name to match

    Returns:
        List of matching file records with metadata
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                f.id, f.original_path, f.organized_path, f.is_soundcloud,
                f.imported_at, f.last_synced,
                m.artist, m.album_artist, m.album, m.title,
                m.genre, m.year, m.bitrate, m.format, m.duration
            FROM files f
            JOIN metadata m ON f.id = m.file_id
            WHERE m.artist = ? AND m.title = ? AND m.album = ?
        """, (artist, title, album))

        results = []
        for row in cursor.fetchall():
            results.append({
                'id': row['id'],
                'original_path': row['original_path'],
                'organized_path': row['organized_path'],
                'is_soundcloud': bool(row['is_soundcloud']),
                'imported_at': row['imported_at'],
                'last_synced': row['last_synced'],
                'metadata': {
                    'artist': row['artist'],
                    'album_artist': row['album_artist'],
                    'album': row['album'],
                    'title': row['title'],
                    'genre': row['genre'],
                    'year': row['year'],
                    'bitrate': row['bitrate'],
                    'format': row['format'],
                    'duration': row['duration']
                }
            })

        return results


def mark_as_duplicate(
    primary_file_id: int,
    duplicate_file_id: int,
    reason: str
) -> int:
    """
    Record a duplicate relationship between two files.

    Args:
        primary_file_id: ID of the higher quality version
        duplicate_file_id: ID of the lower quality version
        reason: Why this is considered a duplicate (e.g., "lower_bitrate", "worse_format")

    Returns:
        duplicate_id: The ID of the created duplicate record
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            INSERT INTO duplicates (primary_file_id, duplicate_file_id, reason)
            VALUES (?, ?, ?)
        """, (primary_file_id, duplicate_file_id, reason))

        duplicate_id = cursor.lastrowid
        conn.commit()

        return duplicate_id


def get_duplicates(reviewed: Optional[bool] = None) -> list[dict]:
    """
    Get duplicate relationships.

    Args:
        reviewed: Filter by reviewed status. None returns all.

    Returns:
        List of duplicate records with primary and duplicate file info
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        query = """
            SELECT
                d.id, d.reason, d.reviewed,
                pf.id as primary_id, pf.original_path as primary_path,
                pm.artist as primary_artist, pm.title as primary_title,
                pm.bitrate as primary_bitrate, pm.format as primary_format,
                df.id as duplicate_id, df.original_path as duplicate_path,
                dm.artist as duplicate_artist, dm.title as duplicate_title,
                dm.bitrate as duplicate_bitrate, dm.format as duplicate_format
            FROM duplicates d
            JOIN files pf ON d.primary_file_id = pf.id
            JOIN files df ON d.duplicate_file_id = df.id
            LEFT JOIN metadata pm ON pf.id = pm.file_id
            LEFT JOIN metadata dm ON df.id = dm.file_id
        """

        if reviewed is not None:
            query += " WHERE d.reviewed = ?"
            cursor.execute(query, (reviewed,))
        else:
            cursor.execute(query)

        results = []
        for row in cursor.fetchall():
            results.append({
                'id': row['id'],
                'reason': row['reason'],
                'reviewed': bool(row['reviewed']),
                'primary': {
                    'id': row['primary_id'],
                    'original_path': row['primary_path'],
                    'artist': row['primary_artist'],
                    'title': row['primary_title'],
                    'bitrate': row['primary_bitrate'],
                    'format': row['primary_format']
                },
                'duplicate': {
                    'id': row['duplicate_id'],
                    'original_path': row['duplicate_path'],
                    'artist': row['duplicate_artist'],
                    'title': row['duplicate_title'],
                    'bitrate': row['duplicate_bitrate'],
                    'format': row['duplicate_format']
                }
            })

        return results


def mark_duplicate_reviewed(duplicate_id: int) -> None:
    """
    Mark a duplicate record as reviewed.

    Args:
        duplicate_id: The ID of the duplicate record
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            UPDATE duplicates SET reviewed = 1 WHERE id = ?
        """, (duplicate_id,))

        conn.commit()


def update_sync_timestamp(file_id: int) -> None:
    """
    Update the last_synced timestamp for a file.

    Args:
        file_id: The ID of the file record
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            UPDATE files SET last_synced = CURRENT_TIMESTAMP WHERE id = ?
        """, (file_id,))

        conn.commit()


def mark_as_indexed(file_id: int) -> None:
    """
    Mark a file as indexed in the search index.

    Args:
        file_id: The ID of the file record
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            INSERT OR REPLACE INTO search_index (file_id, indexed_at)
            VALUES (?, CURRENT_TIMESTAMP)
        """, (file_id,))

        conn.commit()


def get_unindexed_files() -> list[dict]:
    """
    Get all files that haven't been indexed for search.

    Returns:
        List of file records that need indexing
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("""
            SELECT
                f.id, f.original_path, f.organized_path, f.is_soundcloud,
                f.imported_at, f.last_synced,
                m.artist, m.album_artist, m.album, m.title,
                m.genre, m.year, m.bitrate, m.format, m.duration
            FROM files f
            LEFT JOIN metadata m ON f.id = m.file_id
            LEFT JOIN search_index si ON f.id = si.file_id
            WHERE si.file_id IS NULL
        """)

        results = []
        for row in cursor.fetchall():
            results.append({
                'id': row['id'],
                'original_path': row['original_path'],
                'organized_path': row['organized_path'],
                'is_soundcloud': bool(row['is_soundcloud']),
                'imported_at': row['imported_at'],
                'last_synced': row['last_synced'],
                'metadata': {
                    'artist': row['artist'],
                    'album_artist': row['album_artist'],
                    'album': row['album'],
                    'title': row['title'],
                    'genre': row['genre'],
                    'year': row['year'],
                    'bitrate': row['bitrate'],
                    'format': row['format'],
                    'duration': row['duration']
                }
            })

        return results


def delete_file_record(file_id: int) -> bool:
    """
    Delete a file record and its associated metadata.
    Cascades to metadata and search_index due to foreign key constraints.

    Args:
        file_id: The ID of the file record to delete

    Returns:
        True if a record was deleted, False if not found
    """
    with get_connection() as conn:
        cursor = conn.cursor()

        cursor.execute("DELETE FROM files WHERE id = ?", (file_id,))
        deleted = cursor.rowcount > 0

        conn.commit()
        return deleted
