import SwiftUI
import UniformTypeIdentifiers

/// `New Sync Profile…` sheet, opened from the Sync section header ＋ and from the
/// `New Sync Profile…` items of the track and playlist menus.
///
/// Taken from `SyncView`'s private create sheet (W1-1) so the shell can present it now that
/// sync profiles are sidebar rows: same fields and behaviour, system styles, a file panel via
/// `.fileImporter`, and the "Rockbox device detected" toast as a status-bar message.
/// `SyncView` itself is no longer routed (its profile list duplicated the sidebar); W3-SYNC
/// redesigns this sheet and removes `SyncView`.
struct NewSyncProfileSheet: View {
    /// Called with the created profile after a successful create.
    var onCreated: (SyncProfile) -> Void = { _ in }

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    @State private var name = ""
    @State private var outputFolder = ""
    @State private var detectedDevices: [DeviceDetector.RockboxDevice] = []
    @State private var hasRunDetection = false
    @State private var applyDeviceDefaults = false
    @State private var isCreating = false
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Text("New Sync Profile")
                .font(.title3.weight(.semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)

            HStack {
                TextField("Destination folder", text: $outputFolder)
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    isChoosingFolder = true
                }
            }

            VStack(alignment: .leading, spacing: Spacing.s) {
                Button("Detect Device") {
                    detectedDevices = DeviceDetector.detectRockboxDevices()
                    hasRunDetection = true
                }

                if hasRunDetection {
                    if detectedDevices.isEmpty {
                        Text("No device found. Connect it and try again.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detectedDevices, id: \.mountPoint) { device in
                            Button {
                                choose(device)
                            } label: {
                                HStack {
                                    Image(systemName: "externaldrive")
                                    VStack(alignment: .leading) {
                                        Text(device.deviceName)
                                        Text(device.mountPoint)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if applyDeviceDefaults && outputFolder == device.mountPoint {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let error = container.syncViewModel?.errorMessage {
                Label {
                    Text(error)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                .font(.callout)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isCreating)

                Button("Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCreating)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 420)
        .onAppear {
            container.syncViewModel?.clearError()
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                outputFolder = url.path
            }
        }
        .fileDialogMessage("Choose the folder or device this profile copies music to.")
    }

    private func choose(_ device: DeviceDetector.RockboxDevice) {
        outputFolder = device.mountPoint
        if name.isEmpty {
            name = "\(device.deviceName) iPod"
        }
        applyDeviceDefaults = true
        statusBar?.post("Rockbox device detected — device defaults applied")
    }

    private func create() {
        guard let vm = container.syncViewModel else { return }
        let defaults = applyDeviceDefaults
        isCreating = true
        Task {
            await vm.createProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                outputFolder: outputFolder,
                generateM3U8: defaults,
                transcodeMode: defaults ? "aac_248" : "keep_originals",
                fat32SafePaths: true,
                cleanupRemovedFiles: true,
                artworkMode: defaults ? "resize_250" : "keep_original"
            )
            isCreating = false
            if vm.errorMessage == nil {
                NotificationCenter.default.post(name: .syncProfileDidChange, object: nil)
                if let created = vm.selectedProfile {
                    onCreated(created)
                }
                dismiss()
            }
        }
    }
}
