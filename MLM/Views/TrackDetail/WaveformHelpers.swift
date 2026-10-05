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

    // MARK: - Bar shading

    /// Waveform bars use neutral semantic styles only (UC-COLOR-08, DEC-046 — the old blue-to-
    /// orange ramp is gone): played bars `.secondary`, the rest `.tertiary`.
    static func barShading(played: Bool) -> GraphicsContext.Shading {
        played ? .style(.secondary) : .style(.tertiary)
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
