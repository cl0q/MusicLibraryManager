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
        title: String
    ) async throws -> DownloadResult {
        guard let scdl = scdlPath else {
            return .notFound
        }

        // Create temp dir to avoid filename collisions
        let tmpDir = outputDir.appendingPathComponent(".tmp_\(trackId)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

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

        let result = try await ProcessRunner.run(scdl, arguments: arguments)
        if !result.stderr.isEmpty {
            // scdl is chatty on stderr even on success — log at debug so
            // tail-ing the log can show what's happening on a failed run.
            AppLogger.shared.log(
                "scdl stderr: \(result.stderr.prefix(500))",
                level: .debug,
                source: "Download"
            )
        }

        // Check stderr for "not found" indicators
        let stderr = result.stderr.lowercased()
        if stderr.contains("not found") || stderr.contains("404") || stderr.contains("not available") {
            return .notFound
        }

        // Find the most recently created audio file in temp dir
        guard let downloadedFile = findMostRecentAudioFile(in: tmpDir) else {
            if !result.isSuccess {
                return .notFound
            }
            return .notFound
        }

        // Move to output directory
        let outputFile = outputDir.appendingPathComponent(downloadedFile.lastPathComponent)
        if FileManager.default.fileExists(atPath: outputFile.path) {
            try FileManager.default.removeItem(at: outputFile)
        }
        try FileManager.default.moveItem(at: downloadedFile, to: outputFile)

        return .success(outputFile)
    }

    // MARK: - Private

    /// Find the most recently modified audio file in a directory.
    private func findMostRecentAudioFile(in directory: URL) -> URL? {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return nil }

        return contents
            .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            .max { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return dateA < dateB
            }
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

    /// Discover a SoundCloud client_id, in priority order:
    /// 1. `SOUNDCLOUD_CLIENT_ID` environment variable / `.env` file
    /// 2. `client_id = …` line in `~/.config/scdl/scdl.cfg`
    /// 3. `nil` — let scdl auto-generate one (3.0.4+).
    static func clientId() -> String? {
        if let envValue = CredentialsLoader.credential(key: "SOUNDCLOUD_CLIENT_ID"),
           !envValue.isEmpty {
            return envValue
        }
        return scdlConfigValue(key: "client_id")
    }

    /// Discover a SoundCloud `auth_token` (i.e. the value the SoundCloud
    /// website calls `oauth_token`). Order:
    /// 1. `auth_token = …` line in `~/.config/scdl/scdl.cfg` — this is
    ///    what scdl itself uses for SoundCloud Go+ authentication.
    /// 2. Keychain credentials for the SoundCloud OAuth service (the
    ///    access token captured during in-app OAuth).
    /// 3. `nil` — anonymous download (no Go+ 248kbps AAC).
    static func authToken() -> String? {
        if let cfg = scdlConfigValue(key: "auth_token"), !cfg.isEmpty {
            return cfg
        }
        do {
            let storage = TokenStorage()
            if let creds = try storage.getCredentials(service: .soundcloud),
               !creds.accessToken.isEmpty {
                return creds.accessToken
            }
        } catch {
            AppLogger.shared.log(
                "Failed to read SoundCloud Keychain credentials: \(error)",
                level: .warning,
                source: "Download"
            )
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
