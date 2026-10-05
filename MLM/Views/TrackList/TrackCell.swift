import SwiftUI

/// Per-table options the cells read.
struct TrackTableCellOptions {
    /// Second line under failed rows (UC-TABLE-13).
    var showsFailureDetail = false
    /// `#` is dimmed while the container is sorted by another column (UC-TABLE-05).
    var dimsPosition = false
    /// Album values link to the album (UC-TABLE-18; `nil` until W4-2).
    var openAlbum: ((TrackRow) -> Void)?
}

extension EnvironmentValues {
    @Entry var trackTableCellOptions = TrackTableCellOptions()
}

/// One cell of a track table. Reads only the prebuilt row and the table's live state — no
/// formatting, no database, no disk (UC-TABLE-20). One line per row, `.body` text
/// (UC-TABLE-15); absent values `—` in `.tertiary` (UC-TABLE-11); dimmed when the file isn't
/// reachable now (UC-TABLE-10).
struct TrackCell: View {
    let column: TrackColumnID
    let row: TrackRow

    @Environment(TrackTableLive.self) private var live: TrackTableLive?
    @Environment(\.trackTableCellOptions) private var options

    var body: some View {
        let presentation = TrackRowPresentation(row: row, live: live?.state ?? .idle)
        content(presentation)
    }

    @ViewBuilder
    private func content(_ presentation: TrackRowPresentation) -> some View {
        let dimmed = presentation.isDimmed
        switch column {
        case .number:
            Text(row.position, format: .number)
                .monospacedDigit()
                .foregroundStyle(dimmed || options.dimsPosition ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
        case .title:
            TrackTitleCell(row: row, presentation: presentation, live: live?.state ?? .idle,
                           showsFailureDetail: options.showsFailureDetail)
        case .artist:
            value(row.artistText, dimmed: dimmed)
        case .album:
            if let album = row.albumText, let openAlbum = options.openAlbum {
                Button(album) { openAlbum(row) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                    .help("Go to Album")
            } else {
                value(row.albumText, dimmed: dimmed, secondary: true)
            }
        case .time:
            value(row.timeText, dimmed: dimmed, numeric: true)
        case .bpm:
            value(row.bpmText, dimmed: dimmed, numeric: true)
        case .energy:
            TrackMeter(level: row.energyLevel).opacity(dimmed ? 0.5 : 1)
        case .dance:
            TrackMeter(level: row.danceLevel).opacity(dimmed ? 0.5 : 1)
        case .genre:
            value(row.genreText, dimmed: dimmed)
        case .year:
            value(row.yearText, dimmed: dimmed, numeric: true)
        case .format:
            value(row.formatText, dimmed: dimmed)
        case .kbps:
            value(row.kbpsText, dimmed: dimmed, numeric: true)
        case .added:
            value(row.addedText, dimmed: dimmed, secondary: true, numeric: true)
        case .status:
            if let status = presentation.status {
                TrackStatusLabel(status: status)
                    .help(row.failureDetail ?? "")
            }
        }
    }

    @ViewBuilder
    private func value(_ text: String?, dimmed: Bool, secondary: Bool = false, numeric: Bool = false) -> some View {
        if let text {
            Text(text)
                .lineLimit(1)
                .monospacedDigit(numeric)
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : (secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

private extension View {
    @ViewBuilder
    func monospacedDigit(_ on: Bool) -> some View {
        if on { monospacedDigit() } else { self }
    }
}

/// Title cell: 20 pt cover (placeholder for rows without a file, UC-TABLE-17), the
/// now-playing glyph (UC-TABLE-16), the title — and in the Download failed scope a second
/// line (UC-TABLE-13). Type-select matches the title (UC-TABLE-07).
private struct TrackTitleCell: View {
    let row: TrackRow
    let presentation: TrackRowPresentation
    let live: TrackTableLiveState
    let showsFailureDetail: Bool

    static let coverSize: CGFloat = 20

    var body: some View {
        HStack(spacing: Spacing.s) {
            artwork
                .frame(width: Self.coverSize, height: Self.coverSize)
                .opacity(presentation.isDimmed ? 0.5 : 1)
            if presentation.isNowPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .imageScale(.small)
                    .foregroundStyle(.tint)
                    .symbolEffect(.variableColor.iterative, isActive: live.isPlaying)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(row.title)
                    .lineLimit(1)
                    .foregroundStyle(titleStyle)
                if showsFailureDetail, let detail = row.failureDetail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .typeSelectEquivalent(row.title)
        .help(row.failureDetail ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var artwork: some View {
        if presentation.showsPlaceholderArtwork || row.id < 0 {
            TrackPlaceholderArtwork()
        } else {
            TrackCoverView(trackId: row.id, size: .small, cornerRadius: 4)
        }
    }

    private var titleStyle: AnyShapeStyle {
        if presentation.isNowPlaying { return AnyShapeStyle(.tint) }
        return presentation.isDimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary)
    }

    /// Title, artist and the Status word; `Now playing`; the reason a row is dimmed (UC-A11Y-07).
    private var accessibilityText: String {
        var parts = [row.title, row.artistText ?? "Unknown artist"]
        if let status = presentation.status { parts.append(status.text) }
        if presentation.isNowPlaying { parts.append("Now playing") }
        if presentation.isDimmed, let name = live.offlineVolumeName {
            parts.append("Not reachable — “\(name)” is not connected")
        }
        return parts.joined(separator: ", ")
    }
}
