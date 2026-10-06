import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Window-level playlist requests (M3U panel, preview sheet, export)

extension View {
    /// The main window's M3U file panel (`Import M3U…`, `Import M3U into This Playlist…`), the
    /// preview sheet for a chosen or dropped `.m3u` (S-PLD-M3U-PREVIEW) and the M3U export
    /// panel — hosted once by the window, so choosing or dropping never navigates.
    func playlistWindowRequests() -> some View {
        modifier(PlaylistWindowRequests())
    }
}

private struct PlaylistWindowRequests: ViewModifier {
    @Bindable private var center = DropCenter.shared
    @Environment(SidebarModel.self) private var sidebar: SidebarModel?
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    func body(content: Content) -> some View {
        content
            .sheet(item: $center.m3uImport) { request in
                PlaylistM3UImportSheet(request: request)
            }
            .fileImporter(isPresented: $center.isChoosingM3U, allowedContentTypes: PlaylistM3U.contentTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    center.m3uChosen(url)
                }
            }
            .fileDialogMessage(chooseMessage)
            .fileExporter(isPresented: Binding(get: { center.m3uExport != nil }, set: { if !$0 { center.m3uExport = nil } }),
                          document: center.m3uExport?.document,
                          contentType: UTType(filenameExtension: "m3u8") ?? .plainText,
                          defaultFilename: center.m3uExport?.name) { result in
                exported(result)
            }
    }

    /// UC-SHEET-25: `Choose an M3U playlist to import into “‹playlist›”.`
    private var chooseMessage: String {
        if let id = center.m3uChoicePlaylistID, let name = sidebar?.playlistName(id) {
            return "Choose an M3U playlist to import into “\(name)”."
        }
        return "Choose an M3U playlist to import as a new playlist."
    }

    private func exported(_ result: Result<URL, Error>) {
        guard let request = center.m3uExport else { return }
        center.m3uExport = nil
        switch result {
        case .success(let url):
            var text = "Exported “\(request.name)” as “\(url.lastPathComponent)”"
            if request.leftOut > 0 {
                text += " — \(StatusBarText.count(request.leftOut, "track isn’t downloaded and was", "tracks aren’t downloaded and were")) left out"
            }
            statusBar?.post(text)
        case .failure(let error):
            statusBar?.post("Couldn’t export “\(request.name)” — \(error.localizedDescription)")
        }
    }
}

// MARK: - S-PLD-M3U-PREVIEW

/// The M3U preview (S-PLD-M3U-PREVIEW): title and first sentence say where the tracks go — into
/// the open playlist, appended, or into a new playlist named after the file (PP-PLAYLISTS-01
/// fixed: the file's name no longer chooses a playlist). Lists every entry with its result;
/// the primary button is named by its verb and count; the import is one undo step.
struct PlaylistM3UImportSheet: View {
    let request: DropCenter.M3UImport

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(ShellActions.self) private var shell: ShellActions?
    @Environment(SidebarModel.self) private var sidebar: SidebarModel?

    private enum Scope: Hashable { case all, add, present, notFound }

    @State private var plan: M3UImportPlan?
    @State private var destinationName: String?
    @State private var error: String?
    @State private var scope = Scope.all
    @State private var isApplying = false

    private var fileName: String { request.url.lastPathComponent }
    private var intoExisting: Bool { request.playlistID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text(M3UImportPlan.title(fileName: fileName, destination: intoExisting ? destinationName : nil))
                .font(.headline)
            if let plan {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(plan.summary(destination: intoExisting ? destinationName : nil))
                        .fontWeight(.semibold)
                    let skipped = plan.skippedText(intoExisting: intoExisting)
                    if !skipped.isEmpty {
                        Text(skipped).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                ScopeBar(items: [
                    ScopeBarItem(id: Scope.all, title: "All", count: plan.rows.count),
                    ScopeBarItem(id: Scope.add, title: "Will be added", count: plan.toAdd.count),
                    ScopeBarItem(id: Scope.present, title: intoExisting ? "Already in playlist" : "Listed twice",
                                 count: plan.alreadyPresent, hidesWhenEmpty: true),
                    ScopeBarItem(id: Scope.notFound, title: "Not found", count: plan.notFound.count, hidesWhenEmpty: true),
                ], selection: $scope, countNoun: .items, label: "Entries", publishesMenu: false)
                Table(rows(plan)) {
                    TableColumn("#") { row in
                        Text(row.id.formatted(.number)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(34)
                    TableColumn("Entry in the file") { row in
                        Text(row.entry).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary).help(row.entry)
                    }
                    TableColumn("Track in the library") { row in
                        Text(row.trackText ?? "—").foregroundStyle(row.trackText == nil ? .tertiary : .primary).lineLimit(1)
                    }
                    TableColumn("Result") { row in
                        Text(row.outcome.text).foregroundStyle(row.outcome == .willAdd ? .primary : .secondary)
                    }
                    .width(min: 150, ideal: 170)
                }
                .frame(minHeight: 220, idealHeight: 330)
            } else if error == nil {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("Reading “\(fileName)”…")
                }
            }
            if let error {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let plan, !plan.notFound.isEmpty {
                    Button("Copy Not-Found List") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(plan.notFoundList, forType: .string)
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(plan?.primaryTitle(intoExisting: intoExisting) ?? "Add Tracks") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.map { $0.toAdd.isEmpty } ?? true || isApplying)
            }
        }
        .padding(Spacing.xl)
        .frame(minWidth: 640, idealWidth: 720)
        .task(id: request.id) { await load() }
    }

    private func rows(_ plan: M3UImportPlan) -> [M3UImportPlan.Row] {
        switch scope {
        case .all: plan.rows
        case .add: plan.rows.filter { $0.outcome == .willAdd }
        case .present: plan.rows.filter { $0.outcome == .alreadyInPlaylist }
        case .notFound: plan.notFound
        }
    }

    private func load() async {
        guard let ingest = container.playlistIngestService, let playlists = container.playlistRepository else {
            error = "Couldn’t read “\(fileName)” — the library isn’t ready yet."
            return
        }
        var existing = Set<Int64>()
        if let id = request.playlistID {
            guard let playlist = try? await playlists.fetch(id: id) else {
                error = "The playlist no longer exists. Its tracks are still in the library."
                return
            }
            destinationName = playlist.name
            existing = Set(((try? await playlists.fetchTracks(playlistId: id)) ?? []).compactMap(\.id))
        }
        do {
            plan = try await PlaylistM3U.plan(url: request.url, ingest: ingest, existing: existing)
        } catch {
            self.error = "Couldn’t read “\(fileName)” — it isn’t a readable M3U file."
        }
    }

    private func apply() {
        guard let plan, let edits = shell?.edits else { return }
        isApplying = true
        let request = self.request
        let name = destinationName ?? plan.playlistName
        dismiss()
        Task {
            if let id = request.playlistID {
                await edits.importM3U(plan, intoPlaylist: id, name: name)
            } else {
                await edits.importM3UAsNewPlaylist(plan, named: plan.playlistName, inFolder: request.folderID)
            }
        }
    }
}
