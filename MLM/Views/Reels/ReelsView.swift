import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// **Discover ▸ Reels** (V-REELS, DEC-029): master–detail inside the content column — the
/// videos on the left with a state word, the workbench of the selected one on the right. The
/// whole view is a drop target for `.mp4` / `.mov` files, folders and reel links, also when the
/// list is not empty (V-REELS.N02). Selecting a reel never starts work (V-REELS.E04).
struct ReelsView: View {
    @Environment(\.container) private var container
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?
    @Environment(UndoCenter.self) private var undo: UndoCenter?
    @Environment(ShellActions.self) private var shell: ShellActions?

    @State private var model: ReelsModel?

    var body: some View {
        Group {
            if let model {
                ReelsContent(model: model)
            } else {
                Color.clear
            }
        }
        .dropTarget(.reels, cornerRadius: 0, sayRefusal: { statusBar?.post($0) })
        .task { await setUp() }
        .onDisappear {
            if ReelsDropRouter.shared.model === model { ReelsDropRouter.shared.model = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task { await model?.refreshDownloads() }
        }
    }

    private func setUp() async {
        if model == nil, let dependencies = ReelsLive.dependencies(container, shell: shell) {
            model = ReelsModel(dependencies: dependencies)
        }
        guard let model else { return }
        model.statusBar = statusBar
        model.undo = undo
        ReelsDropRouter.shared.model = model
        await model.load()
    }
}

private struct ReelsContent: View {
    @Bindable var model: ReelsModel

    @State private var isChoosing = false
    @State private var isAddingLink = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .statusBarText(model.isLoaded && !model.items.isEmpty ? model.countLine : nil)
        .fileImporter(isPresented: $isChoosing, allowedContentTypes: [.movie, .folder], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { Task { await model.importURLs(urls) } }
        }
        .fileDialogMessage("Choose video files or a folder of videos.")
        .sheet(isPresented: $isAddingLink) { ReelLinkSheet(model: model) }
        .alert(
            ReelsModel.deleteTitle(count: model.pendingDeletion?.count ?? 0),
            isPresented: Binding(get: { model.pendingDeletion != nil }, set: { if !$0 { model.pendingDeletion = nil } }),
            presenting: model.pendingDeletion
        ) { ids in
            let plural = ids.count != 1
            Button("Cancel", role: .cancel) {}
            Button(plural ? "Delete Reels" : "Delete Reel", role: .destructive) {
                Task { await model.confirmDelete(ids, moveFilesToTrash: false) }
            }
            Button(plural ? "Delete Reels and Move Videos to Trash" : "Delete Reel and Move Video to Trash", role: .destructive) {
                Task { await model.confirmDelete(ids, moveFilesToTrash: true) }
            }
        } message: { _ in
            Text(ReelsModel.deleteMessage)
        }
    }

    // MARK: Header (V-REELS.E02, N01, N05)

    private var header: some View {
        HStack(spacing: Spacing.s) {
            Spacer(minLength: Spacing.s)
            Button("Import…") { isChoosing = true }
            Button("Add from Link…") { isAddingLink = true }
            Button("Delete Reel…") { model.requestDelete(model.selection) }
                .disabled(model.selection.isEmpty)
        }
        .padding(.horizontal, Spacing.l)
        .padding(.vertical, Spacing.xs)
        .background(.background)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError, model.items.isEmpty {
            ContentUnavailableView {
                Label("Can’t load the reels", systemImage: "exclamationmark.triangle")
            } description: {
                Text("The library database didn’t answer. Your videos are where they were; nothing was deleted.")
            } actions: {
                Button("Try Again") { Task { await model.load() } }
                Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        } else if !model.isLoaded {
            Color.clear
        } else if model.isEmpty {
            ContentUnavailableView {
                Label("No reels yet", systemImage: "video")
            } description: {
                Text("Save a short video whose music you want, then import it. MLM names the song from the audio, the file name and the text in the video, and finds it on your sources.")
                Text("You can also drop .mp4 or .mov files, folders or a link here.")
                    .font(.caption)
            } actions: {
                Button("Import…") { isChoosing = true }
                    .buttonStyle(.borderedProminent)
                Button("Add from Link…") { isAddingLink = true }
            }
        } else {
            HSplitView {
                ReelList(model: model)
                    .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                ReelWorkbench(model: model)
                    .frame(minWidth: 460)
            }
        }
    }
}

// MARK: - The list (V-REELS.E04, V-REELS.N09)

private struct ReelList: View {
    @Bindable var model: ReelsModel

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { model.setSelection($0) })) {
            ForEach(model.items) { item in
                ReelRow(item: item)
                    .tag(item.id)
                    .draggable(item.url)
            }
        }
        .listStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            ReelContextMenu(model: model, ids: ids)
        }
        .onDeleteCommand { model.requestDelete(model.selection) }
        // UC-KEY-01: Space on the Reels list plays the selected video.
        .onKeyPress(.space) {
            model.toggleVideo()
            return .handled
        }
        .accessibilityLabel("Reels")
    }
}

private struct ReelRow: View {
    let item: ReelItem

    var body: some View {
        HStack(spacing: Spacing.m) {
            ReelThumbnail(url: item.url)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.fileName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.guessLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Spacing.xs)
            Text(item.state.word)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Done reels stay listed, dimmed, until deleted.
        .opacity(item.state == .done ? 0.6 : 1)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.fileName), \(item.guessLine), \(item.state.word)")
    }
}

/// `Play Video — Identify Again · Mark as Done — Show in Finder · Copy ▸ — Delete Reel… ⌫`
/// (V-REELS.N09, UC §10).
private struct ReelContextMenu: View {
    let model: ReelsModel
    let ids: Set<String>

    var body: some View {
        let items = model.items.filter { ids.contains($0.id) }
        if !items.isEmpty {
            Section {
                Button("Play Video") { if let first = items.first { model.playVideo(first.id) } }
                    .disabled(items.count != 1 || model.dependencies.files.fileExists(atPath: items[0].url.path) == false)
            }
            Section {
                Button("Identify Again") {
                    Task { for item in items { await model.identify(item.id) } }
                }
                Button("Mark as Done") { Task { await model.markDone(ids) } }
                    .disabled(items.allSatisfy { $0.state == .done })
            }
            Section {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
                }
                .disabled(!items.contains { model.dependencies.files.fileExists(atPath: $0.url.path) })
                Menu("Copy") {
                    Button("Copy File Name") { copy(items.map(\.fileName).joined(separator: "\n")) }
                    Button("Copy File Path") { copy(items.map(\.url.path).joined(separator: "\n")) }
                    Button("Copy Artist and Title") {
                        copy(items.filter { !$0.artist.isEmpty || !$0.title.isEmpty }
                            .map { "\($0.artist) – \($0.title)" }.joined(separator: "\n"))
                    }
                    .disabled(!items.contains { !$0.artist.isEmpty || !$0.title.isEmpty })
                }
            }
            Section {
                Button("Delete Reel…", role: .destructive) { model.requestDelete(ids) }
                    .keyboardShortcut(.delete, modifiers: [])
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
