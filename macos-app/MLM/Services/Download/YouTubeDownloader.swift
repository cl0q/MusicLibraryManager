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
    func searchAndDownload(
        query: String,
        outputDir: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        guard let ytdlp = ytDlpPath else {
            return .notFound
        }

        let outputTemplate = outputDir.appendingPathComponent("%(title)s.%(ext)s").path
        let normalizedQuery = Self.normalizeQueryForYouTube(query)
        if normalizedQuery != query {
            AppLogger.shared.info(
                "chain[YT]: query normalised → '\(normalizedQuery)' (was '\(query)')",
                source: "Download"
            )
        }

        let arguments = [
            "ytsearch5:\(normalizedQuery)",
            "-f", "bestaudio",
            "-x",
            // Force AAC/m4a output regardless of source codec. AVAudioEngine
            // (the macOS playback path) cannot decode opus/vorbis, which is
            // what yt-dlp picks by default for many YouTube streams — the
            // file would land in the library and refuse to play with
            // 'Cannot open audio file'. yt-dlp invokes ffmpeg internally
            // for the conversion.
            "--audio-format", "m4a",
            "--audio-quality", "0",
            // Match-filter intentionally removed (it was rejecting valid
            // hits for tracks under 30s or over 20min and leaving the
            // chain with "not found" even when YouTube clearly has the
            // song). If garbage results sneak in we'll restore a looser
            // filter later.
            "--no-playlist",
            "--max-downloads", "1",
            "--newline",            // one progress line at a time → parseable
            "--progress",           // force progress lines even when not a TTY
            "--print", "after_move:filepath",
            "-o", outputTemplate
        ]
        AppLogger.shared.debug(
            "chain[YT]: yt-dlp \(arguments.joined(separator: " "))",
            source: "Download"
        )
        let result = try await ProcessRunner.run(
            ytdlp,
            arguments: arguments,
            onStderr: onProgress.map { cb in
                { line in
                    for sub in line.split(separator: "\n") {
                        if let pct = ProcessRunner.parseProgressPercent(String(sub)) {
                            cb(pct)
                        }
                    }
                }
            }
        )

        // Check for "no results" indicators
        let combined = (result.stdout + result.stderr).lowercased()
        if combined.contains("no video results") || combined.contains("unable to extract") {
            let stderrTail = String(result.stderr.suffix(600))
                .replacingOccurrences(of: "\n", with: " | ")
            AppLogger.shared.warn(
                "chain[YT]: yt-dlp reported no results for '\(normalizedQuery)'. stderr tail: \(stderrTail)",
                source: "Download"
            )
            return .notFound
        }

        guard result.isSuccess else {
            // Surface enough stderr + stdout context to debug *why*
            // yt-dlp gave up. The Logs tab is now the diagnosis surface.
            let stderrTail = String(result.stderr.suffix(800))
                .replacingOccurrences(of: "\n", with: " | ")
            let stdoutTail = String(result.stdout.suffix(400))
                .replacingOccurrences(of: "\n", with: " | ")
            AppLogger.shared.warn(
                "chain[YT]: yt-dlp exited non-zero (code=\(result.exitCode)). stderr tail: \(stderrTail) | stdout tail: \(stdoutTail)",
                source: "Download"
            )
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

    // MARK: - Query Normalisation

    /// Strip the parenthetical / bracket noise that turns valid song titles
    /// into queries no YouTube video matches verbatim. Things like
    /// `(feat. Hittman, Six-Two, Nate Dogg & Kurupt)`,
    /// `[Official Music Video]`, `(Remastered 2024)` make ytsearch5 return
    /// zero hits even when the song is on YouTube several times over.
    ///
    /// We collapse to "Artist - Title" with all `(...)` / `[...]` content
    /// removed and whitespace squashed. Visible for testability.
    static func normalizeQueryForYouTube(_ raw: String) -> String {
        var s = raw
        // Repeatedly strip balanced parentheses and brackets — handles
        // nested groups like "Title (Mix) [Remastered]".
        let patterns = ["\\([^()]*\\)", "\\[[^\\[\\]]*\\]"]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(s.startIndex..., in: s)
                    let replaced = regex.stringByReplacingMatches(
                        in: s, range: range, withTemplate: ""
                    )
                    if replaced != s {
                        s = replaced
                        changed = true
                    }
                }
            }
        }
        // Collapse repeated whitespace and tidy stray punctuation that
        // strip-bracket left behind ("Artist -  Title  - " -> "Artist - Title").
        s = s.replacingOccurrences(
            of: "\\s+", with: " ",
            options: .regularExpression
        )
        s = s.trimmingCharacters(in: .whitespaces)
        // Trim trailing " - " or " -" if removal left an orphan separator.
        while s.hasSuffix(" -") || s.hasSuffix("-") {
            s = String(s.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? raw : s
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
