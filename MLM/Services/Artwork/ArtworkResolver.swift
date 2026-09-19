import Foundation

/// Resolves artwork/thumbnail URLs from various sources.
enum ArtworkResolver {
    enum Source: String, Sendable {
        case youtube
        case soundcloud
        case directAudio
        case genericWeb
    }

    static func resolveArtworkURL(
        source: Source,
        url: String,
        metadata: [String: String] = [:]
    ) async throws -> String? {
        switch source {
        case .youtube:
            guard let videoID = extractYouTubeVideoID(from: url) else { return nil }
            return "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg"

        case .soundcloud:
            guard var artworkURL = metadata["artwork_url"] else { return nil }
            artworkURL = artworkURL.replacingOccurrences(of: "-large", with: "-original")
            return artworkURL

        case .directAudio:
            return nil

        case .genericWeb:
            return nil
        }
    }

    static func extractOGImage(from html: String) -> String? {
        if let ogImage = extractMetaContent(from: html, property: "og:image") {
            return ogImage
        }
        return extractMetaContent(from: html, name: "twitter:image")
    }

    // MARK: - Private helpers

    private static func extractYouTubeVideoID(from url: String) -> String? {
        // Handle youtu.be/ID
        if let range = url.range(of: "youtu.be/") {
            let afterSlash = url[range.upperBound...]
            let id = afterSlash.prefix(while: { $0 != "?" && $0 != "&" && $0 != "/" && $0 != "#" })
            return id.isEmpty ? nil : String(id)
        }

        // Handle youtube.com/watch?v=ID
        if let range = url.range(of: "v=") {
            let afterEquals = url[range.upperBound...]
            let id = afterEquals.prefix(while: { $0 != "&" && $0 != "#" && $0 != " " })
            return id.isEmpty ? nil : String(id)
        }

        return nil
    }

    /// Extract content from `<meta property="..." content="...">` with double or single quotes.
    private static func extractMetaContent(from html: String, property: String) -> String? {
        let pattern = "<meta[^>]*property\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: property))[\"'][^>]*content\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let contentRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[contentRange])
    }

    /// Extract content from `<meta name="..." content="...">` with double or single quotes.
    private static func extractMetaContent(from html: String, name: String) -> String? {
        let pattern = "<meta[^>]*name\\s*=\\s*[\"']\(NSRegularExpression.escapedPattern(for: name))[\"'][^>]*content\\s*=\\s*[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let contentRange = Range(match.range(at: 1), in: html) else {
            return nil
        }
        return String(html[contentRange])
    }
}
