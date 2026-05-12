import SwiftUI

/// Pure helper functions for waveform rendering and seek math.
///
/// Extracted as a separate type so unit tests can import and call these
/// without AppKit or SwiftUI environment. All functions are static.
enum WaveformHelpers {

    // MARK: - Adaptive Bin Count

    /// Compute the number of waveform bins for a given track duration.
    ///
    /// Density: 2 bins per second of audio.
    /// Floor: 200 bins (short tracks retain original resolution).
    /// Cap: 14 400 bins (2 hours at 2 bins/sec — memory-safe upper bound).
    static func adaptiveBinCount(duration: TimeInterval) -> Int {
        guard duration.isFinite && duration > 0 else { return 200 }
        let binsPerSecond: Double = 2.0
        let minBins = 200
        let maxBins = 14_400
        return min(max(Int(duration * binsPerSecond), minBins), maxBins)
    }

    // MARK: - Amplitude Color

    /// Map a normalized amplitude (0…1) to a DJ-style HSB color.
    ///
    /// Color ramp (hue in degrees):
    ///   0.0 (quiet)  → 220° steel blue  (hue ≈ 0.611 in 0-1 scale)
    ///   1.0 (loud)   →  30° orange-red  (hue ≈ 0.083 in 0-1 scale)
    ///
    /// Played bars are brighter; unplayed bars are dimmed and semi-transparent.
    static func amplitudeColor(for peak: Float, played: Bool) -> Color {
        let t = Double(peak)
        let hue        = 0.611 - t * 0.528          // 220° → 30°
        let saturation = 0.4 + t * 0.6              // desaturate quiet bars
        let brightness = played
            ? (0.55 + t * 0.45)                     // 0.55–1.00 when played
            : (0.35 + t * 0.30)                     // 0.35–0.65 when unplayed
        let opacity    = played ? 1.0 : 0.55
        return Color(hue: hue, saturation: saturation, brightness: brightness, opacity: opacity)
    }

    // MARK: - Seek Fraction

    /// Compute the seek fraction from a tap position in the Canvas coordinate space.
    ///
    /// `DragGesture.location.x` attached to a view inside a `ScrollView` is already
    /// in the Canvas's local coordinate space (SwiftUI transforms the point for you),
    /// so no scroll offset correction is needed here.
    ///
    /// - Parameters:
    ///   - tapX: `DragGesture.location.x` in the Canvas coordinate space.
    ///   - totalContentWidth: Full Canvas width (`data.count * barStride`).
    /// - Returns: Fraction clamped to 0…1.
    static func seekFraction(
        tapX: CGFloat,
        totalContentWidth: CGFloat
    ) -> Double {
        guard totalContentWidth > 0 else { return 0 }
        return max(0, min(1, Double(tapX / totalContentWidth)))
    }
}
