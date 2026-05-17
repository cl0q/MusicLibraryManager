import SwiftUI

/// Live progress section displayed during an active sync (D-12 / SYNC-v2-16).
///
/// Replaces the preview stats area in SyncProfileDetailView while vm.isSyncing.
/// Reads service state via SyncViewModel forwarding properties (no direct
/// SyncService dependency — service is private to the VM).
///
/// Layout (UI-SPEC Surface 6):
///   Row 1: counter "{processed} / {total}" + Cancel button
///   Row 2: full-width ProgressView (linear)
///   Row 3: current file name (truncated)
struct SyncProgressSection: View {
    let vm: SyncViewModel
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Row 1: counter + Cancel
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundColor(.mlmAccent)
                        .font(.system(size: 13))
                    Text("\(vm.syncProcessed) / \(vm.syncTotal)")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                }
                Spacer()
                Button(role: .destructive) {
                    onCancel()
                } label: {
                    Label("Abbrechen", systemImage: "xmark.circle")
                }
                .buttonStyle(.borderless)
                .tint(.mlmAccent)
            }

            // Row 2: full-width linear progress bar
            ProgressView(value: vm.syncProgress)
                .progressViewStyle(.linear)
                .tint(.mlmAccent)

            // Row 3: current file being processed
            if !vm.syncCurrentFile.isEmpty {
                Text(vm.syncCurrentFile)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(16)
        .background(Color.mlmSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
