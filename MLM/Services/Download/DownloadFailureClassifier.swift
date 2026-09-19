import Foundation

// MARK: - DownloadFailureClass

/// Coarse-grained classification of a download failure.
///
/// The classification drives the heal action and the user-facing message.
/// Rules are evaluated in a fixed order (see `DownloadFailureClassifier.classifyTool`)
/// so that, e.g., DRM protection is never shadowed by a generic 404.
public enum DownloadFailureClass: String, Equatable, Sendable, CaseIterable {
    case drmProtected
    case contentRemoved
    case geoBlocked
    case downloadsDisabled
    case toolStale
    case toolMissing
    case rateLimited
    case networkTimeout
    case networkUnreachable
    case serverError
    case authExpired
    case formatUnavailable
    case mediaCorrupt
    case outputMissing
    case unknown
}

// MARK: - HealAction

/// What the orchestrator should do next after a classified failure.
public enum HealAction: String, Equatable, Sendable {
    /// No recovery possible (permanent content issue).
    case none
    /// Retry the same source as-is (transient network/server issue).
    case retrySameSource
    /// Retry the same source with a different format/codec.
    case retryOtherFormat
    /// Update the downloader tool (yt-dlp / scdl) then retry.
    case updateToolThenRetry
    /// Install the missing downloader tool.
    case installTool
    /// Refresh OAuth / credentials then retry.
    case refreshAuthThenRetry
    /// Quarantine the output for manual inspection (corrupt media).
    case quarantineAndReport
    /// Give up on this source and try the next one.
    case fallThroughToNextSource
}

// MARK: - DownloadFailure

/// A classified download failure carrying everything the orchestrator and UI need:
/// the class, the source, raw detail for logs, a user-safe message, and the heal action.
public struct DownloadFailure: Equatable, Sendable {
    public let klass: DownloadFailureClass
    /// Provider identifier: "soundcloud" | "youtube" | "dab" | "squid".
    public let source: String
    /// Raw evidence for logs (stderr tail). Never shown in the UI.
    public let detail: String
    /// Honest, specific, safe to display to the user.
    public let userMessage: String
    public let heal: HealAction

    public init(klass: DownloadFailureClass, source: String, detail: String,
                userMessage: String, heal: HealAction) {
        self.klass = klass
        self.source = source
        self.detail = detail
        self.userMessage = userMessage
        self.heal = heal
    }

    /// Retrying THIS SAME SOURCE will not help — the failure is structural for
    /// this source (DRM-protected, content removed, geo-blocked, or downloads
    /// disabled on this provider). This is a *source-scoped* verdict: it carries
    /// no information about whether the track is obtainable from other sources.
    /// The orchestrator uses `isPermanent` only to skip a pointless same-source
    /// retry, then continues down the source chain.
    ///
    /// Deliberate user decision: DRM/geo/removal/disable on one source says
    /// nothing about other sources. SoundCloud gating a track behind DRM does
    /// not mean YouTube cannot provide it. Permanence is source-scoped, never
    /// global. Do not re-introduce a short-circuit that stops the chain.
    public var isPermanent: Bool {
        switch klass {
        case .drmProtected, .contentRemoved, .geoBlocked, .downloadsDisabled:
            return true
        default:
            return false
        }
    }

    /// False for permanent classes and mediaCorrupt (quarantined, not retried).
    /// True for all transient/healable classes.
    public var isRetryable: Bool {
        if isPermanent { return false }
        if klass == .mediaCorrupt { return false }
        return true
    }
}

// MARK: - DownloadOutcome

/// Result of a single download attempt: either a file URL or a classified failure.
public enum DownloadOutcome: Equatable, Sendable {
    case success(URL)
    case failure(DownloadFailure)
}

// MARK: - DownloadFailureClassifier

/// Shared classifier that every downloader feeds its stderr into.
///
/// The classifier evaluates patterns in a fixed order — first match wins.
/// Order matters: DRM protection must be checked before any generic 404 rule,
/// and DNS failures ("hostname could not be found") must be checked before
/// generic "not found" so they are not misread as missing content.
///
/// IMPORTANT: Pattern matching uses stderr ONLY. stdout is never scanned for
/// classification patterns because yt-dlp is invoked with `--print after_move:filepath`
/// so stdout contains the final filename (Artist - Title.m4a) and search invocations
/// echo the query. Matching stdout would cause false positives on common English
/// morphemes in artist names and track titles (e.g. "PrivateMail", "Georgia", "Griffin").
/// stdout is used only for the `detail` log field when stderr is empty.
public enum DownloadFailureClassifier {

    /// Returns the last `maxChars` characters of `s`, prefixing "…" when truncated.
    /// Returns the input unchanged when it is already shorter.
    /// Safe for empty strings and `maxChars <= 0` (returns "").
    ///
    /// External tools (scdl, yt-dlp) emit banners first and the error last,
    /// so keeping the END of the output is critical for diagnosis.
    public static func tail(_ s: String, _ maxChars: Int = 800) -> String {
        guard maxChars > 0 else { return "" }
        guard s.count > maxChars else { return s }
        return "…" + String(s.suffix(maxChars))
    }

    /// Classify an external-tool result.
    ///
    /// `producedFile` indicates whether a usable output file exists on disk.
    /// CRITICAL: `exitCode == 0` does NOT imply success — scdl exits 0 on failure.
    /// The classifier relies on stderr content and the `producedFile` flag,
    /// not the exit code alone.
    ///
    /// Pattern matching scans stderr ONLY — stdout carries filenames and search
    /// queries (artist/title text) and must never influence classification.
    public static func classifyTool(source: String, exitCode: Int32, stderr: String,
                                    stdout: String, producedFile: Bool) -> DownloadFailure {
        // stderr only — stdout is user-controlled text (filenames, queries).
        let s = stderr.lowercased()
        let detail = tail(stderr.isEmpty ? stdout : stderr)

        // ── Ordered rules — first match wins ──────────────────────────

        // 1. DRM protected — MUST be checked before any generic 404 rule.
        //    A stale extractor reports "HTTP Error 404" for DRM tracks; the
        //    current extractor reports "DRM protected". Matching DRM first
        //    ensures the correct classification regardless of extractor version.
        //
        //    KNOWN LIMITATION (stale extractor): scdl's bundled yt-dlp==2026.3.17
        //    reports "Unable to download JSON metadata: HTTP Error 404: Not Found"
        //    for DRM-protected tracks and never says "DRM protected". In that case
        //    rule 1 cannot fire and the track classifies as .formatUnavailable
        //    (rule 8). This is unavoidable at the classifier level — the fix is
        //    updating the bundled extractor (separate work package).
        if s.contains("drm protected") || s.contains("drm-protected") {
            return make(.drmProtected, source: source, detail: detail, heal: .none)
        }

        // 2. Geo-blocked.
        //    Only compound/hyphenated forms and specific phrases — bare "geo" is
        //    a common morpheme in artist names (George, Georgia, Georg) and must
        //    NOT be matched.
        if s.contains("not available in your region") ||
           s.contains("not available in your country") ||
           s.contains("geographic restriction") ||
           s.contains("geo-blocked") ||
           s.contains("geoblock") ||
           s.contains("geo blocked") {
            return make(.geoBlocked, source: source, detail: detail, heal: .none)
        }

        // 3. Content removed (private, removed by uploader, login-gated).
        //    Only specific phrases — bare "private" is a common filename token
        //    (e.g. "PrivateMail.m4a") and must NOT be matched.
        if s.contains("private video") ||
           s.contains("this video is private") ||
           s.contains("private track") ||
           s.contains("video is private") ||
           s.contains("login required") ||
           s.contains("this video has been removed") ||
           s.contains("removed by the uploader") {
            return make(.contentRemoved, source: source, detail: detail, heal: .none)
        }

        // 4. Downloads disabled
        if s.contains("downloads disabled") ||
           s.contains("download disabled") ||
           s.contains("not downloadable") {
            return make(.downloadsDisabled, source: source, detail: detail, heal: .none)
        }

        // 5. Tool stale — client_id extraction failure (SoundCloud)
        if s.contains("unable to extract client id") ||
           s.contains("unable to extract client_id") ||
           s.contains("invalid client_id") {
            return make(.toolStale, source: source, detail: detail, heal: .updateToolThenRetry)
        }

        // 6. Tool stale — HTTP 403 with tool-specific indicators (YouTube).
        //    Requires HTTP context ("http error 403" etc.) to avoid matching
        //    403 inside a long numeric track ID.
        if containsHTTPCode(s, 403) &&
           (s.contains("unable to download video data") ||
            s.contains("unable to download audio data") ||
            s.contains("nsig") ||
            s.contains("throttled")) {
            return DownloadFailure(
                klass: .toolStale, source: source, detail: detail,
                userMessage: "\(displayName(for: source)) rejected the request (HTTP 403) — the downloader tool is probably outdated",
                heal: .updateToolThenRetry)
        }

        // 7. HTTP 403 WITHOUT tool-specific indicators → authExpired.
        //    SoundCloud's api-v2 returns 403 when the OAuth client_id is expired
        //    or invalid (see SoundCloudDownloader.swift:281-289). This is a
        //    credentials issue, not a tool-version issue.
        //    Requires HTTP context to avoid matching 403 inside track IDs.
        if containsHTTPCode(s, 403) {
            return DownloadFailure(
                klass: .authExpired, source: source, detail: detail,
                userMessage: "\(displayName(for: source)) returned HTTP 403 — the client ID or credentials may be expired",
                heal: .refreshAuthThenRetry)
        }

        // 8. Format unavailable — 404 with format-specific indicators.
        //    "Unable to download JSON metadata" is the stale extractor's message
        //    for a format probe failure; it is NOT evidence of content absence.
        //    Requires HTTP context for the 404 to avoid matching track IDs.
        if containsHTTPCode(s, 404) &&
           (s.contains("format info json") ||
            s.contains("hls_mp3") ||
            s.contains("http_mp3") ||
            s.contains("unable to download json metadata")) {
            return make(.formatUnavailable, source: source, detail: detail, heal: .retryOtherFormat)
        }

        // 9. Rate limited.
        //    Requires HTTP context for "429" to avoid matching inside track IDs
        //    (SoundCloud track IDs are 10 digits; 146 real log occurrences of
        //    bare "429" inside longer numbers were found).
        if containsHTTPCode(s, 429) ||
           s.contains("retry-after") ||
           s.contains("rate limit") ||
           s.contains("too many requests") {
            return make(.rateLimited, source: source, detail: detail, heal: .retrySameSource)
        }

        // 10. Auth expired (HTTP 401 or credential-related text).
        //     Requires HTTP context for "401" to avoid matching inside track IDs.
        if containsHTTPCode(s, 401) ||
           s.contains("unauthorized") ||
           s.contains("credentials") ||
           s.contains("oauth") ||
           s.contains("token expired") {
            return make(.authExpired, source: source, detail: detail, heal: .refreshAuthThenRetry)
        }

        // 11. Network timeout
        if s.contains("read timed out") ||
           s.contains("timed out") ||
           s.contains("timeout") {
            return make(.networkTimeout, source: source, detail: detail, heal: .retrySameSource)
        }

        // 12. Network unreachable — MUST be checked before generic "not found"
        //     so that DNS failures ("hostname could not be found") are not
        //     misread as missing content.
        //     "offline" tightened to "appears to be offline" / "is offline" to
        //     avoid matching filenames containing "offline".
        if s.contains("-1003") ||
           s.contains("hostname could not be found") ||
           s.contains("-1005") ||
           s.contains("network connection was lost") ||
           s.contains("appears to be offline") ||
           s.contains("is offline") ||
           s.contains("not connected to the internet") ||
           s.contains("could not connect") {
            return make(.networkUnreachable, source: source, detail: detail, heal: .retrySameSource)
        }

        // 13. Server error (5xx text)
        if s.contains("internal server error") ||
           s.contains("bad gateway") ||
           s.contains("service unavailable") ||
           s.contains("gateway timeout") {
            return make(.serverError, source: source, detail: detail, heal: .retrySameSource)
        }

        // 14. Media corrupt.
        //     Bare "riff" removed — it is a common morpheme in artist names
        //     (Griffin, Riff Raff) and track titles. Replaced with "in riff header"
        //     which matches the real ffmpeg text "invalid start code ID3[3] in RIFF header".
        if s.contains("invalid data found when processing input") ||
           s.contains("moov atom not found") ||
           s.contains("invalid start code") ||
           s.contains("in riff header") ||
           s.contains("output file does not contain any stream") {
            return make(.mediaCorrupt, source: source, detail: detail, heal: .quarantineAndReport)
        }

        // 15. Explicit content removal — permanent, non-retryable.
        //     Only unambiguous tool-generated statements about content absence.
        if s.contains("no video results") ||
           s.contains("there are no results") ||
           s.contains("did not match any") {
            return make(.contentRemoved, source: source, detail: detail, heal: .none)
        }

        // 16. Tool missing — MUST precede the generic "not found" branch (rule 17)
        //     because "command not found" contains "not found" as a substring.
        //     If the generic branch came first, it would swallow "command not found"
        //     and return .outputMissing instead of .toolMissing. A future editor
        //     must not reorder these without understanding that hazard.
        if s.contains("no such file or directory") ||
           s.contains("command not found") {
            return make(.toolMissing, source: source, detail: detail, heal: .installTool)
        }

        // 17. Generic "not found" / bare HTTP 404 — WEAK evidence of content absence.
        //
        //     Maps to .outputMissing (non-permanent, heal=.fallThroughToNextSource)
        //     so the orchestrator tries the next source. A generic "not found" is
        //     not strong enough evidence for a permanent refusal telling the user
        //     "Content has been removed."
        //
        //     NEUTRALIZED: scdl emits benign "not found" substrings during SUCCESSFUL
        //     downloads — "artwork not found", "original format not found, falling back
        //     to transcoded". Matching these as content-removed caused false permanent
        //     refusals. See SoundCloudDownloader.swift:125-129. These phrases are
        //     explicitly excluded below so they can never drive classification even if
        //     a future rule reorders.
        let isBenignScdlChatter = s.contains("artwork not found") ||
                                  s.contains("original format not found")
        if !isBenignScdlChatter &&
           (s.contains("not found") || containsHTTPCode(s, 404)) {
            // Weak evidence — fall through to next source, not a permanent refusal.
            // If producedFile is true the caller should use .success; we let it
            // fall through to .unknown at rule 19 instead.
            if !producedFile {
                return DownloadFailure(
                    klass: .outputMissing, source: source, detail: detail,
                    userMessage: "\(displayName(for: source)) did not find the track — trying next source",
                    heal: .fallThroughToNextSource)
            }
            // producedFile is true — fall through to .unknown at rule 19
        }

        // 18. No pattern matched and no file produced → outputMissing.
        //     This is the scdl-exit-0-with-no-file case. The detail carries
        //     the stderr tail (which may be empty), and the userMessage is
        //     honest ("Downloader finished without producing a file"), never
        //     the old bare "Video unavailable".
        if !producedFile {
            return make(.outputMissing, source: source, detail: detail, heal: .fallThroughToNextSource)
        }

        // 19. Nothing matched but a file WAS produced → caller should not
        //     have asked the classifier; return .unknown.
        return make(.unknown, source: source, detail: detail, heal: .fallThroughToNextSource)
    }

    /// Classify a transport-layer error by unwrapping `URLError` via its `.code`
    /// (not by string-matching `localizedDescription` — that was the old bug).
    public static func classifyTransport(source: String, error: Error?) -> DownloadFailure {
        guard let error else {
            return DownloadFailure(
                klass: .unknown, source: source,
                detail: "no error provided",
                userMessage: "Download failed — reason unknown",
                heal: .fallThroughToNextSource)
        }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return make(.networkTimeout, source: source,
                           detail: "URLError(\(urlError.code.rawValue)): timedOut",
                           heal: .retrySameSource)
            case .cannotFindHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet:
                return make(.networkUnreachable, source: source,
                           detail: "URLError(\(urlError.code.rawValue))",
                           heal: .retrySameSource)
            case .cannotConnectToHost:
                return make(.serverError, source: source,
                           detail: "URLError(\(urlError.code.rawValue)): cannotConnectToHost",
                           heal: .retrySameSource)
            default:
                return DownloadFailure(
                    klass: .unknown, source: source,
                    detail: "URLError(\(urlError.code.rawValue)): \(tail(error.localizedDescription))",
                    userMessage: "Download failed — reason unknown",
                    heal: .fallThroughToNextSource)
            }
        }

        return DownloadFailure(
            klass: .unknown, source: source,
            detail: tail(error.localizedDescription),
            userMessage: "Download failed — reason unknown",
            heal: .fallThroughToNextSource)
    }

    /// Classify an HTTP response by status code.
    /// Every returned failure carries `detail` containing the status and a body tail.
    public static func classifyHTTP(source: String, status: Int, body: String?) -> DownloadFailure {
        let bodyTail = tail(body ?? "")
        let detail = "HTTP \(status): \(bodyTail)"

        switch status {
        case 401:
            return DownloadFailure(
                klass: .authExpired, source: source, detail: detail,
                userMessage: "Authentication expired — re-authorize and retry",
                heal: .refreshAuthThenRetry)
        case 403:
            return DownloadFailure(
                klass: .toolStale, source: source, detail: detail,
                userMessage: "\(displayName(for: source)) rejected the request (HTTP 403) — the downloader tool is probably outdated",
                heal: .updateToolThenRetry)
        case 404:
            return DownloadFailure(
                klass: .contentRemoved, source: source, detail: detail,
                userMessage: "Content has been removed from \(displayName(for: source))",
                heal: .none)
        case 429:
            return DownloadFailure(
                klass: .rateLimited, source: source, detail: detail,
                userMessage: "Rate limited by \(displayName(for: source)) — retry after a short wait",
                heal: .retrySameSource)
        case 500...599:
            return DownloadFailure(
                klass: .serverError, source: source, detail: detail,
                userMessage: "\(displayName(for: source)) server error — retry later",
                heal: .retrySameSource)
        default:
            return DownloadFailure(
                klass: .unknown, source: source, detail: detail,
                userMessage: "Download failed — reason unknown",
                heal: .fallThroughToNextSource)
        }
    }

    // MARK: - Private helpers

    /// Check whether stderr contains an HTTP status code in a contextual pairing
    /// that confirms it is an HTTP status, not a substring of a longer number
    /// (e.g. SoundCloud track IDs are 10 digits and may contain "404" or "429").
    ///
    /// Matches shapes actually emitted by scdl/yt-dlp:
    ///   "HTTP Error 403: Forbidden"
    ///   "Error 404: Not Found"
    ///   "status code 429"
    ///   "response 401"
    ///   "403: forbidden"
    ///   "404: not found"
    ///
    /// Trailing boundary: the character after the code must NOT be a digit,
    /// so "error 404" does not match "error 4042155".
    private static func containsHTTPCode(_ s: String, _ code: Int) -> Bool {
        let codeStr = String(code)
        let patterns = [
            "http error \(codeStr)",
            "error \(codeStr)",
            "status code \(codeStr)",
            "response \(codeStr)",
            "\(codeStr): forbidden",
            "\(codeStr): not found",
            "\(codeStr): unauthorized",
            "\(codeStr): too many requests"
        ]
        for pattern in patterns {
            if hasMatchWithTrailingDigitBoundary(s, pattern) {
                return true
            }
        }
        return false
    }

    /// Check whether `s` contains `pattern` where the character immediately
    /// after the match is NOT an ASCII digit (or the match is at end of string).
    /// This prevents "error 404" from matching inside "error 4042155".
    private static func hasMatchWithTrailingDigitBoundary(_ s: String, _ pattern: String) -> Bool {
        var searchStart = s.startIndex
        while let range = s.range(of: pattern, range: searchStart..<s.endIndex) {
            let afterMatch = range.upperBound
            // End of string → boundary satisfied
            if afterMatch >= s.endIndex { return true }
            // Next character is not a digit → boundary satisfied
            let nextChar = s[afterMatch]
            if !nextChar.isASCII || !nextChar.isNumber { return true }
            // Next character is a digit → not a real match, keep searching
            searchStart = range.upperBound
        }
        return false
    }

    private static func make(_ klass: DownloadFailureClass, source: String,
                             detail: String, heal: HealAction) -> DownloadFailure {
        DownloadFailure(
            klass: klass,
            source: source,
            detail: detail,
            userMessage: userMessage(for: klass, source: source),
            heal: heal)
    }

    private static func userMessage(for klass: DownloadFailureClass, source: String) -> String {
        let src = displayName(for: source)
        switch klass {
        case .drmProtected:
            return "DRM-protected on \(src) — this source cannot provide the track"
        case .geoBlocked:
            return "Not available in your region on \(src)"
        case .contentRemoved:
            return "Content has been removed from \(src)"
        case .downloadsDisabled:
            return "Downloads are disabled for this track on \(src)"
        case .toolStale:
            return "\(src) downloader tool is probably outdated — update and retry"
        case .toolMissing:
            return "Downloader tool is not installed"
        case .rateLimited:
            return "Rate limited by \(src) — retry after a short wait"
        case .networkTimeout:
            return "Timed out contacting \(src)"
        case .networkUnreachable:
            return "Network unreachable — check your connection"
        case .serverError:
            return "\(src) server error — retry later"
        case .authExpired:
            return "Authentication expired — re-authorize and retry"
        case .formatUnavailable:
            return "\(src) media format unavailable — another format will be tried"
        case .mediaCorrupt:
            return "Downloaded media is corrupt — quarantined for inspection"
        case .outputMissing:
            return "Downloader finished without producing a file"
        case .unknown:
            return "Download failed — reason unknown"
        }
    }

    private static func displayName(for source: String) -> String {
        switch source.lowercased() {
        case "soundcloud": return "SoundCloud"
        case "youtube": return "YouTube"
        case "dab": return "DAB"
        case "squid": return "Squid"
        default: return source.capitalized
        }
    }
}
