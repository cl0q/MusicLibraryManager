import Foundation

/// SoundCloud downloader wrapping the `scdl` CLI tool.
///
/// Mirrors the Rust `SoundCloudDownloader`. Requires `scdl` (pip install
/// scdl) and SoundCloud Go+ for 248kbps AAC.
///
/// scdl 3.0.0 does **not** read `~/.config/scdl/scdl.cfg` automatically
/// for the client_id, so we always try to pass `--client-id` explicitly
/// when one is discoverable (config file, env var, or Keychain). scdl
/// >= 3.0.4 can auto-generate one via yt-dlp's SoundCloud extractor, so
/// the flags are best-effort, not required.
final class SoundCloudDownloader: Sendable {

    /// Supported audio file extensions for output detection.
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "opus", "wav"]

    /// Maximum wall-clock seconds to wait for scdl before killing it.
    ///
    /// 900s (15 min) is generous: SoundCloud DJ mixes can be 1–2 hours long
    /// and legitimately take many minutes to download on a slow connection.
    /// A timeout is classified as `.networkTimeout` (retryable) by
    /// `DownloadFailureClassifier`, so over-running is always preferable to
    /// cutting off a real download prematurely.
    static let scdlTimeout: TimeInterval = 900

    private let scdlPath: String?

    init() {
        self.scdlPath = ProcessRunner.findExecutable("scdl")
    }

    /// Whether `scdl` is available on this system.
    var isAvailable: Bool { scdlPath != nil }

    /// Download a track from SoundCloud via `scdl` CLI.
    ///
    /// - Parameters:
    ///   - trackURL: The SoundCloud track URL
    ///   - outputDir: Directory to save the downloaded file
    ///   - trackId: Internal track ID (for temp dir naming)
    ///   - title: Expected title for the output filename
    /// - Returns: `.success(URL)` with the downloaded file, or `.failure(DownloadFailure)`
    ///   carrying a classified reason (DRM, transient, tool-missing, …).
    func download(
        trackURL: String,
        outputDir: URL,
        trackId: Int64,
        title: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> DownloadOutcome {
        guard let scdl = scdlPath else {
            return .failure(DownloadFailureClassifier.classifyTransport(
                source: "soundcloud",
                error: URLError(.fileDoesNotExist)))
        }

        // Create temp dir to avoid filename collisions
        let tmpDir = outputDir.appendingPathComponent(".tmp_\(trackId)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Recorded BEFORE launching scdl. Used as a lower bound when
        // picking up the produced file: a leftover file from a crashed
        // prior run (whose `defer { removeItem }` never fired) would
        // predate this timestamp and must be rejected rather than
        // silently returned as this invocation's result (T-39-02).
        let invocationStart = Date()

        let sanitizedTitle = PathSanitizer.sanitizeComponent(title)

        // Build scdl command. Pass --client-id / --auth-token when we can
        // discover values for them — scdl 3.0.0 needs the client_id
        // explicitly (it does not auto-read ~/.config/scdl/scdl.cfg).
        var arguments: [String] = [
            "-l", trackURL,
            "--path", tmpDir.path,
            "--original-art",
            "--name-format", sanitizedTitle
        ]
        if let clientId = SoundCloudCredentials.clientId() {
            arguments.append(contentsOf: ["--client-id", clientId])
        }
        if let authToken = SoundCloudCredentials.authToken() {
            arguments.append(contentsOf: ["--auth-token", authToken])
        }

        AppLogger.shared.log(
            "scdl: downloading \(trackURL)",
            level: .debug,
            source: "Download"
        )

        // Run scdl with a generous timeout. `do/catch` converts launch
        // failures (binary missing at execution time, spawn error) into a
        // classified transport failure rather than letting them propagate
        // as an unstructured throw. `throws` is preserved on the function
        // signature because FileManager operations below (createDirectory,
        // moveItem) can still throw, and Task cancellation propagates
        // through the async chain regardless.
        let result: ProcessRunner.ProcessResult
        do {
            result = try await ProcessRunner.run(
                scdl,
                arguments: arguments,
                timeout: Self.scdlTimeout,
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
        } catch {
            return .failure(DownloadFailureClassifier.classifyTransport(
                source: "soundcloud", error: error))
        }

        // ── File scan runs FIRST ─────────────────────────────────────
        //
        // scdl is chatty on stderr and prints benign "not found"
        // substrings (e.g. "artwork not found", "original format not
        // found, falling back to transcoded") even during successful
        // downloads. Checking stderr before the file scan caused false
        // `.notFound` fallthroughs to YouTube.
        //
        // The produced file is the ground truth for exit-code
        // unreliability: scdl exits 0 on DRM, 404, timeout — 47/47
        // failures in production exited 0. A non-zero exit with a
        // valid audio file in this invocation's exclusive temp dir is
        // a real success (scdl can exit non-zero for benign reasons
        // like an artwork fetch failing after the audio was fully
        // written — the file is complete).
        //
        // A TIMEOUT is different: ProcessRunner sent SIGTERM/SIGKILL
        // while scdl was still writing, so any file on disk is a
        // *partial* write — bytes that do not match the container
        // (e.g. "invalid start code ID3[3] in RIFF header" measured
        // in production: 138 occurrences across 55 ffmpeg failures).
        // A timed-out file must NEVER be accepted as success; it is
        // discarded and the download is reported as a retryable
        // timeout. Do not merge this case with the non-zero-exit
        // case above — only a timeout implies truncation.
        let producedFile = findMostRecentAudioFile(
            in: tmpDir, notBefore: invocationStart)

        // ── Timeout with a partial file: discard and fail ──────────
        //
        // A timeout means scdl was killed mid-write. Any file on disk
        // is incomplete — accepting it would silently admit a corrupt
        // file into the permanent library. Log the discard at .warning
        // with byte size (valuable evidence that timeouts are
        // truncating downloads), delete the partial file explicitly
        // (belt-and-braces: the staging dir's `defer` would clean it
        // up, but the intent must survive a future refactor of that
        // defer), and return .networkTimeout.
        if result.timedOut, let partialFile = producedFile {
            let byteSize = (try? FileManager.default.attributesOfItem(
                atPath: partialFile.path)[.size] as? Int) ?? -1
            AppLogger.shared.log(
                "scdl TIMEOUT trackId=\(trackId) url=\(trackURL) — discarding partial file '\(partialFile.lastPathComponent)' (\(byteSize) bytes)",
                level: .warning,
                source: "Download"
            )
            try? FileManager.default.removeItem(at: partialFile)
            return .failure(DownloadFailure(
                klass: .networkTimeout,
                source: "soundcloud",
                detail: "scdl timed out after \(Self.scdlTimeout)s for trackId=\(trackId) url=\(trackURL) — partial file '\(partialFile.lastPathComponent)' (\(byteSize) bytes) discarded",
                userMessage: "SoundCloud download timed out — retry later",
                heal: .retrySameSource))
        }

        if let downloadedFile = producedFile {
            // Success — a real audio file exists and the process was
            // NOT timed out. Log stderr at debug (tail only — the file
            // is the success signal, stderr is just chatter). The exit
            // code is recorded for diagnosis but does NOT veto a real
            // file (non-zero exit ≠ interrupted write).
            if !result.stderr.isEmpty {
                AppLogger.shared.log(
                    "scdl trackId=\(trackId) exit=\(result.exitCode) stderr: \(DownloadFailureClassifier.tail(result.stderr))",
                    level: .debug,
                    source: "Download"
                )
            }

            // Collapse a doubled audio-container extension (e.g. .m4a.m4a)
            // before the move — RESEARCH Pitfall 4 flags scdl's own naming
            // logic as the [ASSUMED] source; live confirmation is plan 39-07.
            let collapsedName = Self.collapseDoubledAudioExtension(downloadedFile.lastPathComponent)

            // Move to output directory
            let outputFile = nextAvailableURL(
                in: outputDir,
                preferredName: collapsedName
            )
            try FileManager.default.moveItem(at: downloadedFile, to: outputFile)

            return .success(outputFile)
        }

        // ── No usable file produced ──────────────────────────────────
        //
        // Log the FULL untruncated stderr at .warning with track context.
        // This is the diagnosis surface — keyed on file absence, NOT on
        // exit code, because scdl exits 0 on most failures (DRM, 404,
        // …). The old `!result.isSuccess` gate was dead code: 47/47
        // real failures exited 0 and the warning never fired.
        // The old `prefix(500)` head-truncation discarded the diagnostic
        // (scdl/yt-dlp emit the error LAST); `tail` keeps the end.
        if !result.stderr.isEmpty {
            AppLogger.shared.log(
                "scdl trackId=\(trackId) url=\(trackURL) exit=\(result.exitCode) stderr:\n\(result.stderr)",
                level: .warning,
                source: "Download"
            )
        }

        // Classify the failure instead of returning a bare not-found.
        // scdl exits 0 on most failures, so the exit code alone is
        // useless — the classifier inspects stderr content to determine
        // the real cause. This is what turns a DRM-protected track into
        // "DRM-protected on SoundCloud" and a transient timeout into a
        // retryable failure.
        if result.timedOut {
            return .failure(DownloadFailure(
                klass: .networkTimeout,
                source: "soundcloud",
                detail: "scdl timed out after \(Self.scdlTimeout)s for trackId=\(trackId) url=\(trackURL)",
                userMessage: "SoundCloud download timed out — retry later",
                heal: .retrySameSource))
        }

        let failure = DownloadFailureClassifier.classifyTool(
            source: "soundcloud",
            exitCode: result.exitCode,
            stderr: result.stderr,
            stdout: result.stdout,
            producedFile: false)
        return .failure(failure)
    }

    // MARK: - Private

    private func nextAvailableURL(in directory: URL, preferredName: String) -> URL {
        let preferred = directory.appendingPathComponent(preferredName)
        guard FileManager.default.fileExists(atPath: preferred.path) else {
            return preferred
        }

        let ext = preferred.pathExtension
        let stem = preferred.deletingPathExtension().lastPathComponent
        var suffix = 2
        while true {
            let name = ext.isEmpty
                ? "\(stem) (\(suffix))"
                : "\(stem) (\(suffix)).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    /// Find the audio file produced by THIS invocation in `directory`.
    ///
    /// Guards against two failure modes of the plain "most recent file"
    /// scan (T-39-02):
    /// 1. Stale pickup — a leftover file from a crashed prior run (whose
    ///    `defer { removeItem }` never fired) predates `notBefore` and is
    ///    rejected rather than returned as this invocation's result.
    /// 2. Ambiguous pickup — more than one audio candidate exists after
    ///    filtering for freshness; rather than guessing which one belongs
    ///    to this invocation, this logs a warning and fails closed.
    private func findMostRecentAudioFile(in directory: URL, notBefore: Date) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        let candidates = contents.filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }

        let freshCandidates = candidates.filter { url in
            let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modDate < notBefore {
                AppLogger.shared.warn(
                    "chain[SC]: rejecting stale candidate '\(url.lastPathComponent)' (modified before invocation start) — not this invocation's output",
                    source: "Download"
                )
                return false
            }
            return true
        }

        if freshCandidates.count > 1 {
            AppLogger.shared.warn(
                "chain[SC]: \(freshCandidates.count) audio candidates found in temp dir after freshness filtering — refusing to guess, treating as notFound",
                source: "Download"
            )
            return nil
        }

        return freshCandidates.first
    }

    /// Collapse a trailing IDENTICAL doubled audio-container extension
    /// (e.g. `song.m4a.m4a` -> `song.m4a`) to a single extension. Pure,
    /// no I/O — operates only on the produced filename string. Returns
    /// `name` unchanged when there is no doubled pair, when the stem
    /// merely contains an unrelated dot (`my.song.opus`), or when the two
    /// trailing extensions are DIFFERENT audio formats (`song.mp3.m4a`) —
    /// guessing a canonical extension in that case would be wrong.
    static func collapseDoubledAudioExtension(_ name: String) -> String {
        let audioExtPattern = audioExtensions.joined(separator: "|")
        guard let regex = try? NSRegularExpression(
            pattern: "\\.(\(audioExtPattern))\\.(\(audioExtPattern))$",
            options: .caseInsensitive
        ) else { return name }

        let range = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              let firstExtRange = Range(match.range(at: 1), in: name),
              let secondExtRange = Range(match.range(at: 2), in: name)
        else {
            return name
        }

        let firstExt = name[firstExtRange]
        let secondExt = name[secondExtRange]
        guard firstExt.lowercased() == secondExt.lowercased() else {
            return name
        }

        // Drop the first extension + its dot, keeping the second
        // extension's exact characters as produced.
        guard let fullMatchRange = Range(match.range, in: name) else { return name }
        let secondExtWithDot = "." + secondExt
        return name.replacingCharacters(in: fullMatchRange, with: secondExtWithDot)
    }
}

// MARK: - SoundCloud Credentials

/// Best-effort credential discovery for `scdl`.
///
/// scdl 3.0.0 needs `--client-id` passed explicitly — it does *not*
/// auto-load `~/.config/scdl/scdl.cfg`. scdl >= 3.0.4 can fall back to
/// yt-dlp's SoundCloud extractor for an auto-generated client_id, so
/// returning `nil` is fine and just means the flag won't be added.
enum SoundCloudCredentials {

    /// Discover the WEB-pool client_id for scdl.
    ///
    /// scdl talks to api-v2.soundcloud.com with a client_id from the pool
    /// SoundCloud rotates onto its web player (scraped from soundcloud.com
    /// or pulled from `~/.config/scdl/scdl.cfg`). This is NOT the same as
    /// the OAuth 2.1 app client_id we register for the in-app login flow —
    /// passing the OAuth client_id to scdl makes api-v2 return 403, which
    /// scdl 3.0.4's is_client_id_valid() unhelpfully re-raises as a fatal
    /// Python traceback.
    ///
    /// So we ignore `SOUNDCLOUD_CLIENT_ID` from `.env` entirely and only
    /// read scdl.cfg. Nil → let scdl auto-generate via soundcloud.com
    /// scraping (3.0.4+).
    static func clientId() -> String? {
        scdlConfigValue(key: "client_id")
    }

    /// Discover a SoundCloud `auth_token` for scdl.
    ///
    /// scdl's `--auth-token` is the browser-session `oauth_token` — NOT the
    /// API access_token returned by the public OAuth 2.1 PKCE flow. They
    /// look similar but scdl validates them against a different endpoint
    /// and will crash on startup with a Python traceback if the wrong one
    /// is supplied. We therefore ONLY read it from `~/.config/scdl/scdl.cfg`
    /// (the format scdl itself accepts) and skip the Keychain entirely.
    /// Returns nil → scdl downloads anonymously (no Go+ 248kbps AAC).
    static func authToken() -> String? {
        if let cfg = scdlConfigValue(key: "auth_token"), !cfg.isEmpty {
            return cfg
        }
        return nil
    }

    /// Parse a `key = value` pair out of `~/.config/scdl/scdl.cfg`.
    ///
    /// The file is an INI-flavored config: a `[scdl]` section header
    /// followed by `key = value` lines. We accept any value under any
    /// section since users sometimes drop the header.
    private static func scdlConfigValue(key: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home
            .appendingPathComponent(".config")
            .appendingPathComponent("scdl")
            .appendingPathComponent("scdl.cfg")
        guard let contents = try? String(contentsOf: configURL, encoding: .utf8) else {
            return nil
        }
        for rawLine in contents.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            guard line.hasPrefix(key) else { continue }
            guard let eqRange = line.range(of: "=") else { continue }
            let lhs = String(line[..<eqRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            guard lhs == key else { continue }
            let rhs = String(line[eqRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if rhs.isEmpty { continue }
            return rhs
        }
        return nil
    }
}
