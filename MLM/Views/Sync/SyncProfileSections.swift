import AppKit
import SwiftUI

/// A row of the Content section: a playlist or a track added one by one.
enum SyncContentRowID: Hashable {
    case playlist(Int64)
    case track(Int64)
}

/// The profile page body: one list with the sections Content · Plan · Options · Last sync
/// (`sync.html`). ⌫ removes the selected content without asking (undoable, DEC-050).
struct SyncProfileSections: View {
    let vm: SyncViewModel
    let profile: SyncProfile
    let state: SyncProfileState

    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation
    @Environment(ShellActions.self) private var actions: ShellActions?
    @Environment(\.openSettings) private var openSettings
    @State private var selection: Set<SyncContentRowID> = []
    @State private var showsAllAdds = false
    @State private var failedTracks: [Int64: Track] = [:]

    private var id: Int64 { profile.id ?? -1 }
    private var content: SyncProfileContent { vm.contents[id] ?? SyncProfileContent() }
    private var deviceName: String { SyncDestination.deviceName(for: profile.outputFolder) }

    var body: some View {
        List(selection: $selection) {
            contentSection
            planSection
            optionsSection
            lastSyncSection
        }
        .listStyle(.inset)
        .onDeleteCommand { removeSelection() }
        .contextMenu(forSelectionType: SyncContentRowID.self) { ids in
            contentMenu(ids)
        } primaryAction: { ids in
            open(ids)
        }
        .task(id: vm.results[id]?.failures.map(\.trackID) ?? []) { await loadFailedTracks() }
    }

    // MARK: Content

    @ViewBuilder
    private var contentSection: some View {
        Section {
            sectionSubheader("Playlists", count: content.playlists.count, add: .playlists)
            if content.playlists.isEmpty {
                Text("No playlists — press Add… or drag playlists onto “\(profile.name)” in the sidebar.")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                    .dropTarget(.syncProfile(id: id, name: profile.name))
            }
            ForEach(content.playlists) { item in
                HStack {
                    Label(item.playlist.name, systemImage: item.playlist.isLiked == 1 ? "heart" : "music.note.list")
                        .lineLimit(1)
                    Spacer()
                    if item.notDownloaded > 0 {
                        Label("Not downloaded · \(StatusBarText.tracks(item.notDownloaded))", systemImage: "icloud")
                            .foregroundStyle(.secondary)
                    }
                    Text(StatusBarText.tracks(item.trackCount))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(SyncContentRowID.playlist(item.id))
            }
            sectionSubheader("Tracks", count: content.tracks.count, add: .tracks,
                             caption: content.tracks.isEmpty ? nil : "added individually")
            if content.tracks.isEmpty {
                Text("No tracks — press Add…, or select tracks anywhere and choose Add to Sync Profile ▸ “\(profile.name)”.")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                    .dropTarget(.syncProfile(id: id, name: profile.name))
            }
            ForEach(content.tracks, id: \.id) { track in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title).lineLimit(1)
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let word = availabilityWord(track) {
                        Text(word).foregroundStyle(.secondary)
                    }
                    Text(PlaybackWords.time(TimeInterval(track.duration ?? 0)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .tag(SyncContentRowID.track(track.id ?? -1))
            }
        } header: {
            HStack {
                Text("Content")
                Spacer()
                if let total = vm.plans[id]?.preview?.totalTracks, total > 0 {
                    Text("\(StatusBarText.tracks(total)) in all · a track in several playlists is copied once")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .dropTarget(.syncProfile(id: id, name: profile.name))
        }
    }

    private func sectionSubheader(_ title: String, count: Int, add kind: SyncPresenter.AddKind, caption: String? = nil) -> some View {
        HStack {
            Text(title).bold()
            if count > 0 {
                Text(caption.map { "\(count.formatted(.number)) \($0)" } ?? count.formatted(.number))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Add…") { vm.presenter.adding = .init(profile: profile, kind: kind) }
        }
        .selectionDisabled()
        .dropTarget(.syncProfile(id: id, name: profile.name))
    }

    private func availabilityWord(_ track: Track) -> String? {
        switch track.availability() {
        case .local: nil
        case .downloading: "Downloading…"
        case .notDownloaded: "Not downloaded"
        case .failed: "Download failed"
        case .fileMissing: "File missing"
        }
    }

    @ViewBuilder
    private func contentMenu(_ ids: Set<SyncContentRowID>) -> some View {
        let playlistIDs = ids.compactMap { if case .playlist(let id) = $0 { id } else { nil } }
        let trackIDs = Set(ids.compactMap { if case .track(let id) = $0 { id } else { nil } })
        let tracks = content.tracks.filter { $0.id.map(trackIDs.contains) ?? false }
        if !ids.isEmpty {
            if ids.count > 1 {
                Text(playlistIDs.isEmpty ? StatusBarText.tracks(ids.count)
                     : trackIDs.isEmpty ? StatusBarText.playlists(ids.count) : "\(ids.count.formatted(.number)) items")
            }
            // CM-SYNC-PLROW / CM-SYNC-TRACKROW (the track menu without Fix).
            Section {
                if ids.count == 1, let playlistID = playlistIDs.first {
                    Button("Open") { navigation.select(.playlist(playlistID)) }
                }
                if !tracks.isEmpty {
                    Button("Play") { play(tracks) }
                }
            }
            if !tracks.isEmpty {
                Section {
                    Button("Play Next") { TrackCommandActions.playNext(tracks, container: container) }
                    Button("Add to Queue") { TrackCommandActions.addToQueue(tracks, container: container) }
                }
            }
            let others = vm.profiles.filter { $0.id != profile.id }
            if !others.isEmpty {
                Section {
                    Menu("Add to Sync Profile") {
                        ForEach(others) { other in
                            Button(other.name) {
                                Task {
                                    if !playlistIDs.isEmpty { await vm.addPlaylists(playlistIDs, to: other) }
                                    if !trackIDs.isEmpty { await vm.addTracks(Array(trackIDs), to: other) }
                                }
                            }
                        }
                    }
                }
            }
            if tracks.count == 1 {
                Section {
                    Button("Get Info") {
                        NotificationCenter.default.post(name: .openTrackDetailForTrack, object: nil,
                                                        userInfo: ["trackId": tracks[0].id ?? -1])
                    }
                }
            }
            let notDownloaded = content.playlists.filter { playlistIDs.contains($0.id) }.reduce(0) { $0 + $1.notDownloaded }
            if notDownloaded > 0 {
                Section {
                    Button("Download Not-Downloaded Tracks") { downloadPlaylists(playlistIDs) }
                }
            }
            if tracks.contains(where: \.isLocal) {
                Section {
                    Button("Show in Finder") { TrackCommandActions.showInFinder(tracks, container: container) }
                }
            }
            Section {
                Button("Remove from “\(profile.name)”") { remove(ids) }
            }
        }
    }

    private func open(_ ids: Set<SyncContentRowID>) {
        guard ids.count == 1, let first = ids.first else { return }
        switch first {
        case .playlist(let playlistID): navigation.select(.playlist(playlistID))
        case .track(let trackID):
            if let track = content.tracks.first(where: { $0.id == trackID }) { play([track]) }
        }
    }

    private func play(_ tracks: [Track]) {
        guard let first = tracks.first else { return }
        actions?.activateTrack?(first, content.tracks)
    }

    private func removeSelection() {
        remove(selection)
    }

    private func remove(_ ids: Set<SyncContentRowID>) {
        let playlistIDs = Set(ids.compactMap { if case .playlist(let id) = $0 { id } else { nil } })
        let trackIDs = Set(ids.compactMap { if case .track(let id) = $0 { id } else { nil } })
        selection.subtract(ids)
        Task {
            if !playlistIDs.isEmpty { await vm.removePlaylists(playlistIDs, from: profile) }
            if !trackIDs.isEmpty { await vm.removeTracks(trackIDs, from: profile) }
        }
    }

    private func downloadPlaylists(_ playlistIDs: [Int64]) {
        guard let repository = container.playlistRepository else { return }
        Task {
            var tracks: [Track] = []
            for playlistID in playlistIDs {
                tracks += (try? await repository.fetchTracks(playlistId: playlistID)) ?? []
            }
            download(tracks.filter { $0.availability().isDownloadable })
        }
    }

    private func download(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        _ = TrackCommandActions.download(tracks, container: container)
        ShellWindowModels.main.statusBar?.post("Download started — \(StatusBarText.tracks(tracks.count)) · the plan updates when they are ready")
    }

    // MARK: Plan

    @ViewBuilder
    private var planSection: some View {
        Section {
            let entry = vm.plans[id]
            if (vm.contentCounts[id] ?? 0) == 0 {
                Text("Nothing to plan yet. The plan appears as soon as the profile has content.")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            } else {
                HStack {
                    if entry?.isUpdating == true {
                        ProgressView().controlSize(.small)
                        Text(entry?.progress.map { "Updating plan… \($0.done.formatted(.number)) of \($0.total.formatted(.number))" } ?? "Updating plan…")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Button("Cancel") { vm.cancelPlanUpdate(id) }
                            .buttonStyle(.link)
                    } else if let status = state.planStatus {
                        Text(status).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if state.isConnected {
                        Button("Recompute") { vm.recomputePlan(id) }
                            .help("Compare the profile with the device again (⌘R)")
                            .disabled(entry?.isUpdating == true)
                    }
                }
                .selectionDisabled()
                if let error = entry?.error {
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .symbolRenderingMode(.multicolor)
                        Spacer()
                        Button("Try Again") { vm.recomputePlan(id) }
                    }
                    .selectionDisabled()
                }
                if let sentence = state.planSentence {
                    Text(sentence)
                        .font(.title3)
                        .monospacedDigit()
                        .selectionDisabled()
                        .opacity(entry?.isUpdating == true ? 0.55 : 1)
                }
                if let preview = entry?.preview, !vm.libraryDrive().isOffline {
                    planLists(preview)
                }
            }
        } header: {
            Text("Plan")
        }
    }

    @ViewBuilder
    private func planLists(_ preview: SyncService.PreviewResult) -> some View {
        if !preview.filesToSkip.isEmpty {
            DisclosureGroup(isExpanded: .constant(true)) {
                ForEach(preview.filesToSkip) { file in
                    skipRow(file)
                }
            } label: {
                HStack {
                    Text("Skip \(preview.filesToSkip.count.formatted(.number))").bold()
                    Text("can’t be copied until fixed").foregroundStyle(.secondary)
                    Spacer()
                    let downloadable = preview.filesToSkip.filter { $0.reason == .notDownloaded || $0.reason == .downloadFailed }
                    if !downloadable.isEmpty {
                        Button("Download All \(downloadable.count.formatted(.number))") {
                            downloadSkipped(downloadable.map(\.trackId))
                        }
                    }
                }
            }
            .selectionDisabled()
        }
        if !preview.filesToAdd.isEmpty {
            DisclosureGroup {
                let shown = showsAllAdds ? preview.filesToAdd : Array(preview.filesToAdd.prefix(100))
                ForEach(shown) { file in fileRow(file) }
                if !showsAllAdds && preview.filesToAdd.count > shown.count {
                    Button("Show All \(preview.filesToAdd.count.formatted(.number))") { showsAllAdds = true }
                        .buttonStyle(.link)
                }
            } label: {
                HStack {
                    Text("Add \(preview.filesToAdd.count.formatted(.number))").bold()
                    Text("\(SyncProfileState.bytes(preview.totalNewSize)) · \(formatWords)").foregroundStyle(.secondary)
                }
            }
            .selectionDisabled()
        }
        if preview.playlistsToUpdate > 0 {
            HStack {
                Text(SyncProfileState.playlistsText(preview.playlistsToUpdate)).bold()
                Text("playlist files on the device are rewritten — no tracks are copied for them").foregroundStyle(.secondary)
            }
        }
        if !preview.filesToRemove.isEmpty {
            DisclosureGroup {
                ForEach(preview.filesToRemove.prefix(500)) { file in fileRow(file) }
            } label: {
                HStack {
                    Text("Remove \(preview.filesToRemove.count.formatted(.number))").bold()
                    Text(profile.cleanupRemovedFiles
                         ? "no longer in this profile · deleted from the device when it has no Trash"
                         : "Clean up is off — nothing is deleted from the device")
                        .foregroundStyle(.secondary)
                }
            }
            .selectionDisabled()
        }
    }

    private var formatWords: String {
        switch profile.transcodeModeEnum {
        case .keepOriginals: "copied as they are"
        case .aac248: "converted to AAC 248 kbps where needed"
        case .aac320: "converted to AAC 320 kbps where needed"
        }
    }

    private func fileRow(_ file: SyncService.FilePreview) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(file.artist.isEmpty ? file.title : "\(file.artist) — \(file.title)").lineLimit(1)
                Text(file.destinationPath)
                    .font(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if file.size > 0 {
                Text(SyncProfileState.bytes(file.size)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .contextMenu {
            // CM-SYNC-PREVIEWFILE.
            Button("Show Library File in Finder") { withTrack(file.trackId) { TrackCommandActions.showInFinder([$0], container: container) } }
            if FileManager.default.fileExists(atPath: file.destinationPath) {
                Button("Show on Device in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.destinationPath)])
                }
            }
        }
    }

    private func skipRow(_ file: SyncService.SkippedFile) -> some View {
        HStack {
            Text(file.artist.isEmpty ? file.title : "\(file.artist) — \(file.title)").lineLimit(1)
            Spacer()
            Text(file.reason.word).foregroundStyle(.secondary)
            switch file.reason {
            case .notDownloaded:
                Button("Download") { downloadSkipped([file.trackId]) }
            case .downloadFailed:
                Button("Retry Download") { downloadSkipped([file.trackId]) }
            case .fileMissing:
                Button("Locate…") { withTrack(file.trackId) { LocateFileRequest.shared.begin($0) } }
            case .libraryDriveAway:
                EmptyView()
            }
        }
    }

    private func downloadSkipped(_ ids: [Int64]) {
        guard let repository = container.trackRepository else { return }
        Task {
            let tracks = (try? await repository.fetchTracks(ids: Set(ids))) ?? []
            download(tracks.filter { $0.availability().isDownloadable })
        }
    }

    private func withTrack(_ trackID: Int64, _ body: @escaping (Track) -> Void) {
        guard let repository = container.trackRepository else { return }
        Task {
            if let track = try? await repository.fetchTrack(id: trackID) { body(track) }
        }
    }

    // MARK: Options

    @ViewBuilder
    private var optionsSection: some View {
        Section {
            SyncOptionsRows(vm: vm, profile: profile)
            if vm.isRockbox[id] == true, SyncDevicePreset.matching(profile) != .rockbox {
                HStack {
                    Text("Rockbox defaults: \(SyncDevicePreset.rockbox.summary).")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Device Defaults") { Task { await vm.applyPreset(.rockbox, to: id) } }
                }
                .selectionDisabled()
            }
            HStack {
                Text("How much of the Mac a sync may use is set once for all work in Settings ▸ Maintenance.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open Settings ▸ Maintenance") { openSettings(tab: .maintenance) }
                    .buttonStyle(.link)
            }
            .selectionDisabled()
        } header: {
            HStack {
                Text("Options")
                if vm.run(for: profile) != nil {
                    Text("Applies to the next sync").font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Last sync

    @ViewBuilder
    private var lastSyncSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.lastSyncLine)
                    if state.failedCount > 0 {
                        Text("The failures below belong to this profile and stay until they are fixed or the next sync.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else if let result = vm.results[id], result.outcome == .interrupted || result.outcome == .running,
                              vm.run(for: profile) == nil {
                        Text("Nothing is marked as failed; the tracks that weren’t copied are still in the plan.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if vm.results[id]?.operationID != nil || vm.run(for: profile) != nil {
                    Button("Show in Activity") { vm.showInActivity(profile) }
                        .buttonStyle(.link)
                }
            }
            .selectionDisabled()
            if state.failedCount > 0, let failures = vm.results[id]?.failures {
                ForEach(failures) { failure in failureRow(failure) }
            }
        } header: {
            HStack {
                Text("Last sync")
                Spacer()
                if state.failedCount > 0 {
                    Button("Retry Failed (\(state.failedCount.formatted(.number)))") { vm.retryFailed(profile) }
                        .disabled(vm.run(for: profile) != nil || !state.isConnected)
                        .help(state.isConnected ? "Copy the failed tracks again" : "Connect “\(deviceName)” to retry.")
                }
            }
        }
    }

    private func failureRow(_ failure: SyncResultFailure) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.title).lineLimit(1)
                Text(failure.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(SyncFailureReasonText.plain(failure.reason)).foregroundStyle(.secondary)
            Button("Retry") { vm.retryFailed(profile, trackIDs: [failure.trackID]) }
                .disabled(vm.run(for: profile) != nil || !state.isConnected)
        }
        .selectionDisabled()
        .onTapGesture(count: 2) {
            if let track = failedTracks[failure.trackID] { play([track]) }
        }
        .contextMenu {
            // CM-SYNC-FAILED: Play — Play Next · Add to Queue — Get Info — Retry — Show in Finder.
            if let track = failedTracks[failure.trackID] {
                Button("Play") { play([track]) }
                Divider()
                Button("Play Next") { TrackCommandActions.playNext([track], container: container) }
                Button("Add to Queue") { TrackCommandActions.addToQueue([track], container: container) }
                Divider()
                Button("Get Info") {
                    NotificationCenter.default.post(name: .openTrackDetailForTrack, object: nil, userInfo: ["trackId": failure.trackID])
                }
                Divider()
            }
            Button("Retry") { vm.retryFailed(profile, trackIDs: [failure.trackID]) }
            if let track = failedTracks[failure.trackID], track.isLocal {
                Divider()
                Button("Show in Finder") { TrackCommandActions.showInFinder([track], container: container) }
            }
        }
    }

    private func loadFailedTracks() async {
        guard let repository = container.trackRepository, let failures = vm.results[id]?.failures, !failures.isEmpty else { return }
        let tracks = (try? await repository.fetchTracks(ids: Set(failures.map(\.trackID)))) ?? []
        failedTracks = Dictionary(tracks.compactMap { track in track.id.map { ($0, track) } }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Options (was SyncSettingsForm; same keys)

/// Format, normalize, artwork, playlist files, clean up — saved at once; the plan recomputes.
/// `Background processing` lives in Settings ▸ Maintenance only (V-SYNC-DETAIL.E15).
private struct SyncOptionsRows: View {
    let vm: SyncViewModel
    let profile: SyncProfile

    private var id: Int64 { profile.id ?? -1 }
    private var converts: Bool { profile.transcodeModeEnum != .keepOriginals }

    var body: some View {
        Picker(selection: binding(\.transcodeMode) { vm, value in await vm.updateOptions(self.id, transcodeMode: value) }) {
            Text("Original files").tag(TranscodeMode.keepOriginals.rawValue)
            Text("AAC 248 kbps").tag(TranscodeMode.aac248.rawValue)
            Text("AAC 320 kbps").tag(TranscodeMode.aac320.rawValue)
        } label: {
            optionLabel("Format", converts
                        ? "Lossless and high-bitrate files are converted; files already smaller are copied as they are. Changing it replaces every file on the device."
                        : "Files are copied as they are in the library.")
        }
        .selectionDisabled()
        Toggle(isOn: binding(\.normalizeLoudness) { vm, value in await vm.updateOptions(self.id, normalizeLoudness: value) }) {
            optionLabel("Normalize volume", "To −14 LUFS, for tracks whose loudness was measured. Only when converting.")
        }
        .disabled(!converts)
        .selectionDisabled()
        Picker(selection: binding(\.artworkMode) { vm, value in await vm.updateOptions(self.id, artworkMode: value) }) {
            Text("Original").tag(ArtworkMode.keepOriginal.rawValue)
            Text("250 px").tag(ArtworkMode.resize250.rawValue)
        } label: {
            optionLabel("Artwork", "Smaller covers for players with little memory. Only when converting.")
        }
        .disabled(!converts)
        .selectionDisabled()
        Toggle(isOn: binding(\.generateM3U8) { vm, value in await vm.updateOptions(self.id, generateM3U8: value) }) {
            optionLabel("Playlist files", "Write a playlist file for each playlist of this profile.")
        }
        .selectionDisabled()
        Picker(selection: binding(\.playlistFormat) { vm, value in await vm.updateOptions(self.id, playlistFormat: value) }) {
            Text("Rockbox (.m3u8)").tag(PlaylistFormat.rockbox.rawValue)
            Text("Doppi (.m3u)").tag(PlaylistFormat.doppi.rawValue)
            Text("MLM for iOS (.m3u8)").tag(PlaylistFormat.ios.rawValue)
        } label: {
            optionLabel("Playlist file format", profile.playlistFormatEnum == .ios
                        ? "Music goes into “Music”, playlists into “Playlists”, with a library file for MLM for iOS."
                        : "The app that reads the playlist files.")
        }
        .selectionDisabled()
        Toggle(isOn: binding(\.cleanupRemovedFiles) { vm, value in await vm.updateOptions(self.id, cleanupRemovedFiles: value) }) {
            optionLabel("Clean up", "Remove files from the device that are no longer in this profile.")
        }
        .selectionDisabled()
    }

    private func optionLabel(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func binding<Value: Equatable>(_ key: KeyPath<SyncProfile, Value>,
                                           save: @escaping @MainActor (SyncViewModel, Value) async -> Void) -> Binding<Value> {
        Binding(
            get: { profile[keyPath: key] },
            set: { value in
                guard value != profile[keyPath: key] else { return }
                Task { @MainActor in await save(vm, value) }
            }
        )
    }
}
