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
}
