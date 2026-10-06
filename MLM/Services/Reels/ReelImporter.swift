import Foundation

// MARK: - Import (V-REELS.E02, N02)

/// What choosing or dropping files and folders found.
struct ReelImportScan: Equatable, Sendable {
    /// `.mp4` / `.mov` files, in the order found, each once.
    var videos: [URL] = []
    /// Folders without any video (each said in the status bar).
    var emptyFolders: [String] = []
    /// Dropped files that are neither videos nor folders.
    var refused: [String] = []
}

/// Finds the videos in files and folders (subfolders included). Reels are referenced where
/// they are — nothing is copied.
enum ReelImporter {
    static let videoExtensions: Set<String> = ["mp4", "mov"]

    static func isVideo(_ url: URL) -> Bool { videoExtensions.contains(url.pathExtension.lowercased()) }

    /// `No videos in “‹folder›”` (new sentence, status bar).
    static func noVideosSentence(_ folder: String) -> String { "No videos in “\(folder)”" }

    /// `Can’t add “‹name›” — it isn’t a video or a folder` (new sentence, status bar).
    static func notAVideoSentence(_ names: [String]) -> String {
        if names.count == 1 { return "Can’t add “\(names[0])” — it isn’t a video or a folder" }
        return "Can’t add these \(names.count.formatted(.number)) files — none is a video or a folder"
    }

    static func scan(_ urls: [URL], fileManager: FileManager = .default) -> ReelImportScan {
        var scan = ReelImportScan()
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { scan.videos.append(url) }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                let found = videos(in: url, fileManager: fileManager)
                if found.isEmpty { scan.emptyFolders.append(url.lastPathComponent) }
                found.forEach(add)
            } else if isVideo(url) {
                add(url)
            } else {
                scan.refused.append(url.lastPathComponent)
            }
        }
        return scan
    }

    /// Every video below `folder`, sorted by path; hidden files skipped.
    static func videos(in folder: URL, fileManager: FileManager = .default) -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var found: [URL] = []
        for case let url as URL in enumerator where isVideo(url) {
            found.append(url)
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// The records for videos not yet listed. A file name that reads `Artist - Title` pre-fills
    /// the (empty) fields and the reel arrives `Identified`; any other reel arrives `New`.
    static func records(for videos: [URL], excluding existingPaths: Set<String>, now: Date = Date(),
                        makeID: () -> String = { UUID().uuidString }) -> [ImportedReelRecord] {
        var known = existingPaths
        var records: [ImportedReelRecord] = []
        for url in videos where known.insert(url.path).inserted {
            let guess = ReelGuesses.fileNameGuess(url.lastPathComponent)
            records.append(ImportedReelRecord(
                id: makeID(), filePath: url.path, title: guess?.title ?? "", artist: guess?.artist ?? "",
                createdAt: now, updatedAt: now,
                state: guess == nil ? .new : .identified,
                guessesJSON: guess.flatMap { ReelGuesses.encode([$0]) }))
        }
        return records
    }
}
