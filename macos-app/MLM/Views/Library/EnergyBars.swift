import SwiftUI

/// 5-bar energy visualization for the library table.
///
/// Renders the LUFS-derived `energyBucket` (1–5) as colored bars,
/// matching the Tauri app's `EnergyBars` component.
///
/// - Level 1: ▃ (1 bar, cyan)
/// - Level 2: ▃▅ (2 bars, emerald)
/// - Level 3: ▃▅▇ (3 bars, amber)
/// - Level 4: ▃▅▇▅ (4 bars, orange)
/// - Level 5: ▃▅▇▅▃ (5 bars, rose)
///
/// Nil energy shows "—" placeholder.
struct EnergyBars: View {
    let level: Int?

    /// Bar heights for the 5 positions (symmetric mountain shape).
    private static let barHeights: [CGFloat] = [8, 12, 16, 12, 8]

    /// Width of each bar.
    private static let barWidth: CGFloat = 4

    /// Spacing between bars.
    private static let barSpacing: CGFloat = 2

    var body: some View {
        if let level, level >= 1, level <= 5 {
            HStack(alignment: .bottom, spacing: Self.barSpacing) {
                ForEach(0..<5, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(index < level ? colorForLevel(level) : Color.mlmEdgeSubtle)
                        .frame(width: Self.barWidth, height: Self.barHeights[index])
                }
            }
            .frame(height: 16)
        } else {
            Text("—")
                .font(MLMFont.dataSmall)
                .foregroundColor(.mlmInkMuted)
        }
    }

    /// Color for the entire bar group based on energy level.
    private func colorForLevel(_ level: Int) -> Color {
        switch level {
        case 1: Color.mlmEnergy1
        case 2: Color.mlmEnergy2
        case 3: Color.mlmEnergy3
        case 4: Color.mlmEnergy4
        case 5: Color.mlmEnergy5
        default: Color.mlmInkMuted
        }
    }
}

// MARK: - Preview

#Preview("Energy Bars") {
    VStack(alignment: .leading, spacing: 12) {
        ForEach(0..<6, id: \.self) { level in
            HStack {
                Text("Level \(level)")
                    .frame(width: 60, alignment: .leading)
                EnergyBars(level: level == 0 ? nil : level)
            }
        }
    }
    .padding()
    .background(Color.mlmBase)
}
