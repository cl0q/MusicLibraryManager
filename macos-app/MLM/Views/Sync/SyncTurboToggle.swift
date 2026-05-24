import SwiftUI

/// A premium, interactive toolbar toggle that lets the user choose
/// their transcoding sync CPU utilization level (60%, 80%, 100%).
struct SyncTurboToggle: View {
    @Environment(\.container) private var container

    var body: some View {
        if let syncVM = container.syncViewModel {
            let level = syncVM.syncService.syncTurboLevel
            let workerCount = level.workerCount()
            let totalCores = ProcessInfo.processInfo.activeProcessorCount

            Menu {
                Picker("Sync CPU-Leistung", selection: Binding(
                    get: { level },
                    set: { syncVM.syncService.setSyncTurboLevel($0) }
                )) {
                    ForEach(SyncTurboLevel.allCases) { lvl in
                        HStack {
                            Text("Turbo \(lvl.rawValue)")
                            Spacer()
                            Text("(\(lvl.workerCount()) Cores)")
                                .foregroundColor(.secondary)
                        }
                        .tag(lvl)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "gauge.with.needle.fill")
                        .foregroundColor(indicatorColor(for: level))
                        .symbolEffect(.bounce.up, value: level)
                    
                    Text("Turbo: \(level.rawValue)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    
                    Text("(\(workerCount)/\(totalCores) Cores)")
                        .font(.system(size: 10))
                        .foregroundColor(.mlmInkSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.mlmRaised)
                )
            }
            .menuStyle(.button)
            .frame(width: 175)
            .help("Konfiguriere die Transcodierungs-Geschwindigkeit (Turbo-Modus)")
        }
    }

    private func indicatorColor(for level: SyncTurboLevel) -> Color {
        switch level {
        case .low:
            return .mlmInkMuted
        case .medium:
            return .mlmWarning
        case .full:
            return .mlmAccent
        }
    }
}
