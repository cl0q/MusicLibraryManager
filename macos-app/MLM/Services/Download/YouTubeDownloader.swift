import Foundation

/// YouTube audio downloader wrapping the `yt-dlp` CLI.
///
/// Mirrors the Rust `YoutubeClient`. Searches YouTube for an audio match
/// and downloads the best available audio stream.
final class YouTubeDownloader: Sendable {

    enum DownloadResult {
        case success(URL)
        case notFound
    }

    private let ytDlpPath: String?

    init() {
        self.ytDlpPath = ProcessRunner.findExecutable("yt-dlp")
    }

    /// Whether `yt-dlp` is available on this system.
    var isAvailable: Bool { ytDlpPath != nil }

    /// Search YouTube and download the first matching audio result.
    ///
    /// Uses `ytsearch5:` with a duration filter (30s–15min) so we don't
    /// pull in podcasts, finance-tip vlogs, or advertisements that happen
    /// to rank above the actual song. yt-dlp picks the first candidate
    /// that passes the filter.
    ///
    /// - Parameters:
    ///   - query: Search query (e.g., "Artist - Title")
    ///   - outputDir: Directory to save the downloaded file
    /// - Returns: Path to the downloaded file, or `.notFound`
    func searchAndDownload(query: String, outputDir: URL) async throws -> DownloadResult {
        guard let ytdlp = ytDlpPath else {
            return .notFound
        }

        let outputTemplate = outputDir.appendingPathComponent("%(title)s.%(ext)s").path

        let result = try await ProcessRunner.run(
            ytdlp,
            arguments: [
                "ytsearch5:\(query)",
                "-f", "bestaudio",
                "-x",
                // Skip non-song results (podcasts, ads, vlogs) but keep
                // scanning the rest of the 5-hit batch. Do NOT use
                // --break-match-filters — that aborts the scan on first
                // miss and defeats the purpose of ytsearch5.
                "--match-filter", "duration >= 30 & duration <= 1200",
                "--no-playlist",
                "--max-downloads", "1",
                "--print", "after_move:filepath",
                "-o", outputTemplate
            ]
        )

        // Check for "no results" indicators
        let combined = (result.stdout + result.stderr).lowercased()
        if combined.contains("no video results") || combined.contains("unable to extract") {
            return .notFound
        }

        guard result.isSuccess else {
            return .notFound
        }

        // The --print flag outputs the final filepath to stdout
        let outputPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outputPath.isEmpty && FileManager.default.fileExists(atPath: outputPath) {
            return .success(URL(fileURLWithPath: outputPath))
        }

        // Fallback: look for most recent file in output dir
        if let found = findMostRecentFile(in: outputDir) {
            return .success(found)
        }

        return .notFound
    }

    /// Download audio from a specific YouTube URL.
    func downloadByURL(_ url: String, outputDir: URL) async throws -> DownloadResult {
        guard let ytdlp = ytDlpPath else {
            return .notFound
        }

        let outputTemplate = outputDir.appendingPathComponent("%(title)s.%(ext)s").path

        let result = try await ProcessRunner.run(
            ytdlp,
            arguments: [
                url,
                "-f", "bestaudio",
                "-x",
                "--print", "after_move:filepath",
                "-o", outputTemplate
            ]
        )

        guard result.isSuccess else { return .notFound }

        let outputPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if !outputPath.isEmpty && FileManager.default.fileExists(atPath: outputPath) {
            return .success(URL(fileURLWithPath: outputPath))
        }

        return .notFound
    }

    // MARK: - Private

    private func findMostRecentFile(in directory: URL) -> URL? {
        let audioExts: Set<String> = ["mp3", "m4a", "aac", "flac", "opus", "wav", "webm", "ogg"]
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return contents
            .filter { audioExts.contains($0.pathExtension.lowercased()) }
            .max { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
    }
}
