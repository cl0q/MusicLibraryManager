import Foundation
import Testing
@testable import MLM

/// Tests for `YouTubeDownloader.normalizeQueryForYouTube`.
///
/// SCDL-03: identity-bearing qualifiers (remix, edit, version, live,
/// slowed, bootleg, remaster, ...) must survive query normalization,
/// while non-identity noise ("Official Music Video", "feat. X") must
/// still be stripped. This is a pure static function — no I/O, no
/// subprocess invocation — so it is tested directly and exhaustively.
struct YouTubeDownloaderTests {

    @Test
    func preservesRemixQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Kanye West - Bound 2 (Remix)")
        #expect(result.lowercased().contains("remix"))
    }

    @Test
    func preservesEditQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Extended Edit)")
        #expect(result.lowercased().contains("edit"))
    }

    @Test
    func preservesSlowedQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Slowed + Reverb)")
        #expect(result.lowercased().contains("slowed"))
    }

    @Test
    func preservesLiveQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Live at Wembley)")
        #expect(result.lowercased().contains("live"))
    }

    @Test
    func preservesBootlegQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Bootleg)")
        #expect(result.lowercased().contains("bootleg"))
    }

    @Test
    func preservesRemasterQualifierYearPrefixed() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (2024 Remaster)")
        #expect(result.lowercased().contains("remaster"))
    }

    @Test
    func preservesRemasteredQualifier() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Remastered)")
        #expect(result.lowercased().contains("remaster"))
    }

    @Test
    func stripsOfficialMusicVideoNoise() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (Official Music Video)")
        #expect(!result.lowercased().contains("official"))
        #expect(!result.lowercased().contains("video"))
    }

    @Test
    func stripsOfficialVideoBracketNoise() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title [Official Video]")
        #expect(!result.lowercased().contains("official"))
        #expect(!result.lowercased().contains("video"))
    }

    @Test
    func stripsFeaturingNoise() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (feat. X)")
        #expect(!result.lowercased().contains("feat"))
    }

    @Test
    func caseInsensitiveMatching() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title (REMIX)")
        #expect(result.lowercased().contains("remix"))
    }

    @Test
    func plainTitleUnaffected() {
        let result = YouTubeDownloader.normalizeQueryForYouTube("Artist - Title")
        #expect(result == "Artist - Title")
    }

    // MARK: - parseDownloadedFilePath

    /// Creates a temp staging dir containing one file named `fileName`,
    /// runs `parseDownloadedFilePath(stdout:outputDir:)` with `stdout`
    /// (where `__OUTDIR__` is substituted for the real temp path), and
    /// returns the result. Cleans up the temp dir on exit.
    private func parseWithFile(
        fileName: String,
        stdout: String
    ) -> String? {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt-parse-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8))

        let rendered = stdout.replacingOccurrences(of: "__OUTDIR__", with: tmp.path)
        return YouTubeDownloader.parseDownloadedFilePath(
            stdout: rendered,
            outputDir: tmp
        )
    }

    @Test
    func parseExtractsPathFromNoisyProgressStdout() {
        // Realistic yt-dlp stdout with --newline --progress: progress
        // lines followed by the after_move filepath. Exit code 101.
        let stdout = """
        [download]   13.6% of  3.66MiB at    1.89MiB/s ETA 00:01
        [download]   54.6% of  3.66MiB at    2.48MiB/s ETA 00:00
        [download]  100.0% of  3.66MiB at    1.85MiB/s ETA 00:00
        [download]  100% of  3.66MiB in 00:00:02 at 1.35MiB/s
        __OUTDIR__/Artist - Song.m4a
        """
        let result = parseWithFile(fileName: "Artist - Song.m4a", stdout: stdout)
        #expect(result?.hasSuffix("Artist - Song.m4a") == true)
    }

    @Test
    func parseExtractsPathFromCleanStdout() {
        let stdout = "__OUTDIR__/Clean Path.m4a\n"
        let result = parseWithFile(fileName: "Clean Path.m4a", stdout: stdout)
        #expect(result?.hasSuffix("Clean Path.m4a") == true)
    }

    @Test
    func parseReturnsNilForEmptyStdout() {
        let result = parseWithFile(fileName: "ignored.m4a", stdout: "")
        #expect(result == nil)
    }

    @Test
    func parseReturnsNilForGarbageStdout() {
        let stdout = """
        [download] 100% of 3.66MiB
        some random garbage that is not a path
        """
        let result = parseWithFile(fileName: "ignored.m4a", stdout: stdout)
        #expect(result == nil)
    }

    @Test
    func parseReturnsNilWhenFileDoesNotExistOnDisk() {
        // Path matches outputDir prefix but no file is there → must not
        // be returned (T-39-01: only provably-printed AND existing paths).
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt-parse-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let stdout = "\(tmp.path)/Ghost.m4a\n"
        let result = YouTubeDownloader.parseDownloadedFilePath(
            stdout: stdout,
            outputDir: tmp
        )
        #expect(result == nil)
    }

    @Test
    func parsePicksLastMatchingLineWhenMultipleExist() {
        // Progress lines may coincidentally start with outputDir if the
        // user's temp path is a prefix of another line. Only the last
        // matching line that exists on disk should win.
        let stdout = """
        __OUTDIR__/NotTheRealFile.m4a
        [download] 100% done
        __OUTDIR__/Real File.m4a
        """
        let result = parseWithFile(fileName: "Real File.m4a", stdout: stdout)
        #expect(result?.hasSuffix("Real File.m4a") == true)
    }

    // MARK: - classifyDownloadResult

    /// Helper: build a `ProcessResult` without spawning a process.
    private func makeResult(
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false
    ) -> ProcessRunner.ProcessResult {
        ProcessRunner.ProcessResult(
            exitCode: exitCode,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            processIdentifier: -1
        )
    }

    /// Helper: create a temp dir containing one file, run `classifyDownloadResult`,
    /// and clean up. `stdoutTemplate` may contain `__OUTDIR__` which is substituted.
    private func classifyWithFile(
        fileName: String,
        exitCode: Int32,
        stdout: String = "",
        stderr: String = "",
        timedOut: Bool = false
    ) -> DownloadOutcome {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt-classify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fileURL = tmp.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("x".utf8))

        let rendered = stdout.replacingOccurrences(of: "__OUTDIR__", with: tmp.path)
        let result = makeResult(exitCode: exitCode, stdout: rendered, stderr: stderr, timedOut: timedOut)
        return YouTubeDownloader.classifyDownloadResult(result, outputDir: tmp)
    }

    // MARK: - Production 403 regression

    /// The real production failure: stderr `ERROR: unable to download video data:
    /// HTTP Error 403: Forbidden`, exit code 1. Must classify as `.toolStale` with
    /// heal `.updateToolThenRetry` — NOT `.contentRemoved` or `.outputMissing`.
    @Test
    func production403ClassifiesAsToolStaleWithUpdateHeal() {
        let stderr = """
        [youtube] Extracting URL: https://www.youtube.com/watch?v=dQw4w9WgXcQ
        [youtube] dQw4w9WgXcQ: Downloading webpage
        [youtube] dQw4w9WgXcQ: Downloading ios player API JSON
        ERROR: unable to download video data: HTTP Error 403: Forbidden
        """
        let outcome = classifyWithFile(
            fileName: "ignored.m4a",
            exitCode: 1,
            stderr: stderr
        )
        guard case .failure(let failure) = outcome else {
            Issue.record("Expected .failure, got \(outcome)")
            return
        }
        #expect(failure.klass == .toolStale)
        #expect(failure.heal == .updateToolThenRetry)
        #expect(failure.source == "youtube")
        #expect(!failure.detail.isEmpty)
    }

    // MARK: - Exit 101 path-first success

    /// Exit 101 (`--max-downloads` reached) with a valid printed path is `.success`.
    /// This is the most important regression guard — without it every YouTube
    /// download breaks.
    @Test
    func exit101WithValidPathIsSuccess() {
        let stdout = """
        [download]   13.6% of  3.66MiB at    1.89MiB/s ETA 00:01
        [download]  100.0% of  3.66MiB at    1.85MiB/s ETA 00:00
        __OUTDIR__/Artist - Song.m4a
        """
        let outcome = classifyWithFile(
            fileName: "Artist - Song.m4a",
            exitCode: 101,
            stdout: stdout
        )
        guard case .success(let url) = outcome else {
            Issue.record("Expected .success, got \(outcome)")
            return
        }
        #expect(url.lastPathComponent == "Artist - Song.m4a")
    }

    // MARK: - Exit 0 but path does not exist

    /// Exit 0 but printed path does not exist on disk → `.failure`, not `.success`.
    @Test
    func exit0ButPathMissingIsFailure() {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("yt-classify-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // No file created — the printed path does not exist.
        let stdout = "\(tmp.path)/Ghost.m4a\n"
        let result = makeResult(exitCode: 0, stdout: stdout)
        let outcome = YouTubeDownloader.classifyDownloadResult(result, outputDir: tmp)
        guard case .failure = outcome else {
            Issue.record("Expected .failure when printed path does not exist, got \(outcome)")
            return
        }
    }

    // MARK: - "No results" vs 403 distinction

    /// "No video results" → content-related failure, distinguishable from 403.
    @Test
    func noResultsClassifiesAsContentRemoved() {
        let stderr = "[youtube] No video results for query 'xyznonexistent'"
        let outcome = classifyWithFile(
            fileName: "ignored.m4a",
            exitCode: 1,
            stderr: stderr
        )
        guard case .failure(let failure) = outcome else {
            Issue.record("Expected .failure, got \(outcome)")
            return
        }
        #expect(failure.klass == .contentRemoved)
        #expect(failure.klass != .toolStale) // distinct from 403
    }

    /// A genuinely absent track (no results) and a 403 produce different `klass`.
    /// This is the core property the whole rewrite exists to establish.
    @Test
    func absentTrackVs403ProduceDifferentKlass() {
        let absentStderr = "[youtube] No video results"
        let staleStderr = "ERROR: unable to download video data: HTTP Error 403: Forbidden"

        let absentOutcome = classifyWithFile(fileName: "x.m4a", exitCode: 1, stderr: absentStderr)
        let staleOutcome = classifyWithFile(fileName: "x.m4a", exitCode: 1, stderr: staleStderr)

        guard case .failure(let absentFailure) = absentOutcome,
              case .failure(let staleFailure) = staleOutcome else {
            Issue.record("Both outcomes must be .failure")
            return
        }
        #expect(absentFailure.klass != staleFailure.klass)
    }

    // MARK: - Timeout

    /// The download timeout constant is generous (>= 600s).
    @Test
    func downloadTimeoutIsGenerous() {
        #expect(YouTubeDownloader.downloadTimeoutSeconds >= 600)
    }

    /// A `timedOut` result is never `.success`, even if a path was printed.
    @Test
    func timedOutIsNeverSuccess() {
        let stdout = "__OUTDIR__/Partial.m4a\n"
        let outcome = classifyWithFile(
            fileName: "Partial.m4a",
            exitCode: 0,
            stdout: stdout,
            timedOut: true
        )
        guard case .failure(let failure) = outcome else {
            Issue.record("Expected .failure for timedOut, got \(outcome)")
            return
        }
        #expect(failure.klass == .networkTimeout)
    }

    // MARK: - downloadByURL failure has non-empty detail

    /// `downloadByURL` failure returns `.failure` with non-empty `detail`.
    /// This proves the silence is fixed at the type level — every failure
    /// carries diagnostic evidence.
    @Test
    func downloadByURLFailureHasNonEmptyDetail() {
        let stderr = "ERROR: unable to download video data: HTTP Error 403: Forbidden"
        let outcome = classifyWithFile(
            fileName: "ignored.m4a",
            exitCode: 1,
            stderr: stderr
        )
        guard case .failure(let failure) = outcome else {
            Issue.record("Expected .failure, got \(outcome)")
            return
        }
        #expect(!failure.detail.isEmpty)
    }

    // MARK: - yt-dlp missing

    /// When yt-dlp is not found (exitCode 127, stderr "command not found"),
    /// classification yields `.toolMissing`.
    @Test
    func ytDlpMissingClassifiesAsToolMissing() {
        let outcome = classifyWithFile(
            fileName: "ignored.m4a",
            exitCode: 127,
            stderr: "yt-dlp: command not found"
        )
        guard case .failure(let failure) = outcome else {
            Issue.record("Expected .failure, got \(outcome)")
            return
        }
        #expect(failure.klass == .toolMissing)
        #expect(failure.heal == .installTool)
    }
}
