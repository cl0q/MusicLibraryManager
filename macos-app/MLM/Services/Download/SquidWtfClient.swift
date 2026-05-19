import Foundation

/// Squid.wtf Qobuz mirror client.
///
/// Pipeline-position: third fallback (SoundCloud → DAB → Squid → YouTube).
///
/// ## API shape (`https://qobuz.squid.wtf`)
/// - Search:   `GET /api/get-music?q=<query>&offset=0`
///             → `{ success, data: { albums: { items: [...] }, tracks: { items: [...] } } }`
/// - Download: `GET /api/download-music?track_id=<id>&quality=<5|6|7|27>`
///             → either `{ success: true, data: { url: ... } }` or `{ success: false, error: "Captcha required." }`
///
/// ## Captcha
/// The download endpoint gates on a `captcha_verified_at` cookie that
/// the site sets after the user passes its in-page captcha. Without it,
/// every download request returns `{success:false,"error":"Captcha
/// required."}`. Obtain it once by visiting `qobuz.squid.wtf` in a
/// browser, downloading any track (this triggers the captcha), then
/// opening dev-tools → Storage → Cookies → copying the value of
/// `captcha_verified_at` and exporting it via the
/// `MLM_SQUID_CAPTCHA` environment variable. The client attaches it
/// on every request.
///
/// (For back-compat we also accept the older `MLM_SQUID_CF_COOKIE`
/// name — initial assumption was Cloudflare-based; turns out it's a
/// site-specific captcha mechanism.)
///
/// ## Override
/// `MLM_SQUID_API_BASE` overrides the base URL the same way
/// `MLM_DAB_API_BASE` does for DAB.
final class SquidWtfClient: Sendable {

    private static let defaultBaseURL = "https://qobuz.squid.wtf"

    static var baseURL: String {
        ProcessInfo.processInfo.environment["MLM_SQUID_API_BASE"] ?? defaultBaseURL
    }

    /// Value of the `captcha_verified_at` cookie. Sourced from either
    /// `MLM_SQUID_CAPTCHA` (preferred) or the legacy `MLM_SQUID_CF_COOKIE`.
    static var captchaCookie: String? {
        let env = ProcessInfo.processInfo.environment
        for key in ["MLM_SQUID_CAPTCHA", "MLM_SQUID_CF_COOKIE"] {
            if let raw = env[key], !raw.isEmpty { return raw }
        }
        return nil
    }

    /// Back-compat alias used by the orchestrator's boot-time
    /// healthcheck. Returns the same value as `captchaCookie`.
    static var cfClearance: String? { captchaCookie }

    private let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        ]
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Public types

    struct SquidTrack {
        let id: String
        let title: String
        let artist: String
        let durationSec: Int?
        /// Qobuz quality codes: 5 = MP3 320, 6 = FLAC 16/44.1,
        /// 7 = FLAC 24/96, 27 = FLAC 24/192. We prefer 27 then walk down.
        static let preferredQualities: [Int] = [27, 7, 6, 5]
    }

    enum DownloadResult {
        case success(URL)
        case notFound
        case captchaRequired
    }

    // MARK: - Search

    /// Search for a track by free-text query. Returns the first track
    /// hit whose artist + title both match the requested values, or
    /// nil when nothing convincing is found.
    func searchTrack(query: String, artist: String, title: String) async throws -> SquidTrack? {
        let base = Self.baseURL
        guard !base.isEmpty else { return nil }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(base)/api/get-music?q=\(encoded)&offset=0") else {
            return nil
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: URLRequest(url: url))
        } catch let err as URLError where Self.isUnreachable(err) {
            AppLogger.shared.warn(
                "Squid: search endpoint unreachable (\(err.code.rawValue)) — set MLM_SQUID_API_BASE to override",
                source: "Download"
            )
            return nil
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let decoded: SearchResponse
        do {
            decoded = try JSONDecoder().decode(SearchResponse.self, from: data)
        } catch {
            AppLogger.shared.warn(
                "Squid: search response could not be decoded: \(error.localizedDescription)",
                source: "Download"
            )
            return nil
        }

        let candidates = decoded.data?.tracks?.items ?? []
        // Pick the first track whose artist + title both match. We're
        // intentionally strict here: the chain falls through to YouTube
        // if nothing matches, which is better than downloading the
        // wrong song.
        for item in candidates {
            let itemArtist = item.performer?.name ?? item.album?.artist?.name ?? ""
            if titleMatches(item.title, requested: title),
               artistMatches(itemArtist, requested: artist) {
                return SquidTrack(
                    id: String(item.id),
                    title: item.title,
                    artist: itemArtist,
                    durationSec: item.duration
                )
            }
        }
        return nil
    }

    // MARK: - Download

    /// Download a track to `outputDir`. Tries the qualities in
    /// `SquidTrack.preferredQualities` order until one returns a real
    /// audio URL. Returns `.captchaRequired` when Cloudflare refuses
    /// the request — the caller logs once and lets the chain fall
    /// through.
    func download(
        track: SquidTrack,
        outputDir: URL,
        artist: String,
        title: String
    ) async throws -> DownloadResult {
        let base = Self.baseURL
        guard !base.isEmpty else { return .notFound }

        for quality in SquidTrack.preferredQualities {
            let result = try await fetchDownloadURL(trackId: track.id, quality: quality, base: base)
            switch result {
            case .captchaRequired:
                return .captchaRequired
            case .notFound:
                continue
            case .url(let streamURL, let ext):
                let filename = PathSanitizer.sanitizeComponent("\(artist) - \(title).\(ext)")
                let outputURL = outputDir.appendingPathComponent(filename)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    return .success(outputURL)
                }
                let tmpURL = outputDir.appendingPathComponent(filename + ".tmp")
                var req = URLRequest(url: streamURL)
                attachCloudflareCookie(to: &req)
                let (tempLocal, _) = try await session.download(for: req)
                try? FileManager.default.removeItem(at: tmpURL)
                try FileManager.default.moveItem(at: tempLocal, to: tmpURL)
                try FileManager.default.moveItem(at: tmpURL, to: outputURL)
                return .success(outputURL)
            }
        }
        return .notFound
    }

    private enum DownloadURLResult {
        case url(URL, String)        // (download URL, file extension)
        case captchaRequired
        case notFound
    }

    private func fetchDownloadURL(trackId: String, quality: Int, base: String) async throws -> DownloadURLResult {
        guard let url = URL(string: "\(base)/api/download-music?track_id=\(trackId)&quality=\(quality)") else {
            return .notFound
        }
        var req = URLRequest(url: url)
        attachCloudflareCookie(to: &req)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch let err as URLError where Self.isUnreachable(err) {
            return .notFound
        }

        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        // The server returns the same JSON body on 200 success and on
        // 403 captcha, so we always parse the payload to decide.
        if let decoded = try? JSONDecoder().decode(DownloadResponse.self, from: data) {
            if let urlString = decoded.data?.url, let downloadURL = URL(string: urlString) {
                let ext = inferExtension(from: urlString, quality: quality)
                return .url(downloadURL, ext)
            }
            if decoded.success == false, let err = decoded.error,
               err.localizedLowercase.contains("captcha") {
                return .captchaRequired
            }
        }
        if code == 403 {
            return .captchaRequired
        }
        return .notFound
    }

    // MARK: - Helpers

    private func attachCloudflareCookie(to request: inout URLRequest) {
        guard let value = Self.captchaCookie else { return }
        // Site sets `captcha_verified_at=<unix-ms>` after the user
        // solves the in-page captcha. Forwarding this cookie alone is
        // enough to unlock the download endpoint.
        request.addValue("captcha_verified_at=\(value)", forHTTPHeaderField: "Cookie")
    }

    private func inferExtension(from urlString: String, quality: Int) -> String {
        let lower = urlString.lowercased()
        if lower.contains(".flac") { return "flac" }
        if lower.contains(".mp3") { return "mp3" }
        if lower.contains(".m4a") { return "m4a" }
        return quality == 5 ? "mp3" : "flac"
    }

    private func titleMatches(_ candidate: String, requested: String) -> Bool {
        let c = normalize(candidate)
        let r = normalize(requested)
        return c == r || c.contains(r) || r.contains(c)
    }

    private func artistMatches(_ candidate: String, requested: String) -> Bool {
        let c = normalize(candidate)
        let r = normalize(requested)
        // Loose on featured-artists strings — "Dr. Dre" should still match
        // "Dr. Dre feat. Snoop Dogg" and vice versa.
        return c == r || c.contains(r) || r.contains(c)
    }

    private func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "(", with: " ")
            .replacingOccurrences(of: ")", with: " ")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isUnreachable(_ err: URLError) -> Bool {
        switch err.code {
        case .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .timedOut:
            return true
        default:
            return false
        }
    }

    // MARK: - DTOs

    private struct SearchResponse: Decodable {
        let success: Bool?
        let data: SearchData?
    }

    private struct SearchData: Decodable {
        let tracks: TrackList?
    }

    private struct TrackList: Decodable {
        let items: [TrackItem]
    }

    private struct TrackItem: Decodable {
        let id: Int
        let title: String
        let duration: Int?
        let performer: Performer?
        let album: Album?

        struct Performer: Decodable {
            let name: String?
        }
        struct Album: Decodable {
            let artist: Performer?
        }
    }

    private struct DownloadResponse: Decodable {
        let success: Bool?
        let error: String?
        let data: DownloadData?

        struct DownloadData: Decodable {
            let url: String?
        }
    }
}

private extension String {
    var localizedLowercase: String { lowercased() }
}
