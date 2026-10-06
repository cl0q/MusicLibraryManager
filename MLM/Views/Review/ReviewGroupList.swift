import SwiftUI

/// The groups of Duplicates or Conflicts as one list (V-REV.E06): one row per group — `‹n›
/// versions of “‹Title›”` with the artist, `Why`, the recommendation named by format and
/// bitrate — expandable (→ / click) into the comparison. ↑ ↓ move, → ← expand and collapse,
/// ↩ keeps the recommendation / applies the merge (UC-KEY-30, UC-PRIM-09).
struct ReviewGroupList: View {
    let model: ReviewModel
    let groups: [ReviewGroupItem]
    @Binding var expanded: Set<String>
    @Binding var selection: String?
    let writesTags: Bool
    let onTrackActivated: TrackActivation
    let decide: ReviewDecide
    let search: ToolbarSearchModel?

    @Environment(\.container) private var container

    private static let whyWidth: CGFloat = 230
    private static let recommendationWidth: CGFloat = 290
    private static let actionWidth: CGFloat = 150

    var body: some View {
        VStack(spacing: 0) {
            columnHeader
            Divider()
            List(selection: $selection) {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: Spacing.s) {
                        row(group)
                        if expanded.contains(group.key) {
                            comparison(group)
                                .padding(.leading, 34)
                                .padding(.bottom, Spacing.xs)
                        }
                    }
                    .padding(.vertical, Spacing.xxs)
                    .tag(group.key)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { keys in
                menu(for: keys)
            } primaryAction: { keys in
                keys.forEach(toggle)
            }
            .onKeyPress(.rightArrow) { setExpanded(true) }
            .onKeyPress(.leftArrow) { setExpanded(false) }
            .onKeyPress(.return) {
                guard let group = selectedGroup else { return .ignored }
                primary(group)
                return .handled
            }
            // Space on a group previews the picked version (never Play/Pause, THOUGHTS §10).
            .onKeyPress(.space) {
                guard let group = selectedGroup, group.kind == .duplicate else { return .ignored }
                previewPick(of: group)
                return .handled
            }
            .accessibilityIdentifier("review_groups")
        }
    }

    /// The same preview the track table uses, for the version picked in the group.
    private func previewPick(of group: ReviewGroupItem) {
        let pickID = model.pick(for: group)
        guard let track = group.members.first(where: { $0.id == pickID }),
              let row = TrackRowBuilder.build([track]).first else { return }
        container.playbackViewModel?.preview.toggle(
            owner: "review.group.\(group.key)", candidate: PreviewCandidate.make(rows: [row], live: .idle))
    }

    private var selectedGroup: ReviewGroupItem? {
        guard let selection else { return nil }
        return groups.first { $0.key == selection }
    }

    // MARK: Rows

    private var isConflicts: Bool { groups.first?.kind == .conflict }

    private var columnHeader: some View {
        HStack(spacing: Spacing.m) {
            Color.clear.frame(width: 14)
            Text("Group").frame(maxWidth: .infinity, alignment: .leading)
            Text(isConflicts ? "Differs in" : "Why").frame(width: Self.whyWidth, alignment: .leading)
            Text(isConflicts ? "Why" : "Recommendation").frame(width: Self.recommendationWidth, alignment: .leading)
            Color.clear.frame(width: Self.actionWidth)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.xxs)
        .background(.background)
    }

    private func row(_ group: ReviewGroupItem) -> some View {
        let isOpen = expanded.contains(group.key)
        return HStack(spacing: Spacing.m) {
            Button { toggle(group.key) } label: {
                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                    .imageScale(.small)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isOpen ? "Hide Comparison" : "Show Comparison")
            VStack(alignment: .leading, spacing: 0) {
                Text(group.headline).lineLimit(1)
                Text(group.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if isConflicts {
                Text(model.differingFields(group).map(\.label).joined(separator: ", "))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .frame(width: Self.whyWidth, alignment: .leading)
                Text(ReviewPresentation.whyColumn(isVariant: false, matchPercent: group.matchPercent)
                    .replacingOccurrences(of: "Identical recording", with: "Same recording"))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .frame(width: Self.recommendationWidth, alignment: .leading)
                Color.clear.frame(width: Self.actionWidth)
            } else {
                Text(ReviewPresentation.whyColumn(isVariant: group.recommendsKeepAll, matchPercent: group.matchPercent))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .frame(width: Self.whyWidth, alignment: .leading)
                Text(ReviewPresentation.recommendation(for: group))
                    .foregroundStyle(.secondary).lineLimit(2)
                    .frame(width: Self.recommendationWidth, alignment: .leading)
                Button("Keep Recommended") { decide([model.plan(keepRecommendedIn: group)], "Keep Recommended Version") }
                    .controlSize(.small)
                    .frame(width: Self.actionWidth, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func comparison(_ group: ReviewGroupItem) -> some View {
        if group.kind == .conflict {
            ReviewConflictComparison(group: group, model: model, decide: decide, writesTags: writesTags)
        } else {
            ReviewDuplicateComparison(group: group, model: model, onTrackActivated: onTrackActivated, decide: decide)
        }
    }

    // MARK: Keys and actions

    private func toggle(_ key: String) {
        if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
    }

    private func setExpanded(_ open: Bool) -> KeyPress.Result {
        guard let selection else { return .ignored }
        if open { expanded.insert(selection) } else { expanded.remove(selection) }
        return .handled
    }

    /// ↩: `Keep Recommended` / `Apply Merge` (UC-PRIM-09). A conflict merges only when its
    /// comparison is open, so a stray Return never rewrites tags unseen.
    private func primary(_ group: ReviewGroupItem) {
        switch group.kind {
        case .duplicate:
            decide([model.plan(keepRecommendedIn: group)], "Keep Recommended Version")
        case .conflict:
            guard expanded.contains(group.key) else { expanded.insert(group.key); return }
            decide([model.plan(mergeIn: group)], "Merge Tags")
        }
    }

    // MARK: Context menu (CM-REV-GROUP)

    @ViewBuilder
    private func menu(for keys: Set<String>) -> some View {
        if keys.count == 1, let key = keys.first, let group = groups.first(where: { $0.key == key }) {
            if group.kind == .conflict {
                Button("Apply Merge") { decide([model.plan(mergeIn: group)], "Merge Tags") }
            } else {
                Button("Keep Recommended") { decide([model.plan(keepRecommendedIn: group)], "Keep Recommended Version") }
            }
            Button(expanded.contains(group.key) ? "Hide Comparison" : "Show Comparison") { toggle(group.key) }
            Divider()
            Button("Show Versions in All Tracks") {
                search?.show(SearchFilter(text: group.title, tokens: [.artist(group.artist)]), in: .allTracks)
            }
            .disabled(search == nil)
            Divider()
            if group.kind == .conflict {
                Button("Different Versions — Keep Both") { decide([model.plan(keepAllIn: group)], "Keep Different Versions") }
            } else {
                Button("Keep All — Not Duplicates") { decide([model.plan(keepAllIn: group)], "Keep All Versions") }
            }
            Divider()
            Menu("Copy") {
                Button("Title — Artist") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(group.title) — \(group.artist)", forType: .string)
                }
            }
        }
    }
}
