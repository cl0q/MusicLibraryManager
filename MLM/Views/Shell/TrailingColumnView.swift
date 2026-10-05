import SwiftUI

/// Content of the trailing column (`.inspector`, UC-TRAIL-01): a segmented Info | Queue
/// switch at the top, then the mode's content.
///
/// - **Info** is the track inspector (`InspectorView`, W2-E) for the selection of the last
///   track list (`InspectedTrackSelection`) — never the playing track (UC-TRAIL-03); an explicit
///   `Show Details` of an unselected track (`InfoTrackRequest`) shows that one until the
///   selection changes.
/// - **Queue** is the Queue panel (`QueuePanel`, W2-D, P-QUEUE).
struct TrailingColumnView: View {
    @Environment(TrailingColumnState.self) private var state
    private var inspected: InspectedTrackSelection { InspectedTrackSelection.shared }
    private var request: InfoTrackRequest { InfoTrackRequest.shared }

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
                InspectorView(selection: request.effectiveSelection(inspected.trackIDs))
            case .queue:
                QueuePanel()
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: inspected.trackIDs) { _, ids in request.selectionDidChange(ids) }
    }
}
