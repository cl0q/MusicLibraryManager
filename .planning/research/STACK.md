# Technology Stack

**Project:** Music Library Manager
**Researched:** 2026-02-03
**Confidence:** MEDIUM-HIGH

## Executive Summary

The music library management application requires a Python-centric stack optimized for:
- Audio processing and transcoding (FLAC to AAC)
- Metadata manipulation across multiple formats
- API integrations with streaming services
- Cross-platform desktop UI
- Local database for library state
- File system operations and monitoring

**Recommended approach:** Python backend with PySide6 Qt-based desktop UI, SQLAlchemy for database, FFmpeg for transcoding, and established libraries for API integrations.

---

## Core Framework & UI

### Desktop UI Framework

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **PySide6** | 6.10.2 | Cross-platform desktop UI | Official Qt for Python binding (LGPL-licensed), native look and feel on macOS/Windows/Linux, mature ecosystem, actively maintained with Python 3.9-3.14 support. Released Feb 2, 2026. |
| Python | 3.11+ | Runtime | Balance of modern features and library compatibility. PySide6 supports 3.9-3.14, but 3.11+ recommended for performance and typing improvements. |

**Rationale:** PySide6 (Qt for Python) is the clear choice for professional cross-platform desktop applications in 2026. It provides:
- Native widgets and platform integration
- Rich UI components for dashboards (progress bars, tables, status displays)
- Excellent documentation and active development
- Production-ready stability

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **Tkinter** | Too basic for dashboard/control panel aesthetics, looks dated |
| **wxPython** | Less active development than Qt, smaller ecosystem |
| **Kivy** | Better for touch/mobile interfaces, overkill for desktop-focused app |
| **Flet** | Too new (2023+), smaller ecosystem, less mature for production |
| **Electron/Tauri + Python** | Adds complexity with separate frontend/backend, larger bundle size, Python integration via IPC overhead |

**Confidence:** HIGH

---

## Audio Processing & Transcoding

### Audio Transcoding

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **FFmpeg** | Latest (7.x) | Audio transcoding engine | Industry standard for audio/video processing, handles FLAC→AAC conversion with quality control, supports all needed formats (FLAC, AAC, MP3, OGG, etc.) |
| **subprocess** | stdlib | FFmpeg execution | Direct subprocess calls provide full control over FFmpeg parameters without wrapper abstraction, more reliable than aging wrappers |

**Rationale:** Use Python's subprocess module to call FFmpeg directly rather than wrappers:
- `ffmpeg-python` (0.2.0) is unmaintained since 2019
- `pydub` (0.25.1) last updated March 2021, also wraps FFmpeg
- Direct subprocess calls provide full parameter control for quality settings (e.g., 248kbps AAC)
- More explicit error handling and logging

**Example approach:**
```python
import subprocess

def transcode_to_aac(input_flac: Path, output_aac: Path, bitrate: str = "248k"):
    cmd = [
        "ffmpeg", "-i", str(input_flac),
        "-c:a", "aac", "-b:a", bitrate,
        "-movflags", "+faststart",
        str(output_aac)
    ]
    subprocess.run(cmd, check=True, capture_output=True)
```

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **pydub** | Wrapper around FFmpeg, last updated 2021, adds unnecessary abstraction layer |
| **ffmpeg-python** | Unmaintained since 2019, no recent updates despite active issues |
| **PyAV** | Lower-level bindings, more complex for basic transcoding tasks |

**Confidence:** HIGH

### Audio Metadata

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Mutagen** | 1.47.0 | Audio metadata reading/writing | Most comprehensive Python library for metadata, supports all required formats (MP3, FLAC, AAC, M4A, OGG), no dependencies outside stdlib, actively used by professional tools (Beets, Picard), supports ID3v2, APEv2, Vorbis comments |

**Rationale:** Mutagen is the de-facto standard for audio metadata in Python:
- Handles all major audio formats needed (FLAC, AAC/M4A, MP3, OGG)
- Lossless metadata editing (doesn't alter audio data)
- Full Unicode support
- Python 3.10+ compatible
- Used by established music tools (Beets music organizer, MusicBrainz Picard tagger)

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **music-tag** | Just a wrapper around Mutagen, adds no value |
| **TinyTag** | Read-only, no write support (needed for tag normalization) |
| **eyeD3** | MP3-only (ID3 tags), doesn't support FLAC/AAC metadata |
| **audio-metadata** | Less mature, smaller ecosystem than Mutagen |

**Confidence:** HIGH

---

## API Integrations

### Spotify

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Spotipy** | 2.25.2 | Spotify Web API client | Official community-maintained library, supports all Spotify API endpoints, handles OAuth2 flows, actively maintained (Nov 2025 release), comprehensive documentation |

**Rationale:** Spotipy is the established standard for Spotify API access in Python:
- Full coverage of Spotify Web API
- Built-in authentication (SpotifyOAuth, SpotifyClientCredentials)
- Active development and bug fixes
- Large user base and extensive examples

**Confidence:** HIGH

### Apple Music

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **apple-music-python** | 1.0.6 | Apple Music API client | Most recently updated Python wrapper (Dec 28, 2024), supports MusicKit API, provides search, playlist, album, and artist data access |

**Rationale:** Limited options for Apple Music API in Python compared to Spotify:
- `apple-music-python` is the most actively maintained (updated Dec 2024)
- Requires Apple Developer Account with MusicKit API key
- Documented at apple-music-python.readthedocs.io

**Note:** Apple Music API ecosystem is significantly smaller than Spotify's. Most official resources are in Swift/JavaScript. This Python library has modest adoption (558 weekly downloads) but is the best available option.

**Confidence:** MEDIUM (library has limited adoption, but it's the best Python option available)

### SoundCloud

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **soundcloud-v2** / **soundcloud.py** | Latest | SoundCloud API v2 client | Uses internal v2 API (no API key required since SoundCloud stopped accepting new registrations), read-only methods sufficient for library management |

**Rationale:** SoundCloud API situation is challenging:
- Official API registration is closed to new applications
- Community libraries use internal v2 API (reverse-engineered)
- `soundcloud.py` (by 7x11x13) is most maintained option
- Read-only access is sufficient for "like" detection and download

**Important caveat:** Using internal API carries risk of breakage if SoundCloud changes endpoints. However, it's the only viable option without legacy API credentials.

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **soundcloud (official SDK)** | Requires legacy API credentials (registration closed) |
| **SoundcloudPy** | Less actively maintained than soundcloud.py |

**Confidence:** LOW-MEDIUM (internal API dependency, but no better options exist)

---

## Database

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **SQLAlchemy** | 2.0.46 | ORM and database toolkit | Industry-standard Python ORM, excellent async support, type-safe queries with 2.0 syntax, handles SQLite backend, provides migration path if scaling needed, actively maintained (Jan 21, 2026 release) |
| **SQLite** | 3.x (via stdlib) | Database engine | Embedded database, no server required, perfect for local library state, included in Python stdlib, reliable and fast for single-user desktop apps |

**Rationale:** SQLAlchemy provides the right balance of power and simplicity:
- Production-grade ORM with excellent documentation
- Type-safe queries (important for maintainability)
- Async support (useful for background sync operations)
- SQLite backend is zero-configuration, perfect for local database
- Migration path to PostgreSQL/MySQL if multi-user support ever needed

**Performance note:** Raw `sqlite3` is ~2.8x faster for simple operations (1.2s vs 3.4s for 5M rows), but SQLAlchemy's developer productivity, type safety, and query builder outweigh the performance overhead for this use case. The app is I/O-bound (network APIs, file operations), not database-bound.

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **sqlite3 (stdlib)** | Raw SQL strings are error-prone, no type safety, manual migration management, harder to maintain complex queries |
| **Peewee** | Smaller ecosystem than SQLAlchemy, less comprehensive documentation |
| **TinyDB** | JSON-based, no SQL support, not suitable for relational library data |

**Confidence:** HIGH

---

## HTTP Client

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **httpx** | 0.28.1 | HTTP client for API calls | Modern HTTP client with both sync and async support, HTTP/2 support (faster for streaming APIs), drop-in replacement for `requests`, active development (Dec 2024), Python 3.8+ compatible |

**Rationale:** httpx is the modern choice for HTTP operations in 2026:
- Dual sync/async API (can use sync for simple calls, async for concurrent API requests)
- HTTP/2 support improves performance for repeated API calls
- Better async design than aiohttp for mixed codebases
- Clean API similar to `requests` for easy migration

**Use cases:**
- Sync API: Quick one-off API calls during development
- Async API: Concurrent fetching from Spotify/Apple Music/SoundCloud APIs
- File downloads: Streaming downloads with progress tracking

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **requests** | Sync-only, no HTTP/2 support, slower for concurrent operations |
| **aiohttp** | Async-only (forces async everywhere), no HTTP/2 support, more complex API |

**Confidence:** HIGH

---

## File System & Monitoring

| Technology | Version | Purpose | Why |
|-------------|---------|---------|-----|
| **watchdog** | 6.0.0 | File system event monitoring | Cross-platform file monitoring, detects changes to music library directories, Python 3.9+ support, actively maintained (Nov 2024), used for detecting manual file additions/changes |
| **pathlib** | stdlib | Path manipulation | Modern path handling (Python 3.4+), OS-agnostic, cleaner than `os.path` |

**Rationale:** watchdog is the established solution for file system monitoring:
- Monitors directories for create/modify/delete events
- Cross-platform (macOS FSEvents, Linux inotify, Windows ReadDirectoryChangesW)
- Use case: Detect when user manually adds music files to watched directories
- Observer pattern for event handling

**Confidence:** HIGH

---

## Configuration Management

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **pydantic-settings** | Latest (2.x) | Settings management | Type-safe configuration with Pydantic models, validates settings on load, supports .env files + environment variables, integrates well with modern Python (type hints), cleaner than Dynaconf for straightforward use cases |
| **python-dotenv** | Latest | .env file loading | Loads .env files for local development, standard pattern for secrets (API keys, credentials) |

**Rationale:** pydantic-settings provides validated, type-safe configuration:
- Define settings as Pydantic models with type hints
- Automatic validation on load (catch config errors early)
- Supports .env files, environment variables, and priority ordering
- Well-suited for FastAPI-style applications (clean, modern Python)

**Example:**
```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    spotify_client_id: str
    spotify_client_secret: str
    apple_music_api_key: str
    library_path: Path
    output_bitrate: int = 248

    class Config:
        env_file = ".env"
```

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **Dynaconf** | Overkill for single-environment desktop app, more complex than needed |
| **ConfigParser** | INI format is less modern, no type validation, manual parsing |
| **TOML + tomli** | Requires manual validation, less integrated than pydantic-settings |

**Confidence:** HIGH

---

## Logging

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **loguru** | 0.7.3 | Application logging | Modern logging with zero config, colorful console output, structured logging support (JSON), automatic exception tracing with variable values, single logger instance (simpler than stdlib logging), released Dec 2024 |

**Rationale:** loguru makes logging enjoyable and productive:
- Single pre-configured logger (no complex logger hierarchies)
- Beautiful console output for development
- Automatic rotation, retention, compression for log files
- Full stack traces with variable values (critical for debugging)
- JSON serialization for structured logs (useful for monitoring)
- Much simpler API than stdlib `logging` module

**Example:**
```python
from loguru import logger

logger.add("music_library_{time}.log", rotation="10 MB")
logger.info("Transcoding {file} to AAC", file=filename)
logger.exception("Failed to download from SoundCloud")  # Auto-includes traceback
```

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **stdlib logging** | Complex configuration, verbose setup, no colored output, harder to use |
| **structlog** | More complex than loguru, better for large distributed systems (overkill here) |

**Confidence:** HIGH

---

## Concurrency

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **asyncio** | stdlib | Async I/O for API calls | Efficient concurrent API requests (Spotify/Apple Music/SoundCloud), built into Python 3.7+, works well with httpx async client |
| **threading** | stdlib | CPU-bound operations | FFmpeg transcoding in background threads, file copy operations to iPod |

**Rationale:** Hybrid approach using both async and threads:

**asyncio for I/O-bound:**
- Concurrent API requests to multiple streaming services
- Efficient for high-volume network operations
- Lower memory overhead than threads (2KB/task vs 10KB/thread)
- Works naturally with httpx async API

**threading for blocking operations:**
- FFmpeg transcoding (spawns subprocess, blocks during encoding)
- File copy operations (filesystem I/O, blocking)
- Progress bar updates from background tasks

**Note:** Python's `aiofiles` library uses threads under the hood, so threading is already involved in "async" file I/O. For this application, explicit threading for long-running blocking operations (transcoding, file copy) is clearer and more maintainable.

**Confidence:** HIGH

---

## Dependency Management & Packaging

### Dependency Management

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Poetry** | Latest (1.8+) | Dependency management | Mature dependency resolution, lockfile for reproducible builds, clean pyproject.toml format, handles dev dependencies, simplifies packaging, Python 3.9+ required |

**Rationale:** Poetry is the established standard in 2026:
- Deterministic dependency resolution with poetry.lock
- Clear separation of runtime vs dev dependencies
- Integrates package metadata (version, authors) with dependencies
- Simple commands: `poetry add`, `poetry install`, `poetry build`
- Wide adoption and excellent documentation

**Alternatives considered:**

| Alternative | Why Not |
|-------------|---------|
| **PDM** | More standards-compliant (PEP 582), but Poetry is more widely adopted, better documented |
| **pip-tools** | Requires more manual work (requirements.in → requirements.txt), less integrated |
| **pipenv** | Slower dependency resolution than Poetry, less active development |

**Confidence:** HIGH

### Application Packaging

| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **PyInstaller** | Latest (6.x) | Create standalone executables | Fast build times, widely used, good cross-platform support, simpler than Nuitka for initial releases |
| **Nuitka** (future) | Latest (2.x) | Compiled executables | Consider for v2+: True Python-to-C compilation, faster startup, smaller memory footprint, but slower build times |

**Rationale:** Start with PyInstaller, migrate to Nuitka if needed:

**PyInstaller advantages:**
- Fast iteration during development (quick rebuilds)
- Bundles Python interpreter + dependencies
- Well-documented, large community
- Easier debugging (no compilation step)

**Nuitka consideration for future:**
- True compilation to C (better performance)
- Faster startup time (no extraction phase)
- Smaller memory footprint
- Trade-off: Much slower build times (compile entire app + deps)

**Recommendation:** Use PyInstaller for MVP and early releases. Evaluate Nuitka after v1.0 if startup performance becomes a user complaint.

**Confidence:** HIGH (PyInstaller), MEDIUM (Nuitka for future)

---

## Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| **pydantic** | 2.x | Data validation | Validate API responses, ensure data integrity before database writes, type-safe model definitions |
| **python-dotenv** | Latest | Environment variables | Load .env file in development (API keys, paths), used by pydantic-settings |
| **pytest** | Latest | Testing framework | Unit tests for audio processing, API mocking, database operations |
| **click** | Latest (8.x) | CLI interface | Optional: Command-line interface for batch operations, scripting |
| **typer** | Latest | CLI alternative | Alternative to click: Type-hint based CLI, integrates with Pydantic |

**Confidence:** HIGH

---

## Installation Summary

### System Requirements

```bash
# macOS (Homebrew)
brew install python@3.11 ffmpeg

# Ubuntu/Debian
sudo apt install python3.11 ffmpeg

# Windows (Chocolatey)
choco install python311 ffmpeg
```

### Python Dependencies

```toml
# pyproject.toml (Poetry)

[tool.poetry.dependencies]
python = "^3.11"
PySide6 = "^6.10.2"
SQLAlchemy = "^2.0.46"
httpx = "^0.28.1"
mutagen = "^1.47.0"
spotipy = "^2.25.2"
apple-music-python = "^1.0.6"
soundcloud-v2 = "*"  # or soundcloud.py
watchdog = "^6.0.0"
pydantic-settings = "^2.0"
pydantic = "^2.0"
python-dotenv = "^1.0"
loguru = "^0.7.3"

[tool.poetry.dev-dependencies]
pytest = "^8.0"
pytest-asyncio = "^0.23"
black = "^24.0"
mypy = "^1.8"
ruff = "^0.2"
```

---

## Architecture Implications

### Recommended Structure

```
music-library-manager/
├── src/
│   ├── ui/              # PySide6 UI components
│   ├── audio/           # FFmpeg transcoding, Mutagen metadata
│   ├── api/             # Spotipy, Apple Music, SoundCloud clients
│   ├── db/              # SQLAlchemy models
│   ├── sync/            # File system sync, watchdog monitoring
│   └── config/          # pydantic-settings configuration
├── tests/
├── pyproject.toml       # Poetry dependencies
└── .env.example
```

### Key Design Decisions

1. **UI Layer:** PySide6 main window with threaded background workers for long operations
2. **API Layer:** httpx async client for concurrent streaming service requests
3. **Audio Layer:** Direct FFmpeg subprocess calls (avoid wrapper abstractions)
4. **Database Layer:** SQLAlchemy ORM with SQLite backend
5. **Sync Layer:** watchdog for directory monitoring, threading for file copy operations
6. **Config Layer:** pydantic-settings for validated configuration

---

## Risk Assessment

| Technology | Risk Level | Mitigation |
|------------|-----------|------------|
| PySide6 | LOW | Mature, actively maintained, large community |
| FFmpeg | LOW | Industry standard, subprocess isolation prevents crashes |
| Mutagen | LOW | Widely used, stable API |
| Spotipy | LOW | Official community project, active development |
| apple-music-python | MEDIUM | Small user base, but recently updated, only Python option |
| soundcloud-v2 | MEDIUM-HIGH | Internal API dependency (could break), no official alternative |
| SQLAlchemy | LOW | Industry standard, comprehensive docs |
| httpx | LOW | Modern, actively maintained, backed by Encode |
| PyInstaller | LOW | Widely used for Python desktop apps |

**Critical dependency:** SoundCloud integration is highest risk due to unofficial API usage. Recommend:
- Abstract SoundCloud API behind interface (easy to swap implementations)
- Monitor for API changes
- Have fallback plan (manual downloads if API breaks)

---

## Version Pinning Strategy

**Lock all versions in production:**
- Use Poetry's poetry.lock for exact dependency versions
- Pin FFmpeg version in system requirements
- Document Python version (3.11 minimum)

**Stay current with security:**
- Update dependencies quarterly
- Monitor security advisories for httpx, PySide6, SQLAlchemy
- Test updates in development before deploying

---

## Sources

**Note:** All WebSearch findings verified against official documentation where possible.

### Official Documentation (HIGH Confidence)
- [PySide6 PyPI](https://pypi.org/project/PySide6/) - Version 6.10.2, Feb 2, 2026
- [Mutagen Documentation](https://mutagen.readthedocs.io/) - Python 3.10+, comprehensive format support
- [Spotipy GitHub](https://github.com/spotipy-dev/spotipy) - Version 2.25.2, Nov 26, 2025
- [SQLAlchemy PyPI](https://pypi.org/project/SQLAlchemy/) - Version 2.0.46, Jan 21, 2026
- [httpx PyPI](https://pypi.org/project/httpx/) - Version 0.28.1, Dec 6, 2024
- [watchdog PyPI](https://pypi.org/project/watchdog/) - Version 6.0.0, Nov 1, 2024
- [loguru PyPI](https://pypi.org/project/loguru/) - Version 0.7.3, Dec 6, 2024
- [apple-music-python PyPI](https://pypi.org/project/apple-music-python/) - Version 1.0.6, Dec 28, 2024
- [PyDub GitHub](https://github.com/jiaaro/pydub) - Version 0.25.1, Mar 10, 2021

### Community Resources (MEDIUM Confidence)
- [Which Python GUI library should you use in 2026?](https://www.pythonguis.com/faq/which-python-gui-library/)
- [How to Use FFmpeg with Python in 2026?](https://www.gumlet.com/learn/ffmpeg-python/)
- [SQLite vs SQLAlchemy: Write better SQL the leading Python ORM](https://www.thenerdnook.io/p/sqlite-vs-sqlalchemy)
- [Asyncio Vs Threading In Python](https://www.geeksforgeeks.org/python/asyncio-vs-threading-in-python/)
- [HTTPX vs Requests vs AIOHTTP](https://oxylabs.io/blog/httpx-vs-requests-vs-aiohttp)
- [Logging in Python: A Comparison of the Top 6 Libraries](https://betterstack.com/community/guides/logging/best-python-logging-libraries/)
- [Pydantic BaseSettings vs. Dynaconf](https://leapcell.io/blog/pydantic-basesettings-vs-dynaconf-a-modern-guide-to-application-configuration)
- [The State of Python Packaging in 2026](https://learn.repoforge.io/posts/the-state-of-python-packaging-in-2026/)
- [PyInstaller vs Nuitka Comparison](https://medium.com/@jasonyang.algo/from-python-script-to-stand-alone-exe-a-practical-guide-with-pyinstaller-and-nuitka-cf0dd81271dc)

### Ecosystem Research (LOW-MEDIUM Confidence)
- [awesome-python-audio](https://github.com/andreimatveyeu/awesome-python-audio)
- [SoundCloud API discussions](https://developers.soundcloud.com/docs/api/guide)
- [soundcloud.py GitHub](https://github.com/7x11x13/soundcloud.py)

---

## Confidence Assessment

| Category | Confidence | Notes |
|----------|-----------|-------|
| UI Framework (PySide6) | HIGH | Verified from PyPI, active development, current version confirmed |
| Audio Processing (FFmpeg/Mutagen) | HIGH | Industry standards, verified versions, extensive documentation |
| Database (SQLAlchemy/SQLite) | HIGH | Verified current version, well-established patterns |
| API Clients (Spotify) | HIGH | Official community library, active maintenance |
| API Clients (Apple Music) | MEDIUM | Limited ecosystem, but verified recent update (Dec 2024) |
| API Clients (SoundCloud) | LOW-MEDIUM | Internal API usage, unverified reliability, but no alternatives |
| HTTP Client (httpx) | HIGH | Verified version, active development, modern standard |
| Logging (loguru) | HIGH | Verified version, widely recommended in 2026 sources |
| Packaging (Poetry/PyInstaller) | HIGH | Established tools, current best practices |

**Overall stack confidence: MEDIUM-HIGH**

The stack is solid with one notable risk: SoundCloud integration relies on unofficial API access. All other components are production-grade, actively maintained, and well-documented.
