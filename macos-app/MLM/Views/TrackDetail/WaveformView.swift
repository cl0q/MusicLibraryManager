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

    /// User interactive visualization settings (persisted in parent)
    @Binding var zoomLevel: CGFloat
    @Binding var exponent: Float
    @Binding var gain: Float
    @Binding var waveformHeight: CGFloat

    /// Called when the user clicks to seek. Provides a fraction (0.0–1.0).
    var onSeek: ((Double) -> Void)?

    /// Bar width in points at 1.0x zoom.
    private let barWidth: CGFloat = 2

    /// Gap between bars in points at 1.0x zoom.
    private let barGap: CGFloat = 1

    /// Stride per bar at 1.0x zoom: barWidth + barGap.
    private let barStride: CGFloat = 3

    /// State for settings popover visibility.
    @State private var showSettingsPopover = false

    /// State to track active trackpad magnification progress.
    @State private var lastMagnification: CGFloat = 1.0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                if isLoading {
                    loadingPlaceholder
                } else if data.isEmpty {
                    emptyPlaceholder
                } else {
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

                    // Professional HUD Overlay for Zoom & Settings
                    hudControlsOverlay
                        .padding(8)
                }
            }
        }
    }

    // MARK: - HUD Controls Overlay

    private var hudControlsOverlay: some View {
        Button {
            showSettingsPopover.toggle()
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(showSettingsPopover ? .mlmAccent : .mlmInk)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.mlmBase.opacity(0.90))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.mlmEdge, lineWidth: 1)
                        )
                        .shadow(color: Color.black.opacity(0.10), radius: 2, x: 0, y: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Waveform-Einstellungen")
        .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
            settingsView
        }
    }

    // MARK: - Settings Popover Content

    private var settingsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Waveform-Optionen")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.mlmInk)

            Divider()
                .background(Color.mlmEdge)

            // Contrast Slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Empfindlichkeit")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.mlmInkSecondary)

                Slider(value: $exponent, in: 0.5...3.0, step: 0.1)
                    .controlSize(.small)
            }

            // Gain Slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Verstärkung")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.mlmInkSecondary)

                Slider(value: $gain, in: 0.5...2.5, step: 0.1)
                    .controlSize(.small)
            }

            // Height Slider
            VStack(alignment: .leading, spacing: 4) {
                Text("Bereichs-Höhe")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.mlmInkSecondary)

                Slider(value: $waveformHeight, in: 60...250, step: 5)
                    .controlSize(.small)
            }

            Divider()
                .background(Color.mlmEdge)

            Button("Zurücksetzen") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    zoomLevel = 1.0
                    exponent = 1.5
                    gain = 1.0
                    waveformHeight = 80.0
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
        .frame(width: 200)
        .background(Color.mlmSurface)
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

            // Max bar height (half the canvas, leaving a small gap at center)
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

                // DJ-style amplitude color coding — opacity already baked into amplitudeColor
                let played = x < progressX
                let barColor = WaveformHelpers.amplitudeColor(for: peak, played: played)

                context.fill(
                    Path(roundedRect: topRect, cornerRadius: max(currentBarWidth * 0.25, 0.5)),
                    with: .color(barColor)
                )
                context.fill(
                    Path(roundedRect: bottomRect, cornerRadius: max(currentBarWidth * 0.25, 0.5)),
                    with: .color(barColor.opacity(0.6))
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
