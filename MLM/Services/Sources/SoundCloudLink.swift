import Foundation

/// One spelling per SoundCloud link (W3-ADD review S1): `https://soundcloud.com/‹path›` without
/// query (`?si=…`, `utm_*`), fragment, trailing slash or the `www.` / `m.` host — used before a
/// link is looked up and before it is stored, so `original_path` and `track_sources` never
/// carry share parameters and a link matches the track it already is.
enum SoundCloudLink {
    static let hosts: Set<String> = ["soundcloud.com", "www.soundcloud.com", "m.soundcloud.com"]
    /// `on.soundcloud.com/‹code›` share links redirect to the real address.
    static let shortLinkHost = "on.soundcloud.com"

    static func canonical(_ url: String) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let host = components.host?.lowercased(), hosts.contains(host) else { return trimmed }
        components.scheme = "https"
        components.host = "soundcloud.com"
        components.query = nil
        components.fragment = nil
        components.port = nil
        var path = components.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        components.path = path
        return components.string ?? trimmed
    }

    static func isShortLink(_ url: String) -> Bool {
        URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() == shortLinkHost
    }

    /// Follows a short link's redirect (one HEAD request); `nil` when it doesn't lead to
    /// soundcloud.com. Only for an explicit lookup (Add from Link), never per row.
    static func resolveShortLink(_ url: String, session: URLSession = .shared) async -> String? {
        guard isShortLink(url), let address = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        var request = URLRequest(url: address, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await session.data(for: request),
              let final = response.url?.absoluteString,
              let host = response.url?.host?.lowercased(), hosts.contains(host) else { return nil }
        return canonical(final)
    }
}
