import SwiftUI
import AppKit

/// Detail view for a sync profile.
///
/// Extracted from SyncView (Phase 38 Plan 03). Accesses SyncViewModel via
/// @Environment container — no prop-drilling needed.
///
/// Layout (top to bottom):
///   1. Header — name, outputFolder, Refresh + Sync Now buttons
///   2. Divider
///   3. SyncSettingsForm (collapsed by default)
///   4. Content header with playlist and track add actions.
///   5. SyncContentSections — Playlists (N) + Tracks (N) DisclosureGroups
///   6. Divider
///   7. Progress OR Preview stats (D-12: swapped while isSyncing)
///   8. Result section (after sync completes, with SyncFailedDisclosure if needed)
struct SyncProfileDetailView: View {
    let profile: SyncProfile

    @Environment(\.container) private var container

    private var vm: SyncViewModel? { container.syncViewModel }
    @State private var showFilesToAdd = false
    @State private var showFilesToRemove = false

    // MARK: - Human-readable sync-button disable reason

    private func disabledReason(_ vm: SyncViewModel) -> String? {
        if vm.isSyncing { return "Sync is already running" }
        if vm.isPreviewUpdating && vm.preview == nil { return "Preview is updating…" }
        guard let preview = vm.preview else { return "Preview has not been loaded. Select Refresh to try again." }
        if !FileManager.default.fileExists(atPath: profile.outputFolder) {
            return "Device not connected — preview unchecked"
        }
        if !preview.hasSufficientSpace { return "Not enough space on device" }
        if preview.filesToAdd.isEmpty && preview.filesToRemove.isEmpty {
            return "No changes — everything is already synced"
        }
        return nil
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // 1. Header
                if let v = vm {
                    headerSection(v)
                }

                Divider().background(Color.mlmEdge)

                // 2. Settings form (collapsed by default — D-02)
                if let v = vm {
                    SyncSettingsForm(profile: profile, vm: v)
                }

                // 3. Content sections (Playlists & Tracks)
                if let v = vm {
                    SyncContentSections(profile: profile, vm: v)
                }

                Divider().background(Color.mlmEdgeSubtle)

                // 4. Cached preview and its background refresh state.
                if let v = vm {
                    previewStatusRow(v)
                    if let preview = v.preview, preview.isDeviceConnected {
                        previewStatsSection(preview)
                    }

                    if v.isSyncing {
                        syncProgressSection(v)
                    }

                    // Error
                    if let error = v.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.mlmError)
                            Text(error)
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmError)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.mlmError.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.mlmError.opacity(0.15), lineWidth: 1)
                        )
                    }

                    // 5. Result section (D-13)
                    if let result = v.lastResult {
                        resultSection(result, vm: v)
                    }
                }
            }
            .padding(16)
        }
        .background(Color.mlmBase)
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didMountNotification)) { _ in
            vm?.deviceAvailabilityDidChange(for: profile)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            vm?.deviceAvailabilityDidChange(for: profile)
        }
    }

    // MARK: - Header

    @ViewBuilder
    private func headerSection(_ v: SyncViewModel) -> some View {
        let reason = disabledReason(v)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(profile.name)
                        .font(MLMFont.pageTitle)
                        .foregroundColor(.mlmInk)
                    Text(profile.outputFolder)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if v.isPreviewUpdating {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }
                Button {
                    Task { await v.refreshPreviewNow(for: profile) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(v.isPreviewUpdating)
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh the preview and profile content (Command-R)")

                Button("Sync now") {
                    Task { await v.executeSync() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.mlmAccent)
                .disabled(reason != nil)
                .help(reason ?? "Sync this profile to its destination")
            }

            if let reason {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .foregroundColor(.mlmAccent)
                    Text(reason)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.mlmAccent.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.mlmAccent.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Preview Stats

    @ViewBuilder
    private func previewStatusRow(_ vm: SyncViewModel) -> some View {
        HStack(spacing: 8) {
            if vm.isPreviewUpdating {
                ProgressView()
                    .controlSize(.small)
                Text("Preview: updating… \(vm.previewProcessed)/\(vm.previewTotal)")
            } else if let preview = vm.preview, !preview.isDeviceConnected {
                Image(systemName: "externaldrive.badge.xmark")
                    .foregroundColor(.mlmAttention)
                Text("Device not connected — preview unchecked")
            } else if vm.isPreviewStale {
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.mlmAttention)
                Text("Preview: outdated — updating in background")
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.mlmSuccess)
                Text("Preview: up to date\(previewAgeSuffix(vm.previewComputedAt))")
            }

            Spacer()
            if vm.isPreviewUpdating {
                Button("Cancel") {
                    vm.cancelPreviewRefresh()
                }
                .buttonStyle(.borderless)
            }
        }
        .font(MLMFont.muted)
        .foregroundColor(.mlmInkSecondary)
    }

    @ViewBuilder
    private func previewStatsSection(_ preview: SyncService.SyncPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkMuted)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                Button {
                    withAnimation { showFilesToAdd.toggle() }
                } label: {
                    statCard(
                        value: "\(preview.filesToAdd.count)",
                        label: "Add",
                        systemImage: "plus.circle.fill",
                        color: .mlmSuccess
                    )
                }
                .buttonStyle(.plain)
                Button {
                    withAnimation { showFilesToRemove.toggle() }
                } label: {
                    statCard(
                        value: "\(preview.filesToRemove.count)",
                        label: "Remove",
                        systemImage: "minus.circle.fill",
                        color: .mlmError
                    )
                }
                .buttonStyle(.plain)
                statCard(
                    value: "≈ \(formatBytes(preview.totalNewSize))",
                    label: "New size",
                    systemImage: "arrow.triangle.2.circlepath",
                    color: .mlmAccent
                )
                statCard(
                    value: formatBytes(preview.deviceAvailableSpace),
                    label: "Available",
                    systemImage: "externaldrive.fill",
                    color: preview.hasSufficientSpace ? .mlmSuccess : .mlmError
                )
            }

            if showFilesToAdd {
                previewFileList(title: "Files to add", files: preview.filesToAdd)
            }
            if showFilesToRemove {
                previewFileList(title: "Files to remove", files: preview.filesToRemove)
            }

            if !preview.hasSufficientSpace {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.mlmError)
                    Text("Not enough space on device — need ≈\(formatBytes(preview.totalNewSize)), \(formatBytes(preview.deviceAvailableSpace)) available")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmError)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.mlmError.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.mlmError.opacity(0.15), lineWidth: 1)
                )
            }
        }
    }

    private func statCard(value: String, label: String, systemImage: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16))
                .foregroundColor(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.mlmInk)
                Text(label)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.mlmSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func previewFileList(title: String, files: [SyncService.FilePreview]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkMuted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            ForEach(files) { file in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(file.artist) – \(file.title)")
                            .font(MLMFont.body)
                            .foregroundColor(.mlmInk)
                            .lineLimit(1)
                        Text(file.destinationPath)
                            .font(MLMFont.dataSmall)
                            .foregroundColor(.mlmInkMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(formatBytes(file.size))
                        .font(MLMFont.dataSmall)
                        .foregroundColor(.mlmInkSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .contextMenu {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.destinationPath)])
                    }
                }
                Divider().padding(.leading, 12)
            }
        }
        .background(Color.mlmSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func syncProgressSection(_ vm: SyncViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ProgressView(value: vm.syncProgress, total: 1)
                    .progressViewStyle(.linear)
                Text("\(vm.isSyncPaused ? "Paused" : "Syncing…") \(vm.syncProcessed) of \(vm.syncTotal)")
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
            }

            if !vm.syncCurrentFile.isEmpty {
                Text(vm.syncCurrentFile)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button(vm.isSyncPaused ? "Resume" : "Pause") {
                    vm.toggleSyncPause()
                }
                .buttonStyle(.bordered)
                Button("Cancel", role: .cancel) {
                    vm.cancelSync()
                }
                .buttonStyle(.bordered)
            }

            if vm.syncSettingsApplyNextRun {
                Text("Settings changes apply to the next sync.")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            }
        }
        .padding(12)
        .background(Color.mlmActive.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Result Section

    @ViewBuilder
    private func resultSection(_ result: SyncService.SyncResult, vm: SyncViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(Color.mlmEdgeSubtle)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.mlmSuccess)
                Text("\(result.syncedCount) synced")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                if result.failedCount > 0 {
                    Text("·")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.mlmError)
                    Text("\(result.failedCount) failed")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmError)
                }
            }

            if result.failedCount > 0 {
                SyncFailedDisclosure(failedTracks: result.failedTracks, vm: vm)
            }
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes >= 1_000_000_000 {
            return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        } else if bytes >= 1_000_000 {
            return String(format: "%.0f MB", Double(bytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
    }

    private func previewAgeSuffix(_ date: Date?) -> String {
        guard let date else { return "" }
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return " · computed just now" }
        if seconds < 3_600 { return " · computed \(seconds / 60)m ago" }
        return " · computed \(seconds / 3_600)h ago"
    }
}
