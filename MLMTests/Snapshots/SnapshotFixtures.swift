import AppKit
import SwiftUI
@testable import MLM

/// The capture mechanism required by a fixture. SwiftUI content can use
/// ImageRenderer; macOS Tables must be hosted and bitmap-captured by AppKit.
enum SnapshotBackend {
    case swiftUI
    case appKit
}

/// Statically written registry; compile and visually verify on macOS.
@MainActor
enum SnapshotFixtures {
    struct InventoryEntry {
        let path: String
        let disposition: String
    }

    struct Fixture {
        let id: String
        let size: CGSize
        let backend: SnapshotBackend
        let expectedTableRows: Int?
        let makeView: (SnapshotFixtureStore) throws -> AnyView

        init(
            id: String,
            size: CGSize,
            backend: SnapshotBackend = .swiftUI,
            expectedTableRows: Int? = nil,
            makeView: @escaping (SnapshotFixtureStore) throws -> AnyView
        ) {
            self.id = id
            self.size = size
            self.backend = backend
            self.expectedTableRows = expectedTableRows
            self.makeView = makeView
        }

        func view(store: SnapshotFixtureStore) throws -> AnyView {
            let content = try makeView(store)
            return AnyView(content
                .environment(\.container, store.container)
                .environment(\.trackArtworkLoadingEnabled, false))
        }
    }

    static let fixtures: [Fixture] = baseFixtures + additionalFixtures

    private static let baseFixtures: [Fixture] = [
        Fixture(id: "status-chip-failed", size: .init(width: 240, height: 80), makeView: { _ in
            AnyView(try require(StatusChip(availability: .fileMissing), named: "File missing status chip").padding(20))
        }),
        Fixture(id: "metadata-normal", size: .init(width: 360, height: 80), makeView: { _ in
            AnyView(TrackMetadataText("Björk").padding(20))
        }),
        Fixture(id: "metadata-placeholder", size: .init(width: 360, height: 80), makeView: { _ in
            AnyView(TrackMetadataText("Unknown").padding(20))
        }),
        Fixture(id: "danceability", size: .init(width: 180, height: 80), makeView: { _ in
            AnyView(DanceabilitySteps(score: 0.78).padding(20))
        }),
        Fixture(id: "energy-bars", size: .init(width: 180, height: 80), makeView: { _ in
            AnyView(EnergyBars(level: 4).padding(20))
        }),
        Fixture(id: "waveform", size: .init(width: 640, height: 140), makeView: { _ in
            AnyView(WaveformView(
                data: [0.05, 0.25, 0.8, 0.42, 0.62, 0.12, 0.91, 0.35],
                progress: 0.42,
                isLoading: false,
                zoomLevel: .constant(1),
                exponent: .constant(0.8),
                gain: .constant(1),
                waveformHeight: .constant(120),
                needleTimeLabel: "01:42"
            ))
        }),
        Fixture(id: "sync-toast", size: .init(width: 520, height: 100), makeView: { _ in
            AnyView(SyncToast(message: "Device defaults applied", isShowing: true))
        }),
        Fixture(id: "playlist-card", size: .init(width: 280, height: 220), makeView: { store in
            let playlist = try SnapshotFixtures.require(
                store.playlists().first,
                named: "populated playlist"
            )
            // W3-PL card: facts line and the §15.5 words (`Not downloaded · 1 track`).
            let summary = PlaylistSummary(playlistID: 1, totalTracks: 2, localTracks: 1, notDownloadedTracks: 1)
            return AnyView(PlaylistCard(
                item: PlaylistGridItem(
                    playlist: playlist,
                    summary: summary,
                    status: PlaylistStatus.make(summary: summary, echo: nil, expiredSignIn: nil),
                    source: nil
                ),
                renameText: .constant("")
            )
            .frame(width: 180))
        }),
        Fixture(id: "ingest-preview", size: .init(width: 700, height: 580), makeView: { _ in
            let preview = IngestPreview(
                targetPlaylistId: 1,
                targetPlaylistName: "Snapshot Mix",
                willCreate: false,
                added: [.init(id: 1, title: "Jóga", artist: "Björk", uuid: "FIXTURE-1", path: "Björk/Jóga.flac")],
                removed: [],
                reordered: [],
                unresolved: [.init(path: "Missing/Track.flac", uuid: nil, reason: "No library match")]
            )
            return AnyView(IngestPreviewView(
                preview: preview, sourceFileName: "fixture.m3u8", onApply: {}, onCancel: {}
            ))
        }),
        Fixture(id: "discovery-inbox-empty", size: .init(width: 800, height: 560), makeView: { _ in
            AnyView(DiscoveryInboxView())
        }),
        Fixture(id: "discover-screen", size: .init(width: 800, height: 620), makeView: { _ in
            AnyView(DiscoverView())
        }),
        Fixture(id: "review-queue-empty", size: .init(width: 800, height: 620), makeView: { store in
            let analysisRepository = try SnapshotFixtures.require(
                store.container.analysisRepository,
                named: "analysis repository"
            )
            let trackRepository = try SnapshotFixtures.require(
                store.container.trackRepository,
                named: "track repository"
            )
            return AnyView(ReviewQueueView(initialViewModel: ReviewQueueViewModel(
                analysisRepository: analysisRepository,
                trackRepository: trackRepository
            )))
        }),
        Fixture(id: "queue-panel-unavailable", size: .init(width: 320, height: 560), makeView: { _ in
            AnyView(QueuePanel())
        }),
    ]

    static let additionalFixtures: [Fixture] = [
        Fixture(
            id: "library-table-populated",
            size: .init(width: 1_100, height: 460),
            backend: .appKit,
            expectedTableRows: 5,
            makeView: { store in
                let model = TrackListModel(sortOrder: nil)
                model.setTracksNow(SnapshotFixtureData.persisted(try store.tracksForRendering()))
                return AnyView(TrackListTable(model: model, configuration: .allTracks(activate: nil, totals: nil)) {
                    EmptyView()
                })
            }
        ),
        Fixture(
            id: "track-table-populated",
            size: .init(width: 1_100, height: 460),
            backend: .appKit,
            expectedTableRows: 5,
            makeView: { store in
                let model = TrackListModel(sortOrder: nil)
                model.setTracksNow(SnapshotFixtureData.persisted(try store.tracksForRendering()))
                return AnyView(TrackListTable(model: model, configuration: .searchResults(activate: nil)) {
                    EmptyView()
                })
            }
        ),
        Fixture(
            id: "playlist-table-populated",
            size: .init(width: 1_100, height: 460),
            backend: .appKit,
            expectedTableRows: 2,
            makeView: { store in
                let playlist = try SnapshotFixtures.require(
                    store.playlists().first,
                    named: "populated playlist"
                )
                let tracks = try store.playlistTracks(playlistID: require(playlist.id, named: "playlist ID"))
                let model = PlaylistDetailViewModel(
                    playlist: playlist,
                    playlistRepository: try SnapshotFixtures.require(
                        store.container.playlistRepository, named: "playlist repository"
                    ),
                    trackRepository: try SnapshotFixtures.require(
                        store.container.trackRepository, named: "track repository"
                    ),
                    sourceRepository: try SnapshotFixtures.require(
                        store.container.sourceRepository, named: "source repository"
                    ),
                    preloadedTracks: tracks,
                    availabilityByTrackID: SnapshotFixtureData.availability(for: tracks)
                )
                return AnyView(PlaylistTable(playlist: playlist, viewModel: model))
            }
        ),
        // W3-FOLD: the hierarchical outline replaced the folder tracks table; the fixture shows
        // the tracks at the top of a library folder (no disk, no database reads).
        Fixture(
            id: "folder-outline-populated",
            size: .init(width: 1_100, height: 460),
            backend: .appKit,
            expectedTableRows: 5,
            makeView: { store in
                let tracks = try store.tracksForRendering()
                let model = FolderViewModel(environment: FolderViewModel.Environment(
                    queries: { nil }, libraryRoot: { nil }, libraryID: { nil }, isDriveOffline: { true },
                    defaults: UserDefaults(suiteName: "mlm.snapshot.folders") ?? .standard))
                model.showForFixture(tracks, libraryRoot: "/Snapshot/Music")
                let configuration = TrackListConfiguration(listContext: .folder(path: "", name: "Music"), persistenceKey: "folders",
                                                           publishesStatusText: false)
                let live = TrackTableLive()
                let actions = TrackListActions(model: model.trackList, configuration: configuration, live: live,
                                               statusBar: nil, undo: nil, shell: nil)
                return AnyView(FolderOutlineTable(
                    model: model, configuration: configuration, actions: actions,
                    folderActions: FolderActions(model: model, trackActions: actions, shell: nil, statusBar: nil, undo: nil),
                    live: live
                ))
            }
        ),
        Fixture(
            id: "device-ingest-preview-row",
            size: .init(width: 600, height: 440),
            makeView: { _ in
                AnyView(DeviceIngestFileRow(
                    fileName: "Snapshot Mix.m3u8",
                    preview: IngestPreview(
                        targetPlaylistId: 1,
                        targetPlaylistName: "Snapshot Mix",
                        willCreate: false,
                        added: [.init(id: 1, title: "Jóga", artist: "Björk", uuid: nil, path: "Music/Joga.flac")],
                        removed: [.init(id: 4, title: "Stream Only", artist: "Remote Artist", uuid: nil, path: "Music/Remote.m4a")],
                        reordered: [],
                        unresolved: []
                    ),
                    onApply: {}
                ).padding(20))
            }
        ),
        Fixture(id: "track-cover-placeholder", size: .init(width: 220, height: 220), makeView: { _ in
            AnyView(TrackCoverView(trackId: 1, size: .small).frame(width: 180, height: 180).padding(20))
        }),
        // W2-H: the shared drop target (ring only while a drag hovers) replaced the pulsing
        // spring-load modifier.
        Fixture(id: "drop-target-resting", size: .init(width: 300, height: 100), makeView: { _ in
            AnyView(Text("Snapshot drop target").padding(20).dropTarget(.fixedRow))
        }),
        // W3-LAUNCH: the in-window launch states replaced the first-run scrim wizard.
        Fixture(id: "launch-loading-update", size: .init(width: 640, height: 360), makeView: { _ in
            AnyView(LibraryLoadingView(name: "Main Library", phase: .updating(step: 3, total: 5)))
        }),
        Fixture(id: "new-sync-profile-sheet", size: .init(width: 460, height: 400), makeView: { _ in
            AnyView(NewSyncProfileFromSelectionSheet(trackIds: [1, 4]))
        }),
        Fixture(id: "track-table-empty", size: .init(width: 900, height: 400), makeView: { _ in
            let model = TrackListModel(sortOrder: nil)
            model.setTracksNow([])
            return AnyView(TrackListTable(model: model, configuration: .searchResults(activate: nil)) {
                ContentUnavailableView("No tracks", systemImage: "music.note")
            })
        }),
        // First load: redacted placeholder rows under the real header (UC-TABLE-09), no spinner.
        Fixture(id: "track-table-first-load", size: .init(width: 900, height: 400), backend: .appKit, makeView: { _ in
            AnyView(TrackListTable(model: TrackListModel(sortOrder: nil), configuration: .searchResults(activate: nil)) {
                EmptyView()
            })
        }),
        Fixture(id: "status-chip-download-failed", size: .init(width: 300, height: 100), makeView: { _ in
            AnyView(try require(StatusChip(availability: .failed(
                reason: "Video unavailable",
                date: Date(timeIntervalSince1970: 1_704_164_645),
                attempts: 2
            )), named: "Download failed status chip").padding(20))
        }),
        Fixture(id: "status-chip-remote", size: .init(width: 300, height: 100), makeView: { _ in
            AnyView(try require(StatusChip(availability: .notDownloaded), named: "Remote status chip").padding(20))
        }),
        Fixture(
            id: "library-screen-local",
            size: .init(width: 1_280, height: 800),
            backend: .appKit,
            expectedTableRows: 3,
            makeView: { store in
                let allTracks = try store.tracks()
                // All Tracks in its `Local` scope (W2-B: the scope bar replaced the tabs).
                let model = LibraryViewModel(
                    trackRepository: try require(store.container.trackRepository, named: "track repository"),
                    configRepository: try require(store.container.configRepository, named: "config repository"),
                    preloadedTracks: SnapshotFixtureData.persisted(allTracks),
                    scope: .local
                )
                return AnyView(LibraryView(initialViewModel: model))
            }
        ),
    ]

    /// Source-file accounting remains explicit even where a source contains
    /// models, AppKit adapters, or services rather than a renderable View.
    static let inventory: [InventoryEntry] = inventoryPaths.map {
        InventoryEntry(path: $0, disposition: renderedPaths.contains($0)
            ? "Rendered: fixture registry."
            : exclusions[$0] ?? "")
    }

    static let renderedPaths: Set<String> = [
        "Discover/DiscoverView.swift", "DiscoveryInbox/DiscoveryInboxView.swift",
        "Folders/FolderOutlineTable.swift", "Library/DanceabilitySteps.swift",
        "Library/EnergyBars.swift", "Library/LibraryView.swift",
        "TrackList/TrackListTable.swift", "TrackList/TrackCell.swift", "TrackList/TrackRowPresentation.swift",
        "Playlists/PlaylistCard.swift",
        "Playlists/PlaylistTable.swift", "Queue/QueuePanel.swift",
        "ReviewQueue/ReviewQueueView.swift",
        "Shared/SelectionCreationSheets.swift", "Shared/StatusChip.swift",
        "Shared/TrackCoverView.swift", "DragDrop/DropTargetModifier.swift", "Launch/LibraryLoadingView.swift",
        "Shared/TrackMetadataPresentation.swift", "Sync/DeviceIngestResultsView.swift",
        "Sync/IngestPreviewView.swift", "Sync/SyncToast.swift",
        "TrackDetail/WaveformView.swift",
    ]

    private static let exclusions: [String: String] = [
        "Activity/ActivityJobTracking.swift": "Non-view: Maintenance job runner (owns the task and its Activity operation).",
        "Activity/ActivityRouter.swift": "Non-view: popover/window routing and subject navigation.",
        "Activity/LogFeed.swift": "Non-view: log query model.",
        "Activity/LogTextRenderer.swift": "Non-view: attributed-text helper.",
        "Shared/DownloadRetryBudget.swift": "Non-view: retry helper.",
        "TrackList/TrackColumn.swift": "Non-view: track-table column ids and sort order (W2-A).",
        "TrackList/TrackRow.swift": "Non-view: track-table row model, builder and sorter (W2-A).",
        "TrackList/TrackListModel.swift": "Non-view: track-table rows, sort and selection (W2-A).",
        "TrackList/TrackListConfiguration.swift": "Non-view: per-context table configuration and focused values (W2-A).",
        "TrackList/TrackListActions.swift": "Non-view: track-table actions and undoable playlist removal (W2-A).",
        "TrackList/TrackMenuModel.swift": "Non-view: track menu items in DEC-039 order (W2-A).",
        "TrackList/TrackPrimaryAction.swift": "Non-view: primary action per row kind and play-when-ready (W2-A).",
        "TrackList/TrackMenu.swift": "Deferred: menus require interactive presentation; current bitmap hosts do not open them.",
        "Sync/Pickers/PlaylistPickerModel.swift": "Non-view: selection model.",
        "TrackDetail/WaveformHelpers.swift": "Non-view: waveform math; production WaveformView is captured.",
        "Activity/ActivityLogsView.swift": "Deferred: global logger and AppKit text representable need fixed attributed-log input.",
        "Activity/ActivityToolbarItem.swift": "Deferred: toolbar item and popover read the shared ActivityCenter; inject a fixture center.",
        "Activity/ActivityWindow.swift": "Deferred: window reads the shared ActivityCenter and container; inject a fixture center.",
        "ContentView/ContentView.swift": "Deferred: real shell, startup/router/toolbar lifecycle; needs application-level fixture composition.",
        "Folders/FoldersView.swift": "Deferred: the place reads the live library folder, drive and Activity; its rules are unit-tested (FolderViewModelTests, FolderOutlineTests).",
        "Folders/FolderMenus.swift": "Deferred: menus require interactive presentation; the folder actions' rules are unit-tested (FolderDropTests).",
        "Folders/FolderPathBar.swift": "Deferred: drawn under the outline in the live Folders place; its segments come from FolderViewModel.pathSegments (tested).",
        "Library/TrackContextMenu.swift": "Deferred: menus require interactive presentation; current bitmap hosts do not open them.",
        "Player/PlayerBar.swift": "Deferred: concrete playback VM initializes audio/timer/media state; needs passive transport protocol.",
        "Player/PreviewWaveformScrubber.swift": "Deferred: drawn inside the deferred PlayerBar while previewing (W2-C).",
        "Player/LocateFile.swift": "Deferred: Locate File… is a system file panel; bitmap hosts don't present it (W2-C).",
        "Player/PlaybackWindowSupport.swift": "Deferred: window-level Esc, status-bar relay and file panel; nothing drawn (W2-C review).",
        "Player/PlayerDisplay.swift": "Non-view: the player's state words, pure (W2-C).",
        "Player/GoToCurrentTrack.swift": "Non-view: Go to Current Track and the table reveal request (W2-C).",
        "TrackList/TrackListPreviewKeys.swift": "Non-view: preview key decisions and the focused table's key handler (W2-C).",
        "TrackList/SelectionBarState.swift": "Non-view: what the selection bar shows for a selection, and when (W2-G).",
        "TrackList/SelectionBarHosting.swift": "Non-view: the channel between a scaffold's track table and its selection bar (W2-G).",
        "TrackList/SelectionBar.swift": "Deferred: the Liquid Glass selection bar needs a window with a live selection; its rules are unit-tested (SelectionBarStateTests).",
        "Playlists/PlaylistDetailView.swift": "Deferred: lifecycle reloads, source sync and cover work not isolated by table fixture.",
        "Playlists/PlaylistDetailViewLoader.swift": "Deferred: loader async outcomes require controlled ready/not-found/failure injection.",
        "Playlists/PlaylistActions.swift": "Deferred: the playlist menu builder reads the shell environment; its sections are unit-tested (PlaylistMenuModelTests).",
        "Playlists/PlaylistLinkSheet.swift": "Deferred: the Link sheet checks a live source link; its wording is unit-tested.",
        "Playlists/PlaylistM3UImportSheet.swift": "Deferred: the M3U preview reads a file and the library; its plan is unit-tested (PlaylistFolderEditsTests).",
        "Playlists/PlaylistsView.swift": "Deferred: live playlist/cover loading and root view state need a preloaded composition.",
        "ReelsInbox/ReelsInboxView.swift": "Deferred: AVKit/Shazam/Vision work and detached tasks require service/clock seams.",
        "Search/SearchResultsView.swift": "Deferred: Library-scope results read the open library and the shell environment (W2-I); its model is unit-tested.",
        "Search/OnlineSearchResultsView.swift": "Deferred: Online-scope results ask live sources (W2-I); OnlineSearchModel is unit-tested with fake sources.",
        "Search/SearchSuggestionList.swift": "Deferred: search suggestions render only inside the window's toolbar search field (W2-I).",
        "Search/SearchFocusHandoff.swift": "Non-view: moves focus from the search field to the visible table (AppKit, W2-I).",
        "Settings/BackupSettingsView.swift": "Deferred: container-backed backup service and folder/Finder panels require an inert backup model; BackupSettingsViewModel is unit-tested (W3-SET).",
        "Settings/DataLocationsView.swift": "Deferred: container-backed paths, filesystem sizes and a Swift Charts bar require an inert locations model (W3-SET).",
        "Settings/LibrarySetupView.swift": "Deferred: import/filesystem state, the rename and folder sheets need an inert library model; LibraryRename is unit-tested (W3-SET).",
        "Settings/PlaybackSettingsView.swift": "Deferred: AppStorage playback keys and the shared Maintenance coverage need an injected preference store (W3-SET).",
        "Settings/AdvancedSettingsView.swift": "Deferred: credentials-file existence, the logger and the interim genre tools need injected locations (W3-SET).",
        "Settings/SettingsRows.swift": "Deferred: shared Settings rows (paths, state words, Show in Finder, How to Install popover, folder panel); rendered within their tabs (W3-SET).",
        "Launch/LaunchRootView.swift": "Deferred: switches on the shared launch coordinator's screen; needs an injected coordinator (W3-LAUNCH).",
        "Launch/LibraryPickerView.swift": "Deferred: the picker reads the launch coordinator's registry rows and mount events; needs a fixture registry (W3-LAUNCH).",
        "Launch/LibraryAdoptionSheet.swift": "Deferred: a sheet driven by the launch coordinator's adoption state (W3-LAUNCH).",
        "Launch/LibraryFilePresentation.swift": "Deferred: alerts, sheet and file panel; bitmap hosts don't present them (W3-LAUNCH).",
        "Launch/LibraryLaunchFailureView.swift": "Deferred: failed/invalid states load restore options from the launch coordinator (W3-LAUNCH).",
        "Launch/LibrarySetupFlowView.swift": "Deferred: setup steps read the launch coordinator and the import model (W3-LAUNCH).",
        "Launch/NewLibrarySheet.swift": "Deferred: a sheet validating against the launch coordinator's libraries folder (W3-LAUNCH).",
        "Launch/LibraryFileIcon.swift": "Non-view: the library-file icon image and the .mlibm type for the open panel (W3-LAUNCH).",
        "Settings/MaintenanceView.swift": "Deferred: reads the shared Maintenance runner, coverage and Activity history; MaintenanceJobs is unit-tested (W3-SET).",
        "Settings/SettingsView.swift": "Deferred: AppStorage selection and PlaybackSettings read real defaults; inject preference store.",
        "Settings/SourcesSetupView.swift": "Deferred: account states, tool probes and the cookie need isolated preferences and an auth provider; SourceAccounts and DownloadToolsModel are unit-tested (W3-SET).",
        "Settings/GeneralSettingsView.swift": "Deferred: reads the shared library launch coordinator's registry setting; inject a registry store.",
        "Settings/SettingsTab.swift": "Non-view: settings tab enum and router.",
        "Sidebar/LibraryFooter.swift": "Deferred: reads the launch coordinator singleton and live library counts; needs injected library identity.",
        "Sidebar/SidebarView.swift": "Deferred: composes shell environment (navigation, sidebar model, actions) and live sync state; needs a shell fixture.",
        "Shell/NavigationModel.swift": "Non-view: navigation state (destinations, pushed routes, history).",
        "Shell/TrailingColumnState.swift": "Non-view: trailing column mode state.",
        "Shell/StatusBarCenter.swift": "Non-view: status bar message and loading model; rendered by ContentScaffold.",
        "Shell/Spacing.swift": "Non-view: layout constants.",
        "Shell/ScopeBar.swift": "Deferred: scope bar (W2-B) is re-recorded with the wave's snapshot pass; its rules are unit-tested (ScopeBarRulesTests).",
        "TrackList/DownloadFailureReasonText.swift": "Non-view: plain words for stored download-failure reasons (W2-B).",
        "Shell/SidebarModel.swift": "Non-view: sidebar data and sync row state.",
        "Shell/ShellActions.swift": "Non-view: window-level command actions.",
        "Shell/ShellEdits.swift": "Non-view: undoable playlist and sync-profile edits (W2-F).",
        "Shell/UndoCenter.swift": "Non-view: window undo center; its confirmations render in ContentScaffold's status bar.",
        "Shell/ShellSearch.swift": "Deferred: attaches .searchable to the window shell; needs application-level fixture composition.",
        "Shell/ContentScaffold.swift": "Deferred: shell scaffold reads the status-bar centre and mount state from the environment; re-recorded per wave.",
        "Shell/ShellToolbar.swift": "Deferred: toolbar content needs a window toolbar host and the live playback VM.",
        "Shell/DestinationView.swift": "Deferred: routes to container-backed destination views; needs application-level fixture composition.",
        "Shell/TrailingColumnView.swift": "Deferred: hosts InspectorView and QueuePanel, which need live playback state.",
        "Queue/QueuePanelModel.swift": "Non-view: the Queue panel's sections, rows, words and drag payload (W2-D).",
        "Queue/QueueEditCommands.swift": "Non-view: undoable queue edits, drops and Save as Playlist (W2-D).",
        "Queue/SaveQueueAsPlaylistPopover.swift": "Deferred: a popover; bitmap hosts don't present it (W2-D).",
        "Inspector/InspectorModel.swift": "Non-view: Info's selection-keyed edit model (W2-E).",
        "Inspector/InfoTrackRequest.swift": "Non-view: one-track Show Details request (W2-E).",
        "Inspector/InspectorFileStatus.swift": "Non-view: availability sentence and fix per state (W2-E).",
        "Inspector/InspectorAnalysis.swift": "Non-view: single-track analysis runs (W2-E).",
        "Inspector/InspectorView.swift": "Deferred: Info reads the database, undo center and shell environment; re-recorded with wave 2.",
        "Inspector/InspectorDetailsTab.swift": "Deferred: tag fields and playlist membership read the database and shell actions.",
        "Inspector/InspectorAudioTab.swift": "Deferred: waveform extraction, analysis and similarity read files and the database.",
        "Inspector/InspectorFileTab.swift": "Deferred: file location, size and diagnostics read the disk and the database.",
        "Sync/NewSyncProfileSheet.swift": "Deferred: concrete SyncViewModel and device detection; needs passive sync model.",
        "Import/QuickAddSheet.swift": "Deferred: Add from Link is a sheet looking links up through yt-dlp; QuickAddModel is unit-tested (W3-ADD).",
        "Import/ImportPlaylistSheet.swift": "Deferred: the import sheet reads source accounts and providers; ImportPlaylistModel is unit-tested (W3-ADD).",
        "Import/SourceSignInView.swift": "Deferred: the browser sign-in hand-off waits for a real OAuth callback; SourceSignInModel is unit-tested (W3-ADD).",
        "Import/ImportSheetsHost.swift": "Deferred: presents the Add menu sheets on the main window; nothing drawn of its own (W3-ADD).",
        "Sync/Pickers/PlaylistPickerSheet.swift": "Deferred: concrete SyncViewModel requires filesystem TranscodeCache and standard-default-reading SyncService.",
        "Sync/SyncContentSections.swift": "Deferred: same concrete SyncViewModel boundary; needs passive expanded-content model.",
        "Sync/SyncFailedDisclosure.swift": "Deferred: concrete sync VM plus async row lookup; inject passive failed-row state.",
        "Sync/SyncProfileDetailView.swift": "Deferred: live device file checks, cache age and preview task need filesystem/clock seams.",
        "Sync/SyncSettingsForm.swift": "Deferred: concrete sync service supplies preference state; inject settings bindings/actions.",
        "Sync/SyncView.swift": "Deferred: profile/device/preview lifecycle needs inert sync coordinator.",
        "TrackDetail/GrooveStudioView.swift": "Deferred: audio players, model/export services and placeholder randomness need passive deck state.",
        "TrackDetail/GrooveView.swift": "Deferred: preview audio, recommendations and random placeholders require controlled provider/player state.",
    ]

    private static let inventoryPaths = """
Activity/ActivityJobTracking.swift
Activity/ActivityLogsView.swift
Activity/ActivityRouter.swift
Activity/ActivityToolbarItem.swift
Activity/ActivityWindow.swift
Activity/LogFeed.swift
Activity/LogTextRenderer.swift
ContentView/ContentView.swift
Discover/DiscoverView.swift
DiscoveryInbox/DiscoveryInboxView.swift
DragDrop/DropTargetModifier.swift
Folders/FolderMenus.swift
Folders/FolderOutlineTable.swift
Folders/FolderPathBar.swift
Folders/FoldersView.swift
Import/ImportPlaylistSheet.swift
Import/ImportSheetsHost.swift
Import/QuickAddSheet.swift
Import/SourceSignInView.swift
Inspector/InfoTrackRequest.swift
Inspector/InspectorAnalysis.swift
Inspector/InspectorAudioTab.swift
Inspector/InspectorDetailsTab.swift
Inspector/InspectorFileStatus.swift
Inspector/InspectorFileTab.swift
Inspector/InspectorModel.swift
Inspector/InspectorView.swift
Launch/LaunchRootView.swift
Launch/LibraryAdoptionSheet.swift
Launch/LibraryFileIcon.swift
Launch/LibraryFilePresentation.swift
Launch/LibraryLaunchFailureView.swift
Launch/LibraryLoadingView.swift
Launch/LibraryPickerView.swift
Launch/LibrarySetupFlowView.swift
Launch/NewLibrarySheet.swift
Library/DanceabilitySteps.swift
Library/EnergyBars.swift
Library/LibraryView.swift
Library/TrackContextMenu.swift
Player/GoToCurrentTrack.swift
Player/LocateFile.swift
Player/PlaybackWindowSupport.swift
Player/PlayerBar.swift
Player/PlayerDisplay.swift
Player/PreviewWaveformScrubber.swift
Playlists/PlaylistActions.swift
Playlists/PlaylistCard.swift
Playlists/PlaylistDetailView.swift
Playlists/PlaylistDetailViewLoader.swift
Playlists/PlaylistLinkSheet.swift
Playlists/PlaylistM3UImportSheet.swift
Playlists/PlaylistsView.swift
Playlists/PlaylistTable.swift
Queue/QueueEditCommands.swift
Queue/QueuePanel.swift
Queue/QueuePanelModel.swift
Queue/SaveQueueAsPlaylistPopover.swift
ReelsInbox/ReelsInboxView.swift
ReviewQueue/ReviewQueueView.swift
Search/OnlineSearchResultsView.swift
Search/SearchFocusHandoff.swift
Search/SearchResultsView.swift
Search/SearchSuggestionList.swift
Settings/AdvancedSettingsView.swift
Settings/BackupSettingsView.swift
Settings/DataLocationsView.swift
Settings/GeneralSettingsView.swift
Settings/LibrarySetupView.swift
Settings/MaintenanceView.swift
Settings/PlaybackSettingsView.swift
Settings/SettingsRows.swift
Settings/SettingsTab.swift
Settings/SettingsView.swift
Settings/SourcesSetupView.swift
Shared/DownloadRetryBudget.swift
Shared/SelectionCreationSheets.swift
Shared/StatusChip.swift
Shared/TrackCoverView.swift
Shared/TrackMetadataPresentation.swift
Shell/ContentScaffold.swift
Shell/DestinationView.swift
Shell/NavigationModel.swift
Shell/ScopeBar.swift
Shell/ShellActions.swift
Shell/ShellEdits.swift
Shell/ShellSearch.swift
Shell/ShellToolbar.swift
Shell/SidebarModel.swift
Shell/Spacing.swift
Shell/StatusBarCenter.swift
Shell/TrailingColumnState.swift
Shell/TrailingColumnView.swift
Shell/UndoCenter.swift
Sidebar/LibraryFooter.swift
Sidebar/SidebarView.swift
Sync/DeviceIngestResultsView.swift
Sync/IngestPreviewView.swift
Sync/NewSyncProfileSheet.swift
Sync/Pickers/PlaylistPickerModel.swift
Sync/Pickers/PlaylistPickerSheet.swift
Sync/SyncContentSections.swift
Sync/SyncFailedDisclosure.swift
Sync/SyncProfileDetailView.swift
Sync/SyncSettingsForm.swift
Sync/SyncToast.swift
Sync/SyncView.swift
TrackDetail/GrooveStudioView.swift
TrackDetail/GrooveView.swift
TrackDetail/WaveformHelpers.swift
TrackDetail/WaveformView.swift
TrackList/DownloadFailureReasonText.swift
TrackList/SelectionBar.swift
TrackList/SelectionBarHosting.swift
TrackList/SelectionBarState.swift
TrackList/TrackCell.swift
TrackList/TrackColumn.swift
TrackList/TrackListActions.swift
TrackList/TrackListConfiguration.swift
TrackList/TrackListModel.swift
TrackList/TrackListTable.swift
TrackList/TrackMenu.swift
TrackList/TrackMenuModel.swift
TrackList/TrackListPreviewKeys.swift
TrackList/TrackPrimaryAction.swift
TrackList/TrackRow.swift
TrackList/TrackRowPresentation.swift
""".split(separator: "\n").map(String.init)

    private static func require<T>(_ value: T?, named name: String) throws -> T {
        guard let value else {
            throw SnapshotFixtureError.missingDependency(name)
        }
        return value
    }
}

enum SnapshotFixtureError: LocalizedError {
    case missingDependency(String)

    var errorDescription: String? {
        switch self {
        case let .missingDependency(name):
            "Snapshot fixture requires \(name)."
        }
    }
}

@MainActor
private enum SnapshotFixtureData {
    /// The fixture's tracks with the persisted file fact the availability states need (v42):
    /// `Offline File` is File missing.
    static func persisted(_ tracks: [Track]) -> [Track] {
        tracks.map { track in
            var track = track
            if track.title == "Offline File", track.organizedPath != nil {
                track.fileMissingSince = "2026-10-05T10:00:00Z"
            }
            return track
        }
    }

    static func availability(for tracks: [Track]) -> [Int64: TrackAvailability] {
        Dictionary(uniqueKeysWithValues: tracks.compactMap { track in
            guard let id = track.id else { return nil }
            let availability: TrackAvailability
            switch track.title {
            case "Offline File": availability = .fileMissing
            case "Stream Only": availability = .notDownloaded
            case "Metadata pending":
                let failure = SnapshotFixtureStore.downloadFailure
                availability = .failed(reason: failure.reason, date: failure.date, attempts: failure.attempts)
            default: availability = .local
            }
            return (id, availability)
        })
    }
}
