import SwiftUI

/// The player's scrubber while previewing (P-PLAYER.E09, THOUGHTS §7.8): the track's waveform,
/// played part in the accent, the rest `.secondary`, a quiet tick at the hot spot where the
/// preview started. Click or drag to seek. Data visualisation colours only (UC-COLOR-08);
/// never glass (UC-GLASS-07). Drawn with `Canvas` (UC-KIT-17).
struct PreviewWaveformScrubber: View {
    /// Peaks 0…1 (empty while they load: a thin line).
    let peaks: [Float]
    /// Played fraction 0…1.
    let progress: Double
    /// The hot spot as a fraction of the track, if known.
    let hotSpot: Double?
    let onSeek: (Double) -> Void

    /// While dragging: the dragged position (drawn at once), seeks at most this often.
    @State private var dragFraction: Double?
    @State private var lastDragSeek = Date.distantPast
    static let dragSeekInterval: TimeInterval = 0.15

    static let height: CGFloat = 18
    /// Bars drawn at most (peaks are resampled to fit the width).
    private static let barStride: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size, progress: dragFraction ?? progress)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard geometry.size.width > 0 else { return }
                        let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                        dragFraction = fraction
                        // The audio follows the drag, throttled.
                        if Date().timeIntervalSince(lastDragSeek) >= Self.dragSeekInterval {
                            lastDragSeek = Date()
                            onSeek(fraction)
                        }
                    }
                    .onEnded { value in
                        defer { dragFraction = nil }
                        guard geometry.size.width > 0 else { return }
                        onSeek(min(max(value.location.x / geometry.size.width, 0), 1))
                    }
            )
        }
        .frame(height: Self.height)
        .frame(minWidth: 80)
        .accessibilityElement()
        .accessibilityLabel("Preview position")
        .accessibilityValue(Text(progress, format: .percent.precision(.fractionLength(0))))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(progress + 0.05, 1))
            case .decrement: onSeek(max(progress - 0.05, 0))
            @unknown default: break
            }
        }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, progress: Double) {
        let midY = size.height / 2
        let playedX = size.width * CGFloat(min(max(progress, 0), 1))
        guard !peaks.isEmpty, size.width > 0 else {
            var line = Path()
            line.addRect(CGRect(x: 0, y: midY - 0.5, width: size.width, height: 1))
            context.fill(line, with: .style(.quaternary))
            var played = Path()
            played.addRect(CGRect(x: 0, y: midY - 0.5, width: playedX, height: 1))
            context.fill(played, with: .style(.tint))
            return
        }
        let bars = max(Int(size.width / Self.barStride), 1)
        var playedPath = Path()
        var restPath = Path()
        for bar in 0..<bars {
            let start = bar * peaks.count / bars
            let end = max(start + 1, (bar + 1) * peaks.count / bars)
            let peak = peaks[start..<min(end, peaks.count)].max() ?? 0
            let height = max(CGFloat(peak) * (size.height - 2), 1)
            let x = CGFloat(bar) * Self.barStride
            let rect = CGRect(x: x, y: midY - height / 2, width: Self.barStride * 0.6, height: height)
            if x < playedX { playedPath.addRect(rect) } else { restPath.addRect(rect) }
        }
        context.fill(restPath, with: .style(.secondary))
        context.fill(playedPath, with: .style(.tint))
        if let hotSpot, hotSpot > 0, hotSpot < 1 {
            var tick = Path()
            tick.addRect(CGRect(x: size.width * CGFloat(hotSpot) - 0.5, y: 0, width: 1, height: size.height))
            context.fill(tick, with: .style(.tertiary))
        }
    }
}
