import SwiftUI

/// 5-dot drum sequencer visualization for track danceability.
///
/// Renders a rhythmic step-sequencer dot grid representing the danceability score
/// scaled to a 1–5 level, matching the premium aesthetics of the MLM player.
///
/// - Level 1: ● ○ ○ ○ ○ (Low regular rhythm)
/// - Level 2: ● ● ○ ○ ○
/// - Level 3: ● ● ● ○ ○ (Moderate regular rhythm)
/// - Level 4: ● ● ● ● ○
/// - Level 5: ● ● ● ● ● (Highly regular electronic/dance rhythm)
///
/// Nil danceability displays a clean placeholder "—".
struct DanceabilitySteps: View {
    let score: Double?

    /// Size of each dot.
    private static let dotSize: CGFloat = 6

    /// Spacing between dots.
    private static let dotSpacing: CGFloat = 3

    /// Curated modern electric violet to deep indigo gradient for active beats.
    private var activeGradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.7, green: 0.35, blue: 1.0), Color(red: 0.5, green: 0.15, blue: 0.95)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    var body: some View {
        if let score {
            let level = Self.scoreToLevel(score)
            HStack(spacing: Self.dotSpacing) {
                ForEach(0..<5, id: \.self) { index in
                    Circle()
                        .fill(index < level ? AnyShapeStyle(activeGradient) : AnyShapeStyle(Color(nsColor: .quaternaryLabelColor)))
                        .frame(width: Self.dotSize, height: Self.dotSize)
                        .shadow(color: index < level ? Color(red: 0.6, green: 0.25, blue: 0.95).opacity(0.4) : Color.clear, radius: 1.5, x: 0, y: 0.5)
                }
            }
            .frame(height: 16)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
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

// MARK: - Preview

#Preview("Danceability Steps") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<6, id: \.self) { level in
            HStack {
                Text(level == 0 ? "Nil" : String(format: "%.1f", Double(level) / 5.0))
                    .frame(width: 60, alignment: .leading)
                DanceabilitySteps(score: level == 0 ? nil : Double(level) / 5.0)
            }
        }
    }
    .padding()
}
