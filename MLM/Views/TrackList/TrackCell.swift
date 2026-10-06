import SwiftUI

/// Per-table options the cells read.
struct TrackTableCellOptions {
    /// Second line under failed rows (UC-TABLE-13).
    var showsFailureDetail = false
    /// `#` is dimmed while the container is sorted by another column (UC-TABLE-05).
    var dimsPosition = false
    /// Album values link to the album (UC-TABLE-18; `nil` until W4-2).
    var openAlbum: ((TrackRow) -> Void)?
    /// A row without an energy bucket says `Analyzing…` (Discover ▸ Recommendations, V-INBOX.N04):
    /// its automatic analysis is still running.
    var showsAnalysingEnergy = false
    /// The title cell has its 20 pt cover (album pages have one cover, in the header, W4-2).
    var showsRowCover = true
    /// The now-playing glyph sits in the `#` column, not before the title (album pages).
    var playingGlyphInNumber = false
    /// Edit Order: the `#` cell carries a drag handle.
    var showsDragHandle = false
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
        // An album's `Not in library` positions and disc headings carry only what they are.
        if !row.isTrack, ![.number, .title, .status].contains(column) {
            EmptyView()
        } else {
            columnContent(presentation, dimmed: dimmed)
        }
    }

    @ViewBuilder
    private func columnContent(_ presentation: TrackRowPresentation, dimmed: Bool) -> some View {
        switch column {
        case .number:
            numberCell(presentation, dimmed: dimmed)
        case .title:
            TrackTitleCell(row: row, presentation: presentation, live: live?.state ?? .idle,
                           showsFailureDetail: options.showsFailureDetail, showsCover: options.showsRowCover,
                           showsPlayingGlyph: !options.playingGlyphInNumber)
        case .artist:
            value(row.artistText, dimmed: dimmed)
        case .album:
            if let album = row.albumText, row.track.albumId != nil, let openAlbum = options.openAlbum {
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
            if options.showsAnalysingEnergy, row.energyLevel == nil {
                Text("Analyzing…").foregroundStyle(.secondary).lineLimit(1)
            } else {
                TrackMeter(level: row.energyLevel).opacity(dimmed ? 0.5 : 1)
            }
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
        case .match:
            // A plain number, no badge (V-GENRED.N10).
            value(row.matchPercent.map { "\($0) %" }, dimmed: dimmed, numeric: true)
        case .suggestion:
            TrackSuggestionCell(rowID: row.id)
        case .version:
            ReviewVersionCell(row: row)
        case .location:
            ReviewLocationCell(row: row, dimmed: dimmed)
        case .usedIn:
            ReviewUsedInCell(rowID: row.id)
        case .source:
            RecommendationSourceCell(rowID: row.id)
        }
    }

    /// `#`: the position, or an album's number within its disc; an album's playing row shows the
    /// speaker here; Edit Order adds the drag handle; a disc heading has none.
    @ViewBuilder
    private func numberCell(_ presentation: TrackRowPresentation, dimmed: Bool) -> some View {
        if row.synthetic == .discHeader {
            EmptyView()
        } else {
            HStack(spacing: Spacing.xs) {
                if options.showsDragHandle, row.isTrack {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                if options.playingGlyphInNumber, presentation.isNowPlaying {
                    Image(systemName: "speaker.wave.2.fill")
                        .imageScale(.small)
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, isActive: live?.state.isPlaying ?? false)
                        .accessibilityLabel("Now playing")
                } else {
                    Text(row.displayNumber ?? row.position, format: .number)
                        .monospacedDigit()
                        .foregroundStyle(dimmed || options.dimsPosition ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                }
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

// MARK: - Suggestion verdicts (W3-GEN, ST-STUDIO-GENRE.E04)

/// The state and verdicts of a suggestion list's rows: staged ids and what `Add to Genre`,
/// `Remove` (unstage) and `Not Now` do. The host puts it into the environment of the table.
@MainActor
@Observable
final class TrackSuggestionVerdicts {
    var stagedIDs: Set<Int64> = []
    @ObservationIgnored var stage: (Int64) -> Void = { _ in }
    @ObservationIgnored var unstage: (Int64) -> Void = { _ in }
    @ObservationIgnored var hide: (Int64) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var trackSuggestionVerdicts: TrackSuggestionVerdicts? = nil
}

/// `Add to Genre` · `Not Now` — or, once staged, `Staged` · `Remove`.
private struct TrackSuggestionCell: View {
    let rowID: Int64
    @Environment(\.trackSuggestionVerdicts) private var verdicts

    var body: some View {
        if let verdicts {
            HStack(spacing: Spacing.s) {
                if verdicts.stagedIDs.contains(rowID) {
                    Text("Staged").foregroundStyle(.secondary)
                    Button("Remove") { verdicts.unstage(rowID) }
                        .buttonStyle(.link)
                } else {
                    Button("Add to Genre") { verdicts.stage(rowID) }
                        .controlSize(.small)
                    Button("Not Now") { verdicts.hide(rowID) }
                        .buttonStyle(.link)
                }
            }
            .lineLimit(1)
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
    var showsCover = true
    var showsPlayingGlyph = true

    static let coverSize: CGFloat = 20

    var body: some View {
        if row.synthetic == .discHeader {
            Text(row.title)
                .fontWeight(.semibold)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        } else {
            trackTitle
        }
    }

    private var trackTitle: some View {
        HStack(spacing: Spacing.s) {
            if showsCover {
                artwork
                    .frame(width: Self.coverSize, height: Self.coverSize)
                    .opacity(presentation.isDimmed ? 0.5 : 1)
            }
            if presentation.isNowPlaying, showsPlayingGlyph {
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
        if row.synthetic == .absent { return "\(row.title), not in library" }
        var parts = [row.title, row.artistText ?? "Unknown artist"]
        if let status = presentation.status { parts.append(status.text) }
        if presentation.isNowPlaying { parts.append("Now playing") }
        if presentation.isDimmed, let name = live.offlineVolumeName {
            parts.append("Not reachable — “\(name)” is not connected")
        }
        return parts.joined(separator: ", ")
    }
}
