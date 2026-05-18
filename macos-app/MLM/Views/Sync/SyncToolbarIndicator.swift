import SwiftUI

/// Global toolbar indicator shown during sync (D-11).
///
/// GREENFIELD — no existing analog in MLM.
/// Hosted in ContentView.toolbar as ToolbarItem(placement: .primaryAction).
/// Uses SyncViewModel.isSyncing / syncProcessed / syncTotal (not direct SyncService access).
/// Renders only when a sync is actively running; entirely absent from the view tree otherwise.
struct SyncToolbarIndicator: View {
    @Environment(\.container) private var container
    @Binding var selectedSection: SidebarSection

    private var vm: SyncViewModel? { container.syncViewModel }

    var body: some View {
        if let vm, vm.isSyncing {
            Button {
                selectedSection = .sync
            } label: {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                    Text("\(vm.syncProcessed)/\(vm.syncTotal)")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.mlmRaised)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)
            .help("Sync läuft — klicken um zum Sync-Profil zu wechseln")
        }
    }
}
