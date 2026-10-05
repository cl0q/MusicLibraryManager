import SwiftUI

/// Waveform visualization rendered from peak amplitude data.
///
/// Renders an interactive bar-style waveform from an array of normalized peak values.
/// Supports zooming, panning, dynamic sensitivity adjustments (contrast/gain),
/// resizable height, and trackpad pinch gestures.
struct WaveformView: View {
    /// Normalized peak data (0.0–1.0), one value per bar.
    let data: [Float]

    /// Current playback progress (0.0–1.0).
    let progress: Double

    /// Whether waveform data is still loading.
    let isLoading: Bool

    /// Whether the waveform is scrollable (e.g. for long tracks/mixes)
    let isScrollable: Bool

    /// User interactive visualization settings (persisted in parent)
    @Binding var zoomLevel: CGFloat
    @Binding var exponent: Float
    @Binding var gain: Float
    @Binding var waveformHeight: CGFloat

    /// Optional time label rendered inside the Canvas under the playhead needle.
    let needleTimeLabel: String?

    /// Called when the user clicks to seek. Provides a fraction (0.0–1.0).
    var onSeek: ((Double) -> Void)?

    /// Bar width in points at 1.0x zoom.
    private let barWidth: CGFloat = 2

    /// Gap between bars in points at 1.0x zoom.
    private let barGap: CGFloat = 1

    /// Stride per bar at 1.0x zoom: barWidth + barGap.
    private let barStride: CGFloat = 3

    /// State to track active trackpad magnification progress.
    @State private var lastMagnification: CGFloat = 1.0

    init(
        data: [Float],
        progress: Double,
        isLoading: Bool,
        isScrollable: Bool = false,
        zoomLevel: Binding<CGFloat>,
        exponent: Binding<Float>,
        gain: Binding<Float>,
        waveformHeight: Binding<CGFloat>,
        needleTimeLabel: String? = nil,
        onSeek: ((Double) -> Void)? = nil
    ) {
        self.data = data
        self.progress = progress
        self.isLoading = isLoading
        self.isScrollable = isScrollable
        self._zoomLevel = zoomLevel
        self._exponent = exponent
        self._gain = gain
        self._waveformHeight = waveformHeight
        self.needleTimeLabel = needleTimeLabel
        self.onSeek = onSeek
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if isLoading {
                    loadingPlaceholder
                } else if data.isEmpty {
                    emptyPlaceholder
                } else {
                    if isScrollable {
                        let currentBarStride = barStride * zoomLevel
                        let currentBarWidth = barWidth * zoomLevel
                        let totalContentWidth = max(
                            CGFloat(data.count) * currentBarStride,
                            geometry.size.width
                        )

                        ScrollView(.horizontal, showsIndicators: false) {
                            waveformCanvas(
                                in: CGSize(width: totalContentWidth, height: geometry.size.height),
                                currentBarStride: currentBarStride,
                                currentBarWidth: currentBarWidth
                            )
                            .frame(width: totalContentWidth, height: geometry.size.height)
                            .contentShape(Rectangle())
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        let fraction = WaveformHelpers.seekFraction(
                                            tapX: value.location.x,
                                            totalContentWidth: totalContentWidth
                                        )
                                        onSeek?(fraction)
                                    }
                                    .onEnded { value in
                                        let fraction = WaveformHelpers.seekFraction(
                                            tapX: value.location.x,
                                            totalContentWidth: totalContentWidth
                                        )
                                        onSeek?(fraction)
                                    }
                            )
                        }
                        .gesture(
                            MagnificationGesture()
                                .onChanged { value in
                                    let delta = value / lastMagnification
                                    lastMagnification = value
                                    let targetZoom = zoomLevel * delta
                                    zoomLevel = min(max(targetZoom, 0.5), 8.0)
                                }
                                .onEnded { _ in
                                    lastMagnification = 1.0
                                }
                        )
                    } else {
                        // Fit to width: Stride is equal to container width divided by data count
                        let stride = max(geometry.size.width / CGFloat(max(data.count, 1)), 0.5)
                        let width = max(stride * 0.7, 0.5)

                        waveformCanvas(
                            in: geometry.size,
                            currentBarStride: stride,
                            currentBarWidth: width
                        )
                        .contentShape(Rectangle())
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    let fraction = WaveformHelpers.seekFraction(
                                        tapX: value.location.x,
                                        totalContentWidth: geometry.size.width
                                    )
                                    onSeek?(fraction)
                                }
                                .onEnded { value in
                                    let fraction = WaveformHelpers.seekFraction(
                                        tapX: value.location.x,
                                        totalContentWidth: geometry.size.width
                                    )
                                    onSeek?(fraction)
                                }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Canvas Rendering

    private func waveformCanvas(
        in size: CGSize,
        currentBarStride: CGFloat,
        currentBarWidth: CGFloat
    ) -> some View {
        Canvas { context, canvasSize in
            let totalBars = data.count
            guard totalBars > 0 else { return }

            let availableWidth = canvasSize.width
            let height = canvasSize.height

            let midY = height / 2

            // Max bar height (half the waveform area, leaving a small gap at center)
            let maxBarHeight = midY - 1

            // Progress split point
            let progressX = availableWidth * CGFloat(progress)

            for (index, peak) in data.enumerated() {
                let x = CGFloat(index) * currentBarStride

                // Apply non-linear power scale to enhance dynamic contrast
                let scaledPeak = pow(peak, exponent) * gain
                let clampedPeak = min(max(scaledPeak, 0.0), 1.0)
                let barHeight = max(CGFloat(clampedPeak) * maxBarHeight, 1.0)

                // Top bar (grows upward from center)
                let topRect = CGRect(
                    x: x,
                    y: midY - barHeight,
                    width: currentBarWidth,
                    height: barHeight
                )

                // Bottom bar (grows downward from center, slightly shorter)
                let bottomHeight = barHeight * 0.7
                let bottomRect = CGRect(
                    x: x,
                    y: midY + 1,
                    width: currentBarWidth,
                    height: bottomHeight
                )

                // Neutral colours only (UC-COLOR-08, DEC-046): the played part darker.
                let played = x < progressX
                let shading = WaveformHelpers.barShading(played: played)

                context.fill(
                    Path(roundedRect: topRect, cornerRadius: max(currentBarWidth * 0.25, 0.5)),
                    with: shading
                )
                context.fill(
                    Path(roundedRect: bottomRect, cornerRadius: max(currentBarWidth * 0.25, 0.5)),
                    with: shading
                )
            }

            // Playhead in the accent (UC-COLOR-04), only for the playing track.
            if progress > 0 && progress < 1.0 {
                var playheadPath = Path()
                playheadPath.move(to: CGPoint(x: progressX, y: 0))
                playheadPath.addLine(to: CGPoint(x: progressX, y: height))
                context.stroke(
                    playheadPath,
                    with: .style(.tint),
                    lineWidth: 1.5
                )

                // Draw needle time label inside the Canvas, centered on progressX,
                // at the bottom of the waveform area. Same progressX expression as
                // the playhead line — alignment holds by construction under any
                // scroll/zoom because both are drawn in content space.
                if let label = needleTimeLabel {
                    let text = Text(label)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tint)
                    let resolved = context.resolve(text)
                    let labelSize = resolved.measure(in: CGSize(width: 80, height: 20))
                    // Center horizontally on progressX, clamp to content bounds
                    let labelX = min(max(progressX - labelSize.width / 2, 0),
                                     availableWidth - labelSize.width)
                    let labelPoint = CGPoint(x: labelX, y: height - labelSize.height - 1)
                    context.draw(resolved, at: CGPoint(x: labelX + labelSize.width / 2,
                                                       y: labelPoint.y + labelSize.height / 2))
                }
            }
        }
    }

    // MARK: - Placeholder States

    /// Static quiet bars while peaks load (no bespoke animation, UC-MOTION-01).
    private var loadingPlaceholder: some View {
        HStack(spacing: barGap) {
            ForEach(0..<40, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(.quaternary)
                    .frame(width: barWidth)
                    .scaleEffect(y: placeholderHeight(for: index), anchor: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Loading waveform")
    }

    private var emptyPlaceholder: some View {
        Rectangle()
            .fill(.quaternary)
            .frame(height: 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// Fixed heights for the loading placeholder bars.
    private func placeholderHeight(for index: Int) -> CGFloat {
        let heights: [CGFloat] = [0.3, 0.5, 0.8, 0.6, 0.4, 0.9, 0.7, 0.35, 0.65, 0.55]
        return heights[index % heights.count]
    }
}
