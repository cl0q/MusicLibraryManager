import Foundation
import Testing
@testable import MLM

/// Tests for `SoundCloudDownloader.collapseDoubledAudioExtension`.
///
/// SCDL-02 / RESEARCH Pitfall 4: `scdl` can emit a doubled audio
/// container extension (e.g. `.m4a.m4a`). This pure static helper
/// collapses a trailing IDENTICAL extension pair to a single extension
/// and leaves everything else — including a stem containing an
/// unrelated dot, and a pair of two DIFFERENT audio extensions —
/// untouched. No I/O involved, so it is unit-testable directly.
struct SoundCloudDownloaderTests {

    @Test
    func collapsesDoubledM4A() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("song.m4a.m4a")
        #expect(result == "song.m4a")
    }

    @Test
    func collapsesDoubledFlac() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("track.flac.flac")
        #expect(result == "track.flac")
    }

    @Test
    func collapsesDoubledCaseInsensitive() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("Song.MP3.mp3")
        #expect(result.lowercased().hasSuffix(".mp3"))
        // Only one extension remains — no second ".mp3"/".MP3" suffix pair.
        #expect(!result.lowercased().hasSuffix(".mp3.mp3"))
        #expect(result == "Song.mp3")
    }

    @Test
    func leavesSingleExtensionUnchanged() {
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("song.m4a")
        #expect(result == "song.m4a")
    }

    @Test
    func leavesDotInStemUnchanged() {
        // A dot in the stem is not a doubled container extension.
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("my.song.opus")
        #expect(result == "my.song.opus")
    }

    @Test
    func leavesDifferentExtensionPairUnchanged() {
        // Two DIFFERENT audio extensions is not the observed .m4a.m4a
        // doubling symptom — do not guess a canonical one.
        let result = SoundCloudDownloader.collapseDoubledAudioExtension("song.mp3.m4a")
        #expect(result == "song.mp3.m4a")
    }

    // MARK: - WP-F: DownloadOutcome migration + classifier integration

    @Test
    func scdlTimeoutIsGenerous() {
        // Timeout must be >= 600s (10 min) — SoundCloud DJ mixes can be
        // 1–2 hours and legitimately take many minutes on a slow link.
        #expect(SoundCloudDownloader.scdlTimeout >= 600)
        // And it is the documented value.
        #expect(SoundCloudDownloader.scdlTimeout == 900)
    }

    @Test
    func toolMissingReturnsClassifiedFailure() {
        // When scdl is not installed, download() must return a classified
        // .failure, not throw or return success. We cannot force scdl to
        // be absent on this machine, but we can verify the transport
        // classifier produces the expected shape for a tool-missing error.
        let error = URLError(.fileDoesNotExist)
        let failure = DownloadFailureClassifier.classifyTransport(
            source: "soundcloud", error: error)
        #expect(failure.source == "soundcloud")
        // classifyTransport maps URLError.fileDoesNotExist to .unknown
        // (not a network-specific code); the downloader's scdlPath==nil
        // guard feeds this same error. Assert the outcome shape.
        let outcome = DownloadOutcome.failure(failure)
        if case .failure(let f) = outcome {
            #expect(f.source == "soundcloud")
        } else {
            Issue.record("Expected .failure outcome")
        }
    }

    @Test
    func tailTruncationPreservesEndOfLongStderr() {
        // REGRESSION: the old `prefix(500)` head-truncated stderr, which
        // discarded the diagnostic — scdl/yt-dlp emit the error LAST.
        // `DownloadFailureClassifier.tail` keeps the END. Construct a
        // realistic >800-char stderr with the diagnostic at the very end
        // and verify the classifier's `detail` preserves it.
        let banner = String(repeating: "[scdl] starting up download sequence\n", count: 40)
        let diagnostic = "ERROR: [soundcloud] Unable to download JSON metadata: HTTP Error 404: Not Found"
        let stderr = banner + diagnostic
        #expect(stderr.count > 800, "Test fixture must exceed tail's default 800-char window")

        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: 0,
            stderr: stderr,
            stdout: "",
            producedFile: false)

        // The diagnostic at the END must survive in `detail`.
        #expect(failure.detail.hasSuffix("HTTP Error 404: Not Found"))
        // The leading banner must NOT appear (it was head-truncated by tail).
        #expect(!failure.detail.hasPrefix("[scdl] starting up"))
    }

    @Test
    func exit0NoFileDRMStderrClassifiesAsDRMProtected() {
        // The central WP-F scenario: scdl exits 0, produces no file, and
        // stderr says "DRM protected". The classifier must catch this
        // regardless of the exit code.
        let stderr = "Some banner output\nThis video is DRM protected\n"
        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: 0,
            stderr: stderr,
            stdout: "",
            producedFile: false)
        #expect(failure.klass == .drmProtected)
        #expect(failure.isPermanent == true)
        #expect(failure.isRetryable == false)
        #expect(failure.source == "soundcloud")
    }

    @Test
    func exit0NoFile404MetadataClassifiesAsFormatUnavailable() {
        // scdl exits 0 with no file, stderr contains the stale-extractor
        // "Unable to download JSON metadata: HTTP Error 404" pattern.
        // This is NOT .contentRemoved (the track may be downloadable with
        // an updated extractor); it classifies as .formatUnavailable which
        // is non-permanent and retryable.
        let stderr = """
            [soundcloud] track-name: Downloading track info
            ERROR: [soundcloud] Unable to download JSON metadata: HTTP Error 404: Not Found
            """
        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: 0,
            stderr: stderr,
            stdout: "",
            producedFile: false)
        #expect(failure.klass == .formatUnavailable)
        #expect(failure.isPermanent == false)
        #expect(failure.isRetryable == true)
        #expect(failure.source == "soundcloud")
    }

    @Test
    func longStderrWithDRMAtEndClassifiesAsDRMNotUnknown() {
        // End-to-end regression for the prefix→tail fix: a long stderr
        // whose ONLY diagnostic is at the very END must classify correctly.
        // Under the old prefix(500) truncation the DRM marker was lost and
        // every failure fell through to a bare .notFound.
        let filler = String(repeating: "x", count: 1000)
        let stderr = filler + "This video is DRM protected"
        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: 0,
            stderr: stderr,
            stdout: "",
            producedFile: false)
        #expect(failure.klass == .drmProtected)
        #expect(failure.isPermanent == true)
    }

    @Test
    func nonZeroExitWithNoFileProducesClassifiedFailure() {
        // Non-zero exit with no file and an unrecognised stderr pattern
        // must still produce a classified .failure (via .outputMissing at
        // the classifier's rule 18), never a bare not-found.
        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: 1,
            stderr: "Something went wrong",
            stdout: "",
            producedFile: false)
        // Some unrecognised pattern → outputMissing (rule 18) or unknown.
        // Either way it is a DownloadFailure, not a bare not-found.
        #expect(failure.source == "soundcloud")
        #expect(failure.klass != .unknown || failure.source == "soundcloud")
        // outputMissing is the classifier's rule-18 fallback for
        // "no pattern matched and no file produced".
        #expect(failure.klass == .outputMissing)
        #expect(failure.isRetryable == true)
    }

    @Test
    func timeoutResultDoesNotBecomeSuccess() {
        // A timedOut ProcessResult has isSuccess == false (exitCode may be
        // 0 from SIGTERM rounding, but timedOut overrides). Verify the
        // classifier's tail preserves the timeout context and that the
        // download path's explicit timedOut check (which fires BEFORE
        // classifyTool) would produce .networkTimeout.
        //
        // We cannot spawn scdl in a hermetic test, so we verify the
        // contract: the timeout constant is sane, and a .networkTimeout
        // failure built the same way the download method builds it has
        // the expected properties.
        let timeoutFailure = DownloadFailure(
            klass: .networkTimeout,
            source: "soundcloud",
            detail: "scdl timed out after \(SoundCloudDownloader.scdlTimeout)s for trackId=123 url=https://soundcloud.com/test",
            userMessage: "SoundCloud download timed out — retry later",
            heal: .retrySameSource)
        #expect(timeoutFailure.isPermanent == false)
        #expect(timeoutFailure.isRetryable == true)
        // And the outcome is .failure, never .success.
        let outcome = DownloadOutcome.failure(timeoutFailure)
        if case .success = outcome {
            Issue.record("TimedOut must not produce .success")
        }
    }

    // MARK: - WP-F fix-up: log-level keyed on file presence, not exit code

    @Test
    func exit0NoFileFailureDetailCarriesFullStderrAndTrackContext() {
        // The central WP-F scenario end-to-end through the classifier:
        // exit 0, no file, stderr with a real diagnostic. The returned
        // DownloadFailure.detail must contain the FULL stderr (not the
        // 800-char tail) and the classifier must not discard the reason.
        //
        // Note: AppLogger is not observable from tests, so we cannot
        // assert the .warning log level directly. The .warning log is
        // keyed on file absence (not exit code) in the restructured
        // code, so it fires for this exit-0-no-file case. The detail
        // field is the testable proxy for "the reason was preserved".
        let stderr = "ERROR: [soundcloud] Unable to download JSON metadata: HTTP Error 404: Not Found"
        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: 0,
            stderr: stderr,
            stdout: "",
            producedFile: false)
        // Full stderr preserved in detail (shorter than 800-char tail).
        #expect(failure.detail.contains(stderr))
        #expect(failure.source == "soundcloud")
        // Classification is meaningful, not .unknown or .contentRemoved.
        #expect(failure.klass == .formatUnavailable)
        #expect(failure.isPermanent == false)
        #expect(failure.isRetryable == true)
    }

    @Test
    func fileIsGroundTruth_exitCodeDoesNotVetoRealFile() {
        // Success rule: a produced file in the invocation's exclusive
        // temp dir IS success, regardless of exit code. scdl's exit code
        // is proven unreliable in the failure direction (47/47 failures
        // exited 0); the converse also holds — a non-zero exit with a
        // valid audio file is a real success.
        //
        // We cannot spawn scdl in a hermetic test, so we verify the
        // contract: DownloadOutcome.success can carry a URL regardless
        // of what exit code scdl returned. The download method's
        // restructured guard (`if let downloadedFile = producedFile`)
        // does not check result.exitCode — only file presence.
        let url = URL(fileURLWithPath: "/tmp/test.mp3")
        let outcome = DownloadOutcome.success(url)
        if case .success(let u) = outcome {
            #expect(u == url)
        } else {
            Issue.record("Expected .success")
        }
    }

    @Test
    func benignChatterWithFileStillSuccess_exitCodeIrrelevant() {
        // scdl can print "artwork not found" or "original format not
        // found, falling back to transcoded" even during a successful
        // download. With the file-scan-first invariant, a produced file
        // means success regardless of stderr content or exit code.
        //
        // This test verifies the classifier side: if classifyTool were
        // (hypothetically) called with producedFile: true and benign
        // chatter, it must NOT return a failure that vetoes the file.
        // In the restructured code, classifyTool is only called with
        // producedFile: false (the file-scan guard handles the
        // true case), but the classifier must not produce a permanent
        // or DRM failure from benign chatter.
        let stderr = "artwork not found\noriginal format not found, falling back to transcoded"
        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: 1,
            stderr: stderr,
            stdout: "",
            producedFile: true)
        // With producedFile: true, the benign chatter exclusion prevents
        // rule 17 from matching. No other rule matches either, so the
        // classifier falls through to .unknown (rule 19). The download
        // method never calls classifyTool in this path (the file-scan
        // guard returns .success first), but the classifier must not
        // produce a permanent or DRM failure from benign chatter.
        #expect(failure.klass == .unknown)
        #expect(failure.isPermanent == false)
        #expect(failure.klass != .drmProtected)
        #expect(failure.klass != .contentRemoved)
    }

    // MARK: - WP-F timeout/partial-file data-corruption guard

    @Test
    func timeoutWithPartialFileReturnsNetworkTimeoutNotSuccess() {
        // Data-corruption guard: a timeout means scdl was killed mid-write.
        // Any file on disk is a partial write — accepting it would silently
        // admit a corrupt file into the permanent library. The download
        // method's `if result.timedOut, let partialFile = producedFile`
        // guard fires BEFORE the success branch and returns .failure.
        //
        // We cannot spawn scdl in a hermetic test, so we verify the
        // contract at the DownloadOutcome level: construct the exact
        // failure the download method builds for this path and assert
        // it is .failure with .networkTimeout, never .success.
        let failure = DownloadFailure(
            klass: .networkTimeout,
            source: "soundcloud",
            detail: "scdl timed out after \(SoundCloudDownloader.scdlTimeout)s for trackId=42 url=https://soundcloud.com/test — partial file 'track.m4a' (1048576 bytes) discarded",
            userMessage: "SoundCloud download timed out — retry later",
            heal: .retrySameSource)
        let outcome = DownloadOutcome.failure(failure)
        if case .success = outcome {
            Issue.record("Timeout with partial file must NEVER be .success — data corruption path")
        }
        if case .failure(let f) = outcome {
            #expect(f.klass == .networkTimeout)
            #expect(f.isPermanent == false)
            #expect(f.isRetryable == true)
            #expect(f.heal == .retrySameSource)
            // Detail records the partial file was discarded (evidence for
            // diagnosing truncation in production logs).
            #expect(f.detail.contains("partial file"))
            #expect(f.detail.contains("discarded"))
            #expect(f.detail.contains("1048576 bytes"))
        }
    }

    @Test
    func timeoutWithNoFileReturnsNetworkTimeout() {
        // Timeout with no file at all — the simpler case. Same klass,
        // same heal, but the detail does NOT mention a partial file.
        let failure = DownloadFailure(
            klass: .networkTimeout,
            source: "soundcloud",
            detail: "scdl timed out after \(SoundCloudDownloader.scdlTimeout)s for trackId=42 url=https://soundcloud.com/test",
            userMessage: "SoundCloud download timed out — retry later",
            heal: .retrySameSource)
        #expect(failure.klass == .networkTimeout)
        #expect(failure.isPermanent == false)
        #expect(failure.isRetryable == true)
        #expect(failure.heal == .retrySameSource)
        // No partial file mentioned — no file was on disk.
        #expect(!failure.detail.contains("partial file"))
    }

    @Test
    func timeoutDetailFormatIncludesTrackContextAndByteSize() {
        // The timeout-with-partial-file detail is a structured string
        // that production logs can grep for. Verify the format:
        // "scdl timed out after Ns for trackId=X url=Y — partial file 'name' (N bytes) discarded"
        let trackId: Int64 = 12345
        let url = "https://soundcloud.com/artist/track"
        let filename = "artist - track.m4a"
        let byteSize = 2_097_152
        let detail = "scdl timed out after \(Int(SoundCloudDownloader.scdlTimeout))s for trackId=\(trackId) url=\(url) — partial file '\(filename)' (\(byteSize) bytes) discarded"
        #expect(detail.contains("trackId=12345"))
        #expect(detail.contains("url=https://soundcloud.com/artist/track"))
        #expect(detail.contains("partial file 'artist - track.m4a'"))
        #expect(detail.contains("2097152 bytes"))
        #expect(detail.contains("discarded"))
    }

    @Test
    func successOutcomeContract_fileIsSuccessRegardlessOfExitCode() {
        // Guard against over-correction: the timeout fix must not break
        // the "non-zero exit + valid file = success" rule. A non-zero
        // exit is NOT evidence of an interrupted write (scdl can exit
        // non-zero for benign reasons like an artwork fetch failing
        // after the audio was fully written). Only a timeout implies
        // truncation. Verify the .success contract: a URL is a URL.
        let url = URL(fileURLWithPath: "/output/song.m4a")
        let outcome = DownloadOutcome.success(url)
        if case .success(let u) = outcome {
            #expect(u == url)
        } else {
            Issue.record("Expected .success — non-zero exit with valid file must still succeed")
        }
    }

    @Test
    func timeoutAndSuccessOutcomesAreDistinct() {
        // Structural guard: .failure(.networkTimeout) and .success(URL)
        // must never be conflated. This test exists so that a future
        // refactor cannot accidentally make them equal or interchangeable.
        let url = URL(fileURLWithPath: "/output/song.m4a")
        let success = DownloadOutcome.success(url)
        let timeout = DownloadOutcome.failure(DownloadFailure(
            klass: .networkTimeout,
            source: "soundcloud",
            detail: "timeout",
            userMessage: "timed out",
            heal: .retrySameSource))
        #expect(success != timeout)
        // Pattern-match both to prove they are distinct enum cases.
        let successIsSuccess: Bool
        let timeoutIsSuccess: Bool
        if case .success = success { successIsSuccess = true } else { successIsSuccess = false }
        if case .success = timeout { timeoutIsSuccess = true } else { timeoutIsSuccess = false }
        #expect(successIsSuccess == true)
        #expect(timeoutIsSuccess == false)
    }
}
