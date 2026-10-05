import SwiftUI

/// Track menu (M-TRACK, new): every selection command, driven by the focused list's
/// `TrackSelection` (UC-SEL-02). Enabling and titles come from `TrackCommandState`; the
/// list-specific actions from the list's `TrackCommandTarget`, the shared ones from
/// `TrackCommandActions`. Play and Preview register no key: ↩ and Space belong to the focused
/// list (UC-KEY-37). Preview and Locate File… arrived with W2-C.
struct TrackCommands: Commands {
    @FocusedValue(\.trackSelection) private var focusedSelection
    @FocusedValue(\.navigationModel) private var navigation
    @FocusedValue(\.trailingColumn) private var trailingColumn
    @FocusedValue(\.shellActions) private var shellActions
    @FocusedValue(\.playlistSourceRefresh) private var playlistRefresh

    var body: some Commands {
        CommandMenu(MenuBarMenu.track.rawValue) {
            let selection = TrackSelection.usable(focusedSelection, navigation: navigation)
            // Enabling reads the published summary; tracks are resolved only when an item runs.
            let tracks: () -> [Track] = { selection?.selectedTracks ?? [] }
            let target = selection?.target ?? TrackCommandTarget()
            let state = TrackCommandState(
                summary: selection?.summary,
                capabilities: TrackListCapabilities(target),
                isDownloadBusy: DependencyContainer.shared.downloadViewModel?.isDownloading ?? false
            )

            CommandButton(.play, enabled: state.canPlay) {
                if let first = tracks().first, let rows = selection?.rows { target.activate?(first, rows) }
            }
            // The list's Space: starts / ends the preview of the selection (never Play/Pause).
            let previewing = DependencyContainer.shared.playbackViewModel?.preview.isActive == true
            CommandButton(.preview,
                          title: previewing ? "Stop Preview" : MenuCommand.preview.title,
                          enabled: target.preview != nil && (previewing || TrackPreviewCommand.canPreview(selection?.summary)),
                          disabledReason: TrackPreviewCommand.disabledReason) {
                target.preview?()
            }
            CommandButton(.playNext, enabled: state.canPlayNext) {
                guard !KeyEquivalentGuard.keyBelongsToText(
                    .textCommand(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)))
                ) else { return }
                TrackCommandActions.playNext(tracks())
            }
            CommandButton(.addToQueue)

            Divider()

            CommandSubmenu(.addToPlaylist, enabled: state.canAddTo) {
                Button("New Playlist…") { TrackCommandActions.newPlaylistFromSelection(tracks(), shell: shellActions) }
                if !target.playlists.isEmpty { Divider() }
                ForEach(target.playlists) { playlist in
                    Button(playlist.name) {
                        if let id = playlist.id { TrackCommandActions.addToPlaylist(id, tracks: tracks(), shell: shellActions) }
                    }
                }
            }
            CommandSubmenu(.addToSyncProfile, enabled: state.canAddTo) {
                ForEach(target.syncProfiles) { profile in
                    Button(profile.name) {
                        target.addToSyncProfile?(profile, selection?.selectedIDs ?? [])
                    }
                    .disabled(!state.canAddToSyncProfile)
                }
                if !target.syncProfiles.isEmpty { Divider() }
                Button("New Sync Profile…") { TrackCommandActions.newSyncProfileFromSelection(tracks()) }
            }

            Divider()

            // ⌘I is View ▸ Show Info's key; this is the same command for the selection: Info
            // shows the first selected track and opens (the existing Show Details path).
            CommandButton(.getInfo, enabled: state.canGetInfo && trailingColumn != nil) {
                if let id = selection?.summary.firstID {
                    NotificationCenter.default.post(name: .openTrackDetailForTrack, object: nil, userInfo: ["trackId": id])
                }
            }
            CommandButton(.goToAlbum)
            CommandButton(.goToArtist)
            CommandButton(.findSimilar)

            Divider()

            CommandButton(.download, title: state.downloadTitle, enabled: state.canDownload,
                          disabledReason: state.downloadDisabledReason) {
                TrackCommandActions.download(tracks())
            }
            CommandButton(.locateFile,
                          enabled: TrackPreviewCommand.canLocate(selection?.summary),
                          disabledReason: TrackPreviewCommand.locateDisabledReason) {
                if let track = tracks().first { LocateFileRequest.shared.begin(track) }
            }
            rereadItem

            Divider()

            CommandButton(.showInFinder, enabled: state.canShowInFinder) {
                TrackCommandActions.showInFinder(tracks())
            }
            CommandSubmenu(.copyTrack, enabled: state.canCopy) {
                Button("Title — Artist") { TrackCommandActions.copyTitleAndArtist(tracks()) }
                Button("File Path") { TrackCommandActions.copyFilePaths(tracks()) }
                    .disabled(!state.canCopyFilePath)
            }
            CommandButton(.share)

            Divider()

            CommandButton(.removeFromContainer, title: state.removeFromContainerTitle,
                          enabled: state.canRemoveFromContainer,
                          disabledReason: TrackCommandState.removeDisabledReason(selection?.context.container ?? .none)) {
                target.removeFromContainer?(selection?.selectedIDs ?? [])
            }
            CommandButton(.removeFromLibrary, enabled: state.canRemoveFromLibrary) {
                guard !KeyEquivalentGuard.keyBelongsToText(.textCommand(#selector(NSResponder.deleteToBeginningOfLine(_:)))) else { return }
                TrackCommandActions.removeFromLibrary(tracks())
            }
        }
    }

    /// Refresh from Source ⌘R — re-read the visible place from outside, titled for it
    /// (UC-KEY-15). The only ⌘R in the app (UC-KEY-39).
    @ViewBuilder
    private var rereadItem: some View {
        let reread = navigation.map {
            RereadCommand.resolve(
                selection: $0.selection,
                route: $0.currentRoute,
                isSearching: DependencyContainer.shared.searchCoordinator.isPresented
            )
        } ?? .none
        switch reread {
        case .scanLibraryFolder:
            CommandButton(.refreshFromSource, title: reread.title(),
                          enabled: shellActions?.isScanningLibraryFolder == false,
                          disabledReason: "The library folder is being scanned.") {
                shellActions?.scanLibraryFolder()
            }
        case .refreshPlaylist(let id):
            let refresh = playlistRefresh?.playlistID == id ? playlistRefresh : nil
            CommandButton(.refreshFromSource, title: reread.title(sourceName: refresh?.sourceName),
                          enabled: refresh.map { !$0.isRunning } ?? false,
                          disabledReason: "This playlist isn’t linked to a source.") {
                refresh?.perform()
            }
        case .recomputePlan(let id):
            let sync = DependencyContainer.shared.syncViewModel
            let profile = sync?.profiles.first { $0.id == id }
            CommandButton(.refreshFromSource, title: reread.title(),
                          enabled: profile != nil && sync?.selectedProfile?.id == id && sync?.isPreviewUpdating == false) {
                if let sync, let profile { Task { await sync.refreshPreviewNow(for: profile) } }
            }
        case .scanThisFolder, .runScan, .none:
            CommandButton(.refreshFromSource, title: reread.title(), enabled: false,
                          disabledReason: reread == .none
                              ? "Nothing here can be refreshed from outside."
                              : "This place can’t be refreshed yet.") {}
        }
    }
}

/// Enabling of Track ▸ Preview and Track ▸ Locate File… (W2-C) from the published summary.
enum TrackPreviewCommand {
    /// One track whose file can be used now (Local, its disk connected).
    static func canPreview(_ summary: TrackSelectionSummary?) -> Bool {
        guard let summary else { return false }
        return summary.count == 1 && summary.firstIsLocal
    }

    /// One track that is File missing or Download failed.
    static func canLocate(_ summary: TrackSelectionSummary?) -> Bool {
        guard let summary else { return false }
        return summary.count == 1 && (summary.missingCount == 1 || summary.failedCount == 1)
    }

    static let disabledReason = "Select one downloaded track to preview it."
    static let locateDisabledReason = "Select one track whose file is missing."
}
