import Foundation

/// YouTube audio downloader wrapping the `yt-dlp` CLI.
///
/// Mirrors the Rust `YoutubeClient`. Searches YouTube for an audio match
/// and downloads the best available audio stream.
final class YouTubeDownloader: Sendable {

    /// Maximum wall-clock seconds for a single download invocation.
    /// Generous because a long mix or slow connection can legitimately
    /// take many minutes. 900s = 15 minutes.
    static let downloadTimeoutSeconds: TimeInterval = 900

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
    /// - Returns: `.success(URL)` with the downloaded file, or `.failure`
    ///   with a classified `DownloadFailure` describing what went wrong.
    func searchAndDownload(
        query: String,
        outputDir: URL,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> DownloadOutcome {
        guard let ytdlp = ytDlpPath else {
            let failure = DownloadFailureClassifier.classifyTool(
                source: "youtube", exitCode: 127,
                stderr: "yt-dlp: command not found",
                stdout: "", producedFile: false)
            return .failure(failure)
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

        let result: ProcessRunner.ProcessResult
        do {
            result = try await ProcessRunner.run(
                ytdlp,
                arguments: arguments,
                timeout: Self.downloadTimeoutSeconds,
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
        } catch is CancellationError {
            // Preserve task cancellation propagation — the orchestrator
            // relies on this to abort in-flight downloads when the user
            // cancels. Re-throw rather than classifying as a failure.
            throw CancellationError()
        } catch {
            return .failure(DownloadFailureClassifier.classifyTransport(
                source: "youtube", error: error))
        }

        return Self.classifyDownloadResult(result, outputDir: outputDir)
    }

    /// Download audio from a specific YouTube URL.
    ///
    /// - Returns: `.success(URL)` with the downloaded file, or `.failure`
    ///   with a classified `DownloadFailure` describing what went wrong.
    func downloadByURL(_ url: String, outputDir: URL) async throws -> DownloadOutcome {
        guard let ytdlp = ytDlpPath else {
            let failure = DownloadFailureClassifier.classifyTool(
                source: "youtube", exitCode: 127,
                stderr: "yt-dlp: command not found",
                stdout: "", producedFile: false)
            return .failure(failure)
        }

        let outputTemplate = outputDir.appendingPathComponent("%(title)s.%(ext)s").path

        let result: ProcessRunner.ProcessResult
        do {
            result = try await ProcessRunner.run(
                ytdlp,
                arguments: [
                    url,
                    "-f", "bestaudio",
                    "-x",
                    "--print", "after_move:filepath",
                    "-o", outputTemplate
                ],
                timeout: Self.downloadTimeoutSeconds
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(DownloadFailureClassifier.classifyTransport(
                source: "youtube", error: error))
        }

        return Self.classifyDownloadResult(result, outputDir: outputDir)
    }

    /// Search YouTube for videos using yt-dlp.
    ///
    /// - Parameters:
    ///   - query: Free-text search query
    ///   - limit: Maximum number of tracks to return (default is 3)
    /// - Returns: List of matching YouTube tracks
    func searchTracks(query: String, limit: Int = 3) async throws -> [YouTubeTrack] {
        guard let ytdlp = ytDlpPath else {
            return []
        }

        let normalizedQuery = Self.normalizeQueryForYouTube(query)
        let ytSearchArg = "ytsearch\(limit):\(normalizedQuery)"

        let arguments = [
            ytSearchArg,
            "--flat-playlist",
            "--dump-json",
            "--no-playlist"
        ]

        let result = try await ProcessRunner.run(ytdlp, arguments: arguments)
        guard result.isSuccess else {
            AppLogger.shared.warn(
                "YouTube search failed with exit code \(result.exitCode): \(result.stderr)",
                source: "Download"
            )
            return []
        }

        let decoder = JSONDecoder()
        var tracks: [YouTubeTrack] = []

        let lines = result.stdout.split(separator: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            do {
                let track = try decoder.decode(YouTubeTrack.self, from: data)
                tracks.append(track)
            } catch {
                AppLogger.shared.warn(
                    "Failed to decode YouTube search item: \(error.localizedDescription) - line: \(trimmed)",
                    source: "Download"
                )
            }
        }

        return Array(tracks.prefix(limit))
    }

    // MARK: - Result classification

    /// Classify a completed yt-dlp `ProcessResult` into a `DownloadOutcome`.
    ///
    /// Path-first logic: if yt-dlp printed a filepath via `--print after_move:filepath`
    /// AND that file exists on disk, the download succeeded — regardless of exit code.
    /// This preserves the exit-101 (`--max-downloads` reached) success case.
    ///
    /// A `timedOut` result is NEVER success — the process was killed and any
    /// partial file is unreliable.
    ///
    /// Visible + static for testability without spawning yt-dlp.
    static func classifyDownloadResult(
        _ result: ProcessRunner.ProcessResult,
        outputDir: URL
    ) -> DownloadOutcome {
        // Timeout → always failure, even if a path was printed (partial file).
        if result.timedOut {
            let stderrTail = DownloadFailureClassifier.tail(result.stderr)
            let stdoutTail = DownloadFailureClassifier.tail(result.stdout, 400)
            AppLogger.shared.warn(
                "chain[YT]: yt-dlp timed out after \(downloadTimeoutSeconds)s (code=\(result.exitCode)). stderr tail: \(stderrTail) | stdout tail: \(stdoutTail)",
                source: "Download"
            )
            let failure = DownloadFailure(
                klass: .networkTimeout,
                source: "youtube",
                detail: "yt-dlp timed out after \(downloadTimeoutSeconds)s; exit=\(result.exitCode); stderr=\(stderrTail)",
                userMessage: "YouTube download timed out — the connection may be slow or YouTube is not responding",
                heal: .retrySameSource
            )
            return .failure(failure)
        }

        // Trust the printed filepath FIRST — yt-dlp commonly exits
        // with code 101 ("--max-downloads reached") even though the
        // file was successfully downloaded and printed via
        // `--print after_move:filepath`. Treating that as failure
        // (the old behaviour) was throwing away valid downloads.
        //
        // Note: `--newline --progress` makes yt-dlp emit progress lines
        // to stdout alongside the final filepath, so we must walk lines
        // from the end rather than trimming the whole blob.
        if let outputPath = parseDownloadedFilePath(
            stdout: result.stdout,
            outputDir: outputDir
        ) {
            return .success(URL(fileURLWithPath: outputPath))
        }

        // No file path on stdout: classify the failure via the shared classifier.
        let stderrTail = DownloadFailureClassifier.tail(result.stderr)
        let stdoutTail = DownloadFailureClassifier.tail(result.stdout, 400)

        if !result.isSuccess {
            AppLogger.shared.warn(
                "chain[YT]: yt-dlp exited non-zero (code=\(result.exitCode)). stderr tail: \(stderrTail) | stdout tail: \(stdoutTail)",
                source: "Download"
            )
        } else {
            // Exit 0 but no trusted output path — unusual but observed in production
            // (6 occurrences with ~1s runtime, yt-dlp bailed almost immediately).
            AppLogger.shared.warn(
                "chain[YT]: no trusted output path (code=\(result.exitCode), no directory scan). stderr tail: \(stderrTail) | stdout tail: \(stdoutTail)",
                source: "Download"
            )
        }

        let failure = DownloadFailureClassifier.classifyTool(
            source: "youtube",
            exitCode: result.exitCode,
            stderr: result.stderr,
            stdout: result.stdout,
            producedFile: false
        )
        return .failure(failure)
    }

    // MARK: - Query Normalisation

    /// Extract the downloaded file path from yt-dlp's stdout.
    ///
    /// `--newline --progress` causes yt-dlp to emit progress lines to
    /// stdout alongside the final filepath printed by `--print after_move:filepath`.
    /// Walking lines from the end and requiring the line to start with
    /// `outputDir` preserves the T-39-01 invariant: only a path this
    /// invocation provably printed (and that exists on disk) is returned.
    ///
    /// Visible + static for testability without spawning yt-dlp.
    static func parseDownloadedFilePath(stdout: String, outputDir: URL) -> String? {
        let prefix = outputDir.path
        let lines = stdout.split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard trimmed.hasPrefix(prefix) else { continue }
            if FileManager.default.fileExists(atPath: trimmed) {
                return trimmed
            }
        }
        return nil
    }

    /// Case-insensitive tokens that identify a DIFFERENT recording of the
    /// same song (a remix, a live take, a slowed edit, ...). A bracket
    /// group containing one of these must be preserved rather than
    /// stripped, or the normalized query silently retargets a different
    /// recording than the one the user actually requested (SCDL-03).
    private static let identityTokens: Set<String> = [
        "remix", "edit", "version", "live", "slowed", "sped up", "reverb",
        "bootleg", "remaster", "remastered", "vip", "dub", "instrumental",
        "acoustic"
    ]

    /// Strip the parenthetical / bracket noise that turns valid song titles
    /// into queries no YouTube video matches verbatim. Things like
    /// `(feat. Hittman, Six-Two, Nate Dogg & Kurupt)`,
    /// `[Official Music Video]` make ytsearch5 return zero hits even when
    /// the song is on YouTube several times over. Groups that carry an
    /// identity-bearing qualifier (remix, live, slowed, remaster, ...) are
    /// preserved instead — deleting them would make the query match a
    /// DIFFERENT recording of the same song, which is the exact
    /// data-integrity defect this phase closes.
    ///
    /// We collapse to "Artist - Title" with non-identity `(...)` / `[...]`
    /// content removed and whitespace squashed. Visible for testability.
    static func normalizeQueryForYouTube(_ raw: String) -> String {
        var s = raw
        // Repeatedly strip balanced parentheses and brackets — handles
        // nested groups like "Title (Mix) [Remastered]". A group is only
        // stripped when it does NOT contain an identity-bearing token.
        let patterns = ["\\([^()]*\\)", "\\[[^\\[\\]]*\\]"]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let regex = try? NSRegularExpression(pattern: pattern) {
                    let range = NSRange(s.startIndex..., in: s)
                    let matches = regex.matches(in: s, range: range)
                    // Walk matches in reverse so earlier ranges stay valid
                    // as we mutate the string.
                    for match in matches.reversed() {
                        guard let matchRange = Range(match.range, in: s) else { continue }
                        let groupText = String(s[matchRange]).lowercased()
                        let isIdentityGroup = identityTokens.contains { token in
                            groupText.contains(token)
                        }
                        if isIdentityGroup {
                            continue
                        }
                        s.removeSubrange(matchRange)
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

    // MARK: - Playlist Listing

    /// A single entry from a YouTube playlist (flat listing, no download).
    struct PlaylistEntry {
        let id: String
        let title: String
        let uploader: String?
        let durationSeconds: Int?
        let url: String
    }

    /// A resolved playlist: its title plus ordered entries.
    struct PlaylistListing {
        let title: String?
        let entries: [PlaylistEntry]
    }

    /// List a YouTube playlist without downloading, via
    /// `yt-dlp --flat-playlist -J`. Returns the playlist title and entries
    /// in order.
    func listPlaylist(url: String) async throws -> PlaylistListing {
        guard let ytdlp = ytDlpPath else { return PlaylistListing(title: nil, entries: []) }

        let result = try await ProcessRunner.run(
            ytdlp,
            arguments: [
                url,
                "--flat-playlist",
                "-J",
                "--no-warnings"
            ]
        )
        guard result.isSuccess else {
            AppLogger.shared.warn(
                "YT: flat-playlist listing failed (code=\(result.exitCode))",
                source: "Download"
            )
            return PlaylistListing(title: nil, entries: [])
        }

        guard let data = result.stdout.data(using: .utf8) else {
            return PlaylistListing(title: nil, entries: [])
        }
        let root = try JSONDecoder().decode(FlatPlaylistRoot.self, from: data)
        let entries = root.entries.compactMap { entry -> PlaylistEntry? in
            guard let id = entry.id else { return nil }
            let watchURL = entry.url ?? "https://www.youtube.com/watch?v=\(id)"
            return PlaylistEntry(
                id: id,
                title: entry.title ?? "Unknown",
                uploader: entry.uploader ?? entry.channel,
                durationSeconds: entry.duration.map { Int($0) },
                url: watchURL
            )
        }
        return PlaylistListing(title: root.title, entries: entries)
    }

    private struct FlatPlaylistRoot: Decodable {
        let title: String?
        let entries: [FlatEntry]
    }

    private struct FlatEntry: Decodable {
        let id: String?
        let title: String?
        let url: String?
        let uploader: String?
        let channel: String?
        let duration: Double?
    }

    /// Search YouTube (no download) via `yt-dlp "ytsearchN:query" --flat-playlist -J`.
    func search(query: String, limit: Int = 20) async throws -> [FlatPlaylistEntry] {
        guard let ytdlp = ytDlpPath else { return [] }
        let result = try await ProcessRunner.run(
            ytdlp,
            arguments: [
                "ytsearch\(limit):\(query)",
                "--flat-playlist",
                "-J",
                "--no-warnings",
                "--socket-timeout", "10"
            ]
        )
        guard result.isSuccess, let data = result.stdout.data(using: .utf8) else { return [] }
        let root = try JSONDecoder().decode(FlatPlaylistRoot.self, from: data)
        return root.entries.compactMap { entry in
            guard let id = entry.id else { return nil }
            return FlatPlaylistEntry(
                id: id,
                title: entry.title ?? "Unknown",
                uploader: entry.uploader ?? entry.channel,
                durationSeconds: nil,
                url: entry.url ?? "https://www.youtube.com/watch?v=\(id)"
            )
        }
    }

    /// A search/listing entry (used by both playlist listing and search).
    struct FlatPlaylistEntry {
        let id: String
        let title: String
        let uploader: String?
        let durationSeconds: Int?
        let url: String
    }

    /// Resolve metadata for an arbitrary URL supported by yt-dlp (SoundCloud,
    /// YouTube, and hundreds of other sites). Returns one entry for a single
    /// track/video, or all entries when the URL points at a playlist/set.
    func fetchURLInfo(url: String) async throws -> [FlatPlaylistEntry] {
        guard let ytdlp = ytDlpPath else { return [] }
        let result = try await ProcessRunner.run(
            ytdlp,
            arguments: [
                url,
                "-J",
                "--flat-playlist",
                "--no-warnings"
            ]
        )
        guard result.isSuccess, let data = result.stdout.data(using: .utf8) else { return [] }

        let info = try JSONDecoder().decode(URLInfoRoot.self, from: data)
        if let entries = info.entries, !entries.isEmpty {
            // Playlist / set.
            return entries.compactMap { entry in
                guard let id = entry.id else { return nil }
                return FlatPlaylistEntry(
                    id: id,
                    title: entry.title ?? "Unknown",
                    uploader: entry.uploader ?? entry.channel,
                    durationSeconds: entry.duration.map { Int($0) },
                    url: entry.url ?? entry.webpageUrl ?? url
                )
            }
        }
        // Single track / video.
        guard let id = info.id else { return [] }
        return [
            FlatPlaylistEntry(
                id: id,
                title: info.title ?? "Unknown",
                uploader: info.uploader ?? info.channel,
                durationSeconds: info.duration.map { Int($0) },
                url: info.webpageUrl ?? url
            )
        ]
    }

    private struct URLInfoRoot: Decodable {
        let id: String?
        let title: String?
        let uploader: String?
        let channel: String?
        let duration: Double?
        let webpageUrl: String?
        let entries: [URLInfoEntry]?

        enum CodingKeys: String, CodingKey {
            case id, title, uploader, channel, duration, entries
            case webpageUrl = "webpage_url"
        }
    }

    private struct URLInfoEntry: Decodable {
        let id: String?
        let title: String?
        let uploader: String?
        let channel: String?
        let duration: Double?
        let url: String?
        let webpageUrl: String?

        enum CodingKeys: String, CodingKey {
            case id, title, uploader, channel, duration, url
            case webpageUrl = "webpage_url"
        }
    }

}

// MARK: - Models

struct YouTubeTrack: Codable, Sendable {
    let id: String
    let title: String
    let duration: Double?
    let url: String?
    let uploader: String?

    var watchUrl: String {
        if let url = url, !url.isEmpty {
            return url
        }
        return "https://www.youtube.com/watch?v=\(id)"
    }
}
