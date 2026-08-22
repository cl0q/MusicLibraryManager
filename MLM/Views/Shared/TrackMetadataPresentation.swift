import SwiftUI

/// Shared presentation rules for import-time placeholder artist and album values.
enum TrackMetadataPresentation {
    static let placeholderTooltip = "Placeholder from import — will update after download"

    static func isPlaceholder(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "youtube",
            "soundcloud likes",
            "discovered neighbors",
            "reels inbox imports",
            "downloads",
            "unknown",
        ].contains(normalized)
    }

    static func sourceName(for track: Track) -> String {
        let path = track.originalPath.lowercased()
        let format = track.format.lowercased()
        let album = track.album.lowercased()

        if album == "reels" || path.hasPrefix("reels://") {
            return "Reels"
        }
        if path.contains("soundcloud") || format == "soundcloud" {
            return "SoundCloud"
        }
        if path.contains("youtube") || format == "youtube" {
            return "YouTube"
        }
        if format == "qobuz" || path.contains("qobuz") {
            return "Qobuz"
        }
        if format == "dab" {
            return "DABmusic"
        }
        return "Local import"
    }
}

/// Displays metadata with the shared placeholder treatment used by every track table.
struct TrackMetadataText: View {
    let value: String
    let font: Font
    let secondary: Bool

    init(_ value: String, font: Font = MLMFont.body, secondary: Bool = false) {
        self.value = value
        self.font = font
        self.secondary = secondary
    }

    var body: some View {
        if TrackMetadataPresentation.isPlaceholder(value) {
            Text(value)
                .font(font)
                .foregroundStyle(Color.mlmInkMuted)
                .italic()
                .lineLimit(1)
                .help(TrackMetadataPresentation.placeholderTooltip)
        } else {
            Text(value)
                .font(font)
                .foregroundStyle(secondary ? Color.mlmInkSecondary : Color.mlmInk)
                .lineLimit(1)
        }
    }
}
