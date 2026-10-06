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
        // W3-SYNC: Read Playlist Changes from Device (merged sheet) — a merge, MLM-only tracks kept.
        Fixture(id: "device-changes-sheet", size: .init(width: 800, height: 560), makeView: { _ in
            let profile = SyncProfile(id: 1, name: "iPod Classic", outputFolder: "/Volumes/IPOD CLASSIC")
            let card = DevicePlaylistCard(
                id: "Road trip.m3u8", fileURL: URL(fileURLWithPath: "/Volumes/IPOD CLASSIC/Road trip.m3u8"),
                target: .existing(id: 1, name: "Road trip"), device: [1, 3], mlm: [1, 2, 4],
                diff: DevicePlaylistDiff.make(device: [1, 3], mlm: [1, 2, 4], expected: [1, 2]),
                unmatched: [.init(path: "Music/Unknown/track 07.m4a", reason: "no track in the library has this file")],
                labels: [
                    1: .init(title: "Jóga", artist: "Björk", availability: .local),
                    2: .init(title: "Rumble", artist: "Skrillex", availability: .local),
                    3: .init(title: "Kerala", artist: "Bonobo", availability: .local),
                    4: .init(title: "Stream Only", artist: "Remote Artist", availability: .notDownloaded),
                ])
            let model = DevicePlaylistChangesModel(profile: profile, service: nil, isReachable: { _ in true })
            model.load(cards: [card], unchanged: 6)
            return AnyView(DeviceChangesSheet(model: model))
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
        // Review ▸ Albums (W4-3): suggestions with source, match and alternatives; and the never-looked-up state.
        Fixture(id: "review-albums", size: .init(width: 1_100, height: 360), backend: .appKit, expectedTableRows: 4, makeView: { _ in
            try reviewAlbumsView(rows: 4, lookedUp: true)
        }),
        Fixture(id: "review-albums-empty", size: .init(width: 1_100, height: 360), makeView: { _ in
            try reviewAlbumsView(rows: 0, lookedUp: false)
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

    /// Review ▸ Albums over a temporary database: the model is preloaded, the table is the shared SwiftUI one.
    static func reviewAlbumsView(rows: Int, lookedUp: Bool) throws -> AnyView {
        let queue = try DatabaseManager.inMemory()
        let repository = AlbumSuggestionRepository(database: queue)
        let decisions = AlbumSuggestionDecisions(dependencies: .init(
            repository: repository, tagEdit: { TrackTagEdit.live(undo: nil) }, volumeName: { nil }, now: Date.init, didChange: {}))
        let lookup = AlbumLookupRunner(center: ActivityCenter(), repository: { repository }, libraryRoot: { nil },
                                       config: { nil }, suggester: TagAlbumSuggester(), didChange: {})
        let model = ReviewAlbumsModel(
            dependencies: .init(repository: repository, decisions: decisions, noAlbumCount: { 0 }, writesTags: { false }),
            lookup: lookup)
        let samples: [(String, String, String, Int?, String, Double, Int)] = [
            ("So U Know", "Overmono", "Good Lies", 2022, "Folder name", 95, 2),
            ("Feel Good", "Overmono", "Good Lies", 2022, "Library tags", 92, 0),
            ("Arpo", "Karenn", "Grapeshot", nil, "File name", 85, 1),
            ("Tangerine", "Bonobo", "Migration", 2017, "Library tags", 64, 0),
        ]
        let items: [AlbumSuggestionItem] = samples.prefix(rows).enumerated().map { index, sample in
            var track = Track(artist: sample.1, album: "", title: sample.0, format: "flac", originalPath: "/orig/\(index).flac")
            track.id = Int64(index + 1)
            let suggestion = AlbumSuggestion(albumTitle: sample.2, year: sample.3, source: sample.4, match: sample.5)
            let others = (0..<sample.6).map { AlbumSuggestion(albumTitle: "Other \($0 + 1)", year: 2001, source: "Folder name", match: 60) }
            return AlbumSuggestionItem(track: track, row: AlbumSuggestionRow(
                trackID: track.id ?? 0, suggestion: suggestion, alternatives: others, status: .pending, decidedAt: nil))
        }
        model.preload(
            items: items,
            counts: AlbumSuggestionCounts(pending: items.count, noMatch: 0, noAlbum: 0, rows: lookedUp ? items.count : 0),
            tracksWithoutAlbum: rows == 0 ? 0 : 6_341,
            bulkItems: items.filter { $0.row.suggestion.match > ReviewAlbumsModel.bulkThreshold })
        return AnyView(ReviewAlbumsView(model: model, onTrackActivated: { _, _ in }))
    }

    /// Source-file accounting remains explicit even where a source contains
    /// models, AppKit adapters, or services rather than a renderable View.
    static let inventory: [InventoryEntry] = inventoryPaths.map {
        InventoryEntry(path: $0, disposition: renderedPaths.contains($0)
            ? "Rendered: fixture registry."
            : exclusions[$0] ?? "")
    }

    static let renderedPaths: Set<String> = [
        "Folders/FolderOutlineTable.swift", "Library/DanceabilitySteps.swift",
        "Library/EnergyBars.swift", "Library/LibraryView.swift",
        "TrackList/TrackListTable.swift", "TrackList/TrackCell.swift", "TrackList/TrackRowPresentation.swift",
        "Playlists/PlaylistCard.swift",
        "Playlists/PlaylistTable.swift", "Queue/QueuePanel.swift",
        "Shared/StatusChip.swift",
        "Shared/TrackCoverView.swift", "DragDrop/DropTargetModifier.swift", "Launch/LibraryLoadingView.swift",
        "Shared/TrackMetadataPresentation.swift", "Sync/SyncProfileSheets.swift",
        "TrackDetail/WaveformView.swift", "Review/ReviewAlbumsView.swift",
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
        "Shared/SelectionCreationSheets.swift": "Non-view: identifiable selection wrapper (the sheet merged into Sync/NewSyncProfileSheet, W3-SYNC).",
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
        "Reels/ReelsView.swift": "Deferred: the page reads the library database and hosts the AVKit player; ReelsModel (list, selection, Use, Done, Delete, import, drops) is unit-tested on temporary databases with fakes (W3-DISC-B).",
        "Reels/ReelWorkbench.swift": "Deferred: an AVKit VideoPlayer and the keyframe popover over a live reel; the workbench state is ReelsModel, unit-tested (W3-DISC-B).",
        "Reels/ReelWorkbenchSections.swift": "Deferred: guesses, fields and results of the selected reel; their states are ReelBench / ReelsModel, unit-tested (W3-DISC-B).",
        "Reels/ReelLinkSheet.swift": "Deferred: the sheet hands its text to ReelsModel.addLink(text:); link recognition is ReelLinkParser, unit-tested (W3-DISC-B).",
        "Reels/ReelThumbnail.swift": "Deferred: a list thumbnail generated from the video file with AVFoundation (W3-DISC-B).",
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
        "Sync/NewSyncProfileSheet.swift": "Deferred: lists connected devices (reads /Volumes) on appear; needs an injected device list.",
        "Sync/SyncProfileMenu.swift": "Deferred: menus require interactive presentation; reads the live SyncViewModel and Activity.",
        "Sync/SyncProfilePage.swift": "Deferred: live SyncViewModel (plans, destinations, Activity echo); needs a passive sync fixture.",
        "Sync/SyncProfileSections.swift": "Deferred: live SyncViewModel and Activity echo; needs a passive sync fixture.",
        "Import/QuickAddSheet.swift": "Deferred: Add from Link is a sheet looking links up through yt-dlp; QuickAddModel is unit-tested (W3-ADD).",
        "Import/ImportPlaylistSheet.swift": "Deferred: the import sheet reads source accounts and providers; ImportPlaylistModel is unit-tested (W3-ADD).",
        "Import/SourceSignInView.swift": "Deferred: the browser sign-in hand-off waits for a real OAuth callback; SourceSignInModel is unit-tested (W3-ADD).",
        "Import/ImportSheetsHost.swift": "Deferred: presents the Add menu sheets on the main window; nothing drawn of its own (W3-ADD).",
        "Review/ReviewView.swift": "Deferred: the page reads the library database, the scan\u{2019}s Activity echo and the drive; ReviewModel / ReviewPresentation are unit-tested on temporary databases (W3-REV).",
        "Review/ReviewGroupList.swift": "Deferred: the group list hosts live comparisons; its decisions are ReviewModel plans, unit-tested (W3-REV).",
        "Review/ReviewComparison.swift": "Deferred: the comparison is the shared track table over live tracks plus the conflict grid; ReviewModel plans are unit-tested (W3-REV).",
        "Review/ReviewResolvedView.swift": "Deferred: Resolved reads the decision history; its rows and outcomes are unit-tested (ReviewPresentationTests, W3-REV).",
        "Review/ReviewVersionCells.swift": "Deferred: cells of the shared track table (version radio, location, used in); the words they show are ReviewPresentation, unit-tested (W3-REV).",
        "Genres/GenresView.swift": "Deferred: the genre list loads its counts from the library database; GenreOverview / GenreLookalikes are unit-tested (W3-GEN).",
        "Genres/GenreDetailView.swift": "Deferred: the genre page loads tracks and runs tag edits; GenreEdits is unit-tested on temporary databases (W3-GEN).",
        "Genres/GenreSuggestionsSection.swift": "Deferred: suggestions are computed from the similarity analysis; GenreWorkbench / GenreSuggestionRules are unit-tested (W3-GEN).",
        "Genres/GenreMergeSheet.swift": "Deferred: the merge sheet reads the genres' tracks; the merge edit is unit-tested (GenreEditsTests).",
        "Genres/CreateMLExportSheet.swift": "Deferred: the export sheet reads the library and the disk; CreateMLExportPlan / CreateMLExporter are unit-tested.",
        "Genres/GenreMenu.swift": "Deferred: the genre menu builder reads the shell environment; its sections are unit-tested (GenreMenuModelTests).",
        "Genres/GenreRequests.swift": "Non-view: window-level genre requests (the export sheet from File ▸ Export) — hosts the sheet only.",
        "Discover/DiscoverView.swift": "Deferred: the page reads the library database, the drive and the selection; DiscoverModel (groups, counts, Keep, Dismiss, Find Recommendations) is unit-tested on temporary databases (W3-DISC-A).",
        "Discover/RecommendationsView.swift": "Deferred: the groups are the shared track table over live tracks; their verdicts are DiscoverModel, unit-tested (W3-DISC-A).",
        "Discover/RecommendationCells.swift": "Deferred: the source cell of the shared track table (word and 6 pt dot); the words are DiscoverModel.sourceWord, unit-tested (W3-DISC-A).",
        "Discover/DiscoverLive.swift": "Non-view: the app\u{2019}s wiring of DiscoverModel (repositories, downloads, analysis, playlist placement) (W3-DISC-A).",
        "Similar/SimilarView.swift": "Deferred: the page reads the library database, the sources and the download pipeline; SimilarModel (matches, online rows, Download and Keep, failures) is unit-tested on temporary databases (W3-DISC-A).",
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
Discover/DiscoverLive.swift
Discover/DiscoverView.swift
Discover/RecommendationCells.swift
Discover/RecommendationsView.swift
DragDrop/DropTargetModifier.swift
Folders/FolderMenus.swift
Folders/FolderOutlineTable.swift
Folders/FolderPathBar.swift
Folders/FoldersView.swift
Genres/CreateMLExportSheet.swift
Genres/GenreDetailView.swift
Genres/GenreMenu.swift
Genres/GenreMergeSheet.swift
Genres/GenreRequests.swift
Genres/GenreSuggestionsSection.swift
Genres/GenresView.swift
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
Reels/ReelLinkSheet.swift
Reels/ReelThumbnail.swift
Reels/ReelWorkbench.swift
Reels/ReelWorkbenchSections.swift
Reels/ReelsView.swift
Review/ReviewAlbumsView.swift
Review/ReviewComparison.swift
Review/ReviewGroupList.swift
Review/ReviewResolvedView.swift
Review/ReviewVersionCells.swift
Review/ReviewView.swift
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
Similar/SimilarView.swift
Sync/NewSyncProfileSheet.swift
Sync/Pickers/PlaylistPickerModel.swift
Sync/SyncProfileMenu.swift
Sync/SyncProfilePage.swift
Sync/SyncProfileSections.swift
Sync/SyncProfileSheets.swift
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
