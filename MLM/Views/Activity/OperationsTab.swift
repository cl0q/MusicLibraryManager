import SwiftUI

@MainActor
struct OperationsTab: View {
    @Environment(\.container) private var container
    @State private var persistedDownloadFailures: [PersistedDownloadFailure] = []
    @State private var expandedDownloadRowID: String?
    @State private var showClearQueueAlert = false

    var body: some View {
        Group {
            if let vm = container.activityViewModel {
                content(vm: vm)
            } else {
                emptyState
                    .accessibilityIdentifier("operations_empty_state")
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
        .alert("Clear Pending Jobs", isPresented: $showClearQueueAlert) {
            Button("Keep", role: .cancel) {}
            Button("Clear", role: .destructive) {
                PerformanceQueueService.shared.clearQueue()
            }
        } message: {
            let pending = PerformanceQueueService.shared.pendingAnalysesCount
                + PerformanceQueueService.shared.pendingDownloadsCount
            Text("Clear \(pending) pending jobs? This cannot be undone.")
        }
    }

    @ViewBuilder
    private func content(vm: ActivityViewModel) -> some View {
        let snapshot = buildSnapshot(vm: vm)

        if snapshot.isEmpty {
            emptyState
                .accessibilityIdentifier("operations_empty_state")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(snapshot.sections) { section in
                        sectionView(section: section, vm: vm)
                    }
                }
            }
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot(vm: ActivityViewModel) -> ActivityFeedSnapshot {
        let downloadState: DownloadSourceState? = container.downloadViewModel.map {
            $0.sourceState(operationID: nil)
        }
        let syncState: SyncSourceState? = container.syncViewModel.map {
            $0.sourceState(operationID: nil)
        }
        let queueState: QueueSourceState = PerformanceQueueService.shared.sourceState()

        let persistedInputs = persistedDownloadFailures.map { failure in
            PersistedFailureInput(
                trackID: failure.trackID,
                artist: failure.artist,
                title: failure.title,
                reason: failure.failure.reason,
                date: failure.failure.date,
                attempts: failure.failure.attempts
            )
        }

        return ActivityFeed.makeSnapshot(
            operations: vm.operations,
            stalledIDs: vm.stalledOperationIDs,
            recentOperations: vm.recentOperations,
            recentTruncated: vm.isRecentTruncated,
            download: downloadState,
            sync: syncState,
            queue: queueState,
            persistedFailures: persistedInputs,
            now: Date()
        )
    }

    // MARK: - Section

    private func sectionView(section: ActivitySection, vm: ActivityViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader(section: section, vm: vm)

            ForEach(section.rows) { row in
                operationRowView(row: row, vm: vm)
                Divider().padding(.leading, 32)
            }
        }
        .accessibilityIdentifier(sectionIdentifier(section.kind))
    }

    private func sectionIdentifier(_ kind: ActivitySectionKind) -> String {
        switch kind {
        case .active: return "operations_section_active"
        case .attention: return "operations_section_attention"
        case .recent: return "operations_section_recent"
        }
    }

    private func sectionHeader(section: ActivitySection, vm: ActivityViewModel) -> some View {
        HStack {
            Text(section.title)
                .font(MLMFont.sectionLabel)
                .foregroundColor(section.kind == .attention ? .mlmAttention : .mlmInkMuted)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)

            Spacer()

            ForEach(Array(section.headerActions.enumerated()), id: \.offset) { _, action in
                headerActionButton(action, vm: vm)
            }

            if section.showsCapNotice {
                Text("Capped at \(ActivityViewModel.recentCapacity)")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .padding(.trailing, 16)
                    .accessibilityIdentifier("operations_recent_cap_notice")
            }
        }
    }

    @ViewBuilder
    private func headerActionButton(_ action: ActivityRowAction, vm: ActivityViewModel) -> some View {
        switch action {
        case .clearRecent:
            Button("Clear") {
                vm.clearRecent()
            }
            .font(MLMFont.muted)
            .buttonStyle(.plain)
            .padding(.trailing, 16)
            .accessibilityIdentifier("operations_recent_clear_button")
        default:
            EmptyView()
        }
    }

    // MARK: - Row

    private func operationRowView(row: ActivityRow, vm: ActivityViewModel) -> some View {
        let isExpanded = expandedDownloadRowID == row.id

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                // Icon zone
                if !row.childItems.isEmpty {
                    Button {
                        expandedDownloadRowID = isExpanded ? nil : row.id
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down.circle.fill" : "chevron.right.circle.fill")
                            .font(.system(size: 14))
                            .foregroundColor(.mlmInkMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("operation_download_expansion")
                } else {
                    Image(systemName: iconName(for: row.kind))
                        .font(.system(size: 14))
                        .foregroundColor(iconColor(for: row))
                        .frame(width: 20)
                }

                // Text stack
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(MLMFont.body)
                        .lineLimit(1)

                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Progress or badge zone
                if let progress = row.progress {
                    ProgressView(value: progress)
                        .frame(width: 80)
                        .accessibilityIdentifier("operation_progress")
                    if let percentText = row.percentText {
                        Text(percentText)
                            .font(MLMFont.mono)
                            .foregroundColor(.mlmInkMuted)
                            .frame(width: 48)
                    }
                } else if let badgeText = row.badgeText {
                    statusBadge(text: badgeText, color: badgeColor(for: row))
                } else if let durationText = row.durationText {
                    Text(durationText)
                        .font(MLMFont.mono)
                        .foregroundColor(.mlmInkMuted)
                }

                // Actions
                actionButtons(for: row, vm: vm)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.mlmBase)
            .hoverBackground()

            // Child items disclosure
            if isExpanded && !row.childItems.isEmpty {
                ForEach(row.childItems.prefix(5)) { child in
                    childItemView(child)
                }
            }
        }
        // Row identifier uses the stable "operation_row_" prefix from Module 2
        .accessibilityIdentifier(row.accessibilityIdentifier)
    }

    private func childItemView(_ child: ActivityChildItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundColor(.mlmInkMuted)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(child.title)
                    .font(MLMFont.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let errorText = child.errorText, !errorText.isEmpty {
                    Text(errorText)
                        .font(MLMFont.muted)
                        .foregroundColor(.red)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text(child.statusText)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(colorForName(child.statusColorName).opacity(0.15))
                )
                .foregroundColor(colorForName(child.statusColorName))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .accessibilityIdentifier("operation_download_item")
    }

    @ViewBuilder
    private func actionButtons(for row: ActivityRow, vm: ActivityViewModel) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(row.actions.enumerated()), id: \.offset) { _, action in
                actionButton(action, row: row, vm: vm)
            }
            // Driver-backed batch rows with nil operationID get a direct Cancel
            if row.kind == .download && !row.actions.contains(where: { isCancel($0) }) {
                directCancelDownload
            }
            if row.kind == .sync && !row.actions.contains(where: { isCancel($0) }) {
                directCancelSync
            }
        }
    }

    private func isCancel(_ action: ActivityRowAction) -> Bool {
        if case .cancel = action { return true }
        return false
    }

    private var directCancelDownload: some View {
        Button("Cancel") {
            container.downloadViewModel?.cancel()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("operation_cancel_button")
    }

    private var directCancelSync: some View {
        Button("Cancel") {
            container.syncViewModel?.cancelSync()
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("operation_cancel_button")
    }

    @ViewBuilder
    private func actionButton(_ action: ActivityRowAction, row: ActivityRow, vm: ActivityViewModel) -> some View {
        switch action {
        case .cancel(let operationID):
            Button("Cancel") {
                vm.cancelOperation(id: operationID)
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("operation_cancel_button")

        case .retry(let operationID):
            Button("Retry") {
                Task {
                    await vm.retryOperation(id: operationID)
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("operation_retry_button")

        case .retryDownloads(let trackIDs):
            Button("Retry") {
                Task {
                    await container.downloadViewModel?.retryAllFailed(trackIds: trackIDs)
                }
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("operation_retry_button")

        case .pauseSync, .resumeSync:
            Button(row.actions.contains(where: { isResume($0) }) ? "Resume" : "Pause") {
                container.syncViewModel?.toggleSyncPause()
            }
            .buttonStyle(.bordered)

        case .clearAnalysisQueue:
            Button("Clear") {
                showClearQueueAlert = true
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("operation_analysis_clear_button")

        case .clearRecent:
            EmptyView()
        }
    }

    private func isResume(_ action: ActivityRowAction) -> Bool {
        if case .resumeSync = action { return true }
        return false
    }

    // MARK: - Empty state

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

    // MARK: - Helpers

    private func iconName(for kind: ActivityViewModel.Operation.OperationType) -> String {
        switch kind {
        case .download: "arrow.down.circle"
        case .sync: "arrow.triangle.2.circlepath"
        case .import: "square.and.arrow.down"
        case .analysis: "waveform"
        case .fingerprint: "hand.point.up.braille"
        case .artwork: "photo"
        case .createMLExport: "brain"
        }
    }

    private func iconColor(for row: ActivityRow) -> Color {
        switch row.status {
        case .running: .accentColor
        case .completed: .green
        case .failed: .red
        case .cancelled: .orange
        case .stalled: .mlmAttention
        }
    }

    private func badgeColor(for row: ActivityRow) -> Color {
        switch row.status {
        case .failed: .red
        case .cancelled: .orange
        case .stalled: .mlmAttention
        default: .mlmInkMuted
        }
    }

    private func statusBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.15))
            )
            .foregroundColor(color)
            .accessibilityIdentifier("operation_status_badge")
    }

    private func colorForName(_ name: String) -> Color {
        switch name {
        case "accent": return .accentColor
        case "success": return .green
        case "error": return .red
        case "attention": return .mlmAttention
        default: return .mlmInkMuted
        }
    }

    // MARK: - Persisted failures

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

// MARK: - Hover background helper

private extension View {
    func hoverBackground() -> some View {
        modifier(HoverSurfaceModifier())
    }
}

private struct HoverSurfaceModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.mlmSurface : Color.clear)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
