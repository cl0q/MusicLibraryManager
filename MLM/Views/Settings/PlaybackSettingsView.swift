import SwiftUI

/// Settings ▸ Playback (ST-PLAYBACK, DEC-035): loudness normalisation with its dependency
/// explained (how much of the library has ReplayGain, and where to analyse the rest), and the
/// two tuning numbers under `Advanced` with plain labels. Applies to every library on this Mac
/// (same defaults keys as before). No Space-bar pointer (§10 Q1).
struct PlaybackSettingsView: View {
    @Environment(\.container) private var container
    @AppStorage("playback_lufs_normalization") private var lufsNormalization = false
    @AppStorage("playback_history_size") private var historySize = 50
    @AppStorage("playback_context_cap") private var contextCap = 100
    @State private var showsAdvanced = false
    private var jobs: MaintenanceJobs { .shared }

    var body: some View {
        Form {
            Section("Audio") {
                Toggle(isOn: $lufsNormalization) {
                    Text("Normalize loudness")
                    Text("Plays tracks at a similar volume. Takes effect with the next track.")
                    if container.isInitialized, let coverage = jobs.coverage {
                        HStack(spacing: 4) {
                            Text("Works for analysed tracks — \(MaintenanceCoverage.analysed(coverage.replayGain, of: coverage.tracksWithFile))")
                            if coverage.replayGain < coverage.tracksWithFile {
                                Text("·")
                                Button("Run loudness analysis") {
                                    SettingsRouter.shared.select(.maintenance)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                }
            }
            Section {
                DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                    LabeledContent {
                        HStack(spacing: 4) {
                            TextField("Tracks", value: $historySize, format: .number)
                                .labelsHidden()
                                .frame(width: 56)
                                .multilineTextAlignment(.trailing)
                            Stepper("Tracks", value: $historySize, in: 10...500, step: 10)
                                .labelsHidden()
                        }
                    } label: {
                        Text("Keep the last played tracks")
                        Text("Shown under History in the Queue.")
                    }
                    LabeledContent {
                        HStack(spacing: 4) {
                            TextField("Tracks", value: $contextCap, format: .number)
                                .labelsHidden()
                                .frame(width: 56)
                                .multilineTextAlignment(.trailing)
                            Stepper("Tracks", value: $contextCap, in: 10...1000, step: 10)
                                .labelsHidden()
                            Text("tracks").foregroundStyle(.secondary)
                        }
                    } label: {
                        Text("When playing from a list, queue up to")
                        Text("The rows after the track you play become the queue.")
                    }
                }
            } footer: {
                Text("Playback settings apply to every library on this Mac.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: historySize) { _, value in historySize = min(max(value, 10), 500) }
        .onChange(of: contextCap) { _, value in contextCap = min(max(value, 10), 1000) }
        .task(id: container.isInitialized) { await jobs.refreshCoverage() }
    }
}
