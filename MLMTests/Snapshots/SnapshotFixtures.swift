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
            return AnyView(PlaylistCard(
                playlist: playlist,
                source: nil,
                trackCount: 2,
                downloadStatus: PlaylistDownloadStatus(
                    playlistID: 1, totalTracks: 2, localTracks: 1,
                    downloadingTracks: 0, failedTracks: 0, notDownloadedTracks: 1
                ),
                isRenaming: false,
                renameText: .constant(""),
                onTap: {}, onRename: {}, onConfirmRename: {}, onCancelRename: {},
                onTogglePin: {}, onDelete: {}
            ))
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
        Fixture(id: "new-playlist-sheet", size: .init(width: 440, height: 260), makeView: { _ in
            AnyView(NewPlaylistFromSelectionSheet(trackIds: [1, 2]))
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
        Fixture(id: "playback-queue-unavailable", size: .init(width: 800, height: 560), makeView: { _ in
            AnyView(PlaybackQueueView())
        }),
    ]

    static let additionalFixtures: [Fixture] = [
        Fixture(
            id: "library-table-populated",
            size: .init(width: 1_100, height: 460),
            backend: .appKit,
            expectedTableRows: 5,
            makeView: { store in
                let tracks = try store.tracksForRendering()
                let availability = SnapshotFixtureData.availability(for: tracks)
                let model = LibraryViewModel(
                    trackRepository: try SnapshotFixtures.require(
                        store.container.trackRepository, named: "track repository"
                    ),
                    configRepository: try SnapshotFixtures.require(
                        store.container.configRepository, named: "config repository"
                    ),
                    preloadedTracks: tracks,
                    selectedTab: .local,
                    availabilityByTrackID: availability
                )
                return AnyView(LibraryTable(
                    viewModel: model,
                    availablePlaylists: try store.playlists()
                ))
            }
        ),
        Fixture(
            id: "track-table-populated",
            size: .init(width: 1_100, height: 460),
            backend: .appKit,
            expectedTableRows: 5,
            makeView: { store in
                let tracks = try store.tracksForRendering()
                return AnyView(TrackTable(
                    rows: tracks.compactMap { track in
                        track.id.map { TrackTable.Row(id: $0, track: track) }
                    },
                    selection: .constant([]),
                    availabilityByTrackID: SnapshotFixtureData.availability(for: tracks),
                    availablePlaylists: try store.playlists(),
                    emptyContent: { EmptyView() }
                ))
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
                return AnyView(PlaylistTable(
                    playlist: playlist,
                    viewModel: model,
                    availablePlaylists: try store.playlists(),
                    onRemoveTracks: { _ in }
                ))
            }
        ),
        Fixture(
            id: "folder-tracks-populated",
            size: .init(width: 1_100, height: 460),
            backend: .appKit,
            expectedTableRows: 5,
            makeView: { store in
                let tracks = try store.tracksForRendering()
                return AnyView(FolderTracksTable(
                    tracks: tracks,
                    availabilityByTrackID: SnapshotFixtureData.availability(for: tracks),
                    selectedTrackIDs: .constant([]),
                    availablePlaylists: try store.playlists(),
                    availableSyncProfiles: [],
                    onDoubleClick: nil
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
        Fixture(
            id: "universal-search-idle",
            size: .init(width: 760, height: 540),
            makeView: { _ in
                AnyView(UniversalSearchView(onDismiss: {}))
            }
        ),
        Fixture(id: "track-cover-placeholder", size: .init(width: 220, height: 220), makeView: { _ in
            AnyView(TrackCoverView(trackId: 1, size: .small).frame(width: 180, height: 180).padding(20))
        }),
        Fixture(id: "spring-hover-resting", size: .init(width: 300, height: 100), makeView: { _ in
            AnyView(Text("Snapshot drop target").padding(20).springLoadableHover(onTrigger: {}))
        }),
        Fixture(id: "first-run-welcome", size: .init(width: 560, height: 460), makeView: { _ in
            AnyView(FirstRunWizard(onComplete: {}).padding(20))
        }),
        Fixture(id: "new-sync-profile-sheet", size: .init(width: 460, height: 400), makeView: { _ in
            AnyView(NewSyncProfileFromSelectionSheet(trackIds: [1, 4]))
        }),
        Fixture(id: "debug-no-local-file", size: .init(width: 400, height: 160), makeView: { store in
            let track = try require(store.tracks().first(where: { $0.title == "Offline File" }), named: "missing-file track")
            return AnyView(DebugTabView(track: track, preloadedMissingLocalFile: true).padding(16))
        }),
        Fixture(id: "track-table-empty", size: .init(width: 900, height: 400), makeView: { _ in
            AnyView(TrackTable(rows: [], selection: .constant([]), emptyContent: {
                ContentUnavailableView("No tracks", systemImage: "music.note")
            }))
        }),
        Fixture(id: "track-table-error", size: .init(width: 900, height: 400), makeView: { _ in
            AnyView(TrackTable(
                rows: [], selection: .constant([]),
                errorMessage: "The library could not be read. Try again.",
                emptyContent: { EmptyView() }
            ))
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
                let localTracks = allTracks.filter(\.isLocal)
                let model = LibraryViewModel(
                    trackRepository: try require(store.container.trackRepository, named: "track repository"),
                    configRepository: try require(store.container.configRepository, named: "config repository"),
                    preloadedTracks: localTracks,
                    availabilityByTrackID: SnapshotFixtureData.availability(for: localTracks),
                    localCount: allTracks.filter(\.isLocal).count,
                    remoteCount: allTracks.filter(\.isRemote).count
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
        "Folders/FoldersView.swift", "Library/DanceabilitySteps.swift",
        "Library/EnergyBars.swift", "Library/LibraryTable.swift", "Library/LibraryView.swift",
        "Library/TrackTable.swift", "Playlists/PlaylistCard.swift",
        "Playlists/PlaylistTable.swift", "Queue/PlaybackQueueView.swift",
        "ReviewQueue/ReviewQueueView.swift",
        "Shared/SelectionCreationSheets.swift", "Shared/StatusChip.swift",
        "Shared/TrackCoverView.swift", "Shared/SpringLoadableHover.swift", "Shared/FirstRunWizard.swift",
        "Shared/TrackMetadataPresentation.swift", "Sync/DeviceIngestResultsView.swift",
        "Sync/IngestPreviewView.swift", "Sync/SyncToast.swift",
        "TrackDetail/WaveformView.swift", "TrackDetail/DebugTabView.swift", "Search/UniversalSearchView.swift",
    ]

    private static let exclusions: [String: String] = [
        "Activity/ActivityFeed.swift": "Non-view: feed value model.",
        "Activity/ActivityFeedAdapters.swift": "Non-view: model adapters.",
        "Activity/LogFeed.swift": "Non-view: log query model.",
        "Activity/LogTextRenderer.swift": "Non-view: attributed-text helper.",
        "Shared/DownloadRetryBudget.swift": "Non-view: retry helper.",
        "Shared/TrackPresentationAvailability.swift": "Non-view: availability mapper; explicit states are rendered by tables/chips.",
        "Sync/Pickers/PlaylistPickerModel.swift": "Non-view: selection model.",
        "TrackDetail/WaveformHelpers.swift": "Non-view: waveform math; production WaveformView is captured.",
        "Activity/ActivityPanel.swift": "Deferred: persisted AppStorage and live global operation state need injected preferences/feed.",
        "Activity/LogsTab.swift": "Deferred: global logger and AppKit text representable need fixed attributed-log input.",
        "Activity/OperationsTab.swift": "Deferred: directly reads shared performance/download queues; needs immutable feed injection.",
        "ContentView/ContentView.swift": "Deferred: real shell, startup/router/toolbar lifecycle; needs application-level fixture composition.",
        "Folders/FolderTreeView.swift": "Deferred: NSOutlineView delegate/expansion lifecycle requires hosted outline readiness contract.",
        "Library/TrackContextMenu.swift": "Deferred: menus require interactive presentation; current bitmap hosts do not open them.",
        "Player/PlayerBar.swift": "Deferred: concrete playback VM initializes audio/timer/media state; needs passive transport protocol.",
        "Playlists/PlaylistDetailView.swift": "Deferred: lifecycle reloads, source sync and cover work not isolated by table fixture.",
        "Playlists/PlaylistDetailViewLoader.swift": "Deferred: loader async outcomes require controlled ready/not-found/failure injection.",
        "Playlists/PlaylistsView.swift": "Deferred: live playlist/cover loading and root view state need a preloaded composition.",
        "ReelsInbox/ReelsInboxView.swift": "Deferred: AVKit/Shazam/Vision work and detached tasks require service/clock seams.",
        "Search/GlobalSearchPresentationView.swift": "Deferred: constructs search services from container; inject a preloaded presentation model.",
        "Settings/BackupSettingsView.swift": "Deferred: container-backed backup service and folder/Finder panels require an inert backup model.",
        "Settings/DataLocationsView.swift": "Deferred: container-backed paths, backup service and filesystem sizes require an inert locations model.",
        "Settings/LibrarySetupView.swift": "Deferred: import/filesystem state and folder panels require inert import model.",
        "Shared/LibraryLaunchStateView.swift": "Deferred: A3 launch placeholder with open panel; baselines wait for the B1 library picker design.",
        "Settings/MaintenanceView.swift": "Deferred: reads shared BatchControl/maintenance queues and paths; inject passive state.",
        "Settings/SettingsView.swift": "Deferred: AppStorage selection and PlaybackSettings read real defaults; inject preference store.",
        "Settings/SourcesSetupView.swift": "Deferred: AppStorage cookie and credential state require isolated preferences and auth provider.",
        "Sidebar/PinnedPlaylistsDisclosure.swift": "Deferred: async list/rename state requires preloaded pinned model and readiness assertion.",
        "Sidebar/SidebarView.swift": "Deferred: composes live badge/pinned state; needs immutable sidebar presentation fixture.",
        "Sources/RemotePlaylistsView.swift": "Deferred: concrete remote providers fetch on presentation; inject provider clients.",
        "Sources/SourcesView.swift": "Deferred: source model requires OAuth/token clients; needs inert account-status composition.",
        "Sync/Pickers/PlaylistPickerSheet.swift": "Deferred: concrete SyncViewModel requires filesystem TranscodeCache and standard-default-reading SyncService.",
        "Sync/SyncContentSections.swift": "Deferred: same concrete SyncViewModel boundary; needs passive expanded-content model.",
        "Sync/SyncFailedDisclosure.swift": "Deferred: concrete sync VM plus async row lookup; inject passive failed-row state.",
        "Sync/SyncProfileDetailView.swift": "Deferred: live device file checks, cache age and preview task need filesystem/clock seams.",
        "Sync/SyncSettingsForm.swift": "Deferred: concrete sync service supplies preference state; inject settings bindings/actions.",
        "Sync/SyncView.swift": "Deferred: profile/device/preview lifecycle needs inert sync coordinator.",
        "TrackDetail/GrooveStudioView.swift": "Deferred: audio players, model/export services and placeholder randomness need passive deck state.",
        "TrackDetail/GrooveView.swift": "Deferred: preview audio, recommendations and random placeholders require controlled provider/player state.",
        "TrackDetail/MetadataPanel.swift": "Deferred: multiple track-scoped tasks, defaults and shared analysis state need preloaded tab model.",
        "TrackDetail/TrackDetailView.swift": "Deferred: composes playback/waveform/metadata lifecycles; only safe child fixtures captured.",
    ]

    private static let inventoryPaths = """
Activity/ActivityFeed.swift
Activity/ActivityFeedAdapters.swift
Activity/ActivityPanel.swift
Activity/LogFeed.swift
Activity/LogsTab.swift
Activity/LogTextRenderer.swift
Activity/OperationsTab.swift
ContentView/ContentView.swift
Discover/DiscoverView.swift
DiscoveryInbox/DiscoveryInboxView.swift
Folders/FoldersView.swift
Folders/FolderTreeView.swift
Library/DanceabilitySteps.swift
Library/EnergyBars.swift
Library/LibraryTable.swift
Library/LibraryView.swift
Library/TrackContextMenu.swift
Library/TrackTable.swift
Player/PlayerBar.swift
Playlists/PlaylistCard.swift
Playlists/PlaylistDetailView.swift
Playlists/PlaylistDetailViewLoader.swift
Playlists/PlaylistsView.swift
Playlists/PlaylistTable.swift
Queue/PlaybackQueueView.swift
ReelsInbox/ReelsInboxView.swift
ReviewQueue/ReviewQueueView.swift
Search/GlobalSearchPresentationView.swift
Search/UniversalSearchView.swift
Settings/BackupSettingsView.swift
Settings/DataLocationsView.swift
Settings/LibrarySetupView.swift
Settings/MaintenanceView.swift
Settings/SettingsView.swift
Settings/SourcesSetupView.swift
Shared/DownloadRetryBudget.swift
Shared/FirstRunWizard.swift
Shared/LibraryLaunchStateView.swift
Shared/SelectionCreationSheets.swift
Shared/SpringLoadableHover.swift
Shared/StatusChip.swift
Shared/TrackCoverView.swift
Shared/TrackMetadataPresentation.swift
Shared/TrackPresentationAvailability.swift
Sidebar/PinnedPlaylistsDisclosure.swift
Sidebar/SidebarView.swift
Sources/RemotePlaylistsView.swift
Sources/SourcesView.swift
Sync/DeviceIngestResultsView.swift
Sync/IngestPreviewView.swift
Sync/Pickers/PlaylistPickerModel.swift
Sync/Pickers/PlaylistPickerSheet.swift
Sync/SyncContentSections.swift
Sync/SyncFailedDisclosure.swift
Sync/SyncProfileDetailView.swift
Sync/SyncSettingsForm.swift
Sync/SyncToast.swift
Sync/SyncView.swift
TrackDetail/DebugTabView.swift
TrackDetail/GrooveStudioView.swift
TrackDetail/GrooveView.swift
TrackDetail/MetadataPanel.swift
TrackDetail/TrackDetailView.swift
TrackDetail/WaveformHelpers.swift
TrackDetail/WaveformView.swift
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
