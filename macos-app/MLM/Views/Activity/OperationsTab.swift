import SwiftUI

/// Operations tab within the ActivityPanel.
///
/// Shows active and recently completed operations (downloads, syncs,
/// imports, analysis runs).
struct OperationsTab: View {
    @Environment(\.container) private var container

    var body: some View {
        Group {
            if let vm = container.activityViewModel {
                operationsContent(vm: vm)
            } else {
                emptyState
            }
        }
        .background(Color.mlmBase)
    }

    @ViewBuilder
    private func operationsContent(vm: ActivityViewModel) -> some View {
        if vm.operations.isEmpty && vm.recentOperations.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Active operations
                    if !vm.operations.isEmpty {
                        sectionHeader("Active")
                        ForEach(vm.operations) { op in
                            OperationRow(operation: op)
                            Divider().padding(.leading, 32)
                        }
                    }

                    // Recent operations
                    if !vm.recentOperations.isEmpty {
                        HStack {
                            sectionHeader("Recent")
                            Spacer()
                            Button("Clear") {
                                vm.clearRecent()
                            }
                            .font(MLMFont.muted)
                            .buttonStyle(.plain)
                            .padding(.trailing, 16)
                        }
                        ForEach(vm.recentOperations) { op in
                            OperationRow(operation: op)
                            Divider().padding(.leading, 32)
                        }
                    }
                }
            }
        }
    }

    private var emptyState: some View {
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
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(MLMFont.sectionLabel)
            .foregroundColor(.mlmInkMuted)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }
}

// MARK: - Operation Row

struct OperationRow: View {
    let operation: ActivityViewModel.Operation

    var body: some View {
        HStack(spacing: 10) {
            // Type icon
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .font(MLMFont.body)
                    .lineLimit(1)

                if !operation.detail.isEmpty {
                    Text(operation.detail)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Progress or status
            if operation.isActive {
                ProgressView(value: operation.progress)
                    .frame(width: 80)
                Text("\(Int(operation.progress * 100))%")
                    .font(MLMFont.mono)
                    .foregroundColor(.mlmInkMuted)
                    .frame(width: 36)
            } else {
                Text(operation.formattedDuration)
                    .font(MLMFont.mono)
                    .foregroundColor(.mlmInkMuted)
                statusBadge
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var iconName: String {
        switch operation.type {
        case .download: "arrow.down.circle"
        case .sync: "arrow.triangle.2.circlepath"
        case .import: "square.and.arrow.down"
        case .analysis: "waveform"
        case .fingerprint: "hand.point.up.braille"
        case .artwork: "photo"
        }
    }

    private var iconColor: Color {
        switch operation.status {
        case .running: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(operation.status.rawValue)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(iconColor.opacity(0.15))
            )
            .foregroundColor(iconColor)
    }
}
