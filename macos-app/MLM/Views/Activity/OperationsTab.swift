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
            } else if container.downloadViewModel != nil {
                operationsContent(vm: nil)
            } else {
                emptyState
            }
        }
        .background(Color.mlmBase)
    }

    @ViewBuilder
    private func operationsContent(vm: ActivityViewModel?) -> some View {
        let hasOps = (vm?.operations.isEmpty == false) || (vm?.recentOperations.isEmpty == false)
        let hasDownloads = container.downloadViewModel.map { downloadHasState($0) } ?? false

        if !hasOps && !hasDownloads {
            emptyState
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Downloads — pinned section so users always see live
                    // batch state, plus Cancel and Retry controls.
                    if let downloadVM = container.downloadViewModel,
                       downloadHasState(downloadVM) {
                        sectionHeader("Downloads")
                        DownloadStatusRow(vm: downloadVM)
                        Divider().padding(.leading, 32)
                    }

                    // Active operations
                    if let vm, !vm.operations.isEmpty {
                        sectionHeader("Active")
                        ForEach(vm.operations) { op in
                            OperationRow(operation: op)
                            Divider().padding(.leading, 32)
                        }
                    }

                    // Recent operations
                    if let vm, !vm.recentOperations.isEmpty {
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

    /// Whether the download VM has anything to display (running, or a
    /// finished run we want to keep visible with a Retry button).
    private func downloadHasState(_ vm: DownloadViewModel) -> Bool {
        vm.isDownloading || vm.totalCount > 0
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

// MARK: - Download Status Row

/// Live download batch row at the top of the Operations tab.
///
/// While running: shows "Downloading N / M — <Artist - Title>", a
/// progress bar, and a Cancel button.
/// While idle (after a run): shows the final tally ("N downloaded -
/// X failed") and, when failures occurred, a "Retry failed" button.
struct DownloadStatusRow: View {
    let vm: DownloadViewModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(MLMFont.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if vm.isDownloading {
                    ProgressView(value: progressValue, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                }

                if !detailText.isEmpty {
                    Text(detailText)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Cancel while running, Retry once a batch has finished
            // with at least one failure.
            if vm.isDownloading {
                Button("Cancel") {
                    vm.cancel()
                }
                .buttonStyle(.bordered)
            } else if vm.failedCount > 0 {
                Button("Retry failed") {
                    Task { await vm.retryFailed() }
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var titleText: String {
        if vm.isDownloading {
            let n = min(vm.completedCount + 1, max(vm.totalCount, 1))
            return "Downloading \(n) / \(vm.totalCount)"
        }
        if vm.totalCount > 0 {
            return "\(vm.completedCount) downloaded \u{00B7} \(vm.failedCount) failed"
        }
        return "Downloads"
    }

    private var detailText: String {
        if vm.isDownloading && !vm.currentTrack.isEmpty {
            return vm.currentTrack
        }
        return ""
    }

    private var progressValue: Double {
        guard vm.totalCount > 0 else { return 0 }
        return min(max(vm.progress, 0), 1)
    }
}
