import Foundation

// MARK: - Stream preview (IMP-109)
//
// A suggestion (Similar ▸ Online) or a result (Reels) isn't in the library, so there is no file
// to preview. `PreviewCandidate.stream(link, title:)` carries its SoundCloud or YouTube link;
// when the preview starts the link is resolved to a direct audio URL (`StreamResolving`), the
// audio is fetched to a temporary file the preview engine can open (`StreamFetching` — the
// engine plays files), the temporary file is deleted when the preview ends. Nothing is added to
// the library and nothing is kept.

extension Track {
    /// The stand-in of a stream in a preview session: no id, `format == "stream"`, the link as
    /// its path. Never stored.
    static func previewStream(page: URL, title: String) -> Track {
        Track(artist: "", album: "", title: title, format: "stream", originalPath: page.absoluteString)
    }

    var isPreviewStream: Bool { id == nil && format == "stream" }
}

/// The two kinds of link a stream preview resolves — nothing else.
enum StreamLink: Equatable, Sendable {
    case soundCloud
    case youTube

    static func kind(of url: URL) -> StreamLink? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        func isHost(_ name: String) -> Bool { host == name || host.hasSuffix("." + name) }
        if isHost("soundcloud.com") { return .soundCloud }
        if isHost("youtube.com") || host == "youtu.be" { return .youTube }
        return nil
    }

    /// `.stream` for a link a preview can resolve, `nil` for anything else (a DAB or Qobuz
    /// result, a suggestion without a link): such rows offer no Preview.
    static func candidate(link: String?, title: String) -> PreviewCandidate? {
        guard let link, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)),
              kind(of: url) != nil else { return nil }
        return .stream(url, title: title)
    }
}

/// Why a link couldn't become a stream, in the words after `Couldn’t preview “‹title›” — `.
enum StreamResolveError: Error, Equatable, Sendable {
    case unsupportedLink
    case noStream
    case notSignedIn
    case toolMissing
    case timedOut
    case failed(String)

    var cause: String {
        switch self {
        case .unsupportedLink: "only SoundCloud and YouTube links can be previewed"
        case .noStream: "there is no stream for it"
        case .notSignedIn: "SoundCloud isn’t connected"
        case .toolMissing: "yt-dlp isn’t installed"
        case .timedOut: "the link took too long to resolve"
        case .failed(let detail): detail
        }
    }
}

/// Finds the direct audio URL behind a SoundCloud or YouTube link.
protocol StreamResolving: Sendable {
    func resolve(_ page: URL) async throws -> URL
}

/// The live resolver: SoundCloud through the SoundCloud client, YouTube through `yt-dlp -g`
/// (10 s timeout), nothing else. Both are closures so tests (and the app) bring their own.
struct StreamResolver: StreamResolving {
    var soundCloud: @Sendable (URL) async throws -> URL
    var youTube: @Sendable (URL) async throws -> URL

    func resolve(_ page: URL) async throws -> URL {
        switch StreamLink.kind(of: page) {
        case .soundCloud?: return try await soundCloud(page)
        case .youTube?: return try await youTube(page)
        case nil: throw StreamResolveError.unsupportedLink
        }
    }

    /// The app's resolver: SoundCloud through the container's client, YouTube through yt-dlp.
    static func live(soundCloudClient: @escaping @Sendable () async -> SoundCloudClient?) -> StreamResolver {
        StreamResolver(
            soundCloud: { page in
                guard let client = await soundCloudClient() else { throw StreamResolveError.notSignedIn }
                return try await client.previewStreamURL(trackURL: page.absoluteString)
            },
            youTube: { page in try await YtDlpStreamResolver().resolve(page) })
    }
}

/// `yt-dlp -g -f bestaudio` through `ProcessRunner`, 10 s: prints the direct audio URL.
struct YtDlpStreamResolver: StreamResolving {
    var executable: @Sendable () -> String? = { ProcessRunner.findExecutable("yt-dlp") }
    var run: @Sendable (_ tool: String, _ arguments: [String], _ timeout: TimeInterval) async throws -> ProcessRunner.ProcessResult = {
        try await ProcessRunner.run($0, arguments: $1, timeout: $2)
    }

    static let timeout: TimeInterval = 10

    /// `m4a` first: the preview engine can't decode WebM/Opus.
    static func arguments(for page: URL) -> [String] {
        ["--no-playlist", "-g", "-f", "bestaudio[ext=m4a]/bestaudio", page.absoluteString]
    }

    func resolve(_ page: URL) async throws -> URL {
        guard let tool = executable() else { throw StreamResolveError.toolMissing }
        let result: ProcessRunner.ProcessResult
        do {
            result = try await run(tool, Self.arguments(for: page), Self.timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StreamResolveError.failed("yt-dlp couldn’t be started")
        }
        if result.timedOut { throw StreamResolveError.timedOut }
        guard result.isSuccess else { throw StreamResolveError.failed(Self.reason(fromStderr: result.stderr)) }
        // `-g` prints one URL per selected format; a single audio format is one line.
        let line = result.stdout.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let url = URL(string: line), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            throw StreamResolveError.noStream
        }
        return url
    }

    /// yt-dlp's last `ERROR:` line, trimmed; a generic sentence when it printed none.
    static func reason(fromStderr stderr: String) -> String {
        let line = stderr.split(whereSeparator: \.isNewline).last { $0.contains("ERROR:") }
            .map { String($0).replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let line, !line.isEmpty else { return "yt-dlp couldn’t resolve it" }
        // `[youtube] abc123: Video unavailable` → `Video unavailable`.
        var text = line
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            text = String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        if let range = text.range(of: #"^\S+:\s+"#, options: .regularExpression) { text.removeSubrange(range) }
        return text.isEmpty ? "yt-dlp couldn’t resolve it" : text
    }
}

/// Fetches a stream's audio to a temporary file (`nil` = nothing to fetch).
protocol StreamFetching: Sendable {
    func fetch(_ stream: URL) async throws -> URL
}

/// The live fetcher: one temporary file in the temporary directory, at most `maxBytes` (a longer
/// stream is refused, never kept).
struct TemporaryStreamFetcher: StreamFetching {
    static let maxBytes: Int64 = 48 * 1_024 * 1_024

    func fetch(_ stream: URL) async throws -> URL {
        var request = URLRequest(url: stream)
        request.timeoutInterval = 20
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: downloaded)
            throw StreamResolveError.failed("the stream answered \(http.statusCode)")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: downloaded.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= Self.maxBytes else {
            try? FileManager.default.removeItem(at: downloaded)
            throw StreamResolveError.failed("it is too long to preview")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MLM-stream-preview", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(Self.fileExtension(mimeType: response.mimeType, url: stream))
        try FileManager.default.moveItem(at: downloaded, to: file)
        return file
    }

    static func fileExtension(mimeType: String?, url: URL) -> String {
        switch mimeType?.lowercased() {
        case "audio/mpeg", "audio/mp3": return "mp3"
        case "audio/mp4", "audio/x-m4a", "audio/aac", "video/mp4": return "m4a"
        case "audio/ogg", "audio/webm", "video/webm": return "webm"
        default:
            let ext = url.pathExtension.lowercased()
            return ext.isEmpty || ext.count > 5 ? "mp3" : ext
        }
    }
}

/// What the player needs to preview a stream: resolve, fetch, hand back a file to open.
/// The temporary file is the owner's to delete (`PlaybackViewModel`, when the preview ends).
struct StreamPreviewProvider: Sendable {
    var resolver: any StreamResolving
    var fetcher: any StreamFetching

    /// The audio of `page` as a temporary file, or the failure for the status bar.
    func audioFile(for page: URL, title: String) async -> Result<URL, PreviewResolveFailure> {
        do {
            let stream = try await resolver.resolve(page)
            try Task.checkCancellation()
            return .success(try await fetcher.fetch(stream))
        } catch let error as StreamResolveError {
            return .failure(.stream(title: title, cause: error.cause))
        } catch is CancellationError {
            return .failure(.stream(title: title, cause: "it was stopped"))
        } catch {
            return .failure(.stream(title: title, cause: "the stream couldn’t be loaded"))
        }
    }
}

extension StreamPreviewProvider {
    /// The app's provider: SoundCloud through the open library's client, YouTube through yt-dlp.
    static var live: StreamPreviewProvider {
        StreamPreviewProvider(
            resolver: StreamResolver.live(soundCloudClient: { await MainActor.run { DependencyContainer.shared.soundCloudClient } }),
            fetcher: TemporaryStreamFetcher())
    }
}
