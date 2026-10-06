import SwiftUI

/// What the version rows of one Review comparison show beyond the track itself, and what a
/// click on a radio does. The comparison puts it into the environment of its
/// `TrackListTable`; `TrackCell` reads it for the `.version`, `.location` and `.usedIn`
/// columns (V-REV.E07, E07a, N12).
@MainActor
@Observable
final class ReviewVersionContext {
    struct Info: Equatable {
        /// `Recommended — highest quality` · `Lower bitrate` · `Not downloaded` …
        var label: String
        var isRecommended: Bool
        /// Playlists the version is in.
        var usedIn: Int
        /// The file's folder, in full.
        var location: String?
    }

    var infos: [Int64: Info] = [:]
    /// The picked version (the radio that is on).
    var pickedID: Int64?
    @ObservationIgnored var pick: (Int64) -> Void = { _ in }
}

extension EnvironmentValues {
    @Entry var reviewVersionContext: ReviewVersionContext? = nil
}

/// The radio and the version's words — never a colour alone (V-REV.E07a).
struct ReviewVersionCell: View {
    let row: TrackRow
    @Environment(\.reviewVersionContext) private var context

    var body: some View {
        if let context, let info = context.infos[row.id] {
            HStack(spacing: Spacing.s) {
                Button {
                    context.pick(row.id)
                } label: {
                    Image(systemName: context.pickedID == row.id ? "circle.inset.filled" : "circle")
                        .foregroundStyle(context.pickedID == row.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Pick this version")
                .accessibilityValue(context.pickedID == row.id ? "Picked" : "")
                if info.isRecommended {
                    Label(info.label, systemImage: "checkmark")
                        .fontWeight(.medium)
                        .lineLimit(1)
                } else {
                    Text(info.label)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// The file's folder (head truncated; the full path is the help).
struct ReviewLocationCell: View {
    let row: TrackRow
    let dimmed: Bool
    @Environment(\.reviewVersionContext) private var context

    var body: some View {
        if let location = context?.infos[row.id]?.location {
            Text(location)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(dimmed ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                .help(location)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// `3 playlists`.
struct ReviewUsedInCell: View {
    let rowID: Int64
    @Environment(\.reviewVersionContext) private var context

    var body: some View {
        if let count = context?.infos[rowID]?.usedIn, count > 0 {
            Text(count == 1 ? "1 playlist" : "\(count) playlists")
                .monospacedDigit()
                .lineLimit(1)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}
