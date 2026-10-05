import SwiftUI

/// Danceability (0.0–1.0) as the quiet 5-step meter of UC-TABLE-14 / DEC-046 — the same
/// rendering as Energy, no gradient or glow. `—` when not analysed.
struct DanceabilitySteps: View {
    let score: Double?

    var body: some View {
        TrackMeter(level: score.map(Self.scoreToLevel))
    }

    /// Map continuous danceability score (0.0 to 1.0) into discrete levels (1 to 5)
    static func scoreToLevel(_ value: Double) -> Int {
        if value <= 0.2 { return 1 }
        if value <= 0.4 { return 2 }
        if value <= 0.6 { return 3 }
        if value <= 0.8 { return 4 }
        return 5
    }
}
