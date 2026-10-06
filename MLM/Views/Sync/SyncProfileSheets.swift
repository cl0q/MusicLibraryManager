import SwiftUI
import UniformTypeIdentifiers

// MARK: - S-SYNC-DESTINATION

/// Change Destination…: says the consequence before it happens; the plan is computed again for
/// the new destination and nothing is deleted on the old one.
struct ChangeDestinationSheet: View {
    let profile: SyncProfile

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var destination: String
    @State private var isChoosingFolder = false

    init(profile: SyncProfile) {
        self.profile = profile
        _destination = State(initialValue: profile.outputFolder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    LabeledContent {
                        Button("Choose…") { isChoosingFolder = true }
                    } label: {
                        Text(destination.isEmpty ? "No destination chosen" : destination)
                            .monospaced()
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } footer: {
                    Text("Files already copied to the old destination stay there. The plan is computed again for the new destination, so the next sync may copy everything.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Change Destination") {
                    let path = destination
                    Task { await container.syncViewModel?.changeDestination(profile.id ?? -1, to: path) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination.isEmpty || destination == profile.outputFolder)
            }
            .padding(Spacing.l)
        }
        .frame(width: 460)
        .navigationTitle("Change Destination of “\(profile.name)”")
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { destination = url.path }
        }
        .fileDialogMessage("Choose the folder or disk to sync to.")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            destination = url.path
            return true
        }
    }
}

// MARK: - S-SYNC-PLAYLISTPICKER + track picker

/// Add to “‹profile›”: Playlists or Tracks, multi-select with search; items already in the
/// profile are marked and can't be chosen again. Return = Add, Esc = Cancel. Albums join with
/// W4 (no albums exist yet). The track list is a plain read-only list of the library search.
struct SyncAddContentSheet: View {
    let profile: SyncProfile
    @State var kind: SyncPresenter.AddKind

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var playlistModel = PlaylistPickerModel(allPlaylists: [], includedIDs: [])
    @State private var playlistsLoaded = false
    @State private var loadFailed = false
    @State private var trackResults: [Track] = []
    @State private var trackTotal = 0
    @State private var includedTracks: Set<Int64> = []
    @State private var selectedTracks: Set<Int64> = []

    init(profile: SyncProfile, initialKind: SyncPresenter.AddKind) {
        self.profile = profile
        _kind = State(initialValue: initialKind)
    }

    var body: some View {
        VStack(spacing: Spacing.m) {
            HStack {
                Picker("Add", selection: $kind) {
                    Text("Playlists").tag(SyncPresenter.AddKind.playlists)
                    Text("Tracks").tag(SyncPresenter.AddKind.tracks)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            Group {
                switch kind {
                case .playlists: playlistList
                case .tracks: trackList
                }
            }
            .frame(minHeight: 320)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(addTitle) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(addCount == 0)
            }
        }
        .padding(Spacing.l)
        .frame(width: 480, height: 480)
        .navigationTitle("Add to “\(profile.name)”")
        .task { await loadPlaylists() }
        .task(id: "\(kind.rawValue)|\(search)") { await searchTracks() }
        .onChange(of: search) { _, value in playlistModel.searchQuery = value }
    }

    private var addCount: Int {
        kind == .playlists ? playlistModel.commitIDs.count : selectedTracks.subtracting(includedTracks).count
    }

    /// `Add 2 Playlists` / `Add 3 Tracks` (UC-SHEET-03).
    private var addTitle: String {
        let n = addCount
        guard n > 0 else { return "Add" }
        return kind == .playlists
            ? "Add \(n.formatted(.number)) \(n == 1 ? "Playlist" : "Playlists")"
            : "Add \(n.formatted(.number)) \(n == 1 ? "Track" : "Tracks")"
    }

    @ViewBuilder
    private var playlistList: some View {
        if loadFailed {
            ContentUnavailableView("Can’t load the playlists", systemImage: "music.note.list",
                                   description: Text("Try again after the library finishes loading."))
        } else if playlistsLoaded && playlistModel.rows.isEmpty {
            if search.isEmpty {
                ContentUnavailableView("No playlists", systemImage: "music.note.list",
                                       description: Text("Create one first, then add it to this sync profile."))
            } else {
                ContentUnavailableView.search(text: search)
            }
        } else {
            List(playlistModel.rows) { row in
                Button {
                    playlistModel.toggle(row.id)
                } label: {
                    HStack {
                        Image(systemName: row.isIncluded || row.isSelected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(row.isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Label(row.playlist.name, systemImage: row.playlist.isLiked == 1 ? "heart" : "music.note.list")
                        Spacer()
                        if row.isIncluded {
                            Text("In profile").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(row.isIncluded ? .tertiary : .primary)
                .disabled(row.isIncluded)
            }
            .listStyle(.inset)
            .redacted(reason: playlistsLoaded ? [] : .placeholder)
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if search.trimmingCharacters(in: .whitespaces).isEmpty {
            ContentUnavailableView {
                Label("Find tracks", systemImage: "magnifyingglass")
            } description: {
                Text("Type to find tracks by title, artist or album. Faster: select tracks anywhere and drag them onto “\(profile.name)” in the sidebar, or choose Add to Sync Profile ▸.")
            }
        } else if trackResults.isEmpty {
            ContentUnavailableView.search(text: search)
        } else {
            List(trackResults, id: \.id) { track in
                let id = track.id ?? -1
                let included = includedTracks.contains(id)
                let selected = selectedTracks.contains(id)
                Button {
                    if selected { selectedTracks.remove(id) } else { selectedTracks.insert(id) }
                } label: {
                    HStack {
                        Image(systemName: included || selected ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).lineLimit(1)
                            Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if included { Text("In profile").foregroundStyle(.secondary) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(included ? .tertiary : .primary)
                .disabled(included)
            }
            .listStyle(.inset)
            if trackTotal > trackResults.count {
                Text("Showing \(trackResults.count.formatted(.number)) of \(trackTotal.formatted(.number)) — type more to narrow the list.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadPlaylists() async {
        guard let id = profile.id, let playlists = container.playlistRepository,
              let sync = container.syncRepository else {
            loadFailed = true
            return
        }
        do {
            let all = try await playlists.fetchAll()
            let included = Set(try await sync.fetchProfilePlaylists(profileId: id).compactMap(\.id))
            includedTracks = Set(try await sync.fetchProfileTracks(profileId: id).compactMap(\.id))
            playlistModel = PlaylistPickerModel(allPlaylists: all, includedIDs: included)
            playlistModel.searchQuery = search
            playlistsLoaded = true
        } catch {
            loadFailed = true
        }
    }

    private func searchTracks() async {
        guard kind == .tracks, let queries = TrackSearchQueries.current(container) else { return }
        let text = search.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            trackResults = []
            return
        }
        try? await Task.sleep(for: .milliseconds(200))
        guard !Task.isCancelled,
              let found = try? await queries.matchingTracks(filter: SearchFilter(text: text), limit: 200) else { return }
        trackResults = found.tracks
        trackTotal = found.total
    }

    private func add() {
        guard let vm = container.syncViewModel else { return }
        let profile = self.profile
        switch kind {
        case .playlists:
            let ids = playlistModel.commitIDs
            Task { await vm.addPlaylists(ids, to: profile) }
        case .tracks:
            let order = trackResults.compactMap(\.id)
            let ids = order.filter { selectedTracks.contains($0) && !includedTracks.contains($0) }
            Task { await vm.addTracks(ids, to: profile) }
        }
        dismiss()
    }
}

// MARK: - S-SYNC-INGESTPREVIEW (merged with S-SYNC-DEVICEINGEST)

/// Read Playlist Changes from Device: changed playlists on the left with their diff in words,
/// the selected playlist's entries with checkboxes on the right. Apply merges and is one undo
/// step; a card that fails keeps its error, the others stay visible.
struct DeviceChangesSheet: View {
    @Bindable var model: DevicePlaylistChangesModel

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Read Playlist Changes from Device")
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            content
                .frame(minHeight: 320)
            HStack {
                Text("Apply merges the checked changes into your playlists. You can undo it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    model.cancelScan()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button(model.applyTitle) { apply() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canApply)
            }
        }
        .padding(Spacing.l)
        .frame(width: 760, height: 520)
    }

    private var subtitle: String {
        let from = "From “\(model.profile.name)” — \(model.profile.outputFolder)"
        return model.phase == .loaded && !model.cards.isEmpty ? "\(from) · \(model.headline)" : from
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .scanning(let done, let total):
            VStack(spacing: Spacing.s) {
                if total > 0 {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("Reading playlists on “\(model.profile.name)”… \(done.formatted(.number)) of \(total.formatted(.number))")
                } else {
                    ProgressView()
                    Text("Reading playlists on “\(model.profile.name)”…")
                }
            }
            .frame(maxWidth: 360, maxHeight: .infinity)
            .frame(maxWidth: .infinity)
        case .notConnected:
            ContentUnavailableView("“\(model.deviceName)” is not connected", systemImage: "eject",
                                   description: Text("Connect it to read the playlist changes made on it."))
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn’t read the playlists", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { model.scan() }
            }
        case .loaded:
            if model.cards.isEmpty {
                ContentUnavailableView("No playlist changes on the device", systemImage: "checkmark.circle",
                                       description: Text(model.unreadable.isEmpty
                                                         ? "The playlists on the device match MLM."
                                                         : "\(StatusBarText.count(model.unreadable.count, "playlist file", "playlist files")) couldn’t be read: \(model.unreadable.joined(separator: ", "))."))
            } else {
                HSplitView {
                    cardList
                        .frame(minWidth: 230, idealWidth: 250, maxWidth: 300)
                    detail
                        .frame(minWidth: 380)
                }
            }
        }
    }

    private var cardList: some View {
        List(selection: $model.selectedCardID) {
            ForEach(model.cards) { card in
                HStack(alignment: .top) {
                    Toggle(isOn: Binding(get: { model.selections[card.id]?.include ?? false },
                                         set: { model.setInclude(card.id, $0) })) { EmptyView() }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.target.name).lineLimit(1)
                        Text(card.summary).font(.subheadline).foregroundStyle(.secondary)
                        if let error = model.errors[card.id] {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .tag(card.id)
            }
            if model.unchangedCount > 0 {
                Text("\(StatusBarText.playlists(model.unchangedCount)) \(model.unchangedCount == 1 ? "is" : "are") the same on the device and in MLM.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var detail: some View {
        if let id = model.selectedCardID, let card = model.cards.first(where: { $0.id == id }),
           let selection = model.selections[id] {
            List {
                Section {
                    LabeledContent(card.target.name) {
                        Text(card.isNew ? "New playlist · \(StatusBarText.tracks(selection.added.count))"
                                        : "\(StatusBarText.tracks(card.mlm.count)) in MLM")
                            .foregroundStyle(.secondary)
                    }
                }
                if !(card.isNew ? card.device : card.diff.added).isEmpty {
                    Section(card.isNew ? "On the device" : "Added on the device") {
                        ForEach(card.isNew ? card.device : card.diff.added, id: \.self) { trackID in
                            entry(card, trackID, sign: "+", isOn: selection.added.contains(trackID)) {
                                model.toggle(card.id, added: trackID)
                            }
                        }
                    }
                }
                if !card.diff.removed.isEmpty {
                    Section("Removed on the device") {
                        ForEach(card.diff.removed, id: \.self) { trackID in
                            entry(card, trackID, sign: "−", isOn: selection.removed.contains(trackID)) {
                                model.toggle(card.id, removed: trackID)
                            }
                        }
                    }
                }
                if card.diff.orderDiffers && !card.isNew {
                    Section("Order") {
                        Toggle("Use the device’s order for this playlist",
                               isOn: Binding(get: { selection.useDeviceOrder }, set: { model.setUseDeviceOrder(card.id, $0) }))
                            .toggleStyle(.checkbox)
                    }
                }
                if !card.unmatched.isEmpty {
                    Section("Not matched") {
                        ForEach(card.unmatched, id: \.self) { item in
                            Label {
                                Text("\(item.path) — \(item.reason)")
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                            }
                        }
                    }
                }
                if let kept = card.keptSentence {
                    Section("Only in MLM — kept") {
                        Text(kept).foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
        } else {
            ContentUnavailableView("Select a playlist", systemImage: "music.note.list")
        }
    }

    private func entry(_ card: DevicePlaylistCard, _ trackID: Int64, sign: String, isOn: Bool,
                       toggle: @escaping () -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
            HStack {
                Text(sign).foregroundStyle(.secondary).frame(width: 12)
                Text(card.labels[trackID]?.text ?? "Track").lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func apply() {
        let edits = ShellEdits(dependencies: .live(container), undo: .main, window: .main)
        Task {
            if await model.apply(edits: edits) { dismiss() }
        }
    }
}
