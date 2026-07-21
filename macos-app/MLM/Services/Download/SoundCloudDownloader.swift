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

    enum DownloadResult {
        case success(URL)
        case notFound
    }

    /// Supported audio file extensions for output detection.
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "opus", "wav"]

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
    /// - Returns: Path to the downloaded file, or `.notFound`
    func download(
        trackURL: String,
        outputDir: URL,
        trackId: Int64,
        title: String,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> DownloadResult {
        guard let scdl = scdlPath else {
            return .notFound
        }

        // Create temp dir to avoid filename collisions
        let tmpDir = outputDir.appendingPathComponent(".tmp_\(trackId)")
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

        let result = try await ProcessRunner.run(
            scdl,
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
        if !result.stderr.isEmpty {
            // scdl is chatty on stderr even on success — debug-level on
            // success, warn with the FULL message on failure so Python
            // tracebacks aren't truncated mid-stack when something breaks.
            if result.isSuccess {
                AppLogger.shared.log(
                    "scdl stderr: \(result.stderr.prefix(500))",
                    level: .debug,
                    source: "Download"
                )
            } else {
                AppLogger.shared.log(
                    "scdl exit=\(result.exitCode) stderr:\n\(result.stderr)",
                    level: .warning,
                    source: "Download"
                )
            }
        }

        // Check stderr for "not found" indicators
        let stderr = result.stderr.lowercased()
        if stderr.contains("not found") || stderr.contains("404") || stderr.contains("not available") {
            return .notFound
        }

        // Find the most recently created audio file in temp dir. This dir
        // is exclusive to this trackId/invocation, but is still guarded:
        // reject a candidate older than invocationStart (leftover from a
        // crashed prior run) and fail rather than guess when more than one
        // audio candidate is present.
        guard let downloadedFile = findMostRecentAudioFile(in: tmpDir, notBefore: invocationStart) else {
            return .notFound
        }

        // Collapse a doubled audio-container extension (e.g. .m4a.m4a)
        // before the move — RESEARCH Pitfall 4 flags scdl's own naming
        // logic as the [ASSUMED] source; live confirmation is plan 39-07.
        let collapsedName = Self.collapseDoubledAudioExtension(downloadedFile.lastPathComponent)

        // Move to output directory
        let outputFile = outputDir.appendingPathComponent(collapsedName)
        if FileManager.default.fileExists(atPath: outputFile.path) {
            try FileManager.default.removeItem(at: outputFile)
        }
        try FileManager.default.moveItem(at: downloadedFile, to: outputFile)

        return .success(outputFile)
    }

    // MARK: - Private

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
