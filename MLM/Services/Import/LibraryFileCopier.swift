import Foundation

// MARK: - Files from outside the library folder are copied in (settings.html ST-LIB.E12, PATTERN-DND.N09)

/// `Import Files or Folder…` and Finder drops with audio files from outside the library folder:
/// each file is **copied** into the library folder at the place the importer files it anyway
/// (`PathSanitizer.organizedPath` — `Album Artist/Album/Title.ext`, the existing organiser
/// layout; no second layout), and the copy becomes the track. The original is never moved,
/// changed or deleted. Files already inside the library folder are imported where they are.
///
/// Rules (W3-ADD + review H3, S3–S5):
/// - a file that already is a library track (its path is a track's `original_path`, compared
///   case-insensitively and by canonical path) is neither copied nor imported again;
/// - only `FileManager.copyItem` touches originals (read-only); a copy is written under a
///   temporary name next to its destination and renamed into place;
/// - an existing file is never overwritten: the same bytes count as already copied (its
///   canonical path is imported, so a case-insensitive volume never gets a second track for
///   one physical file); different bytes get the next free name `Title 2.ext`, `Title 3.ext`…;
/// - while the library folder is unreachable the copying waits (UC-JOB-10); a full disk stops
///   it with one cause; a temporary copy that can't be removed is reported once.
struct LibraryFileCopier: Sendable {
    let libraryRoot: URL
    /// Reads the tags the destination is built from (`MetadataExtractor.extract`; fakes in tests).
    var readMetadata: @Sendable (URL) async throws -> TrackMetadata = { try await MetadataExtractor.extract(from: $0) }
    /// Which of these (lower-cased) paths are already a track's `original_path`.
    var knownPaths: @Sendable ([String]) async -> Set<String> = { _ in [] }
    /// Waits while the library folder can't be reached; `false` = cancelled meanwhile.
    var waitForLibraryFolder: @Sendable () async -> Bool = { false }

    /// What happened to the files.
    struct Placement: Equatable, Sendable {
        /// The files to import, in the given order (copies and files already in the folder).
        var toImport: [URL] = []
        /// Files copied now.
        var copied = 0
        /// Files whose identical copy was already in the library folder.
        var alreadyCopied = 0
        /// Files that already are library tracks (nothing copied or imported).
        var alreadyInLibrary = 0
        /// Copies that got a numbered name because a different file has the plain one.
        var renamed: [Renamed] = []
        /// Files left out, with the reason in plain words.
        var notCopied: [NotCopied] = []
        /// Files not reached (cancelled, disk full, folder gone).
        var notReached = 0
        /// Why the copying stopped early (`The library folder’s disk is full`).
        var stopCause: String?
        var wasCancelled = false
        /// Temporary copies that couldn't be removed.
        var leftoverTemporaryFiles: [URL] = []
        /// Each chosen file's path → the path that was imported for it (or that already is
        /// the track): what a drop onto a playlist adds.
        var importedPath: [String: String] = [:]

        struct Renamed: Equatable, Sendable {
            let copy: URL
            /// The copy's path inside the library folder (the track's `organized_path`).
            let relativePath: String
        }

        struct NotCopied: Equatable, Sendable {
            enum Kind: Equatable, Sendable { case unreadable, copyFailed, diskFull }
            let file: URL
            let kind: Kind
            let reason: String
        }

        var notCopiedCount: Int { notCopied.count + notReached }
    }

    /// Is `url` inside the library folder (standardized, symlinks resolved)?
    static func isInside(_ url: URL, root: URL) -> Bool {
        let file = url.standardizedFileURL.resolvingSymlinksInPath().path
        let folder = root.standardizedFileURL.resolvingSymlinksInPath().path
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        return file.hasPrefix(prefix)
    }

    /// The copy's place in the library folder (the importer's own organised path).
    static func destination(for metadata: TrackMetadata, root: URL) -> URL {
        root.appendingPathComponent(PathSanitizer.organizedPath(for: metadata))
    }

    /// `Title.ext` → `Title 2.ext` (n ≥ 2), like numbered playlist names.
    static func numbered(_ url: URL, _ n: Int) -> URL {
        guard n > 1 else { return url }
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
    }

    /// The spellings a path can have in `original_path`, lower-cased.
    static func pathKeys(_ url: URL) -> Set<String> {
        var keys: Set<String> = [url.path, url.standardizedFileURL.path, url.resolvingSymlinksInPath().path]
        if let canonical = (try? url.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath { keys.insert(canonical) }
        return Set(keys.flatMap { [asciiLowercased($0), asciiLowercased($0.precomposedStringWithCanonicalMapping),
                                   asciiLowercased($0.decomposedStringWithCanonicalMapping)] })
    }

    /// A–Z only, as SQLite's `LOWER()` does, so the database comparison sees the same key.
    static func asciiLowercased(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { (65...90).contains($0.value) ? Unicode.Scalar($0.value + 32)! : $0 }))
    }

    /// Copies what lies outside the library folder; `progress(done, currentFile)` before each
    /// file and once at the end (never 100 % before a cancel); stops (keeping what is done)
    /// when `isCancelled` says so.
    func place(_ files: [URL],
               progress: @Sendable (Int, String) -> Void = { _, _ in },
               isCancelled: @Sendable () -> Bool = { Task.isCancelled }) async -> Placement {
        var placement = Placement()
        let known = await knownPaths(Array(Set(files.flatMap { Self.pathKeys($0) })))
        // Targets of this run (lower-cased path → the chosen file that went there).
        var claimed: [String: URL] = [:]
        for (index, file) in files.enumerated() {
            if isCancelled() {
                placement.wasCancelled = true
                placement.notReached = files.count - index
                break
            }
            progress(index, file.lastPathComponent)
            if !Self.pathKeys(file).isDisjoint(with: known) {
                placement.alreadyInLibrary += 1
                placement.importedPath[file.path] = file.path
                continue
            }
            if Self.isInside(file, root: libraryRoot) {
                placement.toImport.append(file)
                placement.importedPath[file.path] = file.path
                continue
            }
            // The library folder's drive is away: wait for it, don't fail every file (UC-JOB-10).
            if !FileManager.default.fileExists(atPath: libraryRoot.path) {
                guard await waitForLibraryFolder() else {
                    placement.wasCancelled = isCancelled()
                    placement.stopCause = placement.wasCancelled ? nil : Self.folderGoneCause(libraryRoot)
                    placement.notReached = files.count - index
                    break
                }
            }
            let metadata: TrackMetadata
            do {
                metadata = try await readMetadata(file)
            } catch {
                placement.notCopied.append(.init(file: file, kind: .unreadable, reason: "Couldn’t read the tags"))
                continue
            }
            let target = Self.destination(for: metadata, root: libraryRoot)
            if let stop = await copy(file, to: target, claimed: &claimed, known: known, into: &placement) {
                placement.stopCause = stop
                placement.notReached = files.count - index - 1
                break
            }
        }
        if !placement.wasCancelled, placement.stopCause == nil, !files.isEmpty { progress(files.count, "") }
        return placement
    }

    /// One file: the first free (numbered) name, or the identical copy already there. Returns a
    /// cause when the whole copying has to stop (disk full).
    private func copy(_ file: URL, to target: URL, claimed: inout [String: URL], known: Set<String>,
                      into placement: inout Placement) async -> String? {
        for n in 1...500 {
            let candidate = Self.numbered(target, n)
            let key = candidate.standardizedFileURL.path.lowercased()
            if let earlier = claimed[key] {
                // Two chosen files for one name: the same bytes are one file (S4).
                if FileManager.default.contentsEqual(atPath: earlier.path, andPath: file.path) {
                    placement.alreadyCopied += 1
                    placement.importedPath[file.path] = placement.importedPath[earlier.path]
                    return nil
                }
                continue
            }
            do {
                let outcome = try Self.copy(file, to: candidate)
                switch outcome.result {
                case .copied:
                    claimed[key] = file
                    placement.copied += 1
                    placement.toImport.append(candidate)
                    placement.importedPath[file.path] = candidate.path
                    if n > 1 {
                        placement.renamed.append(.init(copy: candidate, relativePath: relativePath(candidate)))
                    }
                case .alreadyThere(let existing):
                    claimed[key] = file
                    placement.importedPath[file.path] = existing.path
                    if !Self.pathKeys(existing).isDisjoint(with: await knownPaths(Array(Self.pathKeys(existing)))) {
                        placement.alreadyInLibrary += 1
                    } else {
                        placement.alreadyCopied += 1
                        placement.toImport.append(existing)
                        if n > 1 { placement.renamed.append(.init(copy: existing, relativePath: relativePath(existing))) }
                    }
                case .differentFileThere:
                    continue
                }
                if let leftover = outcome.leftover { placement.leftoverTemporaryFiles.append(leftover) }
                return nil
            } catch let failure as CopyFailure {
                if let leftover = failure.leftover { placement.leftoverTemporaryFiles.append(leftover) }
                if Self.isDiskFull(failure.underlying) {
                    placement.notCopied.append(.init(file: file, kind: .diskFull, reason: Self.diskFullCause))
                    return Self.diskFullCause
                }
                placement.notCopied.append(.init(file: file, kind: .copyFailed, reason: failure.underlying.localizedDescription))
                return nil
            } catch {
                placement.notCopied.append(.init(file: file, kind: .copyFailed, reason: error.localizedDescription))
                return nil
            }
        }
        placement.notCopied.append(.init(file: file, kind: .copyFailed, reason: "No free name for “\(target.lastPathComponent)”"))
        return nil
    }

    private func relativePath(_ url: URL) -> String {
        let root = libraryRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        let canonicalRoot = libraryRoot.resolvingSymlinksInPath().path
        let canonicalPrefix = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        let resolved = url.resolvingSymlinksInPath().path
        return resolved.hasPrefix(canonicalPrefix) ? String(resolved.dropFirst(canonicalPrefix.count)) : url.lastPathComponent
    }

    static let diskFullCause = "The library folder’s disk is full"

    static func folderGoneCause(_ root: URL) -> String {
        if let volume = MountObserver.extractVolumePath(from: root.path) {
            return "“\(URL(fileURLWithPath: volume).lastPathComponent)” is not connected"
        }
        return "The library folder can’t be reached"
    }

    static func isDiskFull(_ error: Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { return true }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOSPC) { return true }
        return false
    }

    enum CopyOutcome: Equatable {
        case copied
        /// The same bytes are already there — at this canonical (on-disk) path.
        case alreadyThere(URL)
        case differentFileThere
    }

    struct CopyResult {
        let result: CopyOutcome
        /// A temporary copy that couldn't be removed.
        let leftover: URL?
    }

    struct CopyFailure: Error {
        let underlying: Error
        let leftover: URL?
    }

    /// Copies `source` to `target` without ever overwriting: temporary name, then a rename.
    static func copy(_ source: URL, to target: URL) throws -> CopyResult {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            return CopyResult(result: existingOutcome(source, target), leftover: nil)
        }
        let folder = target.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw CopyFailure(underlying: error, leftover: nil)
        }
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).mlm-copy-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            // `moveItem` refuses an existing target: a file that appeared meanwhile is kept.
            try fileManager.moveItem(at: temporary, to: target)
        } catch {
            let leftover = removeTemporary(temporary)
            if fileManager.fileExists(atPath: target.path) {
                return CopyResult(result: existingOutcome(source, target), leftover: leftover)
            }
            throw CopyFailure(underlying: error, leftover: leftover)
        }
        return CopyResult(result: .copied, leftover: nil)
    }

    private static func existingOutcome(_ source: URL, _ target: URL) -> CopyOutcome {
        guard FileManager.default.contentsEqual(atPath: source.path, andPath: target.path) else { return .differentFileThere }
        let canonical = (try? target.resourceValues(forKeys: [.canonicalPathKey]))?.canonicalPath
        return .alreadyThere(canonical.map { URL(fileURLWithPath: $0) } ?? target)
    }

    /// `nil` when gone (or never written); the URL when it couldn't be removed.
    private static func removeTemporary(_ url: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do { try FileManager.default.removeItem(at: url); return nil } catch { return url }
    }
}
