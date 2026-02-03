"""
Search engine combining Whoosh full-text search with RapidFuzz fuzzy matching.

Search strategy:
1. Query Whoosh index for candidate documents (fast full-text search)
2. Apply RapidFuzz token_set_ratio for fuzzy scoring (handles subsets, typos, reordering)
3. Filter by configurable threshold (default 80)
4. Return results sorted by score descending

Supports:
- General search across all fields
- Field-specific search (artist, album, title)
- CLI interface for testing
"""

import time
from pathlib import Path
from typing import Optional

from whoosh.qparser import MultifieldParser, OrGroup, FuzzyTermPlugin
from whoosh import query as whoosh_query
from rapidfuzz import fuzz

from src.core.config import SEARCH_FUZZY_THRESHOLD, WHOOSH_INDEX_DIR
from src.library.database import get_file_by_id
from src.search.indexer import get_index
from src.search.models import SearchResult, SearchResponse


def _calculate_fuzzy_score(query: str, candidate: dict) -> float:
    """
    Calculate fuzzy match score between query and candidate metadata.

    Uses a combination of fuzzy algorithms for best results:
    - token_set_ratio: handles word reordering and subsets
    - partial_ratio: handles substring matching with typos

    Scores each field individually and returns the best match.

    Args:
        query: Search query string
        candidate: Dictionary with artist, album, title fields

    Returns:
        Score from 0-100 (higher is better match)
    """
    query_lower = query.lower()
    max_score = 0.0

    # Score against each field individually and take best match
    for field in ['artist', 'album_artist', 'album', 'title']:
        value = candidate.get(field)
        if value:
            value_lower = value.lower()
            # Use both algorithms and take the best score:
            # - token_set_ratio: good for word reordering ("daft punk" vs "Punk, Daft")
            # - partial_ratio: good for substring typos ("djem" vs "Dzem - Koszmarna Noc")
            score1 = fuzz.token_set_ratio(query_lower, value_lower)
            score2 = fuzz.partial_ratio(query_lower, value_lower)
            score = max(score1, score2)
            max_score = max(max_score, score)

    return max_score


def _build_search_result(file_id: int, score: float) -> Optional[SearchResult]:
    """
    Build a SearchResult from file_id and score.

    Args:
        file_id: Database file ID
        score: Fuzzy match score

    Returns:
        SearchResult or None if file not found
    """
    file_record = get_file_by_id(file_id)
    if file_record is None:
        return None

    metadata = file_record.get('metadata', {})

    return SearchResult(
        file_id=file_id,
        artist=metadata.get('artist') or '',
        album_artist=metadata.get('album_artist') or '',
        album=metadata.get('album') or '',
        title=metadata.get('title') or '',
        genre=metadata.get('genre') or '',
        year=metadata.get('year'),
        score=score,
        original_path=file_record.get('original_path', ''),
        organized_path=file_record.get('organized_path', ''),
    )


def search_library(
    query: str,
    limit: int = 50,
    threshold: Optional[int] = None,
    index_dir: Optional[Path] = None,
) -> SearchResponse:
    """
    Search the music library with fuzzy matching.

    Strategy:
    1. Query Whoosh for candidates matching any query terms
    2. Apply RapidFuzz token_sort_ratio for fuzzy scoring
    3. Filter by threshold and return top results

    Args:
        query: Search query (searches artist, album, title, genre)
        limit: Maximum number of results to return
        threshold: Minimum fuzzy score (0-100). Defaults to SEARCH_FUZZY_THRESHOLD
        index_dir: Path to Whoosh index. Defaults to WHOOSH_INDEX_DIR

    Returns:
        SearchResponse with results sorted by score descending
    """
    start_time = time.perf_counter()

    # Use configured threshold if not specified
    if threshold is None:
        threshold = SEARCH_FUZZY_THRESHOLD

    # Handle empty query
    query = query.strip()
    if not query:
        return SearchResponse(
            query=query,
            total_results=0,
            results=[],
            search_time_ms=0.0,
        )

    # Get Whoosh index
    ix = get_index(index_dir)

    # Search across multiple fields with fuzzy matching
    parser = MultifieldParser(
        ['artist', 'album_artist', 'album', 'title', 'genre'],
        schema=ix.schema,
        group=OrGroup,  # Match ANY term for broader initial candidates
    )
    # Add fuzzy term support for typo tolerance (e.g., "djem" matches "dzem")
    parser.add_plugin(FuzzyTermPlugin())

    # Build fuzzy query: append ~1 to each word for 1-edit distance tolerance
    # This allows Whoosh to find candidates even with typos
    fuzzy_query = ' '.join(f'{word}~1' for word in query.split())

    # Parse query (handles multiple words with fuzzy matching)
    try:
        parsed_query = parser.parse(fuzzy_query)
    except Exception:
        # Fall back to simple every term in every field
        parsed_query = whoosh_query.Every()

    # Get candidates from Whoosh
    candidates = []
    with ix.searcher() as searcher:
        # Get more candidates than needed for fuzzy filtering
        # Whoosh is fast, so overfetch to ensure good fuzzy results
        whoosh_results = searcher.search(parsed_query, limit=limit * 3)

        for hit in whoosh_results:
            file_id = hit['file_id']
            # Get metadata for fuzzy scoring
            candidate = {
                'file_id': file_id,
                'artist': hit.get('artist', ''),
                'album_artist': hit.get('album_artist', ''),
                'album': hit.get('album', ''),
                'title': hit.get('title', ''),
            }
            candidates.append(candidate)

    # Apply fuzzy scoring and filtering
    scored_results = []
    for candidate in candidates:
        score = _calculate_fuzzy_score(query, candidate)
        if score >= threshold:
            result = _build_search_result(candidate['file_id'], score)
            if result:
                scored_results.append(result)

    # Sort by score descending
    scored_results.sort(key=lambda r: r.score, reverse=True)

    # Limit results
    results = scored_results[:limit]

    elapsed_ms = (time.perf_counter() - start_time) * 1000

    return SearchResponse(
        query=query,
        total_results=len(results),
        results=results,
        search_time_ms=round(elapsed_ms, 2),
    )


def search_by_artist(
    artist: str,
    limit: int = 50,
    threshold: Optional[int] = None,
    index_dir: Optional[Path] = None,
) -> SearchResponse:
    """
    Search for tracks by artist name.

    Args:
        artist: Artist name to search
        limit: Maximum results
        threshold: Minimum fuzzy score
        index_dir: Path to Whoosh index

    Returns:
        SearchResponse with matching tracks
    """
    start_time = time.perf_counter()

    if threshold is None:
        threshold = SEARCH_FUZZY_THRESHOLD

    artist = artist.strip()
    if not artist:
        return SearchResponse(query=artist, total_results=0, results=[], search_time_ms=0.0)

    ix = get_index(index_dir)

    # Search only artist fields
    parser = MultifieldParser(['artist', 'album_artist'], schema=ix.schema, group=OrGroup)

    try:
        parsed_query = parser.parse(artist)
    except Exception:
        parsed_query = whoosh_query.Every()

    candidates = []
    with ix.searcher() as searcher:
        whoosh_results = searcher.search(parsed_query, limit=limit * 3)
        for hit in whoosh_results:
            candidates.append({
                'file_id': hit['file_id'],
                'artist': hit.get('artist', ''),
                'album_artist': hit.get('album_artist', ''),
            })

    # Fuzzy score against artist only
    scored_results = []
    for candidate in candidates:
        artist_text = f"{candidate.get('artist', '')} {candidate.get('album_artist', '')}".strip()
        score = fuzz.token_set_ratio(artist.lower(), artist_text.lower())
        if score >= threshold:
            result = _build_search_result(candidate['file_id'], score)
            if result:
                scored_results.append(result)

    scored_results.sort(key=lambda r: r.score, reverse=True)
    results = scored_results[:limit]

    elapsed_ms = (time.perf_counter() - start_time) * 1000

    return SearchResponse(
        query=f"artist:{artist}",
        total_results=len(results),
        results=results,
        search_time_ms=round(elapsed_ms, 2),
    )


def search_by_album(
    album: str,
    limit: int = 50,
    threshold: Optional[int] = None,
    index_dir: Optional[Path] = None,
) -> SearchResponse:
    """
    Search for tracks by album name.

    Args:
        album: Album name to search
        limit: Maximum results
        threshold: Minimum fuzzy score
        index_dir: Path to Whoosh index

    Returns:
        SearchResponse with matching tracks
    """
    start_time = time.perf_counter()

    if threshold is None:
        threshold = SEARCH_FUZZY_THRESHOLD

    album = album.strip()
    if not album:
        return SearchResponse(query=album, total_results=0, results=[], search_time_ms=0.0)

    ix = get_index(index_dir)

    parser = MultifieldParser(['album'], schema=ix.schema, group=OrGroup)

    try:
        parsed_query = parser.parse(album)
    except Exception:
        parsed_query = whoosh_query.Every()

    candidates = []
    with ix.searcher() as searcher:
        whoosh_results = searcher.search(parsed_query, limit=limit * 3)
        for hit in whoosh_results:
            candidates.append({
                'file_id': hit['file_id'],
                'album': hit.get('album', ''),
            })

    scored_results = []
    for candidate in candidates:
        album_text = candidate.get('album', '')
        score = fuzz.token_set_ratio(album.lower(), album_text.lower())
        if score >= threshold:
            result = _build_search_result(candidate['file_id'], score)
            if result:
                scored_results.append(result)

    scored_results.sort(key=lambda r: r.score, reverse=True)
    results = scored_results[:limit]

    elapsed_ms = (time.perf_counter() - start_time) * 1000

    return SearchResponse(
        query=f"album:{album}",
        total_results=len(results),
        results=results,
        search_time_ms=round(elapsed_ms, 2),
    )


def search_by_title(
    title: str,
    limit: int = 50,
    threshold: Optional[int] = None,
    index_dir: Optional[Path] = None,
) -> SearchResponse:
    """
    Search for tracks by title.

    Args:
        title: Track title to search
        limit: Maximum results
        threshold: Minimum fuzzy score
        index_dir: Path to Whoosh index

    Returns:
        SearchResponse with matching tracks
    """
    start_time = time.perf_counter()

    if threshold is None:
        threshold = SEARCH_FUZZY_THRESHOLD

    title = title.strip()
    if not title:
        return SearchResponse(query=title, total_results=0, results=[], search_time_ms=0.0)

    ix = get_index(index_dir)

    parser = MultifieldParser(['title'], schema=ix.schema, group=OrGroup)

    try:
        parsed_query = parser.parse(title)
    except Exception:
        parsed_query = whoosh_query.Every()

    candidates = []
    with ix.searcher() as searcher:
        whoosh_results = searcher.search(parsed_query, limit=limit * 3)
        for hit in whoosh_results:
            candidates.append({
                'file_id': hit['file_id'],
                'title': hit.get('title', ''),
            })

    scored_results = []
    for candidate in candidates:
        title_text = candidate.get('title', '')
        score = fuzz.token_set_ratio(title.lower(), title_text.lower())
        if score >= threshold:
            result = _build_search_result(candidate['file_id'], score)
            if result:
                scored_results.append(result)

    scored_results.sort(key=lambda r: r.score, reverse=True)
    results = scored_results[:limit]

    elapsed_ms = (time.perf_counter() - start_time) * 1000

    return SearchResponse(
        query=f"title:{title}",
        total_results=len(results),
        results=results,
        search_time_ms=round(elapsed_ms, 2),
    )


if __name__ == '__main__':
    import sys

    # CLI: python -m src.search.engine <query>
    if len(sys.argv) < 2:
        print("Usage: python -m src.search.engine <query>")
        print("       python -m src.search.engine --artist <artist>")
        print("       python -m src.search.engine --album <album>")
        print("       python -m src.search.engine --title <title>")
        sys.exit(1)

    # Parse arguments
    if sys.argv[1] == '--artist' and len(sys.argv) > 2:
        query = ' '.join(sys.argv[2:])
        response = search_by_artist(query)
    elif sys.argv[1] == '--album' and len(sys.argv) > 2:
        query = ' '.join(sys.argv[2:])
        response = search_by_album(query)
    elif sys.argv[1] == '--title' and len(sys.argv) > 2:
        query = ' '.join(sys.argv[2:])
        response = search_by_title(query)
    else:
        query = ' '.join(sys.argv[1:])
        response = search_library(query)

    # Display results
    print(f"\n{response}")
    print("-" * 60)

    if response.results:
        for i, result in enumerate(response.results, 1):
            print(f"{i:3}. {result}")
    else:
        print("No results found.")

    print("-" * 60)
    print(f"Search completed in {response.search_time_ms:.2f}ms")
