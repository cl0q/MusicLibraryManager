import SwiftUI

/// Content of the trailing column (`.inspector`, UC-TRAIL-01): a segmented Info | Queue
/// switch at the top, then the mode's content.
///
/// - **Info** is the track inspector (`InspectorView`, W2-E) for the selection of the last
///   track list (`InspectedTrackSelection`) — never the playing track (UC-TRAIL-03).
/// - **Queue** hosts the existing `PlaybackQueueView` (rebuilt by W2-D).
struct TrailingColumnView: View {
    @Environment(TrailingColumnState.self) private var state
    private var inspected: InspectedTrackSelection { InspectedTrackSelection.shared }

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
                InspectorView(selection: inspected.trackIDs)
            case .queue:
                PlaybackQueueView()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
