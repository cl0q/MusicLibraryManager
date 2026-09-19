import Foundation

/// Metadata extracted from a web page's OG tags and title.
struct WebPageMetadata {
    let title: String?
    let description: String?
    let imageURL: String?
}

/// Fetches web pages and extracts audio CDN links + OG metadata.
enum WebContentFetcher {

    // MARK: - Audio URL extraction

    /// Extract audio URLs from HTML content. Filters out ad domains.
    static func extractAudioURLs(from html: String) -> [String] {
        var urls: [String] = []

        // <audio src="...">
        urls += extractAttributeValues(from: html, tagPattern: "<audio[^>]*", attribute: "src")
        // <source src="...">
        urls += extractAttributeValues(from: html, tagPattern: "<source[^>]*", attribute: "src")
        // <video src="...">
        urls += extractAttributeValues(from: html, tagPattern: "<video[^>]*", attribute: "src")
        // <a href="..."> — only those pointing to audio files
        let hrefs = extractAttributeValues(from: html, tagPattern: "<a[^>]*", attribute: "href")
        urls += hrefs.filter { isAudioURL($0) }

        // Strip tracking params, filter ads, deduplicate
        var seen = Set<String>()
        var result: [String] = []
        for raw in urls {
            let stripped = stripTrackingParams(raw)
            guard !isAdURL(stripped) else { continue }
            if seen.insert(stripped).inserted {
                result.append(stripped)
            }
        }
        return result
    }

    // MARK: - Metadata extraction

    /// Extract OG metadata from HTML content.
    static func extractMetadata(from html: String) -> WebPageMetadata {
        let title = ogValue(from: html, property: "og:title")
            ?? titleTagValue(from: html)
        let description = ogValue(from: html, property: "og:description")
        let imageURL = ogValue(from: html, property: "og:image")
        return WebPageMetadata(title: title, description: description, imageURL: imageURL)
    }

    // MARK: - Audio extension detection

    /// Check if a URL points to an audio file by extension.
    static func isAudioURL(_ url: String) -> Bool {
        let audioExtensions: Set<String> = ["mp3", "m4a", "flac", "wav", "ogg", "aac", "opus", "wma"]
        // Strip query string and fragment before checking extension
        var path = url
        if let qIndex = path.firstIndex(of: "?") {
            path = String(path[path.startIndex..<qIndex])
        }
        if let fIndex = path.firstIndex(of: "#") {
            path = String(path[path.startIndex..<fIndex])
        }
        let ext = (path as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext)
    }

    // MARK: - Private helpers

    /// Extract all values of a given attribute from tags matching a pattern.
    private static func extractAttributeValues(from html: String, tagPattern: String, attribute: String) -> [String] {
        // Match the full tag, then pull out the attribute value (single or double quoted)
        let tagRegex: NSRegularExpression
        do {
            tagRegex = try NSRegularExpression(pattern: tagPattern, options: .caseInsensitive)
        } catch {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        let matches = tagRegex.matches(in: html, options: [], range: range)

        var values: [String] = []
        for match in matches {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            // Look for attribute="value" or attribute='value'
            let attrPattern = "\(attribute)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
            guard let attrRegex = try? NSRegularExpression(pattern: attrPattern, options: .caseInsensitive) else { continue }
            let attrSearchRange = NSRange(tag.startIndex..., in: tag)
            let attrMatches = attrRegex.matches(in: tag, options: [], range: attrSearchRange)
            for attrMatch in attrMatches {
                // Group 1 = double-quoted, Group 2 = single-quoted
                if attrMatch.numberOfRanges > 1, let r = Range(attrMatch.range(at: 1), in: tag), !r.isEmpty {
                    values.append(String(tag[r]))
                } else if attrMatch.numberOfRanges > 2, let r = Range(attrMatch.range(at: 2), in: tag), !r.isEmpty {
                    values.append(String(tag[r]))
                }
            }
        }
        return values
    }

    /// Extract value of an og: meta property.
    private static func ogValue(from html: String, property: String) -> String? {
        // Match <meta property="og:xxx" content="..."> or with content first
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let pattern = "<meta[^>]*?(?:property=[\"']\(escaped)[\"'])[^>]*?content=[\"']([^\"']*)[\"']"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           let r = Range(match.range(at: 1), in: html) {
            return String(html[r])
        }
        // Try reversed order: content before property
        let pattern2 = "<meta[^>]*?content=[\"']([^\"']*)[\"'][^>]*?(?:property=[\"']\(escaped)[\"'])"
        guard let regex2 = try? NSRegularExpression(pattern: pattern2, options: .caseInsensitive) else { return nil }
        if let match = regex2.firstMatch(in: html, options: [], range: range),
           let r = Range(match.range(at: 1), in: html) {
            return String(html[r])
        }
        return nil
    }

    /// Extract text content of <title> tag.
    private static func titleTagValue(from html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>", options: .caseInsensitive) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        if let match = regex.firstMatch(in: html, options: [], range: range),
           let r = Range(match.range(at: 1), in: html) {
            return String(html[r])
        }
        return nil
    }

    /// Check if a URL comes from an ad domain.
    private static func isAdURL(_ url: String) -> Bool {
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        let adIndicators = ["ad", "doubleclick", "adserver", "tracking", "analytics", "ads", "advertising"]
        return adIndicators.contains { host.contains($0) }
    }

    /// Strip utm_* query parameters from a URL.
    private static func stripTrackingParams(_ url: String) -> String {
        guard var components = URLComponents(string: url),
              let queryItems = components.queryItems else {
            return url
        }
        let filtered = queryItems.filter { !$0.name.hasPrefix("utm_") }
        components.queryItems = filtered.isEmpty ? nil : filtered
        return components.string ?? url
    }
}
