import SwiftUI

/// Energy (the LUFS-derived `energyBucket`, 1–5) as the quiet meter of UC-TABLE-14 / DEC-046:
/// number + 5 steps in `.secondary` / `.quaternary`, `—` when not analysed. Track tables use
/// `TrackMeter` directly; this name stays for Folders and Info.
struct EnergyBars: View {
    let level: Int?

    var body: some View {
        TrackMeter(level: level)
    }
}
