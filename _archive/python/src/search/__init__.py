"""
Search module for music library full-text search and fuzzy matching.

Provides:
- Whoosh-based full-text indexing for instant search
- RapidFuzz fuzzy matching for typo tolerance
- Search result models with scoring

Usage:
    from src.search.indexer import index_library
    from src.search.engine import search_library

    # Index all files in database
    index_library()

    # Search with fuzzy matching
    results = search_library("daft punk")
"""

from src.search.models import SearchResult, SearchResponse
from src.search.indexer import index_library, reindex_library
from src.search.engine import search_library

__all__ = [
    'SearchResult',
    'SearchResponse',
    'index_library',
    'reindex_library',
    'search_library',
]
