import SwiftUI

/// Root sync view — profile grid and detail.
///
/// HSplitView: profile list (left) + profile detail with preview/execute (right).
struct SyncView: View {
    @Environment(\.container) private var container
    @State private var showCreateSheet = false
    @State private var newProfileName = ""
    @State private var newProfileOutput = ""
    @State private var detectedDevices: [DeviceDetector.RockboxDevice] = []
    @State private var hasRunDetection = false
    @State private var shouldApplyDeviceDefaults = false
    @State private var showRockboxToast = false
    @State private var isCreating = false
    @State private var profilePendingDeletion: SyncProfile?
    @State private var showingDeleteConfirmation = false
    @State private var profilePendingRename: SyncProfile?
    @State private var renameDraft = ""
    @State private var showingRenameSheet = false
    // WP4 — Device ingest scan
    @State private var showingDeviceIngestSheet = false
    @State private var deviceIngestProfile: SyncProfile?

    var body: some View {
        // [navperf] temporary instrumentation — remove after measurement
        let _ = print("[navperf] section-body sync \(Date().timeIntervalSince1970)")
        ZStack(alignment: .bottom) {
            Group {
                if let vm = container.syncViewModel {
                    HSplitView {
                        profileList(vm: vm)
                            .frame(minWidth: 200, maxWidth: 280)

                        profileDetail(vm: vm)
                            .frame(maxWidth: .infinity)
                    }
                    .task {
                        // [navperf] temporary instrumentation — remove after measurement
                        print("[navperf] section-task-start sync \(Date().timeIntervalSince1970)")
                        // Refresh on first appear; subsequent re-mounts skip re-init
                        // because VM lives in the container.
                        if vm.profiles.isEmpty && !vm.isLoading {
                            await vm.loadProfiles()
                            // [navperf] temporary instrumentation — remove after measurement
                            print("[navperf] section-task-after-first-await sync \(Date().timeIntervalSince1970)")
                        }
                    }
                } else {
                    ProgressView("Loading...")
                }
            }
            .sheet(isPresented: $showCreateSheet) {
                createProfileSheet
            }
            .alert("Delete sync profile?", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) {
                    profilePendingDeletion = nil
                }
                Button("Delete", role: .destructive) {
                    guard let profile = profilePendingDeletion,
                          let vm = container.syncViewModel else { return }
                    profilePendingDeletion = nil
                    Task { await vm.deleteProfile(profile) }
                }
            } message: {
                if let profile = profilePendingDeletion {
                    Text("Delete \"\(profile.name)\"? This removes the sync profile but does not delete any music files.")
                }
            }
            .sheet(isPresented: $showingRenameSheet) {
                renameProfileSheet
            }
            .sheet(isPresented: $showingDeviceIngestSheet) {
                if let profile = deviceIngestProfile {
                    DeviceIngestResultsView(profile: profile)
                }
            }

            SyncToast(
                message: "Rockbox device detected — device defaults applied",
                isShowing: showRockboxToast
            )
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
                    vm.clearError()
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
                    SyncProfileRow(profile: profile, status: vm.profileStatus(for: profile))
                        .tag(profile)
                        .contextMenu {
                            Button("Rename…") {
                                profilePendingRename = profile
                                renameDraft = profile.name
                                showingRenameSheet = true
                            }
                            Button("Duplicate") {
                                Task { await vm.duplicateProfile(profile) }
                            }
                            Button("Read playlist changes from device…") {
                                deviceIngestProfile = profile
                                showingDeviceIngestSheet = true
                                Task { await vm.scanDeviceForPlaylistChanges(profile: profile) }
                            }
                            Button("Delete…", role: .destructive) {
                                profilePendingDeletion = profile
                                showingDeleteConfirmation = true
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
            SyncProfileDetailView(profile: profile)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 32))
                    .foregroundColor(.mlmInkMuted)
                Text("Select a profile from the list")
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

            TextField("Name", text: $newProfileName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Output folder", text: $newProfileOutput)
                    .textFieldStyle(.roundedBorder)
                Button("Browse…") {
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

            // Phase 38 D-09: On-demand device detection
            VStack(alignment: .leading, spacing: 8) {
                Button("Detect device…") {
                    detectedDevices = DeviceDetector.detectRockboxDevices()
                    hasRunDetection = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.mlmAccent)

                if hasRunDetection {
                    if detectedDevices.isEmpty {
                        // D-10: Empty state copy
                        Text("No devices found — is it connected?")
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkMuted)
                    } else {
                        ForEach(detectedDevices, id: \.mountPoint) { device in
                            Button {
                                newProfileOutput = device.mountPoint
                                if newProfileName.isEmpty {
                                    newProfileName = "\(device.deviceName) iPod"
                                }
                                shouldApplyDeviceDefaults = true
                                showRockboxToast = true
                                Task { try? await Task.sleep(for: .seconds(3)); showRockboxToast = false }
                            } label: {
                                HStack {
                                    Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.deviceName)
                                            .font(MLMFont.body)
                                            .foregroundColor(.mlmInk)
                                        Text("\(device.mountPoint)")
                                            .font(MLMFont.muted)
                                            .foregroundColor(.mlmInkMuted)
                                    }
                                    Spacer()
                                    if shouldApplyDeviceDefaults && newProfileOutput == device.mountPoint {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.mlmAccent)
                                    }
                                }
                                .padding(.vertical, 4)
                                .padding(.horizontal, 8)
                                .background(Color.mlmRaised)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let vm = container.syncViewModel, let err = vm.errorMessage {
                Text(err)
                    .foregroundColor(.red)
                    .font(MLMFont.muted)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") {
                    showCreateSheet = false
                    detectedDevices = []
                    hasRunDetection = false
                    shouldApplyDeviceDefaults = false
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Spacer()

                Button("Create") {
                    guard let vm = container.syncViewModel, !newProfileName.isEmpty else { return }
                    let applyDefaults = shouldApplyDeviceDefaults
                    isCreating = true
                    Task {
                        await vm.createProfile(
                            name: newProfileName,
                            outputFolder: newProfileOutput,
                            generateM3U8: applyDefaults ? true : false,
                            transcodeMode: applyDefaults ? "aac_248" : "keep_originals",
                            fat32SafePaths: true,
                            cleanupRemovedFiles: true,
                            artworkMode: applyDefaults ? "resize_250" : "keep_original"
                        )
                        if vm.errorMessage == nil {
                            showCreateSheet = false
                            newProfileName = ""
                            newProfileOutput = ""
                            detectedDevices = []
                            hasRunDetection = false
                            shouldApplyDeviceDefaults = false
                        }
                        isCreating = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newProfileName.isEmpty || isCreating)
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var renameProfileSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename sync profile")
                .font(MLMFont.sectionHeader)
            TextField("Name", text: $renameDraft)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Cancel") {
                    profilePendingRename = nil
                    showingRenameSheet = false
                }
                .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Rename") {
                    guard let profile = profilePendingRename,
                          let vm = container.syncViewModel else { return }
                    Task { await vm.renameProfile(profile, name: renameDraft) }
                    profilePendingRename = nil
                    showingRenameSheet = false
                }
                .keyboardShortcut(.defaultAction)
                .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

}

// MARK: - Profile Row

struct SyncProfileRow: View {
    let profile: SyncProfile
    let status: String

    private var statusSymbol: String {
        if status.hasPrefix("Syncing") { return "arrow.triangle.2.circlepath" }
        if status == "Device not connected" { return "externaldrive.badge.xmark" }
        if status.contains("pending") { return "circle.fill" }
        if status.hasPrefix("Synced") { return "checkmark.circle" }
        return "circle"
    }

    private var statusColor: Color {
        if status.hasPrefix("Syncing") || status.contains("pending") { return .mlmActive }
        if status == "Device not connected" { return .mlmAttention }
        if status.hasPrefix("Synced") { return .mlmSuccess }
        return .mlmInkSecondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(profile.name)
                .font(MLMFont.body)
            Text(profile.outputFolder)
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Label(status, systemImage: statusSymbol)
                .font(MLMFont.muted)
                .foregroundColor(statusColor)
        }
        .padding(.vertical, 4)
    }
}
