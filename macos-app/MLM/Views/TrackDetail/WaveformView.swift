import SwiftUI

/// Waveform visualization rendered from peak amplitude data.
///
/// Renders a bar-style waveform from an array of normalized peak values
/// (0.0–1.0). Uses Canvas for GPU-accelerated drawing.
///
/// ## Features
/// - Mirrored bars (top + bottom) for the classic waveform look
/// - Progress overlay showing played portion in accent color
/// - Click-to-seek interaction via the `onSeek` callback
/// - Smooth loading transition
///
/// Phase 5 implementation. Replaces wavesurfer.js from the Tauri app.
struct WaveformView: View {
    /// Normalized peak data (0.0–1.0), one value per bar.
    let data: [Float]

    /// Current playback progress (0.0–1.0).
    let progress: Double

    /// Whether waveform data is still loading.
    let isLoading: Bool

    /// Called when the user clicks to seek. Provides a fraction (0.0–1.0).
    var onSeek: ((Double) -> Void)?

    /// Bar width in points.
    private let barWidth: CGFloat = 2

    /// Gap between bars in points.
    private let barGap: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if isLoading {
                    loadingPlaceholder
                } else if data.isEmpty {
                    emptyPlaceholder
                } else {
                    waveformCanvas(in: geometry.size)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let fraction = value.location.x / geometry.size.width
                                    onSeek?(min(max(fraction, 0), 1))
                                }
                                .onEnded { value in
                                    let fraction = value.location.x / geometry.size.width
                                    onSeek?(min(max(fraction, 0), 1))
                                }
                        )
                }
            }
        }
    }

    // MARK: - Canvas Rendering

    private func waveformCanvas(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let totalBars = data.count
            guard totalBars > 0 else { return }

            let availableWidth = canvasSize.width
            let height = canvasSize.height
            let midY = height / 2

            // Calculate actual bar width to fill the canvas evenly
            let totalBarWidth = availableWidth / CGFloat(totalBars)
            let actualBarWidth = max(totalBarWidth - barGap, 1)

            // Max bar height (half the canvas, leaving a small gap at center)
            let maxBarHeight = midY - 1

            // Progress split point
            let progressX = availableWidth * CGFloat(progress)

            for (index, peak) in data.enumerated() {
                let x = CGFloat(index) * totalBarWidth
                let barHeight = max(CGFloat(peak) * maxBarHeight, 1)

                // Top bar (grows upward from center)
                let topRect = CGRect(
                    x: x,
                    y: midY - barHeight,
                    width: actualBarWidth,
                    height: barHeight
                )

                // Bottom bar (grows downward from center, slightly shorter)
                let bottomHeight = barHeight * 0.7
                let bottomRect = CGRect(
                    x: x,
                    y: midY + 1,
                    width: actualBarWidth,
                    height: bottomHeight
                )

                // Color based on whether this bar is in the "played" region
                let barColor: Color = x < progressX
                    ? .mlmAccent
                    : .mlmEdge

                let barOpacity: Double = x < progressX ? 1.0 : 0.5

                context.fill(
                    Path(roundedRect: topRect, cornerRadius: 0.5),
                    with: .color(barColor.opacity(barOpacity))
                )
                context.fill(
                    Path(roundedRect: bottomRect, cornerRadius: 0.5),
                    with: .color(barColor.opacity(barOpacity * 0.6))
                )
            }
        }
    }

    // MARK: - Placeholder States

    private var loadingPlaceholder: some View {
        HStack(spacing: barGap) {
            ForEach(0..<40, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.mlmEdge.opacity(0.3))
                    .frame(width: barWidth)
                    .scaleEffect(y: randomHeight(for: index), anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(0.5)
        .animation(
            .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
            value: isLoading
        )
    }

    private var emptyPlaceholder: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Color.mlmEdge.opacity(0.2))
                .frame(height: 1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// Pseudo-random height for loading placeholder bars.
    private func randomHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [0.3, 0.5, 0.8, 0.6, 0.4, 0.9, 0.7, 0.35, 0.65, 0.55]
        return heights[index % heights.count]
    }
}
