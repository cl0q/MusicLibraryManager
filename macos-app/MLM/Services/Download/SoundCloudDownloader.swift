import Foundation

/// SoundCloud downloader wrapping the `scdl` CLI tool.
///
/// Mirrors the Rust `SoundCloudDownloader`. Requires `scdl` >= 3.0.4
/// (pip install scdl) and SoundCloud Go+ for 248kbps AAC.
final class SoundCloudDownloader: Sendable {

    enum DownloadResult {
        case success(URL)
        case notFound
    }

    /// Supported audio file extensions for output detection.
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "opus", "wav"]

    private let scdlPath: String?

    init() {
        self.scdlPath = ProcessRunner.findExecutable("scdl")
    }

    /// Whether `scdl` is available on this system.
    var isAvailable: Bool { scdlPath != nil }

    /// Download a track from SoundCloud via `scdl` CLI.
    ///
    /// - Parameters:
    ///   - trackURL: The SoundCloud track URL
    ///   - outputDir: Directory to save the downloaded file
    ///   - trackId: Internal track ID (for temp dir naming)
    ///   - title: Expected title for the output filename
    /// - Returns: Path to the downloaded file, or `.notFound`
    func download(
        trackURL: String,
        outputDir: URL,
        trackId: Int64,
        title: String
    ) async throws -> DownloadResult {
        guard let scdl = scdlPath else {
            return .notFound
        }

        // Create temp dir to avoid filename collisions
        let tmpDir = outputDir.appendingPathComponent(".tmp_\(trackId)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let sanitizedTitle = PathSanitizer.sanitizeComponent(title)

        let result = try await ProcessRunner.run(
            scdl,
            arguments: [
                "-l", trackURL,
                "--path", tmpDir.path,
                "--original-art",
                "--name-format", sanitizedTitle
            ]
        )

        // Check stderr for "not found" indicators
        let stderr = result.stderr.lowercased()
        if stderr.contains("not found") || stderr.contains("404") || stderr.contains("not available") {
            return .notFound
        }

        // Find the most recently created audio file in temp dir
        guard let downloadedFile = findMostRecentAudioFile(in: tmpDir) else {
            if !result.isSuccess {
                return .notFound
            }
            return .notFound
        }

        // Move to output directory
        let outputFile = outputDir.appendingPathComponent(downloadedFile.lastPathComponent)
        if FileManager.default.fileExists(atPath: outputFile.path) {
            try FileManager.default.removeItem(at: outputFile)
        }
        try FileManager.default.moveItem(at: downloadedFile, to: outputFile)

        return .success(outputFile)
    }

    // MARK: - Private

    /// Find the most recently modified audio file in a directory.
    private func findMostRecentAudioFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return contents
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .max { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
    }
}
