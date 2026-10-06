import SwiftUI

/// Opening a library (V-LAUNCH-LOADING, DEC-031, UC-STATE §15.1): always names the library
/// and says what is happening — a small spinner and a phase line, a count while the database
/// is updated. After 10 s it says that it is taking longer and offers the logs. Never an
/// anonymous full-pane spinner (replaces `Loading Library...`).
struct LibraryLoadingView: View {
    let name: String
    let phase: LibraryOpenPhase
    /// The open has been running longer than usual.
    var isSlow = false
    var onShowLogs: () -> Void = {}

    var body: some View {
        VStack(spacing: Spacing.m) {
            LibraryFileIcon.image(size: 56)
            Text("Opening “\(name)”…")
                .font(.title3.bold())
            if let fraction = phase.fraction {
                VStack(spacing: Spacing.xs) {
                    phaseLine
                    ProgressView(value: fraction)
                        .frame(width: 300)
                }
            } else {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    phaseLine
                }
            }
            if let caption = phase.caption {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            if isSlow, !phase.isWriting {
                Button("Show Logs", action: onShowLogs)
                    .padding(.top, Spacing.s)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private var phaseLine: some View {
        HStack(spacing: Spacing.xs) {
            Text(isSlow && !phase.isWriting ? "\(phase.line) this is taking longer than usual." : phase.line)
            if let count = phase.count {
                Text(count)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}
