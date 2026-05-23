import SwiftUI

/// Sidebar navigation matching the Tauri app's 5-section layout.
///
/// Provides navigation items with ⌘1–⌘5 keyboard shortcuts
/// (wired via CommandMenu in MLMApp) and a Settings footer.
struct SidebarView: View {
    @Binding var selectedSection: SidebarSection
    @Environment(\.container) private var container
    @State private var pendingDuplicatesCount: Int = 0

    var body: some View {
        List(selection: $selectedSection) {
            Section {
                // Phase 36 Plan 04: `.allCases` was removed when SidebarSection
                // gained the `.playlistDetail(Int64)` associated-value case.
                // Top-level rows iterate the explicit `topLevelCases` array;
                // the `.playlists` row is replaced by `PinnedPlaylistsDisclosure`
                // which nests pinned-playlist children under a DisclosureGroup
                // (D-07/D-08) and routes their clicks via `.playlistDetail` (D-09).
                ForEach(SidebarSection.topLevelCases) { section in
                    if section == .playlists {
                        PinnedPlaylistsDisclosure(
                            topLevelLabel: section.label,
                            topLevelIcon: section.icon,
                            topLevelSection: section,
                            onUnpin: { pid in
                                Task {
                                    try? await container.playlistRepository?.togglePin(id: pid)
                                    // togglePin does not post .playlistDidChange itself —
                                    // fire here so the disclosure refreshes after unpin.
                                    NotificationCenter.default.post(name: .playlistDidChange, object: nil)
                                }
                            },
                            onDelete: { pid in
                                Task {
                                    try? await container.playlistRepository?.delete(id: pid)
                                    NotificationCenter.default.post(name: .playlistDidChange, object: nil)
                                }
                            },
                            onSelectSection: { targetSection in
                                selectedSection = targetSection
                            }
                        )
                    } else {
                        HStack {
                            Label(section.label, systemImage: section.icon)

                            // Show disconnected indicator for Library when drive is unmounted
                            if section == .library && !container.isLibraryDriveMounted {
                                Spacer()
                                Circle()
                                    .fill(Color.mlmError)
                                    .frame(width: 7, height: 7)
                                    .help("Library drive disconnected")
                            }

                            // Show pending duplicates badge count
                            if section == .duplicates && pendingDuplicatesCount > 0 {
                                Spacer()
                                Text("\(pendingDuplicatesCount)")
                                    .font(MLMFont.mono)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        Capsule()
                                            .fill(Color.orange)
                                    )
                            }
                        }
                        .tag(section)
                        .springLoadableHover {
                            selectedSection = section
                        }
                    }
                }
            } header: {
                Text("NAVIGATION")
                    .font(MLMFont.sectionLabel)
                    .foregroundColor(.mlmInkMuted)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            settingsFooter
        }
        .background(Color.mlmSurface)
        .task {
            updatePendingDuplicatesCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .reviewQueueDidChange)) { _ in
            updatePendingDuplicatesCount()
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryDidImport)) { _ in
            updatePendingDuplicatesCount()
        }
    }

    // MARK: - Settings footer

    private var settingsFooter: some View {
        Button {
            if let delegate = AppDelegate.shared {
                delegate.showSettingsWindow()
            } else {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
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
    }

    private func updatePendingDuplicatesCount() {
        guard let analysisRepo = container.analysisRepository else { return }
        Task {
            if let count = try? await analysisRepo.countPendingReviews() {
                await MainActor.run {
                    self.pendingDuplicatesCount = count
                }
            }
        }
    }
}
