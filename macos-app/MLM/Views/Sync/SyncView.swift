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

