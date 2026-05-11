# MLM macOS App — Build & Debug

This is a Swift Package executable (`Package.swift`), not an Xcode project.
The same `Package.swift` powers three workflows: terminal builds, ad-hoc
`.app` bundle launches, and Xcode debugging with breakpoints.

## Quick start

From `macos-app/`:

```bash
swift build               # debug build, ~2 s incremental
swift test                # run the test suite
./scripts/run.sh          # build + open as .app
./scripts/run.sh --kill   # kill any running MLM, rebuild, open
./scripts/run.sh --clean  # nuke .build/ first, full rebuild
./scripts/run.sh --release # optimized release build
```

The `.app` bundle is written to `.build/MLM.app` (gitignored). Info.plist
is regenerated on every run; ad-hoc codesigned so macOS picks up changes.

## Debugging with Xcode

Best for setting breakpoints and watching stdout/stderr live.

```bash
cd macos-app
open Package.swift
```

In Xcode:

1. Wait for SwiftPM to resolve dependencies (GRDB.swift).
2. Top-left scheme picker → select **MLM** (executable).
3. ⌘R to build + run with debugger attached.

stdout/stderr land in Xcode's Debug Console. `print()` and
`AppLogger.shared.*` output both appear there.

**Working directory note:** by default Xcode runs from `DerivedData`,
which means relative paths break. If you need that:
**Edit Scheme... → Run → Options → Working Directory → Use custom: `$PROJECT_DIR`**.

## Logging

`AppLogger.shared` has three sinks per call:

| Sink                                        | Lifetime       | View it with                                |
| ------------------------------------------- | -------------- | ------------------------------------------- |
| In-memory ring buffer (500 entries)         | session        | Activity panel → Logs tab                   |
| `~/Library/Logs/MLM/mlm.log` (rotates @5MB) | persists       | `tail -f ~/Library/Logs/MLM/mlm.log`        |
| Apple unified logging                       | system journal | `Console.app` filter by subsystem `com.ilczuk.mlm` |

### Live tail

```bash
tail -f ~/Library/Logs/MLM/mlm.log
```

### Console.app

1. Open `/System/Applications/Utilities/Console.app`
2. Top toolbar → **Subsystems** → filter by `com.ilczuk.mlm`
3. Categories appear as sub-filter (one per `source:` argument)

This shows MLM output even when running from a release build — no
Xcode required.

### Reveal log file in Finder

In-app: Activity panel → Logs tab → "Reveal Log" button.

## Project layout

```
macos-app/
├── Package.swift          # SwiftPM manifest (min macOS 15)
├── MLM/                   # executable target
│   ├── App/               # MLMApp, AppDelegate, DependencyContainer
│   ├── Database/          # GRDB manager + repositories
│   ├── Models/            # GRDB record types
│   ├── Services/          # Auth, Audio, Import, Sources, Sync, …
│   ├── ViewModels/        # @Observable view models
│   ├── Views/             # SwiftUI views grouped by screen
│   ├── Theme/             # Native macOS-token aliases
│   └── Utilities/         # AppLogger, ProcessRunner, helpers
├── MLMTests/              # swift-testing target
├── scripts/
│   ├── run.sh             # build + bundle + open
│   └── README.md          # (this file)
└── PLAN.md                # phase roadmap
```

## Common tasks

```bash
# Run a single test
swift test --filter LibraryViewModelTests/searchFiltersTracks

# Clean rebuild
./scripts/run.sh --clean --kill

# Check what's actually inside the bundle
ls -la .build/MLM.app/Contents/{MacOS,Resources}

# Compare against Tauri DB schema
sqlite3 ~/Library/Application\ Support/com.musiclibrary.app/music_library.db \
        ".schema tracks"
```

## Database

The Swift app **shares** `~/Library/Application Support/com.musiclibrary.app/music_library.db`
with the Tauri app. Schema migrations live in `MLM/Database/DatabaseManager.swift`
and are designed to be a no-op when run against a Tauri-populated DB.

**Foreign keys are intentionally disabled** because the Tauri DB has
orphaned `track_tags` and `playlist_tracks` rows. App-level invariants
guarantee referential integrity; SQLite FK enforcement would crash on
existing data.

Backups before any schema-changing work:

```bash
cp ~/Library/Application\ Support/com.musiclibrary.app/music_library.db \
   ~/Library/Application\ Support/com.musiclibrary.app/music_library.backup-$(date +%Y%m%d-%H%M%S).db
```
