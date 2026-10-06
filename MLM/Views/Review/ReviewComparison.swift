import SwiftUI

/// A decision the comparison asks its host to make: the plans and the name of the undo step.
typealias ReviewDecide = ([ReviewGroupPlan], _ actionName: String) -> Void

// MARK: - Duplicates: the versions as a track table (V-REV.E07)

/// The comparison of one duplicate group: the shared track table with one row per version
/// (`.version` radio and words · format · kbps · time · `.location` · `.usedIn` · status), then
/// `Keep Recommended` · `Keep Selected` · `Keep All — Not Duplicates` and the consequence.
/// The pick follows the table's selection, so Space previews the picked version and a radio
/// click selects its row (V-REV.E07a/E07b/E07c/E07d, CM-REV-VERSION).
struct ReviewDuplicateComparison: View {
    let group: ReviewGroupItem
    let model: ReviewModel
    let onTrackActivated: TrackActivation
    let decide: ReviewDecide

    @State private var list = TrackListModel(sortOrder: nil)
    @State private var versions = ReviewVersionContext()
    @Environment(ToolbarSearchModel.self) private var search: ToolbarSearchModel?

    private static let headerHeight: CGFloat = 30
    private static let rowHeight: CGFloat = 26

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            TrackListTable(model: list, configuration: configuration) { EmptyView() }
                .environment(\.reviewVersionContext, versions)
                .frame(height: Self.headerHeight + Self.rowHeight * CGFloat(group.members.count) + 4)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
            actions
            if group.recommendsKeepAll {
                Label("Probably different versions of the same recording (edit, remaster). Listen before you decide.",
                      systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: group.members.map(\.id)) {
            versions.pick = { id in select(id) }
            await list.setTracks(group.members)
            refreshInfos()
            list.selection = [model.pick(for: group)]
        }
        // The pick follows the table's selection (Space previews the picked version).
        .onChange(of: list.selection) { _, selection in
            guard selection.count == 1, let id = selection.first else { return }
            if model.pick(for: group) != id { model.setPick(id, in: group) }
            versions.pickedID = id
        }
        .onChange(of: model.pick(for: group)) { _, _ in refreshInfos() }
    }

    private func select(_ id: Int64) {
        model.setPick(id, in: group)
        list.selection = [id]
        versions.pickedID = id
    }

    private func refreshInfos() {
        var infos: [Int64: ReviewVersionContext.Info] = [:]
        for track in group.members {
            guard let id = track.id else { continue }
            infos[id] = .init(
                label: ReviewPresentation.versionLabel(for: track, in: group),
                isRecommended: id == group.recommendedID && !group.recommendsKeepAll,
                usedIn: group.usedIn[id] ?? 0,
                location: Self.folder(of: track))
        }
        versions.infos = infos
        versions.pickedID = model.pick(for: group)
    }

    /// The folder of the file, in full.
    static func folder(of track: Track) -> String? {
        guard let path = track.organizedPath, !path.isEmpty else { return nil }
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? "/" : folder
    }

    private var configuration: TrackListConfiguration {
        var configuration = TrackListConfiguration(
            listContext: TrackListContext(container: .reviewGroup(key: group.key), viewName: nil),
            persistenceKey: "reviewGroup",
            columns: [.version, .format, .kbps, .time, .location, .usedIn, .status],
            defaultSort: nil,
            isSortable: false,
            publishesStatusText: false,
            accessibilityID: "review_group_table",
            activate: onTrackActivated)
        configuration.canAddToSyncProfile = false
        configuration.menuExtras = TrackMenuExtrasProvider(
            items: { rows in
                guard rows.count == 1 else { return .none }
                return TrackMenuExtras(
                    info: [TrackMenuExtra(id: "showInAllTracks", title: "Show in All Tracks")],
                    fix: [TrackMenuExtra(id: "keepThisVersion", title: "Keep This Version")])
            },
            perform: { id, rows in
                guard rows.count == 1, let row = rows.first else { return }
                switch id {
                case "keepThisVersion":
                    decide([model.plan(keep: row.id, in: group, action: .keepSelected)], "Keep Selected Version")
                case "showInAllTracks":
                    if let search { SearchReveal.showInAllTracks(row.id, search: search) }
                default:
                    break
                }
            })
        return configuration
    }

    private var actions: some View {
        let pick = model.pick(for: group)
        let entries = group.members.reduce(0) { $0 + ($1.id == pick ? 0 : (group.usedIn[$1.id ?? -1] ?? 0)) }
        return HStack(spacing: Spacing.s) {
            Button("Keep Recommended") {
                decide([model.plan(keepRecommendedIn: group)], "Keep Recommended Version")
            }
            .buttonStyle(.borderedProminent)
            .help("Keeps the recommended version. Return does the same on the group.")
            Button("Keep Selected") {
                decide([model.plan(keepSelectedIn: group)], "Keep Selected Version")
            }
            .disabled(!model.canKeepSelected(group))
            Button("Keep All — Not Duplicates") {
                decide([model.plan(keepAllIn: group)], "Keep All Versions")
            }
            Text(ReviewPresentation.groupConsequence(others: group.members.count - 1, playlistEntries: entries,
                                                     mode: model.effectiveMode))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Conflicts: one column per version (V-REV.E08b)

/// The comparison of one conflict group: a field grid with **every** version as a column (not
/// only the first two), a radio per value, `Use All from ‹A›`, the `After merge` line, and
/// `Apply Merge` · `Different Versions — Keep Both`.
struct ReviewConflictComparison: View {
    let group: ReviewGroupItem
    let model: ReviewModel
    let decide: ReviewDecide
    let writesTags: Bool

    @Environment(\.container) private var container

    var body: some View {
        let fields = model.differingFields(group)
        VStack(alignment: .leading, spacing: Spacing.s) {
            if fields.isEmpty {
                Text("The tags of these versions already match.")
                    .foregroundStyle(.secondary)
            } else {
                grid(fields)
            }
            HStack(spacing: Spacing.s) {
                ForEach(group.members.compactMap(\.id), id: \.self) { id in
                    Button("Use All from \(group.letter(of: id))") { model.useAll(from: id, in: group) }
                }
                Spacer(minLength: 0)
                Button(group.members.count == 2 ? "Different Versions — Keep Both" : "Different Versions — Keep All") {
                    decide([model.plan(keepAllIn: group)], "Keep Different Versions")
                }
                Button("Apply Merge") {
                    decide([model.plan(mergeIn: group)], "Merge Tags")
                }
                .buttonStyle(.borderedProminent)
                .disabled(fields.isEmpty)
            }
            Text(footnote)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(Spacing.m)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var footnote: String {
        let files = group.members.count
        let target = writesTags ? "the database and to the file tags of \(files) files" : "the database"
        return "Writes to \(target). The versions stay separate tracks — if they are also duplicates, the group appears under Duplicates afterwards."
    }

    private func grid(_ fields: [ConflictField]) -> some View {
        Grid(alignment: .topLeading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.xs) {
            GridRow {
                Text("Field").foregroundStyle(.secondary)
                ForEach(group.members, id: \.id) { track in
                    versionHeader(track)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(fields) { field in
                GridRow {
                    Text(field.label).foregroundStyle(.secondary)
                    ForEach(group.members, id: \.id) { track in
                        valueCell(field, track)
                    }
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("After merge").fontWeight(.medium)
                Text(model.mergedValues(group).map { "\($0.field.label) “\($0.text.isEmpty ? "—" : $0.text)”" }.joined(separator: " · "))
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
                    .gridCellColumns(group.members.count)
            }
        }
    }

    private func versionHeader(_ track: Track) -> some View {
        let id = track.id ?? -1
        let playlists = group.usedIn[id] ?? 0
        return VStack(alignment: .leading, spacing: 2) {
            Text("Version \(group.letter(of: id)) · \(ReviewPresentation.formatAndBitrate(track))")
                .fontWeight(.medium)
            Text([ReviewDuplicateComparison.folder(of: track), playlists == 0 ? "no playlists" : (playlists == 1 ? "1 playlist" : "\(playlists) playlists")]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.head)
            Button("Preview") { preview(track) }
                .buttonStyle(.link)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueCell(_ field: ConflictField, _ track: Track) -> some View {
        let id = track.id ?? -1
        let chosen = model.choice(for: field, in: group) == id
        let text = field.text(of: track)
        return Button {
            model.setChoice(id, for: field, in: group)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Image(systemName: chosen ? "circle.inset.filled" : "circle")
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                if text.isEmpty {
                    Text("— empty").foregroundStyle(.tertiary)
                } else {
                    Text(text).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(field.label): \(text.isEmpty ? "empty" : text), version \(group.letter(of: id))")
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    /// The same preview as everywhere (never Play/Pause of the main player).
    private func preview(_ track: Track) {
        guard let row = TrackRowBuilder.build([track]).first else { return }
        container.playbackViewModel?.preview.toggle(
            owner: "review.conflict.\(group.key)", candidate: PreviewCandidate.make(rows: [row], live: .idle))
    }
}
