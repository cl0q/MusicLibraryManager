import SwiftUI

/// Sidebar nested-disclosure subcomponent listing pinned playlists
/// (Plan 36-04, decisions D-07/D-08/D-09/D-11).
///
/// Renders as the body of a `DisclosureGroup` nested under the "Playlists"
/// sidebar row. The disclosure's label-row stays tagged with the parent
/// `topLevelSection` (typically `.playlists`) so clicking the label still
/// opens the grid; the child rows tag themselves with
/// `SidebarSection.playlistDetail(id)` so a click flows through the existing
/// `List(selection:)` binding straight into `ContentView.detailView`'s
/// `case .playlistDetail(let id)` route — direct to `PlaylistDetailView`
/// with no grid intermediary (D-09 Apple-Music sidebar behaviour).
///
/// **Inline rename (D-11)** — "Funktional vollständig, keine künstliche Minimal-Variante":
/// selecting *Rename…* from the per-row context menu flips that row into a
/// focused `TextField`. `.onSubmit` (Enter) commits via
/// `playlistRepository.rename(id:name:)` and posts `.playlistDidChange`,
/// `.onExitCommand` (Escape) cancels. No grid round-trip — the entire rename
/// UX is sidebar-resident, matching how Unpin and Delete also act in-place
/// from the same context menu.
///
/// **Empty state** — when no playlists are pinned, the disclosure body shows
/// a single muted italic caption "No pinned playlists" with `.disabled(true)`
/// so it never enters the selection binding.
///
/// **Refresh observer** — `.task` does the initial load; an
/// `.onReceive(.playlistDidChange)` re-runs `loadPinned()` so Plan 03's
/// `togglePin` emission, Plan 02's `PlaylistCoverService` regen post, and
/// the inline rename here all surface within one update cycle.
struct PinnedPlaylistsDisclosure: View {
    let topLevelLabel: String
    let topLevelIcon: String
    let topLevelSection: SidebarSection
    let onUnpin: (Int64) -> Void
    let onDelete: (Int64) -> Void
    let onRevealInGrid: () -> Void

    @AppStorage("sidebar.pinnedPlaylists.expanded") private var pinnedExpanded = true
    @Environment(\.container) private var container

    @State private var pinnedPlaylists: [Playlist] = []

    // Inline-rename state (D-11). All local — no shared plumbing needed.
    @State private var renamingId: Int64?
    @State private var renameText: String = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        DisclosureGroup(isExpanded: $pinnedExpanded) {
            if pinnedPlaylists.isEmpty {
                Text("No pinned playlists")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .italic()
                    .padding(.vertical, 4)
                    .padding(.leading, 16)
                    .disabled(true)
            } else {
                ForEach(pinnedPlaylists.prefix(8)) { pl in
                    pinnedRow(for: pl)
                }
            }
        } label: {
            Label(topLevelLabel, systemImage: topLevelIcon)
                .tag(topLevelSection)   // label-click still selects .playlists (grid)
        }
        .task { await loadPinned() }
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { _ in
            Task { await loadPinned() }
        }
    }

    // MARK: - Row (inline rename vs. label)

    @ViewBuilder
    private func pinnedRow(for pl: Playlist) -> some View {
        if renamingId == pl.id, let pid = pl.id {
            // Rename mode (D-11) — TextField in place of the Label.
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                    .foregroundColor(.mlmInkSecondary)
                TextField("", text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .focused($renameFocused)
                    .onSubmit { Task { await commitRename(id: pid) } }
                    .onExitCommand { cancelRename() }    // Esc cancels
                    .onAppear { renameFocused = true }
            }
            // Intentionally NOT tagged — prevents the row from swallowing
            // selection while the user is typing.
            .contextMenu {
                Button("Cancel") { cancelRename() }
            }
        } else {
            // Normal mode — selectable Label tagged for direct-to-detail routing.
            Label(pl.name, systemImage: "music.note.list")
                .lineLimit(1)
                .truncationMode(.tail)
                .tag(SidebarSection.playlistDetail(pl.id ?? -1))
                .contextMenu { contextMenu(for: pl) }
                .help(pl.name)
        }
    }

    // MARK: - Pinned-row context menu (D-11)

    @ViewBuilder
    private func contextMenu(for pl: Playlist) -> some View {
        Button("Unpin from Sidebar") {
            if let pid = pl.id { onUnpin(pid) }
        }
        Button("Rename…") {
            if let pid = pl.id { startRename(id: pid, currentName: pl.name) }
        }
        Divider()
        Button("Reveal in Grid") {
            onRevealInGrid()
        }
        Divider()
        Button("Delete", role: .destructive) {
            if let pid = pl.id { onDelete(pid) }
        }
    }

    // MARK: - Rename helpers (D-11 inline)

    private func startRename(id: Int64, currentName: String) {
        renamingId = id
        renameText = currentName
        // Focus is set in pinnedRow's .onAppear once the TextField materialises.
    }

    private func commitRename(id: Int64) async {
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reject empty or unchanged names — close edit silently.
        guard !trimmed.isEmpty,
              let current = pinnedPlaylists.first(where: { $0.id == id })?.name,
              trimmed != current else {
            cancelRename()
            return
        }
        do {
            try await container.playlistRepository?.rename(id: id, name: trimmed)
            NotificationCenter.default.post(name: .playlistDidChange, object: nil)
        } catch {
            // Silent-fail on rename collision / DB error; row reverts on next loadPinned().
        }
        renamingId = nil
        renameText = ""
        renameFocused = false
    }

    private func cancelRename() {
        renamingId = nil
        renameText = ""
        renameFocused = false
    }

    // MARK: - Loading

    private func loadPinned() async {
        guard let repo = container.playlistRepository else { return }
        let all = (try? await repo.fetchAll()) ?? []
        pinnedPlaylists = all
            .filter { $0.isPinned == 1 }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
