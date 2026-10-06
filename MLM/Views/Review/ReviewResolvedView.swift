import SwiftUI

/// Review ▸ Resolved (V-REV.E09, DEC-041): the decisions made — date, kind, group, what happened
/// — and `Restore`, which puts the group back into its tab and undoes hiding, re-pointing, tag
/// changes and (while the files are still there) the Trash move. A decision from before
/// decisions were recorded has nothing to restore from.
struct ReviewResolvedView: View {
    let model: ReviewModel
    let statusBar: StatusBarCenter?
    let search: ToolbarSearchModel?

    @State private var selection: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            Text("Decisions you made. They are remembered by every later scan. Restore puts a group back into its tab; versions that went to the Trash are put back if they are still there.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.s)
                .background(.background)
            Divider()
            let rows = model.visibleResolved
            if model.resolved.isEmpty {
                ContentUnavailableView {
                    Label("Nothing decided yet", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Decisions you make in Duplicates and Conflicts appear here.")
                }
            } else if rows.isEmpty {
                ContentUnavailableView {
                    Label("No results", systemImage: "magnifyingglass")
                } description: {
                    Text("No decision matches the search.")
                } actions: {
                    Button("Clear Filters") { search?.clear() }
                }
            } else {
                table(rows)
            }
        }
    }

    private func table(_ rows: [ReviewResolvedRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("Date") { row in
                Text(row.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 110, ideal: 140, max: 190)
            TableColumn("Kind") { row in
                Text(ReviewPresentation.kindWord(row.kind)).foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 80, max: 110)
            TableColumn("Group") { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text(row.groupName).lineLimit(1)
                    if !row.artist.isEmpty {
                        Text(row.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .width(min: 140, ideal: 240)
            TableColumn("Decision") { row in
                Text(row.decision).lineLimit(1)
            }
            .width(min: 100, ideal: 130, max: 170)
            TableColumn("Outcome") { row in
                Text(row.outcome).foregroundStyle(.secondary).lineLimit(2)
            }
            .width(min: 200, ideal: 420)
            TableColumn("") { row in
                Button("Restore") {
                    Task { await model.restore(row, statusBar: statusBar) }
                }
                .controlSize(.small)
                .disabled(!row.canRestore)
                .help(row.canRestore ? "" : "Earlier decision cannot be restored")
            }
            .width(min: 70, ideal: 80, max: 90)
        }
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: String.self) { keys in
            menu(for: keys, rows: rows)
        }
        .accessibilityIdentifier("review_resolved")
    }

    @ViewBuilder
    private func menu(for keys: Set<String>, rows: [ReviewResolvedRow]) -> some View {
        if keys.count == 1, let key = keys.first, let row = rows.first(where: { $0.key == key }) {
            Button("Restore") { Task { await model.restore(row, statusBar: statusBar) } }
                .disabled(!row.canRestore)
            Divider()
            // Hidden versions are not listed (IMP-049): there is nothing to show there.
            Button("Show Versions in All Tracks") {
                search?.show(SearchFilter(text: row.title, tokens: row.artist.isEmpty ? [] : [.artist(row.artist)]), in: .allTracks)
            }
            .disabled(true)
            .help("Hidden versions don’t appear in All Tracks")
            Divider()
            Menu("Copy") {
                Button("Title — Artist") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("\(row.title) — \(row.artist)", forType: .string)
                }
            }
        }
    }
}
