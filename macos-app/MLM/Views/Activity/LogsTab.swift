import SwiftUI

/// Logs tab within the ActivityPanel.
///
/// Shows a streaming log of application events.
/// Empty-state placeholder for Phase 2.
/// Phase 16 wires in real-time log streaming.
struct LogsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.alignleft")
                .font(.system(size: 24))
                .foregroundColor(.mlmInkMuted)
            Text("No log entries")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkMuted)
            Text("Application events stream here in real time")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }
}
