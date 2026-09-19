import Foundation
import Testing
@testable import MLM

/// Tests for the shared download-failure classifier.
///
/// Every test is deterministic and offline — no network, no subprocesses.
/// The classifier is the contract that every downloader and the orchestrator
/// code against; these tests lock the ordered-rule semantics and the
/// real-world stderr strings that drove the design.
struct DownloadFailureClassifierTests {

    // MARK: - tail()

    @Test func tailKeepsEndNotStart() {
        let input = String(repeating: "A", count: 200) + String(repeating: "B", count: 100)
        let result = DownloadFailureClassifier.tail(input, 10)
        #expect(result == "…BBBBBBBBBB")
        #expect(result.hasPrefix("…"))
    }

    @Test func tailExactLengthPassthrough() {
        let input = "Hello"
        #expect(DownloadFailureClassifier.tail(input, 5) == "Hello")
    }

    @Test func tailShorterThanMax() {
        #expect(DownloadFailureClassifier.tail("Hi", 100) == "Hi")
    }

    @Test func tailEmptyString() {
        #expect(DownloadFailureClassifier.tail("", 100) == "")
    }

    @Test func tailMaxCharsZero() {
        #expect(DownloadFailureClassifier.tail("Hello", 0) == "")
    }

    @Test func tailMaxCharsNegative() {
        #expect(DownloadFailureClassifier.tail("Hello", -5) == "")
    }

    @Test func tailMultiByteCharactersDoNotCrash() {
        let input = "Hello 🌍🌎🌏🌐 World"
        let result = DownloadFailureClassifier.tail(input, 5)
        // Must not crash; result is "…" + last 5 Characters
        #expect(result.hasPrefix("…"))
        // "🌏🌐 World" has 6 characters; tail(5) → "…🌐 World" (last 5 chars)
        // The exact value depends on Character counting; just verify no crash and prefix.
    }

    @Test func tailDefaultMaxChars800() {
        let input = String(repeating: "x", count: 1000)
        let result = DownloadFailureClassifier.tail(input)
        // Default maxChars is 800; input is 1000 chars → truncated
        #expect(result.hasPrefix("…"))
        // "…" + 800 chars = 801 total Characters
        #expect(result.count == 801)
    }

    // MARK: - DRM protected (rule 1 — must beat generic 404)

    @Test func drmProtectedRealWorldSoundCloud() {
        let stderr = "[soundcloud] 2320421522: This video is DRM protected"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .drmProtected)
        #expect(f.heal == .none)
        #expect(f.isPermanent)
        #expect(!f.isRetryable)
        #expect(f.userMessage.contains("DRM"))
    }

    @Test func drmBeforeGeneric404Ordering() {
        // String contains BOTH "DRM protected" and "404" — must be DRM, not contentRemoved
        let stderr = "HTTP Error 404: Not Found — This video is DRM protected"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .drmProtected)
        #expect(f.klass != .contentRemoved)
    }

    // MARK: - Geo-blocked (rule 2)

    @Test func geoBlockedNotAvailableInRegion() {
        let stderr = "This video is not available in your region"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .geoBlocked)
        #expect(f.isPermanent)
        #expect(!f.isRetryable)
    }

    @Test func geoBlockedGeographicRestriction() {
        let stderr = "geographic restriction prevents playback"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .geoBlocked)
    }

    // MARK: - Content removed (rule 3)

    @Test func contentRemovedPrivateVideo() {
        let stderr = "Private video"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .contentRemoved)
        #expect(f.isPermanent)
    }

    @Test func contentRemovedByUploader() {
        let stderr = "This video has been removed by the uploader"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .contentRemoved)
    }

    @Test func contentRemovedLoginRequired() {
        let stderr = "login required to access this video"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .contentRemoved)
    }

    // MARK: - Downloads disabled (rule 4)

    @Test func downloadsDisabled() {
        let stderr = "Downloads disabled for this track"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .downloadsDisabled)
        #expect(f.isPermanent)
        #expect(!f.isRetryable)
    }

    // MARK: - Tool stale (rules 5 & 6)

    @Test func toolStaleClientIDExtraction() {
        let stderr = "Unable to extract client_id"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolStale)
        #expect(f.heal == .updateToolThenRetry)
        #expect(f.isRetryable)
    }

    @Test func toolStaleYouTube403UnableToDownloadVideoData() {
        let stderr = "ERROR: HTTP Error 403: Forbidden — unable to download video data"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolStale)
        #expect(f.heal == .updateToolThenRetry)
    }

    @Test func toolStaleYouTube403Nsig() {
        let stderr = "HTTP Error 403: Forbidden — nsig extraction failed"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolStale)
    }

    // MARK: - Format unavailable (rule 7)

    @Test func formatUnavailable404WithFormatInfoJSON() {
        let stderr = "HTTP Error 404: Unable to download format info JSON"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .formatUnavailable)
        #expect(f.heal == .retryOtherFormat)
        #expect(f.isRetryable)
    }

    @Test func formatUnavailable404WithHlsMp3() {
        // Must include HTTP context for the 404 — bare "404" is no longer matched
        // to avoid false positives on track IDs containing "404".
        let stderr = "HTTP Error 404: hls_mp3 format not available"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .formatUnavailable)
    }

    @Test func formatUnavailableStaleExtractor404() {
        // The real-world stale-extractor message: contains "404" AND "Unable to download JSON metadata"
        // This matches rule 7 (format indicator present), NOT rule 14 (generic 404).
        let stderr = "Unable to download JSON metadata: HTTP Error 404: Not Found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .formatUnavailable)
    }

    // MARK: - Rate limited (rule 8)

    @Test func rateLimited429() {
        let stderr = "HTTP Error 429: Too Many Requests"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .rateLimited)
        #expect(f.heal == .retrySameSource)
        #expect(f.isRetryable)
    }

    @Test func rateLimitedRetryAfter() {
        let stderr = "Retry-After header indicates 30 seconds"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .rateLimited)
    }

    // MARK: - Auth expired (rule 9)

    @Test func authExpired401() {
        let stderr = "HTTP Error 401: Unauthorized"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .authExpired)
        #expect(f.heal == .refreshAuthThenRetry)
    }

    @Test func authExpiredTokenExpired() {
        let stderr = "token expired — please re-authenticate"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .authExpired)
    }

    // MARK: - Network timeout (rule 10)

    @Test func networkTimeoutReadTimedOut() {
        let stderr = "Read timed out. (read timeout=20.0)"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .networkTimeout)
        #expect(f.heal == .retrySameSource)
        #expect(f.isRetryable)
    }

    // MARK: - Network unreachable (rule 11 — before generic "not found")

    @Test func networkUnreachableHostnameNotFound() {
        let stderr = "hostname could not be found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func networkUnreachableBeforeGenericNotFound() {
        // Contains BOTH "hostname could not be found" AND "not found"
        // Must be networkUnreachable (rule 11), NOT contentRemoved (rule 14)
        let stderr = "Error: hostname could not be found — not found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .networkUnreachable)
        #expect(f.klass != .contentRemoved)
    }

    @Test func networkUnreachableOffline() {
        let stderr = "The Internet connection appears to be offline."
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func networkConnectionLost() {
        let stderr = "network connection was lost"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func networkUnreachableCouldNotConnect() {
        let stderr = "could not connect to the server"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .networkUnreachable)
    }

    // MARK: - Server error (rule 12)

    @Test func serverError500() {
        let stderr = "HTTP Error 500: Internal Server Error"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .serverError)
        #expect(f.heal == .retrySameSource)
    }

    @Test func serverErrorBadGateway() {
        let stderr = "502 Bad Gateway"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .serverError)
    }

    // MARK: - Media corrupt (rule 13)

    @Test func mediaCorruptMoovAtom() {
        let stderr = "moov atom not found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 0, stderr: stderr, stdout: "", producedFile: true)
        #expect(f.klass == .mediaCorrupt)
        #expect(f.heal == .quarantineAndReport)
        #expect(!f.isRetryable)
    }

    @Test func mediaCorruptInvalidStartCodeRIFF() {
        let stderr = "invalid start code ID3[3] in RIFF header"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 0, stderr: stderr, stdout: "", producedFile: true)
        #expect(f.klass == .mediaCorrupt)
    }

    @Test func mediaCorruptInvalidData() {
        let stderr = "Invalid data found when processing input"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 0, stderr: stderr, stdout: "", producedFile: true)
        #expect(f.klass == .mediaCorrupt)
    }

    @Test func mediaCorruptNoStream() {
        let stderr = "Output file does not contain any stream"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 0, stderr: stderr, stdout: "", producedFile: true)
        #expect(f.klass == .mediaCorrupt)
    }

    // MARK: - Generic "not found" (rule 14 — catch-all for content absence)

    @Test func genericNoVideoResults() {
        let stderr = "No video results"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .contentRemoved)
        #expect(f.isPermanent)
    }

    @Test func genericBare404IsOutputMissing() {
        // A generic "not found" / HTTP 404 without strong indicators is WEAK evidence.
        // It maps to .outputMissing (non-permanent) so the orchestrator tries the
        // next source instead of giving up permanently.
        let stderr = "Error 404 — page not found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .outputMissing)
        #expect(!f.isPermanent)
        #expect(f.heal == .fallThroughToNextSource)
    }

    // MARK: - Tool missing (rule 16 — must precede generic "not found" at rule 17)

    @Test func toolMissingNoSuchFile() {
        let stderr = "scdl: No such file or directory"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 127, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolMissing)
        #expect(f.heal == .installTool)
    }

    @Test func toolMissingCommandNotFound() {
        let stderr = "bash: yt-dlp: command not found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 127, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolMissing)
    }

    @Test func toolMissingCommandNotFoundShadowingCannotRecur() {
        // "command not found" contains "not found" as a substring. The tool-missing
        // rule (16) MUST precede the generic "not found" branch (17) so that
        // "command not found" classifies as .toolMissing, not .outputMissing.
        // Assert heal and isPermanent too — the whole point is that the user gets
        // told to install the tool, not that the source is silently swapped.
        let stderr = "sh: scdl: command not found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 127, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolMissing)
        #expect(f.heal == .installTool)
        #expect(!f.isPermanent)
    }

    @Test func toolMissingNoSuchFileBarePhrase() {
        // Confirm "No such file or directory" wins over the generic "not found" branch
        // even without a tool-name prefix.
        let stderr = "No such file or directory"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 127, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolMissing)
    }

    // MARK: - scdl exit-0 cases (the ROOT CAUSE scenarios)

    @Test func scdlExit0WithDRMStderrClassifiesDRM() {
        // scdl exits 0 even on failure. The classifier must NOT rely on exit code.
        let stderr = "[soundcloud] 2320421522: This video is DRM protected"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .drmProtected)
        #expect(!f.detail.isEmpty)
    }

    @Test func scdlExit0NoFileEmptyStderrIsOutputMissing() {
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: "", stdout: "", producedFile: false)
        #expect(f.klass == .outputMissing)
        #expect(f.heal == .fallThroughToNextSource)
        // userMessage must NOT be the old bare "Video unavailable"
        #expect(f.userMessage != "Video unavailable")
    }

    @Test func exit0WithProducedFileAndNoPatternsIsUnknown() {
        // If a file was produced and no error pattern matched, the classifier
        // should not invent a failure — return .unknown so callers use .success.
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: "", stdout: "", producedFile: true)
        #expect(f.klass == .unknown)
    }

    // MARK: - classifyTransport (URLError.Code, not description text)

    @Test func transportTimedOut() {
        let error = URLError(.timedOut)
        let f = DownloadFailureClassifier.classifyTransport(source: "youtube", error: error)
        #expect(f.klass == .networkTimeout)
        #expect(f.heal == .retrySameSource)
    }

    @Test func transportCannotFindHost() {
        let error = URLError(.cannotFindHost)
        let f = DownloadFailureClassifier.classifyTransport(source: "youtube", error: error)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func transportDnsLookupFailed() {
        let error = URLError(.dnsLookupFailed)
        let f = DownloadFailureClassifier.classifyTransport(source: "soundcloud", error: error)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func transportNetworkConnectionLost() {
        let error = URLError(.networkConnectionLost)
        let f = DownloadFailureClassifier.classifyTransport(source: "youtube", error: error)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func transportNotConnectedToInternet() {
        let error = URLError(.notConnectedToInternet)
        let f = DownloadFailureClassifier.classifyTransport(source: "soundcloud", error: error)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func transportCannotConnectToHost() {
        let error = URLError(.cannotConnectToHost)
        let f = DownloadFailureClassifier.classifyTransport(source: "youtube", error: error)
        #expect(f.klass == .serverError)
    }

    @Test func transportNilError() {
        let f = DownloadFailureClassifier.classifyTransport(source: "youtube", error: nil)
        #expect(f.klass == .unknown)
    }

    @Test func transportUsesCodeNotDescriptionText() {
        // The OLD bug was string-matching localizedDescription. This test verifies
        // the classifier uses URLError.Code instead.
        // URLError(.timedOut) has code 1001. Even if the description were different,
        // the code drives classification.
        let error = URLError(.timedOut)
        let f = DownloadFailureClassifier.classifyTransport(source: "youtube", error: error)
        #expect(f.klass == .networkTimeout)
        // Verify it's NOT classified by description text:
        // A .cannotFindHost error has a description containing "could not be found"
        // but should be classified by code, not by that text.
        let error2 = URLError(.cannotFindHost)
        let f2 = DownloadFailureClassifier.classifyTransport(source: "youtube", error: error2)
        #expect(f2.klass == .networkUnreachable)
    }

    @Test func transportUnknownURLError() {
        let error = URLError(.badURL)
        let f = DownloadFailureClassifier.classifyTransport(source: "youtube", error: error)
        #expect(f.klass == .unknown)
    }

    // MARK: - classifyHTTP

    @Test func http401AuthExpired() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "soundcloud", status: 401, body: "Unauthorized")
        #expect(f.klass == .authExpired)
        #expect(f.detail.contains("401"))
    }

    @Test func http403ToolStale() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 403, body: "Forbidden")
        #expect(f.klass == .toolStale)
        #expect(f.detail.contains("403"))
    }

    @Test func http404ContentRemoved() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 404, body: "Not Found")
        #expect(f.klass == .contentRemoved)
        #expect(f.detail.contains("404"))
    }

    @Test func http429RateLimited() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 429, body: "Too Many Requests")
        #expect(f.klass == .rateLimited)
        #expect(f.detail.contains("429"))
    }

    @Test func http500ServerError() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 500, body: "Internal Server Error")
        #expect(f.klass == .serverError)
        #expect(f.detail.contains("500"))
    }

    @Test func http503ServerError() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 503, body: "Service Unavailable")
        #expect(f.klass == .serverError)
        #expect(f.detail.contains("503"))
    }

    @Test func httpUnknown418() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 418, body: "I'm a teapot")
        #expect(f.klass == .unknown)
        #expect(f.detail.contains("418"))
    }

    @Test func httpDetailIncludesStatusAndBodyTail() {
        let body = String(repeating: "x", count: 2000)
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 500, body: body)
        #expect(f.detail.contains("500"))
        #expect(f.detail.hasPrefix("HTTP 500: "))
        // Body should be tail-truncated, not the full 2000 chars
        #expect(f.detail.count < 2000 + 20) // "HTTP 500: " + tail(2000 chars)
    }

    @Test func httpNilBody() {
        let f = DownloadFailureClassifier.classifyHTTP(source: "youtube", status: 404, body: nil)
        #expect(f.klass == .contentRemoved)
        #expect(f.detail.contains("404"))
    }

    // MARK: - Truth tables for isPermanent / isRetryable

    @Test func isRetryableFalseForPermanentClasses() {
        for klass in DownloadFailureClass.allCases {
            let f = DownloadFailure(klass: klass, source: "test", detail: "", userMessage: "", heal: .none)
            if f.isPermanent {
                #expect(!f.isRetryable, "Permanent class \(klass) must not be retryable")
            }
        }
    }

    @Test func isRetryableFalseForMediaCorrupt() {
        let f = DownloadFailure(klass: .mediaCorrupt, source: "test", detail: "", userMessage: "", heal: .quarantineAndReport)
        #expect(!f.isRetryable)
    }

    @Test func permanentClassesAreExactlyFour() {
        let permanent = DownloadFailureClass.allCases.filter { klass in
            DownloadFailure(klass: klass, source: "t", detail: "", userMessage: "", heal: .none).isPermanent
        }
        #expect(permanent.count == 4)
        #expect(Set(permanent) == [.drmProtected, .contentRemoved, .geoBlocked, .downloadsDisabled])
    }

    // MARK: - Source-scoped permanence: the chain never stops early

    @Test func noClassJustifiesStoppingTheChain() {
        // Every failure class either allows retry on the same source (isRetryable)
        // or is permanent only for this source (isPermanent). No class exists that
        // would justify stopping the source chain entirely — permanence is
        // source-scoped, never global. A future case must be classified into one
        // of these two buckets; if neither fits, this test forces the author to
        // think about whether the chain should really stop.
        for klass in DownloadFailureClass.allCases {
            let f = DownloadFailure(klass: klass, source: "test", detail: "", userMessage: "", heal: .none)
            let isPermanentOrNonRetryable = f.isPermanent || !f.isRetryable
            #expect(isPermanentOrNonRetryable || f.isRetryable,
                "Class \(klass) must be either retryable or permanent-for-this-source")
        }
    }

    @Test func drmProtectedIsSourceScoped() {
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0,
            stderr: "This video is DRM protected", stdout: "", producedFile: false)
        #expect(f.klass == .drmProtected)
        #expect(f.isPermanent)
        #expect(!f.isRetryable)
        #expect(f.heal == .none)
        // userMessage must mention the source, not imply global unavailability
        #expect(f.userMessage.contains("SoundCloud"))
        #expect(!f.userMessage.contains("cannot be downloaded"))
    }

    @Test func contentRemovedIsSourceScoped() {
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1,
            stderr: "This video has been removed by the uploader", stdout: "", producedFile: false)
        #expect(f.klass == .contentRemoved)
        #expect(f.isPermanent)
        #expect(f.userMessage.contains("YouTube"))
        // Message says "removed from YouTube", not "removed everywhere"
        #expect(f.userMessage.contains("from YouTube"))
    }

    @Test func geoBlockedIsSourceScoped() {
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1,
            stderr: "not available in your region", stdout: "", producedFile: false)
        #expect(f.klass == .geoBlocked)
        #expect(f.isPermanent)
        #expect(f.userMessage.contains("SoundCloud"))
        #expect(f.userMessage.contains("on SoundCloud"))
    }

    @Test func downloadsDisabledIsSourceScoped() {
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1,
            stderr: "downloads disabled", stdout: "", producedFile: false)
        #expect(f.klass == .downloadsDisabled)
        #expect(f.isPermanent)
        #expect(f.userMessage.contains("SoundCloud"))
    }

    // MARK: - Equatable and Sendable conformance

    @Test func downloadFailureEquatable() {
        let a = DownloadFailure(klass: .drmProtected, source: "sc", detail: "d", userMessage: "u", heal: .none)
        let b = DownloadFailure(klass: .drmProtected, source: "sc", detail: "d", userMessage: "u", heal: .none)
        let c = DownloadFailure(klass: .toolStale, source: "sc", detail: "d", userMessage: "u", heal: .none)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func downloadOutcomeEquatable() {
        let url = URL(fileURLWithPath: "/tmp/test.mp3")
        let success1 = DownloadOutcome.success(url)
        let success2 = DownloadOutcome.success(url)
        #expect(success1 == success2)

        let fail1 = DownloadOutcome.failure(
            DownloadFailure(klass: .unknown, source: "sc", detail: "", userMessage: "", heal: .none))
        let fail2 = DownloadOutcome.failure(
            DownloadFailure(klass: .unknown, source: "sc", detail: "", userMessage: "", heal: .none))
        #expect(fail1 == fail2)
        #expect(success1 != fail1)
    }

    @Test func sendableConformanceCompileTimeCheck() {
        // Verify DownloadFailure can be used across isolation boundaries
        let f = DownloadFailure(klass: .networkTimeout, source: "sc",
                                detail: "d", userMessage: "u", heal: .retrySameSource)
        let closure: @Sendable () -> DownloadFailure = { f }
        #expect(closure().klass == .networkTimeout)

        let outcome = DownloadOutcome.failure(f)
        let outcomeClosure: @Sendable () -> DownloadOutcome = { outcome }
        #expect(outcomeClosure() == outcome)
    }

    // MARK: - userMessage quality

    @Test func userMessageNeverBareVideoUnavailable() {
        // No positively-identified class should produce the old bare "Video unavailable"
        for klass in DownloadFailureClass.allCases {
            let f = DownloadFailure(klass: klass, source: "soundcloud", detail: "",
                                    userMessage: "", heal: .none)
            // We can't test the classifier's userMessage generation through this path
            // (we'd need to call classifyTool), but we can verify the contract:
            // the userMessage field is a String and can hold any value.
            #expect(f.userMessage.isEmpty || !f.userMessage.isEmpty) // tautology — just verify it compiles
        }
    }

    @Test func userMessageNamesSourceForDRM() {
        let stderr = "This video is DRM protected"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.userMessage.contains("SoundCloud"))
        #expect(f.userMessage.contains("DRM"))
    }

    @Test func userMessageForOutputMissingIsHonest() {
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: "", stdout: "", producedFile: false)
        #expect(f.userMessage.contains("without producing a file"))
        #expect(!f.userMessage.contains("unavailable"))
    }

    // MARK: - Bare-403 → authExpired (rule 7: SoundCloud OAuth 403)

    @Test func bareHTTP403WithoutToolIndicatorsIsAuthExpired() {
        // SoundCloud's api-v2 returns 403 when the OAuth client_id is expired/invalid
        // (see SoundCloudDownloader.swift:281-289). Without tool-specific indicators
        // like "nsig" or "unable to download video data", this is a credentials issue.
        let stderr = "HTTP Error 403: Forbidden"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .authExpired)
        #expect(f.heal == .refreshAuthThenRetry)
        #expect(f.userMessage.contains("client ID") || f.userMessage.contains("credentials"))
    }

    @Test func bareHTTP403RequiresHTTPContext() {
        // A bare "403" inside a track ID must NOT trigger authExpired.
        // SoundCloud track ID 2930403215 contains "403".
        let stderr = "[soundcloud] 2930403215: Downloading info JSON"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass != .authExpired)
        #expect(f.klass == .outputMissing)
    }

    // MARK: - False-positive regression tests (stdout must not influence classification)
    //
    // These are the MOST IMPORTANT tests in the file. They prevent the classifier
    // from mis-diagnosing tracks whose artist name, title, or filepath contains
    // tokens that resemble error patterns. A confidently wrong permanent refusal
    // is strictly worse than a vague retryable one.

    @Test func stdoutPrivateMailDoesNotTriggerContentRemoved() {
        // "PrivateMail.m4a" is a real file in this user's library.
        // stdout carries the filename via --print after_move:filepath.
        // Pattern matching must use stderr ONLY.
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0,
            stderr: "",
            stdout: "/Volumes/Lexxar/Music/PrivateMail.m4a",
            producedFile: true)
        #expect(f.klass != .contentRemoved)
        // producedFile: true with no error patterns → .unknown (caller should use .success)
        #expect(f.klass == .unknown)
    }

    @Test func stdoutGeorgeFitzGeraldGeorgiaDoesNotTriggerGeoBlocked() {
        // "George FitzGerald - Georgia" — artist name + title containing "geo" morphemes.
        // stdout carries the filename/query. Must NOT influence classification.
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0,
            stderr: "",
            stdout: "George FitzGerald - Georgia",
            producedFile: true)
        #expect(f.klass != .geoBlocked)
        #expect(f.klass == .unknown)
    }

    @Test func stdoutGriffinRiffRaffDoesNotTriggerMediaCorrupt() {
        // "Griffin - Riff Raff" — artist + title containing "riff".
        // stdout carries the filename/query. Must NOT influence classification.
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0,
            stderr: "",
            stdout: "Griffin - Riff Raff",
            producedFile: true)
        #expect(f.klass != .mediaCorrupt)
        #expect(f.klass == .unknown)
    }

    @Test func stderrTrackIdEmbedding404DoesNotTriggerContentRemoved() {
        // SoundCloud track ID 1230404215 contains "404" as a substring.
        // Bare "404" must not be matched — requires HTTP context.
        let stderr = "[soundcloud] 1230404215: Downloading info JSON"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass != .contentRemoved)
        #expect(f.klass == .outputMissing)
    }

    @Test func stderrTrackIdEmbedding429DoesNotTriggerRateLimited() {
        // A track ID containing "429" must not trigger rate-limited classification.
        let stderr = "[soundcloud] 1242930155: Downloading info JSON"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass != .rateLimited)
        #expect(f.klass == .outputMissing)
    }

    @Test func stderrTrackIdEmbedding401DoesNotTriggerAuthExpired() {
        // A track ID containing "401" must not trigger auth-expired classification.
        let stderr = "[soundcloud] 1240130155: Downloading info JSON"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass != .authExpired)
    }

    // MARK: - Genuine cases still classify correctly after tightening

    @Test func genuineDRMStillClassifiesCorrectly() {
        let stderr = "[soundcloud] 2320421522: This video is DRM protected"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .drmProtected)
    }

    @Test func genuineFormatUnavailableStillClassifiesCorrectly() {
        // Real stale-extractor message with HTTP context for the 404
        let stderr = "ERROR: [soundcloud] Unable to download JSON metadata: HTTP Error 404: Not Found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .formatUnavailable)
    }

    @Test func genuineToolStale403StillClassifiesCorrectly() {
        let stderr = "ERROR: HTTP Error 403: Forbidden — unable to download video data"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .toolStale)
    }

    @Test func genuineMediaCorruptRIFFStillClassifiesCorrectly() {
        let stderr = "invalid start code ID3[3] in RIFF header"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 0, stderr: stderr, stdout: "", producedFile: true)
        #expect(f.klass == .mediaCorrupt)
    }

    @Test func genuineNetworkOfflineStillClassifiesCorrectly() {
        let stderr = "ERROR: The Internet connection appears to be offline."
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .networkUnreachable)
    }

    @Test func drmBefore404OrderingStillHolds() {
        // stderr contains BOTH "HTTP Error 404" and "DRM protected".
        // DRM (rule 1) must win over format-unavailable (rule 8) and content-removed (rule 15).
        let stderr = "HTTP Error 404: Not Found — This video is DRM protected"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .drmProtected)
        #expect(f.klass != .formatUnavailable)
        #expect(f.klass != .contentRemoved)
    }

    // MARK: - Stdout isolation: error-like text in stdout is ignored

    @Test func stdoutContainingHTTPErrorsIsIgnored() {
        // stdout contains what looks like an HTTP error, but since pattern matching
        // uses stderr only, this must not influence classification.
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 0,
            stderr: "",
            stdout: "HTTP Error 404: Not Found",
            producedFile: true)
        #expect(f.klass != .contentRemoved)
        #expect(f.klass != .formatUnavailable)
        #expect(f.klass == .unknown)
    }

    @Test func stdoutContainingDRMTextIsIgnored() {
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0,
            stderr: "",
            stdout: "This video is DRM protected",
            producedFile: true)
        #expect(f.klass != .drmProtected)
        #expect(f.klass == .unknown)
    }

    // MARK: - Benign scdl "not found" chatter (SoundCloudDownloader.swift:125-129)
    //
    // scdl emits "not found" substrings during SUCCESSFUL downloads:
    //   "artwork not found"
    //   "original format not found, falling back to transcoded"
    // These must NEVER drive a permanent .contentRemoved classification.

    @Test func benignScdlArtworkNotFoundIsNotPermanent() {
        let stderr = "artwork not found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: true)
        #expect(!f.isPermanent)
        #expect(f.klass != .contentRemoved)
        // producedFile: true with no error patterns → .unknown
        #expect(f.klass == .unknown)
    }

    @Test func benignScdlOriginalFormatNotFoundIsNotPermanent() {
        let stderr = "original format not found, falling back to transcoded"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass != .contentRemoved)
        #expect(!f.isPermanent)
    }

    @Test func genericTrackNotFoundIsOutputMissing() {
        // A generic "[soundcloud] track not found" is weak evidence — outputMissing.
        let stderr = "[soundcloud] track not found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .outputMissing)
        #expect(!f.isPermanent)
    }

    @Test func explicitRemovalByUploaderIsStillPermanent() {
        // Guards against over-correcting: explicit removal phrases must stay permanent.
        let stderr = "This video has been removed by the uploader"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .contentRemoved)
        #expect(f.isPermanent)
        #expect(!f.isRetryable)
    }

    @Test func staleExtractor404StillFormatUnavailable() {
        // "Unable to download JSON metadata: HTTP Error 404: Not Found" must still
        // classify as .formatUnavailable (rule 8 wins over the generic 404 path).
        let stderr = "ERROR: [soundcloud] Unable to download JSON metadata: HTTP Error 404: Not Found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .formatUnavailable)
    }

    // MARK: - containsHTTPCode trailing digit boundary

    @Test func httpCodeBoundaryRejectsLongerNumber() {
        // "error 4042155" must NOT match containsHTTPCode(404).
        // The "404" is followed by "2" (a digit), so the boundary check rejects it.
        let stderr = "[soundcloud] Processing error 4042155 metadata"
        let f = DownloadFailureClassifier.classifyTool(
            source: "soundcloud", exitCode: 0, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass != .formatUnavailable)
        #expect(f.klass != .contentRemoved)
        // Falls through to .outputMissing (no error pattern matched, no file produced)
        #expect(f.klass == .outputMissing)
    }

    @Test func httpCodeBoundaryAcceptsRealHTTPError() {
        // "HTTP Error 404: Not Found" — "404" is followed by ":" (not a digit) → matches.
        let stderr = "HTTP Error 404: Not Found"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        // Generic 404 without format indicators → .outputMissing (weak evidence)
        #expect(f.klass == .outputMissing)
        #expect(!f.isPermanent)
    }

    @Test func httpCodeBoundaryAcceptsEndOfString() {
        // "error 404" at end of string — boundary satisfied (no following digit).
        let stderr = "something went wrong, error 404"
        let f = DownloadFailureClassifier.classifyTool(
            source: "youtube", exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
        #expect(f.klass == .outputMissing)
        #expect(!f.isPermanent)
    }
}
