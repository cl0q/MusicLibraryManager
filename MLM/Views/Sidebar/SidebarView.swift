import SwiftUI

// MARK: Accessibility labels for shotty UI automation (snake_case literals)

/// Sidebar navigation for the native macOS app shell.
///
/// Provides navigation items with ⌘1–⌘7 keyboard shortcuts
/// (wired via CommandMenu in MLMApp) and a Settings footer.
struct SidebarView: View {
    @Binding var selectedSection: SidebarSection
    @Environment(\.container) private var container
    @State private var pendingDuplicatesCount: Int = 0
    @State private var pendingConflictsCount: Int = 0
    @State private var pendingRecommendationsCount: Int = 0
    @State private var hasExpiredSource = false
    @State private var pendingPlaylistDeletion: Playlist?

    var body: some View {
        List(selection: $selectedSection) {
            Section {
                sidebarRow(.library)
                    .accessibilityIdentifier("sidebar_library_row")
                    .accessibilityLabel("sidebar_library_row")
                pinnedPlaylistsRow
                    .accessibilityIdentifier("sidebar_playlists_row")
                    .accessibilityLabel("sidebar_playlists_row")
                sidebarRow(.folders)
                    .accessibilityIdentifier("sidebar_folders_row")
                    .accessibilityLabel("sidebar_folders_row")
                sidebarRow(.sync)
                    .accessibilityIdentifier("sidebar_sync_row")
                    .accessibilityLabel("sidebar_sync_row")
                sidebarRow(.sources)
                    .accessibilityIdentifier("sidebar_sources_row")
                    .accessibilityLabel("sidebar_sources_row")
            } header: {
                Text("LIBRARY")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkMuted)
            }

            Section {
                sidebarRow(.review)
                    .accessibilityIdentifier("sidebar_review_row")
                    .accessibilityLabel("sidebar_review_row")
                sidebarRow(.discover)
                    .accessibilityIdentifier("sidebar_discover_row")
                    .accessibilityLabel("sidebar_discover_row")
            } header: {
                Text("WORK")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkMuted)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            bottomInset
        }
        .background(Color.mlmSurface)
        .task {
            updatePendingDuplicatesCount()
            updatePendingRecommendationsCount()
            updateSourceStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewQueueDidChange)) { _ in
            updatePendingDuplicatesCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            updatePendingDuplicatesCount()
            updatePendingRecommendationsCount()
            updateSourceStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .downloadDidComplete)) { _ in
            updatePendingRecommendationsCount()
        }
        .confirmationDialog(
            "Delete playlist?",
            isPresented: Binding(
                get: { pendingPlaylistDeletion != nil },
                set: { if !$0 { pendingPlaylistDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Playlist", role: .destructive) {
                guard let id = pendingPlaylistDeletion?.id else { return }
                pendingPlaylistDeletion = nil
                Task {
                    do {
                        try await container.playlistRepository?.delete(id: id)
                        NotificationCenter.default.post(name: .playlistDidChange, object: nil)
                    } catch {
                        AppLogger.shared.error(
                            "Could not delete playlist: \(error.localizedDescription)",
                            source: "Sidebar"
                        )
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingPlaylistDeletion = nil
            }
        } message: {
            Text("Delete “\(pendingPlaylistDeletion?.name ?? "")”? Its music files will remain in your library.")
        }
    }

    @ViewBuilder
    private var pinnedPlaylistsRow: some View {
        PinnedPlaylistsDisclosure(
            topLevelLabel: SidebarSection.playlists.label,
            topLevelIcon: SidebarSection.playlists.icon,
            topLevelSection: .playlists,
            onUnpin: { pid in
                Task {
                    try? await container.playlistRepository?.togglePin(id: pid)
                    NotificationCenter.default.post(name: .playlistDidChange, object: nil)
                }
            },
            onDelete: { playlist in
                pendingPlaylistDeletion = playlist
            },
            onSelectSection: { targetSection in
                selectedSection = targetSection
            }
        )
    }

    private func sidebarRow(_ section: SidebarSection) -> some View {
        Button {
            selectedSection = section
        } label: {
            HStack {
                Label(section.label, systemImage: section.icon)

            if section == .library && !container.isLibraryDriveMounted {
                Spacer()
                Circle()
                    .fill(Color.mlmError)
                    .frame(width: 7, height: 7)
                    .help("Library drive disconnected")
                    .accessibilityIdentifier("sidebar_library_drive_disconnected")
                    .accessibilityLabel("Library drive disconnected")
            }

            if section == .sync, container.syncViewModel?.isSyncing == true {
                Spacer()
                ProgressView()
                    .controlSize(.mini)
                    .tint(.mlmActive)
                    .help("Sync in progress")
                    .accessibilityIdentifier("sidebar_sync_in_progress")
                    .accessibilityLabel("Sync in progress")
            }

            if section == .sources && hasExpiredSource {
                Spacer()
                Circle()
                    .fill(Color.mlmAttention)
                    .frame(width: 7, height: 7)
                    .help("A source sign-in has expired")
                    .accessibilityIdentifier("sidebar_source_expired")
                    .accessibilityLabel("A source sign-in has expired")
            }

            if section == .review && (pendingDuplicatesCount > 0 || pendingConflictsCount > 0) {
                Spacer()
                Text("\(pendingDuplicatesCount) dup · \(pendingConflictsCount) conf")
                    .font(MLMFont.badge)
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.mlmAttention))
                    .help("\(pendingDuplicatesCount) duplicate groups and \(pendingConflictsCount) metadata conflicts need review")
                    .accessibilityIdentifier("sidebar_review_pending_counts")
                    .accessibilityLabel("\(pendingDuplicatesCount) duplicate groups and \(pendingConflictsCount) metadata conflicts need review")
            }

            if section == .discover && pendingRecommendationsCount > 0 {
                Spacer()
                Text("\(pendingRecommendationsCount)")
                    .font(MLMFont.badge)
                    .foregroundColor(.mlmInkMuted)
                    .help("\(pendingRecommendationsCount) recommendations pending")
                    .accessibilityIdentifier("sidebar_discover_pending_count")
                    .accessibilityLabel("\(pendingRecommendationsCount) recommendations pending")
            }
        }
            .springLoadableHover {
                selectedSection = section
            }
        }
        .buttonStyle(.plain)
        .tag(section)
    }

    // MARK: - Queue footer

    private var queueFooter: some View {
        Button {
            selectedSection = .queue
        } label: {
            HStack {
                Label(SidebarSection.queue.label, systemImage: SidebarSection.queue.icon)
                    .font(MLMFont.body)
                    .foregroundColor(selectedSection == .queue ? .white : .mlmInkSecondary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selectedSection == .queue ? Color.accentColor : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .keyboardShortcut("8")
        .accessibilityIdentifier("sidebar_queue_footer")
        .accessibilityLabel("sidebar_queue_footer")
    }

    // MARK: - Settings footer

    private var settingsFooter: some View {
        Button {
            AppDelegate.shared?.showSettingsWindow()
        } label: {
            Label("Settings", systemImage: "gearshape")
                .font(MLMFont.body)
                .foregroundColor(.mlmInkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .accessibilityIdentifier("settings_button")
        .accessibilityLabel("settings_button")
    }

    /// Bottom safeAreaInset content: queue footer above settings.
    private var bottomInset: some View {
        VStack(spacing: 0) {
            queueFooter
            Divider()
            settingsFooter
        }
    }

    private func updatePendingDuplicatesCount() {
        guard let analysisRepo = container.analysisRepository else { return }
        Task {
            if let counts = try? await analysisRepo.pendingReviewCounts() {
                await MainActor.run {
                    self.pendingDuplicatesCount = counts.duplicates
                    self.pendingConflictsCount = counts.conflicts
                }
            }
        }
    }

    private func updatePendingRecommendationsCount() {
        guard let trackRepo = container.trackRepository else { return }
        Task {
            let count = (try? await trackRepo.fetchDiscoveryInboxTracks().count) ?? 0
            await MainActor.run {
                pendingRecommendationsCount = count
            }
        }
    }

    private func updateSourceStatus() {
        guard let tokenStorage = container.tokenStorage else { return }
        hasExpiredSource = TokenStorage.Service.allCases.contains { service in
            let credentials = try? tokenStorage.getCredentials(service: service)
            return credentials?.isExpired ?? false
        }
    }
}
