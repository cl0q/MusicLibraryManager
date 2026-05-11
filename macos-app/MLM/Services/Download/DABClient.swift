import Foundation
import os

/// DAB Music API client for high-quality FLAC downloads.
///
/// Mirrors the Rust `DabClient` — authenticates via session cookie,
/// searches for tracks, and downloads FLAC files.
final class DABClient: Sendable {
    /// Base URL for the DAB API.
    private static let baseURL = "https://dab.yeet.su/api"
    private static let tokenSource = "dab"
    private static let tokenUser = "default"

    private let session: URLSession
    private let tokenStorage: TokenStorage

    /// Current session token (thread-safe).
    private let sessionToken = OSAllocatedUnfairLock<String?>(initialState: nil)

    init(tokenStorage: TokenStorage) {
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = HTTPCookieStorage.shared
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.tokenStorage = tokenStorage

        // Restore saved session token from UserDefaults (not Keychain — it's just a session cookie)
        if let saved = UserDefaults.standard.string(forKey: "dab_session_token") {
            sessionToken.withLock { $0 = saved }
        }
    }

    // MARK: - Search

    /// Search DAB for a track matching the query.
    func searchTrack(query: String) async throws -> DabTrack? {
        try await ensureAuthenticated()

        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        let url = URL(string: "\(Self.baseURL)/search?q=\(encoded)")!

        var request = URLRequest(url: url)
        addAuthCookie(to: &request)

        let (data, response) = try await session.data(for: request)
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        if statusCode == 401 {
            // Try re-login
            try await login()
            return try await searchTrack(query: query)
        }

        guard statusCode == 200 else { return nil }

        let searchResponse = try JSONDecoder().decode(DabSearchResponse.self, from: data)
        return searchResponse.tracks.first
    }

    // MARK: - Download

    enum DownloadResult {
        case success(URL)
        case notFound
    }

    /// Download a track from DAB to the output directory.
    ///
    /// - Parameters:
    ///   - dabTrack: The DAB track to download
    ///   - outputDir: Directory to save the FLAC file
    ///   - artist: Expected artist for filename
    ///   - title: Expected title for filename
    /// - Returns: Path to the downloaded file, or `.notFound`
    func download(dabTrack: DabTrack, outputDir: URL, artist: String, title: String) async throws -> DownloadResult {
        try await ensureAuthenticated()

        // Check if already downloaded
        let filename = PathSanitizer.sanitizeComponent("\(artist) - \(title).flac")
        let outputURL = outputDir.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            return .success(outputURL)
        }

        // Get stream URL
        let streamURL = try await getStreamURL(trackId: dabTrack.id)
        guard let streamURL else { return .notFound }

        // Download to temp file, then rename
        let tmpURL = outputDir.appendingPathComponent(filename + ".tmp")
        var request = URLRequest(url: URL(string: streamURL)!)
        addAuthCookie(to: &request)

        let (tempLocal, _) = try await session.download(for: request)
        try? FileManager.default.removeItem(at: tmpURL)
        try FileManager.default.moveItem(at: tempLocal, to: tmpURL)
        try FileManager.default.moveItem(at: tmpURL, to: outputURL)

        return .success(outputURL)
    }

    /// Validate that a DAB track matches the requested artist/title.
    func matches(dabTrack: DabTrack, artist: String, title: String) -> Bool {
        titleMatches(dabTrack.title, requested: title) &&
        artistMatches(dabTrack.artist, requested: artist)
    }

    // MARK: - Private

    private func getStreamURL(trackId: UInt64) async throws -> String? {
        let url = URL(string: "\(Self.baseURL)/stream?trackId=\(trackId)")!
        var request = URLRequest(url: url)
        addAuthCookie(to: &request)

        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }

        let streamResponse = try JSONDecoder().decode(DabStreamResponse.self, from: data)
        return streamResponse.url
    }

    private func ensureAuthenticated() async throws {
        let hasToken = sessionToken.withLock { $0 != nil }
        if !hasToken {
            try await login()
        }
    }

    private func login() async throws {
        guard let email = ProcessInfo.processInfo.environment["DAB_EMAIL"],
              let password = ProcessInfo.processInfo.environment["DAB_PASSWORD"] else {
            throw DABError.noCredentials
        }

        let url = URL(string: "\(Self.baseURL)/auth/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(["email": email, "password": password])

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DABError.loginFailed
        }

        // Extract session cookie
        if let cookies = HTTPCookieStorage.shared.cookies(for: url) {
            for cookie in cookies where cookie.name == "session" {
                sessionToken.withLock { $0 = cookie.value }
                // Persist to UserDefaults
                UserDefaults.standard.set(cookie.value, forKey: "dab_session_token")
            }
        }
    }

    private func addAuthCookie(to request: inout URLRequest) {
        if let token = sessionToken.withLock({ $0 }) {
            request.setValue("session=\(token)", forHTTPHeaderField: "Cookie")
        }
    }

    private func titleMatches(_ dabTitle: String, requested: String) -> Bool {
        DABMatcher.titleMatches(dabTitle, requested: requested)
    }

    private func artistMatches(_ dabArtist: String, requested: String) -> Bool {
        DABMatcher.artistMatches(dabArtist, requested: requested)
    }
}

// MARK: - Matching helpers (visible for tests)

/// Artist/title matching rules for DAB search results.
///
/// A DAB hit is only used when **both** artist AND title match. Without
/// the artist check, many DAB results return wrong-artist covers and the
/// download chain prefers DAB FLAC over YouTube — meaning the user ends
/// up with a high-quality file of the wrong track. This is documented
/// invariant #1 in `SONNET_PROMPT_PHASE11_DOWNLOADS.md`.
///
/// A match is accepted when either:
/// - one normalized string contains the other (matches the Rust impl —
///   handles cases like "Track (feat. X)" vs "Track"), OR
/// - Jaro similarity on the normalized strings is ≥ `threshold` (0.85),
///   which catches typos and small spelling variations.
enum DABMatcher {
    /// Minimum Jaro similarity for a fuzzy match.
    static let threshold: Double = 0.85

    static func titleMatches(_ dabTitle: String, requested: String) -> Bool {
        match(dabTitle, requested: requested)
    }

    static func artistMatches(_ dabArtist: String, requested: String) -> Bool {
        match(dabArtist, requested: requested)
    }

    static func match(_ dab: String, requested: String) -> Bool {
        let a = normalize(dab)
        let b = normalize(requested)
        if a.isEmpty || b.isEmpty { return false }
        // Cheap exact / containment short-circuit. Mirrors the Rust impl
        // semantics so the existing Rust test cases keep matching.
        if a == b || a.contains(b) || b.contains(a) { return true }
        // Fuzzy fallback for typos and minor spelling variations.
        return jaroSimilarity(a, b) >= threshold
    }

    /// Lowercase, strip non-alphanumeric (preserve spaces), collapse
    /// whitespace. Matches the Rust normalization step exactly.
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .reduce(into: "") { $0 += String($1) }
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Jaro similarity for two strings — returns a value in [0, 1].
    ///
    /// Classic Jaro algorithm: count matching characters within a
    /// distance window, then factor in transpositions. We use it instead
    /// of Levenshtein because it's well-suited to short strings (song
    /// titles, artist names) and treats prefix differences gently.
    static func jaroSimilarity(_ s1: String, _ s2: String) -> Double {
        let a = Array(s1)
        let b = Array(s2)
        if a.isEmpty && b.isEmpty { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0.0 }

        let matchDistance = max(a.count, b.count) / 2 - 1
        var aMatches = [Bool](repeating: false, count: a.count)
        var bMatches = [Bool](repeating: false, count: b.count)

        var matches = 0
        for i in 0..<a.count {
            let start = max(0, i - matchDistance)
            let end = min(i + matchDistance + 1, b.count)
            if start >= end { continue }
            for j in start..<end {
                if bMatches[j] { continue }
                if a[i] != b[j] { continue }
                aMatches[i] = true
                bMatches[j] = true
                matches += 1
                break
            }
        }
        if matches == 0 { return 0.0 }

        // Count transpositions
        var transpositions = 0
        var k = 0
        for i in 0..<a.count {
            if !aMatches[i] { continue }
            while !bMatches[k] { k += 1 }
            if a[i] != b[k] { transpositions += 1 }
            k += 1
        }

        let m = Double(matches)
        return (m / Double(a.count)
                + m / Double(b.count)
                + (m - Double(transpositions) / 2) / m) / 3.0
    }
}

// MARK: - Models

struct DabTrack: Codable {
    let id: UInt64
    let title: String
    let artist: String
    let albumTitle: String?
    let albumId: UInt64?
    let duration: UInt64?
    let audioQuality: DabAudioQuality?

    enum CodingKeys: String, CodingKey {
        case id, title, artist, duration
        case albumTitle = "album_title"
        case albumId = "album_id"
        case audioQuality = "audio_quality"
    }
}

struct DabAudioQuality: Codable {
    let maximumBitDepth: Int?
    let maximumSamplingRate: Double?
    let isHiRes: Bool?

    enum CodingKeys: String, CodingKey {
        case maximumBitDepth = "maximum_bit_depth"
        case maximumSamplingRate = "maximum_sampling_rate"
        case isHiRes = "is_hi_res"
    }
}

struct DabSearchResponse: Codable {
    let tracks: [DabTrack]
}

struct DabStreamResponse: Codable {
    let url: String
}

enum DABError: LocalizedError {
    case noCredentials
    case loginFailed

    var errorDescription: String? {
        switch self {
        case .noCredentials: "DAB_EMAIL and DAB_PASSWORD environment variables not set"
        case .loginFailed: "DAB login failed"
        }
    }
}
