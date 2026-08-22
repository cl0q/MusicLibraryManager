import SwiftUI

/// Operations tab within the ActivityPanel.
///
/// Shows active and recently completed operations (downloads, syncs,
/// imports, analysis runs).
@MainActor
struct OperationsTab: View {
    @Environment(\.container) private var container
    @State private var persistedDownloadFailures: [PersistedDownloadFailure] = []

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
        .task {
            await loadPersistedDownloadFailures()
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            Task {
                await loadPersistedDownloadFailures()
            }
        }
    }

    @ViewBuilder
    private func operationsContent(vm: ActivityViewModel?) -> some View {
        let hasOps = (vm?.operations.isEmpty == false) || (vm?.recentOperations.isEmpty == false)
            || !persistedDownloadFailures.isEmpty
        let hasDownloads = container.downloadViewModel.map { downloadHasState($0) } ?? false
        let hasSync = container.syncViewModel.map { syncHasState($0) } ?? false
        let hasQueueState = PerformanceQueueService.shared.pendingAnalysesCount > 0 || PerformanceQueueService.shared.pendingDownloadsCount > 0 || PerformanceQueueService.shared.activeJobDescription != nil

        if !hasOps && !hasDownloads && !hasSync && !hasQueueState {
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
                        if !downloadVM.queueItems.isEmpty {
                            ForEach(downloadVM.queueItems) { item in
                                DownloadItemRow(item: item)
                            }
                        }
                        Divider().padding(.leading, 32)
                    }

                    // Sync — pinned section, same treatment as Downloads.
                    if let syncVM = container.syncViewModel,
                       syncHasState(syncVM) {
                        sectionHeader("Sync")
                        SyncStatusRow(vm: syncVM)
                        Divider().padding(.leading, 32)
                    }

                    // Auto-Analysis Queue
                    if hasQueueState {
                        sectionHeader("Auto-Analysis Queue")
                        PerformanceQueueStatusRow()
                        Divider().padding(.leading, 32)
                    }

                    // Active operations — hide `.sync` here because the
                    // pinned Sync row above is the canonical live view.
                    if let vm {
                        let active = vm.operations.filter { $0.type != .sync }
                        if !active.isEmpty {
                            sectionHeader("Active")
                            ForEach(active) { op in
                                OperationRow(operation: op)
                                Divider().padding(.leading, 32)
                            }
                        }
                    }

                    // Recent operations and durable download failures. Unlike
                    // transient operation history, persisted failures are not
                    // clearable here because they remain actionable after a
                    // relaunch until a successful download clears the record.
                    if !persistedDownloadFailures.isEmpty || (vm?.recentOperations.isEmpty == false) {
                        HStack {
                            sectionHeader("Recent")
                            Spacer()
                            if !persistedDownloadFailures.isEmpty {
                                Button("Retry All") {
                                    Task {
                                        await container.downloadViewModel?.retryAllFailed(
                                            trackIds: persistedDownloadFailures.map(\.trackID)
                                        )
                                    }
                                }
                                .buttonStyle(.bordered)
                                .padding(.trailing, 12)
                            }
                            if let vm, !vm.recentOperations.isEmpty {
                                Button("Clear") {
                                    vm.clearRecent()
                                }
                                .font(MLMFont.muted)
                                .buttonStyle(.plain)
                                .padding(.trailing, 16)
                            }
                        }
                        ForEach(persistedDownloadFailures) { failure in
                            PersistedDownloadFailureRow(failure: failure)
                            Divider().padding(.leading, 32)
                        }
                        if let vm {
                            ForEach(vm.recentOperations) { op in
                                OperationRow(operation: op)
                                Divider().padding(.leading, 32)
                            }
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

    /// Whether the sync VM has anything to display (running, or a finished
    /// run we want to keep visible with a Retry button).
    private func syncHasState(_ vm: SyncViewModel) -> Bool {
        vm.isSyncing || vm.lastResult != nil
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

    private func loadPersistedDownloadFailures() async {
        guard let repository = container.trackRepository else {
            persistedDownloadFailures = []
            return
        }

        do {
            let tracks = try await repository.fetchTracksWithDownloadFailures()
            var failures = Dictionary(uniqueKeysWithValues: tracks.compactMap { track -> (Int64, PersistedDownloadFailure)? in
                guard let trackID = track.id,
                      let failure = downloadFailure(for: track) else {
                    return nil
                }
                return (
                    trackID,
                    PersistedDownloadFailure(
                        trackID: trackID,
                        artist: track.artist,
                        title: track.title,
                        failure: failure
                    )
                )
            })

            // The legacy queue remains the fallback when finalization itself
            // could not write to GRDB. Include it after DB failures and key by
            // track ID so one failure never appears twice in Recent.
            for item in container.downloadViewModel?.persistedRetryItems() ?? [] {
                guard failures[item.trackId] == nil,
                      let track = try await repository.fetchTrack(id: item.trackId) else {
                    continue
                }
                failures[item.trackId] = PersistedDownloadFailure(
                    trackID: item.trackId,
                    artist: track.artist,
                    title: track.title,
                    failure: TrackDownloadFailure(
                        reason: item.lastError ?? "Download failed",
                        date: date(from: item.queuedAt),
                        attempts: item.attemptCount
                    )
                )
            }

            persistedDownloadFailures = failures.values.sorted {
                $0.failure.date > $1.failure.date
            }
        } catch {
            AppLogger.shared.error(
                "Could not load persisted download failures: \(error.localizedDescription)",
                source: "Activity"
            )
        }
    }

    private func downloadFailure(for track: Track) -> TrackDownloadFailure? {
        if let structured = track.downloadFailureRecord {
            return structured
        }
        switch track.downloadStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "failed", "error":
            return TrackDownloadFailure(
                reason: "Download failed",
                date: .distantPast,
                attempts: 1
            )
        default:
            return nil
        }
    }

    private func date(from text: String) -> Date {
        ISO8601DateFormatter().date(from: text) ?? .distantPast
    }
}

// MARK: - Persisted Download Failure

private struct PersistedDownloadFailure: Identifiable {
    let trackID: Int64
    let artist: String
    let title: String
    let failure: TrackDownloadFailure

    var id: Int64 { trackID }
}

private struct PersistedDownloadFailureRow: View {
    let failure: PersistedDownloadFailure
    @Environment(\.container) private var container

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 14))
                .foregroundColor(.mlmAttention)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(failure.artist) - \(failure.title)")
                    .font(MLMFont.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(detailText)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(1)
            }

            Spacer()

            Button("Retry") {
                Task {
                    await container.downloadViewModel?.retryDownload(trackId: failure.trackID)
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var attemptText: String {
        let attempts = failure.failure.attempts
        if attempts < 3 {
            let remaining = 3 - attempts
            return remaining == 1 ? "1 attempt left" : "\(remaining) attempts left"
        }
        return attempts == 1 ? "1 attempt" : "\(attempts) attempts"
    }

    private var detailText: String {
        let dateText = failure.failure.date == .distantPast
            ? ""
            : " · \(failure.failure.date.formatted(date: .abbreviated, time: .shortened))"
        return "\(failure.failure.reason)\(dateText) · \(attemptText)"
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
        case .createMLExport: "brain"
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
            } else if vm.hasActionableRetryFailures {
                Button("Retry all") {
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
            var parts = [
                "\(vm.completedCount) downloaded",
                "\(vm.failedCount) failed",
            ]
            if let skipped = vm.lastResult?.skipped, skipped > 0 {
                parts.append("\(skipped) skipped")
            }
            if let cancelled = vm.lastResult?.cancelledTrackIds.count, cancelled > 0 {
                parts.append("\(cancelled) cancelled")
            }
            return parts.joined(separator: " \u{00B7} ")
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

// MARK: - Download Item Row

/// Per-item row for a single `DownloadItem` in `queueItems`.
///
/// SCDL-06: `queueItems` was populated and updated but rendered nowhere —
/// this row makes every batch item's real, terminal status visible
/// (queued/downloading/transcoding/completed/failed), plus the failure
/// reason when one is available, distinguishing a download-stage failure
/// ("download error") from a persistence-stage one ("downloaded but not
/// saved to library").
struct DownloadItemRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundColor(.mlmInkMuted)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(item.artist) - \(item.title)")
                    .font(MLMFont.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let error = item.error, !error.isEmpty {
                    Text(error)
                        .font(MLMFont.muted)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            statusBadge
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch item.status {
        case .queued: .mlmInkMuted
        case .downloading, .transcoding: .accentColor
        case .completed: .green
        case .failed: .red
        case .skipped: .mlmInkMuted
        case .cancelled: .orange
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        Text(item.status.rawValue)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(statusColor.opacity(0.15))
            )
            .foregroundColor(statusColor)
    }
}

// MARK: - Sync Status Row

/// Live sync row at the top of the Operations tab.
///
/// While running: title "Syncing N / M", linear progress, current track
/// as a sub-line, and a Cancel button.
/// After completion: final tally ("N synced · M failed") plus a Retry
/// button when failures occurred (jumps to the Sync tab so the user can
/// inspect / retry individual tracks).
struct SyncStatusRow: View {
    let vm: SyncViewModel
    @Environment(\.container) private var container

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(titleText)
                    .font(MLMFont.body)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if vm.isSyncing {
                    ProgressView(value: progressValue, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 240)
                }

                if !detailText.isEmpty {
                    Text(detailText)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer()

            if vm.isSyncing {
                Button(vm.isSyncPaused ? "Resume" : "Pause") {
                    vm.toggleSyncPause()
                }
                .buttonStyle(.bordered)
                Button("Cancel", role: .cancel) {
                    vm.cancelSync()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var titleText: String {
        if vm.isSyncing {
            let n = min(vm.syncProcessed + 1, max(vm.syncTotal, 1))
            return "Syncing… \(n) of \(vm.syncTotal)"
        }
        if let result = vm.lastResult {
            return "\(result.syncedCount) synced \u{00B7} \(result.failedCount) failed"
        }
        return "Sync"
    }

    private var detailText: String {
        if vm.isSyncing && !vm.syncCurrentFile.isEmpty {
            return vm.syncCurrentFile
        }
        return ""
    }

    private var progressValue: Double {
        guard vm.syncTotal > 0 else { return 0 }
        return min(max(vm.syncProgress, 0), 1)
    }
}

// MARK: - Performance Queue Status Row

struct PerformanceQueueStatusRow: View {
    var service = PerformanceQueueService.shared

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.system(size: 14))
                .foregroundColor(.accentColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                if let activeDesc = service.activeJobDescription {
                    Text(activeDesc)
                        .font(MLMFont.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Queue Idle")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                }

                Text("\(service.pendingAnalysesCount) analyses pending \u{00B7} \(service.pendingDownloadsCount) downloads pending")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(1)
            }

            Spacer()

            if service.pendingAnalysesCount > 0 || service.pendingDownloadsCount > 0 {
                Button("Clear") {
                    service.clearQueue()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
