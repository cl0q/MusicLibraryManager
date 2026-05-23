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

                // 3. Content sections (Playlists & Tracks)
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
    private func previewStatsSection(_ preview: SyncService.SyncPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync-Vorschau")
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkMuted)

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ], spacing: 12) {
                statCard(
                    value: "\(preview.filesToAdd.count)",
                    label: "Hinzufügen",
                    systemImage: "plus.circle.fill",
                    color: .green
                )
                statCard(
                    value: "\(preview.filesToRemove.count)",
                    label: "Entfernen",
                    systemImage: "minus.circle.fill",
                    color: .mlmError
                )
                statCard(
                    value: formatBytes(preview.totalNewSize),
                    label: "Neue Größe",
                    systemImage: "arrow.triangle.2.circlepath",
                    color: .mlmAccent
                )
                statCard(
                    value: formatBytes(preview.deviceAvailableSpace),
                    label: "Verfügbar",
                    systemImage: "sdcard.fill",
                    color: preview.hasSufficientSpace ? .green : .mlmError
                )
            }

            if !preview.hasSufficientSpace {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.mlmError)
                    Text("Nicht genug Speicherplatz auf dem Zielgerät")
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
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
        )
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
