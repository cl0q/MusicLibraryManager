import SwiftUI

/// Content of the trailing column (`.inspector`, UC-TRAIL-01): a segmented Info | Queue
/// switch at the top, then the mode's content.
///
/// - **Info** hosts the existing `TrackDetailView` for `infoTrack` (the track last activated
///   in a list, as before). Following the table selection, the multi-track form and the
///   Details · Audio · File tabs arrive with W2-E.
/// - **Queue** hosts the existing `PlaybackQueueView` (rebuilt by W2-D).
struct TrailingColumnView: View {
    let infoTrack: Track?

    @Environment(TrailingColumnState.self) private var state

    var body: some View {
        @Bindable var state = state
        VStack(spacing: 0) {
            Picker("Show", selection: $state.mode) {
                ForEach(TrailingColumnState.Mode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(Spacing.s)

            Divider()

            switch state.mode {
            case .info:
                if let infoTrack {
                    TrackDetailView(track: infoTrack)
                } else {
                    ContentUnavailableView(
                        "No selection",
                        systemImage: "info.circle",
                        description: Text("Select a track to see and edit its details.")
                    )
                }
            case .queue:
                PlaybackQueueView()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
