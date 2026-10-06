import Foundation

// MARK: - Add from Link… (S-REELS-LINK, D-REELS-URL)

enum ReelLinkSource: String, Equatable, Sendable {
    case instagram, tiktok, youtubeShorts

    var word: String {
        switch self {
        case .instagram: "Instagram"
        case .tiktok: "TikTok"
        case .youtubeShorts: "YouTube Shorts"
        }
    }
}

struct ReelLink: Equatable, Sendable {
    let url: URL
    let source: ReelLinkSource
}

enum ReelLinkParser {
    /// The sheet's help text, verbatim (S-REELS-LINK).
    static let helpText = "Instagram, TikTok and YouTube Shorts links. The video is saved to ~/Downloads/Reels and appears as New. If the link needs a sign-in, MLM says so here."

    /// What a link of another kind is told (new sentence).
    static let refusal = "That isn’t an Instagram, TikTok or YouTube Shorts link."

    /// A link to one reel, short video or Short; nil for anything else (other hosts, a profile,
    /// a plain YouTube video).
    static func parse(_ text: String) -> ReelLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.lowercased()
        func isHost(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if isHost("instagram.com") {
            let prefixes = ["/reel/", "/reels/", "/p/", "/tv/"]
            guard prefixes.contains(where: { path.hasPrefix($0) && path.count > $0.count }) else { return nil }
            return ReelLink(url: url, source: .instagram)
        }
        if isHost("tiktok.com") {
            // vm./vt. short links carry the id in the path; watch pages are `/@user/video/id`.
            guard path.count > 1 else { return nil }
            return ReelLink(url: url, source: .tiktok)
        }
        if isHost("youtube.com") {
            guard path.hasPrefix("/shorts/"), path.count > "/shorts/".count else { return nil }
            return ReelLink(url: url, source: .youtubeShorts)
        }
        return nil
    }

    /// The first reel link in dropped or pasted text (several lines allowed).
    static func firstLink(in text: String) -> ReelLink? {
        text.split(whereSeparator: \.isWhitespace).lazy.compactMap { parse(String($0)) }.first
    }
}

/// Why a fetch failed, in words for the status bar and Activity.
enum ReelFetchError: LocalizedError, Equatable {
    case toolMissing
    case needsSignIn
    case failed(String)
    case noFile

    var errorDescription: String? {
        switch self {
        case .toolMissing: "yt-dlp isn’t installed"
        case .needsSignIn: "the link needs a sign-in"
        case .failed(let cause): cause
        case .noFile: "no video file came back"
        }
    }
}

protocol ReelFetching: Sendable {
    /// Saves the video into `folder` and returns its file.
    func fetch(_ link: ReelLink, into folder: URL) async throws -> URL
}

enum ReelFetchLocation {
    /// `~/Downloads/Reels` — what the sheet's help text says.
    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Reels", isDirectory: true)
    }
}

/// `yt-dlp` through the existing process runner (the same tool the YouTube downloader uses).
struct YtDlpReelFetcher: ReelFetching {
    var executable: @Sendable () -> String? = { ProcessRunner.findExecutable("yt-dlp") }

    func fetch(_ link: ReelLink, into folder: URL) async throws -> URL {
        guard let tool = executable() else { throw ReelFetchError.toolMissing }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let template = folder.appendingPathComponent("%(extractor_key)s_%(id)s.%(ext)s").path
        let result = try await ProcessRunner.run(
            tool,
            arguments: ["--no-playlist", "--no-progress", "-o", template, "--print", "after_move:filepath", link.url.absoluteString],
            timeout: 300)
        guard result.isSuccess else { throw Self.error(fromStderr: result.stderr, timedOut: result.timedOut) }
        let path = result.stdout.split(whereSeparator: \.isNewline).last.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { throw ReelFetchError.noFile }
        return URL(fileURLWithPath: path)
    }

    /// Reads yt-dlp's complaint: a sign-in wall is its own sentence; anything else is its last
    /// `ERROR:` line.
    static func error(fromStderr stderr: String, timedOut: Bool) -> ReelFetchError {
        if timedOut { return .failed("the download took too long") }
        let lower = stderr.lowercased()
        let signInMarkers = ["login required", "log in", "sign in", "cookies", "private", "rate-limit", "not available without"]
        if signInMarkers.contains(where: lower.contains) { return .needsSignIn }
        let line = stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR:") }
            .map { String($0).replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        return .failed(line.flatMap { $0.isEmpty ? nil : $0 } ?? "the video couldn’t be fetched")
    }
}
