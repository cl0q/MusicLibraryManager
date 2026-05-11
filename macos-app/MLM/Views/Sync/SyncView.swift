import SwiftUI

/// Root sync view — profile grid and detail.
///
/// HSplitView: profile list (left) + profile detail with preview/execute (right).
struct SyncView: View {
    @Environment(\.container) private var container
    @State private var showCreateSheet = false
    @State private var newProfileName = ""
    @State private var newProfileOutput = ""

    var body: some View {
        Group {
            if let vm = container.syncViewModel {
                HSplitView {
                    profileList(vm: vm)
                        .frame(minWidth: 200, maxWidth: 280)

                    profileDetail(vm: vm)
                        .frame(maxWidth: .infinity)
                }
                .task {
                    // Refresh on first appear; subsequent re-mounts skip re-init
                    // because VM lives in the container.
                    if vm.profiles.isEmpty && !vm.isLoading {
                        await vm.loadProfiles()
                    }
                }
            } else {
                ProgressView("Loading...")
            }
        }
        .sheet(isPresented: $showCreateSheet) {
            createProfileSheet
        }
    }

    // MARK: - Profile List

    @ViewBuilder
    private func profileList(vm: SyncViewModel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sync Profiles")
                    .font(MLMFont.sectionLabel)
                Spacer()
                Button {
                    showCreateSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if vm.isLoading && vm.profiles.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.profiles.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 28))
                        .foregroundColor(.mlmInkMuted)
                    Text("No sync profiles")
                        .font(MLMFont.body)
                        .foregroundColor(.mlmInkMuted)
                    Text("Create a profile to sync music to an external device")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(vm.profiles, selection: Binding(
                    get: { vm.selectedProfile },
                    set: { vm.selectedProfile = $0 }
                )) { profile in
                    SyncProfileRow(profile: profile)
                        .tag(profile)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                Task { await vm.deleteProfile(profile) }
                            }
                        }
                }
                .listStyle(.sidebar)
                .onChange(of: vm.selectedProfile) { _, newProfile in
                    guard let p = newProfile else { return }
                    Task { await vm.loadPreview(for: p) }
                }
            }
        }
        .background(Color.mlmSurface)
    }

    // MARK: - Profile Detail

    @ViewBuilder
    private func profileDetail(vm: SyncViewModel) -> some View {
        if let profile = vm.selectedProfile {
            SyncProfileDetailView(
                profile: profile,
                preview: vm.preview,
                isLoading: vm.isLoading,
                isSyncing: vm.isSyncing,
                lastResult: vm.lastResult,
                errorMessage: vm.errorMessage,
                onSync: { Task { await vm.executeSync() } },
                onRefresh: { Task { await vm.loadPreview(for: profile) } }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 32))
                    .foregroundColor(.mlmInkMuted)
                Text("Select a sync profile")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Create Sheet

    private var createProfileSheet: some View {
        VStack(spacing: 16) {
            Text("New Sync Profile")
                .font(MLMFont.title3)

            TextField("Profile Name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Output Folder", text: $newProfileOutput)
                    .textFieldStyle(.roundedBorder)
                Button("Browse...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Choose"
                    if panel.runModal() == .OK, let url = panel.url {
                        newProfileOutput = url.path
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    showCreateSheet = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create") {
                    guard let vm = container.syncViewModel, !newProfileName.isEmpty else { return }
                    Task {
                        await vm.createProfile(name: newProfileName, outputFolder: newProfileOutput)
                        showCreateSheet = false
                        newProfileName = ""
                        newProfileOutput = ""
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newProfileName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

// MARK: - Profile Row

struct SyncProfileRow: View {
    let profile: SyncProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name)
                .font(MLMFont.body)
            Text(profile.outputFolder)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Profile Detail

struct SyncProfileDetailView: View {
    let profile: SyncProfile
    let preview: SyncService.SyncPreview?
    let isLoading: Bool
    let isSyncing: Bool
    let lastResult: SyncService.SyncResult?
    let errorMessage: String?
    let onSync: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(profile.name)
                            .font(MLMFont.title2)
                        Text(profile.outputFolder)
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                    }

                    Spacer()

                    Button("Refresh") {
                        onRefresh()
                    }
                    .disabled(isLoading)

                    Button("Sync Now") {
                        onSync()
                    }
                    .disabled(isSyncing || !(preview?.hasSufficientSpace ?? false))
                    .buttonStyle(.borderedProminent)
                }

                Divider()

                // Preview
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Computing preview...")
                            .font(MLMFont.body)
                    }
                } else if let preview {
                    previewSection(preview)
                }

                // Error
                if let error = errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(MLMFont.body)
                }

                // Last result
                if let result = lastResult {
                    resultSection(result)
                }
            }
            .padding(16)
        }
        .background(Color.mlmBase)
    }

    @ViewBuilder
    private func previewSection(_ preview: SyncService.SyncPreview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sync Preview")
                .font(MLMFont.sectionLabel)

            HStack(spacing: 24) {
                VStack {
                    Text("\(preview.filesToAdd.count)")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                    Text("To Add")
                        .font(MLMFont.muted)
                }
                VStack {
                    Text("\(preview.filesToRemove.count)")
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                    Text("To Remove")
                        .font(MLMFont.muted)
                }
                VStack {
                    Text(formatBytes(preview.totalNewSize))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                    Text("New Size")
                        .font(MLMFont.muted)
                }
                VStack {
                    Text(formatBytes(preview.deviceAvailableSpace))
                        .font(.system(size: 24, weight: .semibold, design: .monospaced))
                        .foregroundColor(preview.hasSufficientSpace ? .mlmInkPrimary : .red)
                    Text("Available")
                        .font(MLMFont.muted)
                }
            }

            if !preview.hasSufficientSpace {
                Label("Insufficient disk space", systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            }
        }
    }

    @ViewBuilder
    private func resultSection(_ result: SyncService.SyncResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Sync Result")
                .font(MLMFont.sectionLabel)

            HStack(spacing: 16) {
                Label("\(result.syncedCount) synced", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)

                if result.failedCount > 0 {
                    Label("\(result.failedCount) failed", systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                }
            }
            .font(MLMFont.body)
        }
    }

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
