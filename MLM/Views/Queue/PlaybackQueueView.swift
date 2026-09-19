import SwiftUI

/// Queue view showing three sections: History, Currently Playing, Next Up.
///
/// Reads from the PlaybackViewModel via the DependencyContainer environment.
struct PlaybackQueueView: View {
    @Environment(\.container) private var container
    @State private var historySelection = Set<Int64>()
    @State private var nowPlayingSelection = Set<Int64>()
    @State private var upNextSelection = Set<Int64>()

    var body: some View {
        // [navperf] temporary instrumentation — remove after measurement
        let _ = print("[navperf] section-body queue \(Date().timeIntervalSince1970)")
        VStack(spacing: 0) {
            if let playbackVM = container.playbackViewModel {
                // History section
                Section {
                    historyTable(playbackVM)
                } header: {
                    sectionHeader("History")
                }

                Divider()

                // Currently playing section
                Section {
                    nowPlayingTable(playbackVM)
                } header: {
                    sectionHeader("Currently playing")
                }

                Divider()

                // Next up section
                Section {
                    upNextTable(playbackVM)
                } header: {
                    sectionHeader("Next up")
                }
            } else {
                ContentUnavailableView(
                    "No Playback",
                    systemImage: "speaker.slash",
                    description: Text("Playback is not available.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.mlmBase)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkMuted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - History Table

    private func historyTable(_ vm: PlaybackViewModel) -> some View {
        let historyRows = vm.history.reversed().compactMap { track -> TrackTable.Row? in
            guard let id = track.id else { return nil }
            return TrackTable.Row(id: id, track: track)
        }

        return TrackTable(
            rows: historyRows,
            selection: $historySelection,
            onDoubleClick: { track, _ in
                guard let playbackVM = container.playbackViewModel else { return }
                Task { await playbackVM.playTrack(track) }
            },
            emptyContent: {
                emptyState("No history yet", icon: "clock")
            },
            accessibilityID: "queue_history_table"
        )
        .frame(minHeight: 150)
    }

    // MARK: - Now Playing Table

    private func nowPlayingTable(_ vm: PlaybackViewModel) -> some View {
        let nowPlayingRows: [TrackTable.Row] = {
            guard let track = vm.currentTrack, let id = track.id else { return [] }
            return [TrackTable.Row(id: id, track: track)]
        }()

        return TrackTable(
            rows: nowPlayingRows,
            selection: $nowPlayingSelection,
            onDoubleClick: { track, _ in
                guard let playbackVM = container.playbackViewModel else { return }
                Task { await playbackVM.playTrack(track) }
            },
            emptyContent: {
                emptyState("Nothing playing", icon: "pause.circle")
            },
            accessibilityID: "queue_now_playing_table"
        )
        .frame(height: 64)
    }

    // MARK: - Up Next Table

    private func upNextTable(_ vm: PlaybackViewModel) -> some View {
        let upNextRows = vm.upcoming.compactMap { track -> TrackTable.Row? in
            guard let id = track.id else { return nil }
            return TrackTable.Row(id: id, track: track)
        }

        return TrackTable(
            rows: upNextRows,
            selection: $upNextSelection,
            onDoubleClick: { track, _ in
                guard let playbackVM = container.playbackViewModel else { return }
                Task { await playbackVM.playFromQueue(track: track) }
            },
            emptyContent: {
                emptyState("Queue is empty", icon: "list.number")
            },
            accessibilityID: "queue_upnext_table"
        )
        .frame(minHeight: 150)
    }

    // MARK: - Empty State

    private func emptyState(_ message: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(.mlmInkMuted)
            Text(message)
                .font(MLMFont.body)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
