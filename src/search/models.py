"""
Search result data models for music library search.

Provides dataclasses for:
- SearchResult: Individual search hit with metadata and score
- SearchResponse: Complete search response with timing and results
"""

from dataclasses import dataclass, field
from typing import Optional


@dataclass
class SearchResult:
    """
    A single search result with metadata and match score.

    Attributes:
        file_id: Database file ID
        artist: Track artist
        album_artist: Album artist (may differ for compilations)
        album: Album name
        title: Track title
        genre: Genre classification
        year: Release year (None if unknown)
        score: Match score (0-100, higher is better)
        original_path: Path where file is stored
        organized_path: Album Artist/Album/Track organized path
    """
    file_id: int
    artist: str
    album_artist: str
    album: str
    title: str
    genre: str
    year: Optional[int]
    score: float
    original_path: str
    organized_path: str

    def __str__(self) -> str:
        """Human-readable representation."""
        year_str = f" ({self.year})" if self.year else ""
        return f"{self.artist} - {self.title} [{self.album}{year_str}] ({self.score:.1f})"

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            'file_id': self.file_id,
            'artist': self.artist,
            'album_artist': self.album_artist,
            'album': self.album,
            'title': self.title,
            'genre': self.genre,
            'year': self.year,
            'score': self.score,
            'original_path': self.original_path,
            'organized_path': self.organized_path,
        }


@dataclass
class SearchResponse:
    """
    Complete search response with results and metadata.

    Attributes:
        query: Original search query string
        total_results: Number of results found
        results: List of SearchResult objects
        search_time_ms: Time taken to perform search in milliseconds
    """
    query: str
    total_results: int
    results: list[SearchResult] = field(default_factory=list)
    search_time_ms: float = 0.0

    def __str__(self) -> str:
        """Human-readable representation."""
        return f"Search '{self.query}': {self.total_results} results in {self.search_time_ms:.1f}ms"

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            'query': self.query,
            'total_results': self.total_results,
            'results': [r.to_dict() for r in self.results],
            'search_time_ms': self.search_time_ms,
        }
