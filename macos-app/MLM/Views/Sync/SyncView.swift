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

    var body: some View {
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

            // Phase 38: Rockbox smart-defaults toast (D-03)
            SyncToast(
                message: "Rockbox iPod erkannt — Device-Defaults aktiviert",
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
            SyncProfileDetailView(profile: profile)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 32))
                    .foregroundColor(.mlmInkMuted)
                Text("Profil aus der Liste auswählen")
                    .font(MLMFont.body)
                    .foregroundColor(.mlmInkMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Create Sheet

    private var createProfileSheet: some View {
        VStack(spacing: 16) {
            Text("Neues Sync-Profil")
                .font(MLMFont.title3)

            TextField("Profilname", text: $newProfileName)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Ausgabe-Ordner", text: $newProfileOutput)
                    .textFieldStyle(.roundedBorder)
                Button("Durchsuchen…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.canCreateDirectories = true
                    panel.allowsMultipleSelection = false
                    panel.prompt = "Auswählen"
                    if panel.runModal() == .OK, let url = panel.url {
                        newProfileOutput = url.path
                    }
                }
            }

            // Phase 38 D-09: On-demand device detection
            VStack(alignment: .leading, spacing: 8) {
                Button("Gerät erkennen…") {
                    detectedDevices = DeviceDetector.detectRockboxDevices()
                    hasRunDetection = true
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.mlmAccent)

                if hasRunDetection {
                    if detectedDevices.isEmpty {
                        // D-10: Empty state copy
                        Text("Keine Geräte gefunden — angeschlossen?")
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

            HStack {
                Button("Abbrechen") {
                    showCreateSheet = false
                    detectedDevices = []
                    hasRunDetection = false
                    shouldApplyDeviceDefaults = false
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Erstellen") {
                    guard let vm = container.syncViewModel, !newProfileName.isEmpty else { return }
                    let applyDefaults = shouldApplyDeviceDefaults
                    Task {
                        await vm.createProfile(
                            name: newProfileName,
                            outputFolder: newProfileOutput,
                            generateM3U8: applyDefaults ? true : false,
                            transcodeMode: applyDefaults ? "aac_248" : "keep_originals",
                            fat32SafePaths: true,
                            cleanupRemovedFiles: true
                        )
                        showCreateSheet = false
                        newProfileName = ""
                        newProfileOutput = ""
                        detectedDevices = []
                        hasRunDetection = false
                        shouldApplyDeviceDefaults = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newProfileName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
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

