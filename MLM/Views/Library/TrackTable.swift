import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

/// Shared, sortable SwiftUI `Table` for track rows.
///
/// Single source of truth for the track-table look & behavior: columns,
/// cells, context menu, and double-click handling. `LibraryTable` wraps
/// this for the library; the global search results reuse it unchanged so
/// search rows behave exactly like library rows.
///
/// Sorting is parent-driven: the table reports header clicks via
/// `onSortChange` and renders `rows` in the order the parent provides.
struct TrackTable: View {
    /// Identifiable wrapper so `Table` selection can use `Set<Int64>`
    /// even though `Track.id` is `Int64?` for unsaved DB rows.
    struct Row: Identifiable, Equatable {
        let id: Int64
        let track: Track
    }

    let rows: [Row]
    @Binding var selection: Set<Int64>

    /// Initial header sort indicator (defaults to Added descending).
    var initialSortOrder: [KeyPathComparator<Row>] = [
        KeyPathComparator(\.track.dateAddedSortKey, order: .reverse)
    ]

    /// Called when the user clicks a sortable column header.
    var onSortChange: ((SortColumn, Bool) -> Void)? = nil

    /// Called on double-click / primary action with the clicked track and
    /// the visible rows in display order (the playback queue).
    var onDoubleClick: ((Track, [Track]) -> Void)? = nil

    var availabilityByTrackID: [Int64: TrackAvailability] = [:]
    var availablePlaylists: [Playlist] = []
    var availableSyncProfiles: [SyncProfile] = []
    var addToSyncProfile: ((SyncProfile, Set<Int64>) -> Void)? = nil
    var playlist: Playlist? = nil
    var onRemoveFromPlaylist: ((Set<Int64>) -> Void)? = nil

    /// Playlist id used as drag source for reorder-aware drop targets.
    var dragSourcePlaylistID: Int64? = nil

    var isLoading: Bool = false
    var errorMessage: String? = nil
    var contextMenuAllowsLibraryActions: Bool = true
    /// What this list is for the menu bar's track commands (`TrackSelection`, W1-2).
    var listContext: TrackListContext = .unnamed
    private let emptyContent: AnyView

    var accessibilityID: String = "track_table"

    @Environment(\.container) private var container

    @State private var sortOrder: [KeyPathComparator<Row>]

    init<EmptyContent: View>(
        rows: [Row],
        selection: Binding<Set<Int64>>,
        initialSortOrder: [KeyPathComparator<Row>] = [
            KeyPathComparator(\.track.dateAddedSortKey, order: .reverse)
        ],
        onSortChange: ((SortColumn, Bool) -> Void)? = nil,
        onDoubleClick: ((Track, [Track]) -> Void)? = nil,
        availabilityByTrackID: [Int64: TrackAvailability] = [:],
        availablePlaylists: [Playlist] = [],
        availableSyncProfiles: [SyncProfile] = [],
        addToSyncProfile: ((SyncProfile, Set<Int64>) -> Void)? = nil,
        playlist: Playlist? = nil,
        onRemoveFromPlaylist: ((Set<Int64>) -> Void)? = nil,
        dragSourcePlaylistID: Int64? = nil,
        isLoading: Bool = false,
        errorMessage: String? = nil,
        contextMenuAllowsLibraryActions: Bool = true,
        listContext: TrackListContext = .unnamed,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent,
        accessibilityID: String = "track_table"
    ) {
        self.listContext = listContext
        self.rows = rows
        self._selection = selection
        self.initialSortOrder = initialSortOrder
        self.onSortChange = onSortChange
        self.onDoubleClick = onDoubleClick
        self.availabilityByTrackID = availabilityByTrackID
        self.availablePlaylists = availablePlaylists
        self.availableSyncProfiles = availableSyncProfiles
        self.addToSyncProfile = addToSyncProfile
        self.playlist = playlist
        self.onRemoveFromPlaylist = onRemoveFromPlaylist
        self.dragSourcePlaylistID = dragSourcePlaylistID
        self.isLoading = isLoading
        self.errorMessage = errorMessage
        self.contextMenuAllowsLibraryActions = contextMenuAllowsLibraryActions
        self.emptyContent = AnyView(emptyContent())
        self.accessibilityID = accessibilityID
        self._sortOrder = State(initialValue: initialSortOrder)
    }

    var body: some View {
        Group {
            if isLoading {
                loadingState
            } else if let errorMessage {
                errorState(errorMessage)
            } else if rows.isEmpty {
                emptyContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                tableView
            }
        }
    }

    // MARK: - Table

    private var tableView: some View {
        Table(selection: $selection, sortOrder: $sortOrder) {
            Group {
                TableColumn("Title", value: \Row.track.title) { row in
                    let track = row.track
                    HStack(spacing: 8) {
                        // UI-SPEC Surface 1: 18pt thumbnail, cornerRadius 4, HStack spacing 8
                        TrackCoverView(trackId: track.id ?? 0, size: .small, cornerRadius: 4)
                            .frame(width: 18, height: 18)

                        if isNowPlaying(track) {
                            Image(systemName: "speaker.wave.2.fill")
                                .imageScale(.small)
                                .foregroundStyle(Color.mlmAccent)
                                .symbolEffect(.variableColor, isActive: true)
                        }
                        Text(track.title)
                            .lineLimit(1)
                            .foregroundStyle(isNowPlaying(track) ? Color.mlmAccent : Color.mlmInk)
                    }
                }
                .width(min: 160, ideal: 280)

                TableColumn("Artist", value: \Row.track.artist) { row in
                    TrackMetadataText(row.track.artist)
                }
                .width(min: 100, ideal: 180)

                TableColumn("Album", value: \Row.track.album) { row in
                    TrackMetadataText(row.track.album, secondary: true)
                }
                .width(min: 100, ideal: 180)

                TableColumn("Time", value: \Row.track.durationSortKey) { row in
                    Text(row.track.formattedDuration)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(54)

                TableColumn("Format", value: \Row.track.format) { row in
                    Text(displayFormat(for: row.track))
                        .foregroundStyle(.secondary)
                }
                .width(60)

                TableColumn("Status") { row in
                    if let trackID = row.track.id,
                       let availability = availabilityByTrackID[trackID],
                       let statusChip = StatusChip(availability: availability) {
                        statusChip
                    }
                }
                .width(90)
            }

            Group {
                TableColumn("kbps", value: \Row.track.bitrateSortKey) { row in
                    Text(row.track.bitrate.map { "\($0)" } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(48)

                TableColumn("Genre", value: \Row.track.genreSortKey) { row in
                    Text(row.track.genre ?? "—")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 70, ideal: 110)

                TableColumn("Year", value: \Row.track.yearSortKey) { row in
                    Text(row.track.year.map { "\($0)" } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(48)

                TableColumn("Energy", value: \Row.track.energySortKey) { row in
                    EnergyBars(level: row.track.energyBucket)
                }
                .width(56)

                TableColumn("Dance", value: \Row.track.danceabilitySortKey) { row in
                    DanceabilitySteps(score: row.track.danceability)
                }
                .width(56)

                TableColumn("BPM", value: \Row.track.bpmSortKey) { row in
                    Text(row.track.bpm.map { "\($0)" } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(48)

                TableColumn("Added", value: \Row.track.dateAddedSortKey) { row in
                    Text(formatDateAdded(row.track.dateAddedLibrary ?? row.track.dateAdded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(78)
            }
        } rows: {
            ForEach(rows) { row in
                TableRow(row)
                    .draggable(TrackDragData(trackId: row.id, sourcePlaylistId: dragSourcePlaylistID))
            }
        }
        .contextMenu(forSelectionType: Int64.self) { selectedIDs in
            TrackContextMenu(
                selectedTrackIDs: selectedIDs,
                tracks: rows.map(\.track),
                availablePlaylists: availablePlaylists,
                availableSyncProfiles: availableSyncProfiles,
                addToSyncProfile: { profile in
                    addToSyncProfile?(profile, selectedIDs)
                },
                playlist: playlist,
                onRemoveFromPlaylist: onRemoveFromPlaylist.map { remove in
                    { remove(selectedIDs) }
                },
                allowsLibraryActions: contextMenuAllowsLibraryActions
            )
        } primaryAction: { selectedIDs in
            if let trackID = selectedIDs.first,
               let track = rows.first(where: { $0.id == trackID })?.track {
                onDoubleClick?(track, rows.map(\.track))
            }
        }
        .onChange(of: sortOrder) { _, newOrder in
            guard let first = newOrder.first else { return }
            let col: SortColumn
            switch first.keyPath {
            case \Row.track.title:          col = .title
            case \Row.track.artist:         col = .artist
            case \Row.track.album:          col = .album
            case \Row.track.durationSortKey: col = .duration
            case \Row.track.format:         col = .format
            case \Row.track.bitrateSortKey: col = .bitrate
            case \Row.track.genreSortKey:   col = .genre
            case \Row.track.yearSortKey:    col = .year
            case \Row.track.energySortKey:  col = .energy
            case \Row.track.danceabilitySortKey: col = .danceability
            case \Row.track.bpmSortKey: col = .bpm
            case \Row.track.dateAddedSortKey: col = .dateAdded
            default: return
            }
            onSortChange?(col, first.order == .forward)
        }
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(accessibilityID)
        // The menu bar's Track commands act on this list while it has focus (UC-SEL-02).
        .focusedValue(\.trackSelection, menuSelection)
    }

    /// This list as the Track menu sees it (`TrackSelection`, W1-2).
    private var menuSelection: TrackSelection {
        let selection = $selection
        return TrackSelection(
            selectedIDs: selection.wrappedValue,
            rows: rows,
            id: \.id,
            isPlayable: { $0.track.isLocal },
            track: \.track,
            context: listContext,
            target: TrackCommandTarget(
                activate: onDoubleClick,
                removeFromContainer: onRemoveFromPlaylist,
                deselectAll: { selection.wrappedValue = [] },
                playlists: availablePlaylists.filter { $0.id != playlist?.id },
                syncProfiles: availableSyncProfiles,
                addToSyncProfile: addToSyncProfile
            )
        )
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
            Text("Loading tracks…").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        ContentUnavailableView {
            Label("Failed to load tracks", systemImage: "exclamationmark.triangle.fill")
        } description: {
            Text(message)
        }
    }

    // MARK: - Helpers

    /// Whether a track is the currently playing track.
    private func isNowPlaying(_ track: Track) -> Bool {
        guard let playbackVM = container.playbackViewModel,
              let currentTrack = playbackVM.currentTrack,
              let currentID = currentTrack.id,
              let trackID = track.id else {
            return false
        }
        return currentID == trackID && playbackVM.isPlaying
    }

    private func displayFormat(for track: Track) -> String {
        let format = track.format.trimmingCharacters(in: .whitespacesAndNewlines)
        return format.isEmpty ? "—" : format.uppercased()
    }

    /// Format date_added for display (e.g., "2026-05-07" → "May 7").
    private func formatDateAdded(_ dateString: String?) -> String {
        Self.formatDateAddedShared(dateString)
    }

    // Shared formatters — DateFormatter init is expensive (~0.03ms each),
    // so reuse static instances across all rows instead of creating new ones per row.
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private static func formatDateAddedShared(_ dateString: String?) -> String {
        guard let dateString else { return "—" }
        if let date = isoFormatter.date(from: String(dateString.prefix(10))) {
            return displayFormatter.string(from: date)
        }
        return String(dateString.prefix(10))
    }
}
