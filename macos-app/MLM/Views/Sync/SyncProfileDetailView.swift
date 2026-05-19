import SwiftUI

/// Detail view for a sync profile.
///
/// Extracted from SyncView (Phase 38 Plan 03). Accesses SyncViewModel via
/// @Environment container — no prop-drilling needed.
///
/// Layout (top to bottom):
///   1. Header — name, outputFolder, Refresh + Sync Now buttons
///   2. Divider
///   3. SyncSettingsForm (collapsed by default)
///   4. Content header — "Playlists hinzufügen…" + "Tracks hinzufügen…"
///   5. SyncContentSections — Playlists (N) + Tracks (N) DisclosureGroups
///   6. Divider
///   7. Progress OR Preview stats (D-12: swapped while isSyncing)
///   8. Result section (after sync completes, with SyncFailedDisclosure if needed)
struct SyncProfileDetailView: View {
    let profile: SyncProfile

    @Environment(\.container) private var container
    @State private var showPlaylistPicker = false
    @State private var showTrackPicker = false

    private var vm: SyncViewModel? { container.syncViewModel }

    // MARK: - Human-readable sync-button disable reason

    private func disabledReason(_ vm: SyncViewModel) -> String? {
        if vm.isSyncing { return "Sync läuft bereits…" }
        if vm.isLoading { return "Vorschau wird berechnet…" }
        guard let preview = vm.preview else { return "Vorschau noch nicht geladen — Refresh klicken" }
        if !FileManager.default.fileExists(atPath: profile.outputFolder) {
            return "Output-Ordner nicht erreichbar: \(profile.outputFolder)"
        }
        if !preview.hasSufficientSpace { return "Nicht genug Speicherplatz auf dem Zielordner" }
        if preview.filesToAdd.isEmpty && preview.filesToRemove.isEmpty {
            return "Keine Änderungen — alles bereits synchronisiert"
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

                Divider().background(Color.mlmEdgeSubtle)

                // 3. Content header + sections (D-07)
                contentHeader

                if let v = vm {
                    SyncContentSections(profile: profile, vm: v)
                }

                Divider().background(Color.mlmEdgeSubtle)

                // 4. Preview stats — Live-Progress läuft jetzt im Operations-Tab
                if let v = vm {
                    if v.isLoading {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Vorschau wird berechnet…")
                                .font(MLMFont.body)
                                .foregroundColor(.mlmInkMuted)
                        }
                        .padding(.vertical, 8)
                    } else if let preview = v.preview {
                        previewStatsSection(preview)
                    }

                    if v.isSyncing {
                        Label("Sync läuft — Details im Operations-Tab", systemImage: "arrow.triangle.2.circlepath")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                            .padding(.top, 4)
                    }

                    // Error
                    if let error = v.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.mlmError)
                            .font(MLMFont.muted)
                            .padding(.vertical, 4)
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
        .sheet(isPresented: $showPlaylistPicker) {
            if let v = vm {
                PlaylistPickerSheet(vm: v)
            }
        }
        .sheet(isPresented: $showTrackPicker) {
            if let v = vm {
                TrackPickerSheet(vm: v)
            }
        }
        // VIEW observes .syncProfileDidChange — VM only posts (confirmed in 38-02)
        .onReceive(NotificationCenter.default.publisher(for: .syncProfileDidChange)) { notification in
            guard let profileId = notification.userInfo?["profileId"] as? Int64,
                  profileId == profile.id else { return }
            Task { await vm?.loadPreview(for: profile) }
        }
        .task(id: profile.id) {
            await vm?.loadPreview(for: profile)
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
                        .font(MLMFont.title2)
                        .foregroundColor(.mlmInk)
                    Text(profile.outputFolder)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if v.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }
                Button {
                    Task { await v.loadPreview(for: profile) }
                } label: {
                    Label("Aktualisieren", systemImage: "arrow.clockwise")
                }
                .disabled(v.isLoading)
                .keyboardShortcut("r", modifiers: .command)
                .help("Vorschau und Profil-Inhalt neu laden (⌘R)")

                Button("Sync starten") {
                    Task { await v.executeSync() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.mlmAccent)
                .disabled(v.isSyncing || !(v.preview?.hasSufficientSpace ?? false))
                .help(reason ?? "Profil-Inhalt mit dem Zielordner synchronisieren")
            }

            if let reason {
                Label(reason, systemImage: "info.circle")
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkSecondary)
            }
        }
    }

    // MARK: - Content Header

    private var contentHeader: some View {
        HStack(spacing: 8) {
            Text("Inhalt")
                .font(MLMFont.bodyBold)
                .foregroundColor(.mlmInk)
            Spacer()
            Button("Playlists hinzufügen…") { showPlaylistPicker = true }
                .buttonStyle(.borderless)
                .tint(.mlmAccent)
            Button("Tracks hinzufügen…") { showTrackPicker = true }
                .buttonStyle(.borderless)
                .tint(.mlmAccent)
        }
        .padding(.top, 4)
    }

    // MARK: - Preview Stats

    @ViewBuilder
    private func previewStatsSection(_ preview: SyncService.SyncPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync-Vorschau")
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkMuted)

            HStack(spacing: 24) {
                statCard(
                    value: "\(preview.filesToAdd.count)",
                    label: "Hinzufügen",
                    color: .green
                )
                statCard(
                    value: "\(preview.filesToRemove.count)",
                    label: "Entfernen",
                    color: .mlmError
                )
                statCard(
                    value: formatBytes(preview.totalNewSize),
                    label: "Neue Größe",
                    color: .mlmInk
                )
                statCard(
                    value: formatBytes(preview.deviceAvailableSpace),
                    label: "Verfügbar",
                    color: preview.hasSufficientSpace ? .mlmInk : .mlmError
                )
            }

            if !preview.hasSufficientSpace {
                Label("Nicht genug Speicherplatz", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.mlmError)
                    .font(MLMFont.muted)
            }
        }
    }

    private func statCard(value: String, label: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .foregroundColor(color)
            Text(label)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
        }
    }

    // MARK: - Result Section

    @ViewBuilder
    private func resultSection(_ result: SyncService.SyncResult, vm: SyncViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().background(Color.mlmEdgeSubtle)

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("\(result.syncedCount) synchronisiert")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInk)
                if result.failedCount > 0 {
                    Text("·")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.mlmError)
                    Text("\(result.failedCount) fehlgeschlagen")
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
}
