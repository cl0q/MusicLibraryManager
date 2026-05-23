import SwiftUI

/// Metadata panel showing detailed track information.
///
/// Displays all available metadata fields in organized sections:
/// - **File** — Format, bitrate, duration, path
/// - **Tags** — Artist, album artist, album, genre, year
/// - **Analysis** — LUFS, true peak, energy bucket
/// - **Library** — Date added, download status, duplicate flag
///
/// Part of `TrackDetailView`. Designed as a scrollable side panel.
struct MetadataPanel: View {
    let track: Track

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {

                // MARK: - Tags Section
                metadataSection("Tags", icon: "tag") {
                    metadataRow("Title", value: track.title)
                    metadataRow("Artist", value: track.artist)
                    metadataRow("Album Artist", value: track.albumArtist)
                    metadataRow("Album", value: track.album)
                    metadataRow("Genre", value: track.genre ?? "—")
                    metadataRow("Year", value: track.year.map { "\($0)" } ?? "—")
                }

                Divider()
                    .background(Color.mlmEdge)

                // MARK: - File Section
                metadataSection("File", icon: "doc") {
                    metadataRow("Format", value: track.format.uppercased())
                    metadataRow("Bitrate", value: track.bitrate.map { "\($0) kbps" } ?? "—")
                    metadataRow("Duration", value: track.formattedDuration)
                    metadataRow("Original Path", value: track.originalPath, isPath: true)
                    if let organized = track.organizedPath {
                        metadataRow("Organized Path", value: organized, isPath: true)
                    }
                }

                Divider()
                    .background(Color.mlmEdge)

                // MARK: - Analysis Section
                metadataSection("Analysis", icon: "waveform") {
                    metadataRow("LUFS (Integrated)",
                                value: track.lufsI.map { String(format: "%.1f LUFS", $0) } ?? "—")
                    metadataRow("Loudness Range",
                                value: track.lufsRange.map { String(format: "%.1f LU", $0) } ?? "—")
                    metadataRow("True Peak",
                                value: track.truePeak.map { String(format: "%.1f dBTP", $0) } ?? "—")

                    HStack {
                        Text("Energy")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                            .frame(width: 110, alignment: .leading)
                        EnergyBars(level: track.energyBucket)
                        if let bucket = track.energyBucket {
                            Text("\(bucket)/5")
                                .font(MLMFont.dataSmall)
                                .foregroundColor(.mlmInkMuted)
                        }
                        Spacer()
                    }

                    HStack {
                        Text("Danceability")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                            .frame(width: 110, alignment: .leading)
                        DanceabilitySteps(score: track.danceability)
                        if let d = track.danceability {
                            Text(String(format: "%.0f%%", d * 100))
                                .font(MLMFont.dataSmall)
                                .foregroundColor(.mlmInkMuted)
                        }
                        Spacer()
                    }
                }

                Divider()
                    .background(Color.mlmEdge)

                // MARK: - Library Section
                metadataSection("Library", icon: "music.note.house") {
                    metadataRow("Date Added", value: Self.formatLocalDateTime(track.dateAdded))
                    metadataRow("Status", value: track.isLocal ? "Local" : "Remote")
                    if let status = track.downloadStatus {
                        // download_status is also an ISO 8601 timestamp in
                        // modern rows; render it in local time too.
                        metadataRow("Download", value: Self.formatLocalDateTime(status))
                    }
                    metadataRow("Duplicate", value: track.isDuplicate == 1 ? "Yes" : "No")
                    if let albumId = track.albumId {
                        metadataRow("Album ID", value: "\(albumId)")
                    }
                    if let variantOf = track.variantOf {
                        metadataRow("Variant Of", value: "Track #\(variantOf)")
                    }
                }
            }
            .padding(12)
        }
    }

    // MARK: - Section Builder

    private func metadataSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon)
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkSecondary)
                .padding(.bottom, 2)

            content()
        }
    }

    // MARK: - Row Builder

    private func metadataRow(_ label: String, value: String, isPath: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
                .frame(width: 110, alignment: .leading)

            Text(value)
                .font(isPath ? MLMFont.dataSmall : MLMFont.body)
                .foregroundColor(isPath ? .mlmInkMuted : .mlmInk)
                .lineLimit(isPath ? 3 : 1)
                .textSelection(.enabled)

            Spacer()
        }
    }

    // MARK: - Date Formatting

    /// Parse an ISO 8601 timestamp (UTC) and render it in the user's
    /// local timezone. Previously the raw UTC string was shown, which
    /// looked two hours early to a CEST user.
    static func formatLocalDateTime(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = parser.date(from: iso) {
            return Self.localFormatter.string(from: date)
        }
        parser.formatOptions = [.withInternetDateTime]
        if let date = parser.date(from: iso) {
            return Self.localFormatter.string(from: date)
        }
        // Date-only fallback ("YYYY-MM-DD"): keep as-is.
        return iso
    }

    private static let localFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.timeZone = .current
        f.locale = .current
        return f
    }()
}
