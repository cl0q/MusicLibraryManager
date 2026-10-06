import Foundation

// MARK: - Files from outside the library folder are copied in (settings.html ST-LIB.E12, PATTERN-DND.N09)

/// `Import Files or Folder…` with audio files from outside the library folder: each file is
/// **copied** into the library folder at the place the importer files it anyway
/// (`PathSanitizer.organizedPath` — `Album Artist/Album/Title.ext`, the existing organiser
/// layout; no second layout), and the copy becomes the track. The original is never moved,
/// changed or deleted. Files already inside the library folder are imported where they are.
///
/// Safety rules:
/// - only `FileManager.copyItem` touches originals (read-only);
/// - a copy is written under a temporary name next to its destination and renamed into place,
///   so a cancelled or failed copy never leaves a half file under a real name;
/// - an existing file at the destination is never overwritten: the same file (same size and
///   bytes) counts as already copied, a different one is reported and not imported.
struct LibraryFileCopier: Sendable {
    let libraryRoot: URL
    /// Reads the tags the destination is built from (`MetadataExtractor.extract`; fakes in tests).
    var readMetadata: @Sendable (URL) async throws -> TrackMetadata = { try await MetadataExtractor.extract(from: $0) }

    /// What happened to the files.
    struct Placement: Equatable, Sendable {
        /// The files to import, in the given order (copies and files already in the folder).
        var toImport: [URL] = []
        /// Files copied now.
        var copied: Int = 0
        /// Files whose copy was already in the library folder.
        var alreadyCopied: Int = 0
        /// Files left out, with the reason in plain words.
        var notCopied: [NotCopied] = []

        struct NotCopied: Equatable, Sendable {
            let file: URL
            let reason: String
        }
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

    /// Copies what lies outside the library folder; `progress(done, currentFile)` after each
    /// file; stops (keeping what is done) when `isCancelled` says so.
    func place(_ files: [URL],
               progress: @Sendable (Int, String) -> Void = { _, _ in },
               isCancelled: @Sendable () -> Bool = { Task.isCancelled }) async -> Placement {
        var placement = Placement()
        var claimed = Set<String>()
        for (index, file) in files.enumerated() {
            if isCancelled() { break }
            progress(index, file.lastPathComponent)
            if Self.isInside(file, root: libraryRoot) {
                placement.toImport.append(file)
                continue
            }
            do {
                let metadata = try await readMetadata(file)
                let target = Self.destination(for: metadata, root: libraryRoot)
                // Two files of this import that would land on the same name: the second is left out.
                guard claimed.insert(target.standardizedFileURL.path.lowercased()).inserted else {
                    placement.notCopied.append(.init(file: file, reason: Self.sameNameReason(target)))
                    continue
                }
                switch try Self.copy(file, to: target) {
                case .copied:
                    placement.copied += 1
                    placement.toImport.append(target)
                case .alreadyThere:
                    placement.alreadyCopied += 1
                    placement.toImport.append(target)
                case .differentFileThere:
                    placement.notCopied.append(.init(file: file, reason: Self.sameNameReason(target)))
                }
            } catch {
                placement.notCopied.append(.init(file: file, reason: "Couldn’t copy “\(file.lastPathComponent)” — \(error.localizedDescription)"))
            }
        }
        if !files.isEmpty { progress(files.count, "") }
        return placement
    }

    static func sameNameReason(_ target: URL) -> String {
        "A different file named “\(target.lastPathComponent)” is already in the library folder"
    }

    enum CopyOutcome: Equatable { case copied, alreadyThere, differentFileThere }

    /// Copies `source` to `target` without ever overwriting: temporary name, then a rename.
    static func copy(_ source: URL, to target: URL) throws -> CopyOutcome {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) {
            return fileManager.contentsEqual(atPath: source.path, andPath: target.path) ? .alreadyThere : .differentFileThere
        }
        let folder = target.deletingLastPathComponent()
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let temporary = folder.appendingPathComponent(".\(target.lastPathComponent).mlm-copy-\(UUID().uuidString)")
        do {
            try fileManager.copyItem(at: source, to: temporary)
            // `moveItem` refuses an existing target: a file that appeared meanwhile is kept.
            try fileManager.moveItem(at: temporary, to: target)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if fileManager.fileExists(atPath: target.path) {
                return fileManager.contentsEqual(atPath: source.path, andPath: target.path) ? .alreadyThere : .differentFileThere
            }
            throw error
        }
        return .copied
    }
}
