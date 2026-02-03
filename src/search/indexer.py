"""
Whoosh full-text search indexer for music library.

Creates and manages a Whoosh search index with the schema:
- file_id (NUMERIC): Database file ID for linking results
- artist (TEXT): Track artist
- album_artist (TEXT): Album artist (often different for compilations)
- album (TEXT): Album name
- title (TEXT): Track title
- genre (TEXT): Genre classification
- year (NUMERIC): Release year
- comments (TEXT): Additional searchable text

Uses config.WHOOSH_INDEX_DIR for index location.
Tracks indexing status in database search_index table.
"""

import os
from pathlib import Path
from typing import Optional

from whoosh import index
from whoosh.fields import Schema, TEXT, NUMERIC
from whoosh.analysis import StemmingAnalyzer

from src.core.config import WHOOSH_INDEX_DIR
from src.library.database import (
    get_all_files,
    get_file_by_id,
    get_unindexed_files,
    mark_as_indexed,
)


# Whoosh schema for music metadata
# Uses StemmingAnalyzer for better matching (e.g., "running" matches "run")
_analyzer = StemmingAnalyzer()

MUSIC_SCHEMA = Schema(
    file_id=NUMERIC(stored=True, unique=True),
    artist=TEXT(analyzer=_analyzer, stored=True),
    album_artist=TEXT(analyzer=_analyzer, stored=True),
    album=TEXT(analyzer=_analyzer, stored=True),
    title=TEXT(analyzer=_analyzer, stored=True),
    genre=TEXT(analyzer=_analyzer, stored=True),
    year=NUMERIC(stored=True),
    comments=TEXT(analyzer=_analyzer, stored=True),
)


def create_index(index_dir: Optional[Path] = None) -> index.Index:
    """
    Create a new Whoosh index with the music schema.

    Args:
        index_dir: Directory to store the index (defaults to WHOOSH_INDEX_DIR)

    Returns:
        The created Whoosh index

    Raises:
        OSError: If directory cannot be created
    """
    index_path = index_dir or WHOOSH_INDEX_DIR
    index_path = Path(index_path)

    # Create directory if it doesn't exist
    index_path.mkdir(parents=True, exist_ok=True)

    # Create and return the index
    return index.create_in(str(index_path), MUSIC_SCHEMA)


def get_index(index_dir: Optional[Path] = None) -> index.Index:
    """
    Get existing Whoosh index or create if it doesn't exist.

    Args:
        index_dir: Directory containing the index (defaults to WHOOSH_INDEX_DIR)

    Returns:
        The Whoosh index (existing or newly created)
    """
    index_path = index_dir or WHOOSH_INDEX_DIR
    index_path = Path(index_path)

    # Check if index exists
    if index.exists_in(str(index_path)):
        return index.open_dir(str(index_path))

    # Create new index
    return create_index(index_path)


def index_file(file_id: int, index_dir: Optional[Path] = None) -> bool:
    """
    Index a single file by its database ID.

    Args:
        file_id: Database ID of the file to index
        index_dir: Directory containing the index (defaults to WHOOSH_INDEX_DIR)

    Returns:
        True if file was indexed, False if file not found
    """
    file_record = get_file_by_id(file_id)
    if file_record is None:
        return False

    metadata = file_record.get('metadata', {})
    ix = get_index(index_dir)

    writer = ix.writer()
    try:
        # Use update_document to handle re-indexing gracefully
        writer.update_document(
            file_id=file_id,
            artist=metadata.get('artist') or '',
            album_artist=metadata.get('album_artist') or '',
            album=metadata.get('album') or '',
            title=metadata.get('title') or '',
            genre=metadata.get('genre') or '',
            year=metadata.get('year'),
            comments='',  # Reserved for future use (e.g., ID3 comments)
        )
        writer.commit()

        # Mark as indexed in database
        mark_as_indexed(file_id)
        return True

    except Exception:
        writer.cancel()
        raise


def index_library(index_dir: Optional[Path] = None) -> int:
    """
    Index all unindexed files from the database.

    Only indexes files that haven't been indexed yet (incremental).
    For full reindex, use reindex_library().

    Args:
        index_dir: Directory containing the index (defaults to WHOOSH_INDEX_DIR)

    Returns:
        Number of files indexed
    """
    unindexed = get_unindexed_files()
    if not unindexed:
        return 0

    ix = get_index(index_dir)
    writer = ix.writer()

    indexed_count = 0
    try:
        for file_record in unindexed:
            file_id = file_record['id']
            metadata = file_record.get('metadata', {})

            writer.update_document(
                file_id=file_id,
                artist=metadata.get('artist') or '',
                album_artist=metadata.get('album_artist') or '',
                album=metadata.get('album') or '',
                title=metadata.get('title') or '',
                genre=metadata.get('genre') or '',
                year=metadata.get('year'),
                comments='',
            )
            indexed_count += 1

        writer.commit()

        # Mark all as indexed in database
        for file_record in unindexed:
            mark_as_indexed(file_record['id'])

        return indexed_count

    except Exception:
        writer.cancel()
        raise


def reindex_library(index_dir: Optional[Path] = None) -> int:
    """
    Reindex all files from the database (full rebuild).

    Clears existing index and rebuilds from scratch.
    Use this when index is corrupted or schema changes.

    Args:
        index_dir: Directory to store the index (defaults to WHOOSH_INDEX_DIR)

    Returns:
        Number of files indexed
    """
    # Create fresh index (overwrites existing)
    ix = create_index(index_dir)

    all_files = get_all_files()
    if not all_files:
        return 0

    writer = ix.writer()

    indexed_count = 0
    try:
        for file_record in all_files:
            file_id = file_record['id']
            metadata = file_record.get('metadata', {})

            writer.add_document(
                file_id=file_id,
                artist=metadata.get('artist') or '',
                album_artist=metadata.get('album_artist') or '',
                album=metadata.get('album') or '',
                title=metadata.get('title') or '',
                genre=metadata.get('genre') or '',
                year=metadata.get('year'),
                comments='',
            )
            indexed_count += 1

        writer.commit()

        # Mark all as indexed in database
        for file_record in all_files:
            mark_as_indexed(file_record['id'])

        return indexed_count

    except Exception:
        writer.cancel()
        raise


def get_index_stats(index_dir: Optional[Path] = None) -> dict:
    """
    Get statistics about the search index.

    Args:
        index_dir: Directory containing the index (defaults to WHOOSH_INDEX_DIR)

    Returns:
        Dictionary with index statistics:
        - doc_count: Number of indexed documents
        - index_exists: Whether index exists
        - index_path: Path to index directory
    """
    index_path = index_dir or WHOOSH_INDEX_DIR
    index_path = Path(index_path)

    if not index.exists_in(str(index_path)):
        return {
            'doc_count': 0,
            'index_exists': False,
            'index_path': str(index_path),
        }

    ix = index.open_dir(str(index_path))
    return {
        'doc_count': ix.doc_count(),
        'index_exists': True,
        'index_path': str(index_path),
    }


if __name__ == '__main__':
    import sys

    # CLI: python -m src.search.indexer [reindex]
    if len(sys.argv) > 1 and sys.argv[1] == 'reindex':
        print("Reindexing entire library...")
        count = reindex_library()
        print(f"Reindexed {count} files")
    else:
        print("Indexing unindexed files...")
        count = index_library()
        print(f"Indexed {count} new files")

    stats = get_index_stats()
    print(f"Total documents in index: {stats['doc_count']}")
