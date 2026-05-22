import SwiftUI

/// DisclosureGroup of failed sync tracks with per-row Retry button (D-13 / SYNC-v2-17).
///
/// GREENFIELD — no direct analog in MLM (closest shape: PinnedPlaylistsDisclosure).
/// Defaults to collapsed to avoid visual clutter when syncs partially fail.
///
/// `failedTracks` matches SyncService.SyncResult.failedTracks: [(Int64, String)]
/// where the tuple is (trackId, errorMessage).
struct SyncFailedDisclosure: View {
    let failedTracks: [(Int64, String)]
    let vm: SyncViewModel

    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(Array(failedTracks.enumerated()), id: \.element.0) { _, entry in
                let (trackId, errorMessage) = entry
                failedTrackRow(trackId: trackId, errorMessage: errorMessage)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.mlmError)
                    .font(.system(size: 12))
                Text("Fehlgeschlagene Tracks (\(failedTracks.count))")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func failedTrackRow(trackId: Int64, errorMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Track #\(trackId)")
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .lineLimit(1)
            Text(errorMessage)
                .font(MLMFont.muted)
                .foregroundColor(.mlmError)
                .lineLimit(2)
            Button("Wiederholen") {
                Task { await vm.retryFailedTrack(trackId) }
            }
            .buttonStyle(.borderless)
            .tint(.mlmAccent)
            .font(MLMFont.muted)
        }
        .padding(.vertical, 8)
        .padding(.leading, 12)
    }
}
