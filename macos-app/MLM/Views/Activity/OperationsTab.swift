import SwiftUI

/// Operations tab within the ActivityPanel.
///
/// Shows a list of active and recent operations (downloads, syncs,
/// imports, analysis runs). Empty-state placeholder for Phase 2.
/// Phase 16 wires in real operation tracking.
struct OperationsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 24))
                .foregroundColor(.mlmInkMuted)
            Text("No active operations")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkMuted)
            Text("Downloads, imports, and sync jobs appear here")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.mlmBase)
    }
}
