import SwiftUI

/// DisclosureGroup of failed sync tracks with per-row Retry button (D-13 / SYNC-v2-17).
///
/// GREENFIELD — no direct analog in MLM (closest shape: PinnedPlaylistsDisclosure).
/// Defaults to collapsed to avoid visual clutter when syncs partially fail.
///
/// `failedTracks` carries display metadata so the UI never exposes raw track
/// IDs as the only explanation of a failed sync item.
struct SyncFailedDisclosure: View {
    let failedTracks: [SyncService.SyncFailure]
    let vm: SyncViewModel

    @State private var isExpanded: Bool = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(failedTracks) { failure in
                failedTrackRow(failure)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.mlmError)
                    .font(.system(size: 12))
                Text("Failed tracks (\(failedTracks.count))")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func failedTrackRow(_ failure: SyncService.SyncFailure) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(failure.artist) – \(failure.title)")
                .font(MLMFont.bodyBold)
                .foregroundColor(.mlmInk)
                .lineLimit(1)
            Text(failure.reason)
                .font(MLMFont.muted)
                .foregroundColor(.mlmError)
                .lineLimit(2)
            Button("Retry") {
                Task { await vm.retryFailedTrack(failure.trackId) }
            }
            .buttonStyle(.borderless)
            .tint(.mlmAccent)
            .font(MLMFont.muted)
        }
        .padding(.vertical, 8)
        .padding(.leading, 12)
    }
}
