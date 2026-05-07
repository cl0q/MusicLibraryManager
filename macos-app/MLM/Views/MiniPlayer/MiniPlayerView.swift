import SwiftUI

/// Persistent mini-player bar at the bottom of the window.
///
/// Phase 2 ships the empty-state shell (no track loaded).
/// Phase 5 (Track Detail & Playback) wires it to `PlaybackViewModel`
/// with play/pause, seek, LUFS gain, and track metadata.
struct MiniPlayerView: View {
    var body: some View {
        HStack(spacing: 12) {
            // Play button — disabled in empty state
            Button(action: {}) {
                Image(systemName: "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.mlmInkMuted)
            }
            .buttonStyle(.plain)
            .disabled(true)
            .frame(width: 24, height: 24)

            // Track info placeholder
            VStack(alignment: .leading, spacing: 1) {
                Text("No track playing")
                    .font(MLMFont.miniPlayerTitle)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(1)
            }

            Spacer()

            // Progress bar placeholder (2px tall, invisible in empty state)
            progressBar
                .frame(width: 200)

            // Duration placeholder
            Text("—:— / —:—")
                .font(MLMFont.dataSmall)
                .foregroundColor(.mlmInkMuted)
        }
        .padding(.horizontal, MLMSpacing.pagePadding)
        .frame(height: MLMSpacing.miniPlayerHeight)
        .background(Color.mlmSurface)
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Track (background)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.mlmEdge)
                    .frame(height: 2)

                // Progress (empty — 0%)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.mlmInkMuted)
                    .frame(width: 0, height: 2)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 12) // Hit-target height for future seek interaction
    }
}
