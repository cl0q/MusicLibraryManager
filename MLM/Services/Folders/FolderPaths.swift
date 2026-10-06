import Foundation

// MARK: - Paths inside the library folder (V-FOLD, DEC-024)

/// Folders are real directories under the library folder. Inside MLM a folder is named by its
/// path **relative to the library folder** (`""` = the library folder itself, `2026/Sets`), so
/// nothing depends on where the drive is mounted. Pure — no disk access.
enum FolderPath {
    /// The library folder itself.
    static let root = ""

    /// `/a//b/` → `a/b`; `.` components dropped. Never resolves `..` (see `isSafe`).
    static func normalize(_ relative: String) -> String {
        relative.split(separator: "/", omittingEmptySubsequences: true)
            .filter { $0 != "." }
            .joined(separator: "/")
    }

    /// A stored relative path may be used: not absolute, no `..` (it must never leave the
    /// library folder — a persisted value is not trusted).
    static func isSafe(_ relative: String) -> Bool {
        guard !relative.hasPrefix("/"), !relative.hasPrefix("~") else { return false }
        return !relative.split(separator: "/").contains("..")
    }

    static func components(_ relative: String) -> [String] {
        relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// `a/b` → `a`; `a` → `""`; `""` → nil.
    static func parent(of relative: String) -> String? {
        guard !relative.isEmpty else { return nil }
        var parts = components(relative)
        parts.removeLast()
        return parts.joined(separator: "/")
    }

    /// The last component; the library folder's own name for `""`.
    static func name(of relative: String, libraryFolderName: String) -> String {
        components(relative).last ?? libraryFolderName
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    /// `child` is `folder` or lies inside it.
    static func isWithin(_ child: String, _ folder: String) -> Bool {
        folder.isEmpty || child == folder || child.hasPrefix(folder + "/")
    }

    /// `""`, `a`, `a/b` for `a/b/c` (every folder above, outermost first; `relative` itself is
    /// not included).
    static func ancestors(of relative: String) -> [String] {
        let parts = components(relative)
        guard !parts.isEmpty else { return [] }
        var result = [root]
        var current = ""
        for part in parts.dropLast() {
            current = join(current, part)
            result.append(current)
        }
        return result
    }

    /// The absolute URL of a folder or file inside `libraryRoot`.
    static func url(_ relative: String, libraryRoot: String) -> URL {
        let base = URL(fileURLWithPath: libraryRoot, isDirectory: true)
        return relative.isEmpty ? base : base.appendingPathComponent(relative)
    }

    /// The path of `absolute` relative to `libraryRoot`, or nil when it is outside.
    static func relative(_ absolute: String, libraryRoot: String) -> String? {
        let root = trimmedRoot(libraryRoot)
        let path = URL(fileURLWithPath: absolute).standardizedFileURL.path
        if path == root { return "" }
        let prefix = root == "/" ? "/" : root + "/"
        guard path.hasPrefix(prefix) else { return nil }
        let rest = normalize(String(path.dropFirst(prefix.count)))
        return isSafe(rest) ? rest : nil
    }

    /// The library folder without a trailing slash, standardized.
    static func trimmedRoot(_ libraryRoot: String) -> String {
        let path = URL(fileURLWithPath: libraryRoot).standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    // MARK: Which files the outline lists

    /// Hidden files and MLM's own temporary files (`.‹name›.mlm-copy-…` of the library-file
    /// copier, anything `.mlm-`) never appear.
    static func isListable(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".") && !name.contains(".mlm-")
    }

    /// A key that compares two paths of one file the way the disk does: Unicode composed (macOS
    /// hands out decomposed names, typed paths are composed) and case-insensitive (APFS default).
    static func matchKey(_ relative: String) -> String {
        relative.precomposedStringWithCanonicalMapping.lowercased()
    }
}

// MARK: - Where a library track lies (no disk access)

/// The folder of a library track, decided from its stored paths only (UC-TABLE-20) — the
/// outline is built from the database, so it works while the drive is away.
///
/// A track's file is its `organized_path` if that exists, else its absolute `original_path`
/// (`PlaybackFileResolver`). Without a disk probe the rule is (IMP proposed by W3-FOLD):
/// 1. an absolute `original_path` inside the library folder — a file imported where it lies
///    (a scan keeps the file in place; its stored `organized_path` is only the organiser's
///    suggestion) and a copy made by `Import Files or Folder…` (both paths agree);
/// 2. else a relative `organized_path` (downloads, transcodes);
/// 3. else an absolute `organized_path` inside the library folder;
/// 4. else none — the track is not in the library folder (not downloaded, another disk).
enum FolderPlacement {
    /// The file's path relative to the library folder, or nil.
    static func relativeFilePath(organizedPath: String?, originalPath: String, libraryRoot: String) -> String? {
        guard let organizedPath, !organizedPath.isEmpty else { return nil }
        let root = FolderPath.trimmedRoot(libraryRoot)
        if originalPath.hasPrefix("/"), let inside = FolderPath.relative(originalPath, libraryRoot: root), !inside.isEmpty {
            return inside
        }
        if !organizedPath.hasPrefix("/") {
            let relative = FolderPath.normalize(organizedPath)
            return relative.isEmpty || !FolderPath.isSafe(relative) ? nil : relative
        }
        if let inside = FolderPath.relative(organizedPath, libraryRoot: root), !inside.isEmpty {
            return inside
        }
        return nil
    }

    /// The folder a file path lies in (`a/b/x.flac` → `a/b`, `x.flac` → `""`).
    static func folder(ofFile relativeFile: String) -> String {
        FolderPath.parent(of: relativeFile) ?? FolderPath.root
    }

    /// Every path under which a track's file may be found on disk, relative to the library
    /// folder (organized and original), as match keys — a file on disk with one of them is
    /// in the library.
    static func knownFileKeys(organizedPath: String?, originalPath: String, libraryRoot: String) -> [String] {
        var keys: [String] = []
        let root = FolderPath.trimmedRoot(libraryRoot)
        if let organizedPath, !organizedPath.isEmpty {
            if organizedPath.hasPrefix("/") {
                if let inside = FolderPath.relative(organizedPath, libraryRoot: root), !inside.isEmpty {
                    keys.append(FolderPath.matchKey(inside))
                }
            } else {
                keys.append(FolderPath.matchKey(FolderPath.normalize(organizedPath)))
            }
        }
        if originalPath.hasPrefix("/"), let inside = FolderPath.relative(originalPath, libraryRoot: root), !inside.isEmpty {
            keys.append(FolderPath.matchKey(inside))
        }
        return keys
    }
}

// MARK: - App-owned folders

/// `Managed by MLM` (§15.9): the download and transcode folders MLM creates at the top of the
/// library folder (`ManagedLibraryLayout`).
enum ManagedFolders {
    static func isManaged(_ relative: String) -> Bool {
        !relative.contains("/") && ManagedLibraryLayout.folderNames.contains(relative)
    }
}
