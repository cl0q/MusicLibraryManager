# A0 — What is a library?

**Status:** DECIDED. 2026-10-04, Oliver + agent, settling the Track-A open questions from `ROADMAP.md` §2.
**Revision 2 (same day):** the library directory is wrapped as a **`.mlibm` file package** — see D1 and D9. Contents, registry, and all other decisions are unchanged.
**Authority:** This document is the binding definition of "library" for A3 (multi-library), A2 (backup), and the B1 library-picker screens. `UI-GROUNDTRUTH.md` remains binding for UI until B2 supersedes it.

---

## D1 — A library is a `.mlibm` package: a directory Finder treats as one file

A **library** is a self-describing file package with the extension `.mlibm`, registered as a `com.apple.package`–conforming UTI (D9) so Finder presents, moves, copies, and drags it as a single file. On disk it is a directory:

```
Main Library.mlibm/           # one file to the user, a folder to the filesystem
├── library.json              # manifest (see D6) — REQUIRED
├── music_library.db          # SQLite DB, WAL mode — REQUIRED
├── music_library.db-wal      # transient; never relied upon
├── music_library.db-shm      # transient; never relied upon
└── playlist-covers/          # per-library auxiliary data (moved here by A3)
```

The package is movable as one unit: everything that identifies or reconstructs the library's *content* lives inside it. The external registry (D5) stores only a pointer to the package path, so a library can be relocated by dragging the `.mlibm` file anywhere (including an external disk) and updating — or re-discovering — the registry entry.

**Why package over plain directory:** same self-describing benefits, but Finder-level containment: one icon, one drag, one delete; the internals (`.db`, `-wal`) are opaque to the user instead of looking like loose, breakable files. This is the established macOS pattern — `.photoslibrary`, `.imovielibrary`, and Apple Music's own `.musiclibrary` are all file packages.

**Why package over bare DB file:** a bare `.db` carries no name, no identity, no schema-version metadata readable without opening it (the chicken-and-egg from `ROADMAP.md` §0.5). The manifest makes the package self-describing and gives the registry and backup code something cheap to read without touching SQLite.

**Naming:** `<library name>.mlibm` (e.g. `Main Library.mlibm`) — readable in Finder. The name is **asked of the user** at the two points where one is created: during legacy migration/adoption (D7 — suggested default "Main Library") and during new-library creation. `library_id` (D5) remains the identity; the filename is presentation. Renaming through the app updates manifest + registry + filename together; a rename done in Finder behind the app's back is detected on open via `library_id` match and the registry is re-pointed (name-sync offered, not forced).

**Why not "DB in App Support + audio elsewhere" as the *definition*:** that split still exists in practice (audio never lives in the package — see D2), but it is an implementation detail of the default layout, not the definition. The definition must survive a user moving the `.mlibm` file to an external disk.

## D2 — Audio is referenced, never contained

The library directory does **not** contain audio files. Audio lives under `library_root` (currently `/Volumes/Lexxar/Music`, stored in `app_config.library_root`), and `tracks.organized_path` remains **relative to `library_root`** (migration `v12_strip_absolute_paths`). Consequences:

- Moving the *library directory* never breaks track paths.
- Moving the *audio volume* requires updating `library_root` (existing FirstRunWizard/MountObserver territory), not touching tracks.
- The transcode cache (`app_config.transcode_cache_path`) stays on the audio volume — it is derived data keyed to the audio, not to the DB.

## D3 — Credentials are global, never per-library

OAuth tokens (`…/com.musiclibrary.app/tokens/`) and `~/Library/Application Support/MLM/.env` belong to the user/machine and are shared by all libraries. They:

- never live inside a library directory,
- are never copied when a library is copied or backed up,
- are never deleted when a library is deleted.

Backups (A2) must exclude credentials by construction — they are outside the library directory, so a directory-level backup gets this for free.

## D4 — One active library at a time

A running MLM instance has exactly one open library. "Switch library" means: close the current `DatabasePool` and dependent services, rebuild the container around the new path, reopen. No merged views, no cross-library search, no tabs.

**Why:** `DependencyContainer.shared` holds ~40 `private(set)` services constructed once; rebuild-on-switch is a bounded refactor, library-scoping every service is not. This decision is what keeps A3 tractable.

## D5 — Registry lives outside any database

`~/Library/Application Support/com.musiclibrary.app/libraries.json`:

```json
{
  "registry_version": 1,
  "libraries": [
    {
      "library_id": "f1c9d287-7c19-4e62-ad81-eef851bf751f",
      "path": "~/Library/Application Support/com.musiclibrary.app/libraries/Main Library.mlibm",
      "name": "Main Library",
      "last_opened_at": "2026-10-04T12:00:00Z"
    }
  ],
  "last_active_library_id": "f1c9d287-7c19-4e62-ad81-eef851bf751f",
  "remember_last_library": true
}
```

Rules:

- **Default location for new libraries** is `…/com.musiclibrary.app/libraries/<name>.mlibm`. The registry accepts any path, so a user may move a `.mlibm` package anywhere (including an external disk) and re-point the entry. Rationale for the default: Application Support survives `.app` deletion, is always mounted, and matches the current install — an external-disk default would make the app unusable whenever the volume is offline.
- `library_id` is the UUID already in `app_config.library_id`; it is the join key between registry, manifest, and DB, and must match in all three. A mismatch is a corruption signal, not something to silently repair.
- Registry entries whose path doesn't exist are shown as *missing* (B1 picker state), not pruned silently — the volume may just be unmounted (`MountObserver` already knows).
- `name` in the registry is a display cache; the manifest is authoritative.

## D6 — Manifest schema (`library.json`)

```json
{
  "manifest_version": 1,
  "library_id": "f1c9d287-7c19-4e62-ad81-eef851bf751f",
  "name": "Main Library",
  "created_at": "2026-10-04T12:00:00Z",
  "schema_version": "v41_remote_provider_identity"
}
```

Kept deliberately tiny: it must be readable without SQLite, writable atomically (temp + rename), and stable enough that a backup from any future version can be interpreted. `schema_version` is informational for the picker/backup UI — the migrator remains the authority on actual schema state.

## D7 — Legacy installs are auto-adopted, never migrated destructively

The current single-library install (`…/com.musiclibrary.app/music_library.db`, ~130 MB, plus `playlist-covers/`) is the only "legacy" layout in existence — the plain-directory shape of revision 1 of this doc never shipped. Adoption into a `.mlibm` package is **automatic, backed up first, and deferrable**:

- On first launch of an A3-era build, the app detects the legacy layout and offers adoption — asking the user for the library name (suggested default "Main Library"), then moving DB + covers into the resulting `<name>.mlibm` package under `libraries/`, writing manifest + registry, and reporting what happened. The user can defer/skip; the legacy path keeps working until adoption runs.
- Invariant: adoption is atomic or resumable — an interrupted adoption must leave either the legacy layout intact or a complete package, never a half-moved split. The pre-adoption backup is what makes this safe.
- Until A3 ships, the hardcoded `DatabaseManager.defaultDatabasePath()` behavior is unchanged. Nothing in A0 authorizes touching the live install.

See the **Legacy migration guide** below for the user-facing procedure.

## D8 — Dev/subset libraries are deferred

"Create a small dev library by copying a subset of the main library" is a distinct future feature, out of scope for A0–A3. The manifest carries no `derived_from` field for now; if the feature lands later, `manifest_version: 2` can add it without breaking anything defined here.

## D9 — `.mlibm` package format and Finder integration

- **UTI:** export `com.ilczuk.mlm.library` (reverse-DNS of the app bundle id `com.ilczuk.mlm` from `scripts/run.sh`), conforming to `com.apple.package` — the conformance is what makes Finder treat the directory as a single opaque file. Declared via `UTExportedTypeDeclarations` + `CFBundleDocumentTypes` in the app's Info.plist.
- **Registration point:** `scripts/run.sh` generates `MLM.app/Contents/Info.plist` as a heredoc (lines ~93–109). The document-type and UTI declarations go into that heredoc, and the icon file into the bundle's `Contents/Resources/`. No Xcode project exists to fight with.
- **Icon:** a dedicated **static** `.icns`, *not* the app icon — derived from its visual language but clearly reading as "an MLM library", not "MLM itself" (per Oliver, 2026-10-04). Referenced by `CFBundleDocumentTypes → LSItemContentTypes → CFBundleTypeIconFile`. Designing this icon is an A3/B1-adjacent asset task.
- **Double-click to open:** registering the document type makes MLM the handler for `.mlibm`; the app must handle the open-file event (`NSApplicationDelegate.application(_:open:)` / SwiftUI `onOpenURL` for file URLs) and resolve it through the registry (adding an unregistered package on open — the "import by double-click" path).
- **Per-library dynamic cover icons** (rendered from artwork) were considered and deferred: custom per-file icons live in extended attributes/resource forks, which many copy and backup tools silently drop. The static icon is the contract.

## Legacy migration guide (user-facing)

For the one legacy layout that exists — a loose DB at `~/Library/Application Support/com.musiclibrary.app/music_library.db` (+ `-wal`/`-shm`, `playlist-covers/`):

1. **One question, then nothing.** On first launch of an A3-era build, MLM detects the legacy layout and offers adoption, asking the user to name the library (suggested default "Main Library" → `Main Library.mlibm`). Deferring keeps the old layout fully working.
2. **Before anything moves**, MLM takes a backup (A2). Adoption = create `libraries/<name>.mlibm/`, move DB + covers in, write `library.json` + registry entry, verify open, then (and only then) consider the legacy location consumed. Interrupted adoption resumes or leaves the legacy layout untouched (D7 invariant).
3. **Manual migration** (e.g. a DB from another machine or a pre-adoption backup restore): create a folder named `<name>.mlibm`, put `music_library.db` inside it; MLM's "Open Library…" writes the manifest and registry entry on first open. A missing manifest is repaired from the DB's `app_config.library_id`, never the other way around.
4. **What never migrates:** credentials (`tokens/`, `MLM/.env`) stay global (D3); audio stays where `library_root` points (D2); the registry itself is machine-local.
5. **Moving an adopted library:** quit MLM (or close the library), drag the `.mlibm` file, reopen via double-click or "Open Library…" — the registry re-points by `library_id` (D1 naming rules).

---

## Consequences for downstream work

| Track | What A0 fixes for it |
|---|---|
| **A2 backup** | Backup unit = the `.mlibm` package (or `VACUUM INTO` a DB snapshot inside a backup bundle modeled on it). Credentials excluded by construction (D3). Adoption (D7) must be preceded by a backup. |
| **A3 multi-library** | Registry schema (D5), manifest schema (D6), rebuild-on-switch (D4), adoption invariant (D7), and the `.mlibm` UTI/icon/open-file wiring (D9). `DatabaseManager(path:)` already exists. |
| **B1 design** | Library picker shows registry entries incl. *missing/unmounted* states (D5); "remember last library" is a registry-level setting; empty state = no registry entries or last active missing; the `.mlibm` icon (D9) is an asset B1 should account for. |
| **Track C** | Unaffected. Album work reads/writes the DB inside whichever library is active. |

## Still open (does not block A2)

1. Whether the picker offers "Create new library" on first run or only after the wizard configures `library_root` — a B1 flow question. Either way the creation flow asks the user for the library name (D1).
2. Registry file corruption/loss recovery: a scan of `libraries/` for `.mlibm` packages (reading each `library.json`) can rebuild it; specify in A3.
3. Icon artwork for `.mlibm` (D9) — needs a design pass; blocked on nothing, but is a real deliverable for A3.
