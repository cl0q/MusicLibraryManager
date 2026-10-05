import Foundation
import Testing
@testable import MLM

/// Stored download-failure reasons → plain words (W2-B, UC-TABLE-13, UC-JOB-11, §11.1 #7):
/// every category the pipeline can persist, for every source, plus the drive and the legacy
/// catch-all. Never a raw error string, never `Video unavailable` for a non-YouTube source.
@Suite("DownloadFailureReasonTextTests")
struct DownloadFailureReasonTextTests {
    private static let sources = ["soundcloud", "youtube", "dab", "squid"]

    /// Every class the shared classifier knows, as each source would persist it.
    private static func classifierMessages(source: String) -> [(DownloadFailureClass, String)] {
        let stderrSamples = [
            "ERROR: This track is DRM protected",
            "ERROR: not available in your country",
            "ERROR: This video is private",
            "ERROR: downloads disabled",
            "ERROR: unable to extract client id",
            "ERROR: HTTP Error 403: Forbidden unable to download video data",
            "ERROR: HTTP Error 403: Forbidden",
            "ERROR: HTTP Error 404: Not Found unable to download JSON metadata",
            "ERROR: HTTP Error 429: Too Many Requests",
            "ERROR: HTTP Error 401: Unauthorized",
            "ERROR: Read timed out",
            "ERROR: The Internet connection appears to be offline",
            "ERROR: 503 Service Unavailable",
            "Invalid data found when processing input",
            "ERROR: No video results",
            "zsh: command not found: yt-dlp",
            "ERROR: track not found",
            "",
        ]
        let tool = stderrSamples.map { stderr -> (DownloadFailureClass, String) in
            let failure = DownloadFailureClassifier.classifyTool(
                source: source, exitCode: 1, stderr: stderr, stdout: "", producedFile: false)
            return (failure.klass, failure.userMessage)
        }
        let http = [401, 403, 404, 429, 500, 418].map { status -> (DownloadFailureClass, String) in
            let failure = DownloadFailureClassifier.classifyHTTP(source: source, status: status, body: "<html>")
            return (failure.klass, failure.userMessage)
        }
        let transport = [URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.cannotConnectToHost),
                         URLError(.badURL)].map { error -> (DownloadFailureClass, String) in
            let failure = DownloadFailureClassifier.classifyTransport(source: source, error: error)
            return (failure.klass, failure.userMessage)
        }
        return tool + http + transport
    }

    /// The expected category of each classifier class.
    private static func expectedCategory(_ klass: DownloadFailureClass) -> DownloadFailureReasonText.Category {
        switch klass {
        case .drmProtected: .drmProtected
        case .contentRemoved: .unavailable
        case .geoBlocked: .regionBlocked
        case .downloadsDisabled: .downloadsDisabled
        case .toolStale: .toolOutdated
        case .toolMissing: .toolMissing(nil)
        case .rateLimited: .rateLimited
        case .networkTimeout: .timedOut
        case .networkUnreachable: .offline
        case .serverError: .serverError
        case .authExpired: .signInExpired
        case .formatUnavailable: .formatUnavailable
        case .mediaCorrupt: .damagedFile
        case .outputMissing: .noMatch
        case .unknown: .unknown
        }
    }

    @Test(arguments: sources)
    func everyClassifierCategoryMapsToPlainWords(source: String) {
        for (klass, message) in Self.classifierMessages(source: source) {
            let (category, _) = DownloadFailureReasonText.classify(message)
            let expected = Self.expectedCategory(klass)
            switch (klass, category) {
            case (.outputMissing, .noFile), (.outputMissing, .noMatch):
                break  // "did not find the track" vs "finished without producing a file"
            default:
                #expect(category == expected, "\(source) \(klass): “\(message)” → \(category)")
            }
            let plain = DownloadFailureReasonText.plain(message, sourceHint: "SoundCloud")
            Self.expectPlain(plain, from: message)
        }
    }

    @Test func wordsNameTheSourceTheTextNames() {
        #expect(DownloadFailureReasonText.plain("DRM-protected on SoundCloud — this source cannot provide the track")
            == "DRM-protected (SoundCloud)")
        #expect(DownloadFailureReasonText.plain("Timed out contacting DAB") == "DAB didn’t answer")
        #expect(DownloadFailureReasonText.plain("Content has been removed from YouTube") == "Private or no longer available (YouTube)")
        #expect(DownloadFailureReasonText.plain("Rate limited by Squid — retry after a short wait") == "Too many requests (Squid)")
        #expect(DownloadFailureReasonText.plain("SoundCloud did not find the track — trying next source") == "No match found (SoundCloud)")
        #expect(DownloadFailureReasonText.plain("YouTube rejected the request (HTTP 403) — the downloader tool is probably outdated")
            == "Download tool out of date (YouTube)")
        #expect(DownloadFailureReasonText.plain("Network unreachable — check your connection") == "No internet connection")
        #expect(DownloadFailureReasonText.plain("Downloaded media is corrupt — quarantined for inspection") == "Downloaded file was damaged")
    }

    /// The design's example: `Sign-in expired (SoundCloud) · 2 attempts left` (G-TRK-FAILED).
    @Test func signInExpiredNamesTheTracksSource() {
        let failure = TrackDownloadFailure(reason: "Authentication expired — re-authorize and retry", date: .now, attempts: 1)
        #expect(DownloadFailureReasonText.detail(failure.reason, failure: failure, sourceHint: "SoundCloud")
            == "Sign-in expired (SoundCloud) · 2 attempts left")
        #expect(DownloadFailureReasonText.plain("SoundCloud returned HTTP 403 — the client ID or credentials may be expired",
                                                sourceHint: "YouTube") == "Sign-in expired (SoundCloud)")
        #expect(DownloadFailureReasonText.plain("Authentication expired — re-authorize and retry") == "Sign-in expired")
    }

    /// The old batch catch-all said `Video unavailable` for everything; only a YouTube track
    /// keeps those words.
    @Test func videoUnavailableOnlyForYouTube() {
        #expect(DownloadFailureReasonText.plain("Video unavailable", sourceHint: "YouTube") == "Video unavailable (YouTube)")
        for hint in ["SoundCloud", "DAB", "Qobuz", "Local import", nil] as [String?] {
            let plain = DownloadFailureReasonText.plain("Video unavailable", sourceHint: hint)
            #expect(plain == "No match found on any source", "\(hint ?? "no source")")
        }
        #expect(DownloadFailureReasonText.plain("Video unavailable in your region", sourceHint: "SoundCloud")
            == "Not available in your region")
        #expect(DownloadFailureReasonText.plain("Private video", sourceHint: "SoundCloud") == "Private or no longer available")
        #expect(DownloadFailureReasonText.plain("Network error") == "No internet connection")
    }

    @Test func driveNotConnectedIsNeverAnUnavailableVideo() {
        let away = DownloadOrchestrator.stagingFailureReason(
            libraryRoot: URL(fileURLWithPath: "/Volumes/Lexxar/Music"), isMounted: { _ in false })
        #expect(away == "“Lexxar” not connected")
        #expect(DownloadFailureReasonText.plain(away, sourceHint: "SoundCloud") == "“Lexxar” not connected")
        let unwritable = DownloadOrchestrator.stagingFailureReason(
            libraryRoot: URL(fileURLWithPath: "/Volumes/Lexxar/Music"), isMounted: { _ in true })
        #expect(unwritable == "Library folder not reachable")
        #expect(DownloadFailureReasonText.plain(unwritable) == "Library folder not reachable")
        let bootDisk = DownloadOrchestrator.stagingFailureReason(
            libraryRoot: URL(fileURLWithPath: "/Users/someone/Music"), isMounted: { _ in false })
        #expect(bootDisk == "Library folder not reachable")
    }

    @Test func pipelineFixedTextsAndToolsMapToPlainWords() {
        let cases: [(String, String)] = [
            ("yt-dlp not installed — open Settings", "yt-dlp not found"),
            ("scdl not installed — install via `pip install scdl`", "scdl not found"),
            ("Downloader tool is not installed", "Download tool not found"),
            ("No SoundCloud URL — cannot download (pinned to SoundCloud)", "No SoundCloud link"),
            ("DAB requires a captcha cookie — try another source", "Blocked by a captcha check (DAB)"),
            ("Squid requires a captcha cookie — set MLM_SQUID_CAPTCHA from browser dev-tools", "Blocked by a captcha check (Squid)"),
            ("Another download batch is already running.", "Another download was running"),
            ("Downloaded file could not be saved to library", "Couldn’t save the file to the library"),
            ("Download cancelled", "Cancelled"),
            ("Download failed", "Reason unknown"),
            ("Download failed — reason unknown", "Reason unknown"),
            ("Downloader finished without producing a file", "No file received"),
            ("", "Reason unknown"),
            // A raw error string never reaches the UI.
            ("Error Domain=NSCocoaErrorDomain Code=513 \"You don’t have permission.\"", "Reason unknown"),
        ]
        for (stored, expected) in cases {
            #expect(DownloadFailureReasonText.plain(stored, sourceHint: "SoundCloud") == expected, "“\(stored)”")
        }
    }

    /// Words already plain stay the same — a producer may store them directly later.
    @Test func plainWordsAreStable() {
        let samples = [
            "Sign-in expired (SoundCloud)", "yt-dlp not found", "Download tool not found", "Download tool out of date (YouTube)",
            "DRM-protected (SoundCloud)", "Not available in your region", "Private or no longer available (DAB)",
            "Downloads turned off (SoundCloud)", "Too many requests (Squid)", "SoundCloud didn’t answer",
            "The source didn’t answer", "No internet connection", "Server error (DAB)", "Format not available (SoundCloud)",
            "Downloaded file was damaged", "No match found (SoundCloud)", "No match found on any source",
            "No file received", "No SoundCloud link", "Blocked by a captcha check (DAB)",
            "Couldn’t save the file to the library", "“Lexxar” not connected", "Library folder not reachable",
            "Another download was running", "Cancelled", "Reason unknown", "Video unavailable (YouTube)",
        ]
        for text in samples {
            #expect(DownloadFailureReasonText.plain(text) == text, "“\(text)”")
        }
    }

    @Test func failedRowsCarryTheDetailLine() throws {
        var track = Track(artist: "A", album: "", title: "T", format: "soundcloud", originalPath: "https://soundcloud.com/a/t")
        track.id = 7
        try track.setDownloadFailureRecord(TrackDownloadFailure(reason: "Video unavailable", date: .now, attempts: 2))
        let row = try #require(TrackRowBuilder.build([track]).first)
        #expect(row.failureDetail == "No match found on any source · 1 attempt left")
    }

    // MARK: -

    private static func expectPlain(_ plain: String, from stored: String) {
        #expect(!plain.isEmpty)
        #expect(plain != "Video unavailable", "“\(stored)”")
        #expect(!plain.contains("HTTP") && !plain.contains("—") && !plain.contains("Error"), "“\(stored)” → “\(plain)”")
        #expect(plain.rangeOfCharacter(from: .decimalDigits) == nil, "“\(stored)” → “\(plain)”: no codes")
        #expect(!plain.hasSuffix("."), "“\(plain)” is a fragment (UC-COPY-04)")
        #expect(!plain.contains("\"") && !plain.contains("'"), "typographic quotes only (UC-COPY-06)")
    }
}
