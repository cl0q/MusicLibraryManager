import SwiftUI

/// Queue view showing three sections: History, Currently Playing, Next Up.
///
/// Reads from the PlaybackViewModel via the DependencyContainer environment.
struct PlaybackQueueView: View {
    @Environment(\.container) private var container
    @State private var history = TrackListModel()
    @State private var nowPlaying = TrackListModel()
    @State private var upNext = TrackListModel()

    var body: some View {
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

    // MARK: - History Table (the shared track table, W2-A; W2-D rebuilds the Queue)

    private func historyTable(_ vm: PlaybackViewModel) -> some View {
        TrackListTable(
            model: history,
            configuration: .queue(section: "history", accessibilityID: "queue_history_table") { track, _ in
                guard let playbackVM = container.playbackViewModel else { return }
                Task { await playbackVM.playTrack(track) }
            }
        ) {
            emptyState("No history yet", icon: "clock")
        }
        .task(id: vm.history.compactMap(\.id)) {
            await history.setTracks(Array(vm.history.reversed()))
        }
        .frame(minHeight: 150)
    }

    // MARK: - Now Playing Table

    private func nowPlayingTable(_ vm: PlaybackViewModel) -> some View {
        TrackListTable(
            model: nowPlaying,
            configuration: .queue(section: "nowPlaying", accessibilityID: "queue_now_playing_table") { track, _ in
                guard let playbackVM = container.playbackViewModel else { return }
                Task { await playbackVM.playTrack(track) }
            }
        ) {
            emptyState("Nothing playing", icon: "pause.circle")
        }
        .task(id: vm.currentTrack?.id) {
            await nowPlaying.setTracks(vm.currentTrack.map { [$0] } ?? [])
        }
        .frame(height: 64)
    }

    // MARK: - Up Next Table

    private func upNextTable(_ vm: PlaybackViewModel) -> some View {
        TrackListTable(
            model: upNext,
            configuration: .queue(section: "next", accessibilityID: "queue_upnext_table") { track, _ in
                guard let playbackVM = container.playbackViewModel else { return }
                Task { await playbackVM.playFromQueue(track: track) }
            }
        ) {
            emptyState("Queue is empty", icon: "list.number")
        }
        .task(id: vm.upcoming.compactMap(\.id)) {
            await upNext.setTracks(vm.upcoming)
        }
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
