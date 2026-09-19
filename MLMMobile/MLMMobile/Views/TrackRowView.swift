import SwiftUI

/// A single track row showing title, artist, and duration.
struct TrackRowView: View {
    let track: IndexedTrack
    var isLiked: Bool = false
    var onToggleLike: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 12) {
            // Energy indicator
            EnergyIndicator(bucket: track.energyBucket)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(.body)
                    .lineLimit(1)
                Text("\(track.artist) · \(track.album)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(track.formattedDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if let onToggleLike = onToggleLike {
                Button(action: onToggleLike) {
                    Image(systemName: isLiked ? "heart.fill" : "heart")
                        .foregroundStyle(isLiked ? .red : .secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Compact energy-bucket indicator (1-5 bars).
struct EnergyIndicator: View {
    let bucket: Int

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level <= bucket ? Color.accentColor : Color.secondary.opacity(0.2))
                    .frame(width: 3, height: CGFloat(level) * 3 + 4)
            }
        }
        .frame(width: 24, height: 20)
    }
}
