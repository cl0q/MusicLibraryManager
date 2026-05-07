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
            VStack(alignment: .leading, spacing: MLMSpacing.sectionGap) {

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
                }

                Divider()
                    .background(Color.mlmEdge)

                // MARK: - Library Section
                metadataSection("Library", icon: "music.note.house") {
                    metadataRow("Date Added", value: track.dateAdded ?? "—")
                    metadataRow("Status", value: track.isLocal ? "Local" : "Remote")
                    if let status = track.downloadStatus {
                        metadataRow("Download", value: status.capitalized)
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
            .padding(MLMSpacing.cardPadding)
        }
    }

    // MARK: - Section Builder

    private func metadataSection<Content: View>(
        _ title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: MLMSpacing.tightGap) {
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
}
