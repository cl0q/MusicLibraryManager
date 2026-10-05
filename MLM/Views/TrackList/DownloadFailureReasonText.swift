import Foundation

/// The reason of a failed download in plain words (UC-TABLE-13, UC-JOB-11, G-TRK-FAILED):
/// `Sign-in expired (SoundCloud)`, `No match found on any source`, `yt-dlp not found`.
///
/// `tracks.download_failure.reason` holds whatever the download pipeline wrote at the time —
/// the classifier's `userMessage` (`Authentication expired — re-authorize and retry`), the
/// batch's fallback words (`Video unavailable`, `Network error`) or older free text. Rows
/// persisted long ago keep those strings, so the words are decided here, at display time, for
/// every stored text: a raw error string never reaches the UI (UC-COPY-11), and `Video
/// unavailable` is said only for a YouTube track (§11.1 #7, PP-ACTIVITY-04).
///
/// Pure, unit-tested (`DownloadFailureReasonTextTests`). Use it wherever a stored reason is
/// shown: the `Download failed` scope's second line and the row's help text (here), Info ▸
/// File (W2-E), Activity's per-item outcomes (W3-ACT).
enum DownloadFailureReasonText {
    /// What went wrong, independent of wording.
    enum Category: Equatable, Sendable {
        case signInExpired
        /// `yt-dlp`, `scdl`, or `nil` when the tool isn't named.
        case toolMissing(String?)
        case toolOutdated
        case drmProtected
        case regionBlocked
        /// Private, removed by the uploader, or gone from the source.
        case unavailable
        case downloadsDisabled
        case rateLimited
        case timedOut
        case offline
        case serverError
        case formatUnavailable
        case damagedFile
        /// The source(s) had no matching track.
        case noMatch
        /// The tool ended without a file.
        case noFile
        /// The old batch catch-all `Video unavailable` (any source, any error).
        case videoUnavailable
        /// The download was pinned to SoundCloud but the track has no SoundCloud link.
        case noSourceLink
        case captcha
        case couldNotSave
        /// The library's disk wasn't there (`“Lexxar”`), or its folder couldn't be written.
        case libraryFolderUnavailable(volumeName: String?)
        /// A second batch was refused while one ran.
        case anotherDownloadRunning
        case cancelled
        case unknown
    }

    /// Display names of the download sources, as the stored texts and the UI spell them.
    static let sourceNames = ["SoundCloud", "YouTube", "DAB", "Squid", "Qobuz", "Spotify"]

    /// The plain reason for a stored text.
    ///
    /// - Parameters:
    ///   - stored: `TrackDownloadFailure.reason` as persisted.
    ///   - sourceHint: the track's own source (`SoundCloud`, `YouTube`, …). Used only where
    ///     the stored text can't say it: a sign-in that expired (the classifier's text names
    ///     no source) and the old `Video unavailable`.
    static func plain(_ stored: String, sourceHint: String? = nil) -> String {
        let (category, namedSource) = classify(stored)
        let hint = sourceHint.flatMap(normalizedSourceName)
        switch category {
        case .signInExpired:
            // The track's own source is the one that asked for the sign-in (G-SRC-EXPIRED).
            return text(category, source: namedSource ?? hint)
        case .videoUnavailable:
            // Only a YouTube track keeps YouTube's words; every other one ran out of sources.
            return text(category, source: namedSource ?? hint)
        default:
            // Other reasons name their source in the stored text when they have one; a hint
            // would guess (the download chain tries several sources).
            return text(category, source: namedSource)
        }
    }

    /// `‹reason› · ‹n› attempts left` — the second line of a failed row in the `Download
    /// failed` scope and its help text (UC-TABLE-13, §15.4).
    static func detail(_ stored: String, failure: TrackDownloadFailure?, sourceHint: String? = nil) -> String {
        "\(plain(stored, sourceHint: sourceHint)) · \(DownloadRetryBudget.remainingText(for: failure))"
    }

    /// The source a track was linked from, for `sourceHint` (`nil` for local imports, reels).
    static func sourceHint(for track: Track) -> String? {
        normalizedSourceName(TrackMetadataPresentation.sourceName(for: track))
    }

    // MARK: - Classification

    /// The category of a stored text and the source it names, if any. The order matters:
    /// specific phrases before generic ones (`not installed` before `not found`, `timed out`
    /// before `network`, `credentials may be expired` before the 403 it comes with).
    static func classify(_ stored: String) -> (Category, String?) {
        let text = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        let source = namedSource(in: lower)
        func has(_ phrases: String...) -> Bool { phrases.contains { lower.contains($0) } }

        if let volume = volumeName(inNotConnected: text) {
            return (.libraryFolderUnavailable(volumeName: volume), nil)
        }
        if has("library folder not reachable") { return (.libraryFolderUnavailable(volumeName: nil), nil) }
        if lower.isEmpty || lower == "download failed" || has("reason unknown") { return (.unknown, nil) }
        if lower == "cancelled" || has("download cancelled", "download canceled") { return (.cancelled, nil) }
        if has("another download batch", "another download was running") { return (.anotherDownloadRunning, nil) }
        if has("could not be saved to library", "couldn’t save") { return (.couldNotSave, nil) }
        if has("not installed", "tool not found", "yt-dlp not found", "scdl not found") {
            let tool = lower.contains("yt-dlp") ? "yt-dlp" : (lower.contains("scdl") ? "scdl" : nil)
            return (.toolMissing(tool), nil)
        }
        if has("outdated", "out of date") { return (.toolOutdated, source) }
        if has("authentication expired", "sign-in expired", "credentials may be expired", "re-authorize",
               "unauthorized", "token expired") {
            return (.signInExpired, source)
        }
        if has("drm") { return (.drmProtected, source) }
        if has("your region", "your country", "geographic", "geo-blocked") { return (.regionBlocked, source) }
        if has("downloads are disabled", "not downloadable", "downloads turned off") { return (.downloadsDisabled, source) }
        if has("captcha") { return (.captcha, source) }
        if has("no soundcloud url", "no soundcloud link") { return (.noSourceLink, nil) }
        if has("rate limited", "too many requests") { return (.rateLimited, source) }
        if has("timed out", "timeout", "didn’t answer") { return (.timedOut, source) }
        if has("network", "internet", "offline") { return (.offline, nil) }
        if has("server error") { return (.serverError, source) }
        if has("format unavailable", "format not available") { return (.formatUnavailable, source) }
        if has("corrupt", "damaged") { return (.damagedFile, nil) }
        // The old catch-all — before "private", which "Private video" also says.
        if has("video unavailable", "video is unavailable") { return (.videoUnavailable, source) }
        if has("has been removed", "private", "no longer available", "removed by the uploader") {
            return (.unavailable, source)
        }
        if has("did not find the track", "no match") { return (.noMatch, source) }
        if has("without producing a file", "no file") { return (.noFile, source) }
        return (.unknown, nil)
    }

    // MARK: - Words

    /// The words of a category, with its source in parentheses where one is known.
    static func text(_ category: Category, source: String?) -> String {
        func with(_ words: String) -> String {
            source.map { "\(words) (\($0))" } ?? words
        }
        switch category {
        case .signInExpired: return with("Sign-in expired")
        case .toolMissing(let tool): return tool.map { "\($0) not found" } ?? "Download tool not found"
        case .toolOutdated: return with("Download tool out of date")
        case .drmProtected: return with("DRM-protected")
        case .regionBlocked: return with("Not available in your region")
        case .unavailable: return with("Private or no longer available")
        case .downloadsDisabled: return with("Downloads turned off")
        case .rateLimited: return with("Too many requests")
        case .timedOut: return source.map { "\($0) didn’t answer" } ?? "The source didn’t answer"
        case .offline: return "No internet connection"
        case .serverError: return with("Server error")
        case .formatUnavailable: return with("Format not available")
        case .damagedFile: return "Downloaded file was damaged"
        case .noMatch: return source.map { "No match found (\($0))" } ?? "No match found on any source"
        case .noFile: return with("No file received")
        case .videoUnavailable: return source == "YouTube" ? "Video unavailable (YouTube)" : "No match found on any source"
        case .noSourceLink: return "No SoundCloud link"
        case .captcha: return with("Blocked by a captcha check")
        case .couldNotSave: return "Couldn’t save the file to the library"
        case .libraryFolderUnavailable(let volume): return volume.map { "“\($0)” not connected" } ?? "Library folder not reachable"
        case .anotherDownloadRunning: return "Another download was running"
        case .cancelled: return "Cancelled"
        case .unknown: return "Reason unknown"
        }
    }

    // MARK: - Helpers

    /// The source named in a lower-cased text, by whole word (`scdl` → SoundCloud, `yt-dlp` →
    /// YouTube).
    static func namedSource(in lower: String) -> String? {
        let words = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if words.contains("soundcloud") || words.contains("scdl") { return "SoundCloud" }
        if words.contains("youtube") || (words.contains("yt") && words.contains("dlp")) { return "YouTube" }
        if words.contains("dab") || words.contains("dabmusic") { return "DAB" }
        if words.contains("squid") { return "Squid" }
        if words.contains("qobuz") { return "Qobuz" }
        if words.contains("spotify") { return "Spotify" }
        return nil
    }

    static func normalizedSourceName(_ name: String) -> String? {
        sourceNames.first { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// `“Lexxar” not connected` → `Lexxar`.
    private static func volumeName(inNotConnected text: String) -> String? {
        guard text.hasPrefix("“"), text.lowercased().hasSuffix("” not connected"),
              let close = text.firstIndex(of: "”") else { return nil }
        let name = text[text.index(after: text.startIndex)..<close]
        return name.isEmpty ? nil : String(name)
    }
}
