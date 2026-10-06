import SwiftUI
import UniformTypeIdentifiers

/// S-SYNC-NEWPROFILE: one sheet for the Sync section ＋, File ▸ New Sync Profile… and
/// Add to Sync Profile ▸ New Sync Profile… (with the selection: `Create and Add ‹n› Tracks`).
/// Detected devices are listed at once; choosing one fills the destination, the name and the
/// preset, and the preset says what it sets before anything applies (replaces the toast,
/// S-SYNC-TOAST). A destination is required; errors stay in the sheet (UC-SHEET-05).
struct NewSyncProfileSheet: View {
    /// Tracks to add as the first content (from a selection; nothing navigates then).
    var trackIDs: [Int64] = []
    /// Called with the created profile (the ＋ opens its page).
    var onCreated: (SyncProfile) -> Void = { _ in }

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(StatusBarCenter.self) private var statusBar: StatusBarCenter?

    @State private var name = ""
    @State private var destination = ""
    @State private var preset: SyncDevicePreset = .plainFolder
    @State private var devices: [DeviceDetector.RockboxDevice] = []
    @State private var isCreating = false
    @State private var isChoosingFolder = false
    @State private var isDropTargeted = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool { !trimmedName.isEmpty && !destination.isEmpty && !isCreating }
    private var libraryVolume: String? { container.mountObserver?.libraryVolumePath }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("iPod Classic"))
                }
                Section("Destination") {
                    ForEach(devices, id: \.mountPoint) { device in
                        deviceRow(device)
                    }
                    LabeledContent {
                        Button("Choose…") { isChoosingFolder = true }
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(destination.isEmpty ? "No destination chosen" : destination)
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                                    .monospaced(!destination.isEmpty)
                                Text("Any folder on this Mac or on a connected disk. You can also drop a folder or a disk here.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                }
                Section("Device preset") {
                    Picker("Preset", selection: $preset) {
                        ForEach(SyncDevicePreset.allCases) { Text($0.title).tag($0) }
                    }
                    Text(preset.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("Every option can be changed later on the profile.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let error = container.syncViewModel?.errorMessage {
                    Section {
                        Text(error)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Text("The profile appears in the sidebar under Sync.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(trackIDs.isEmpty ? "Create" : "Create and Add \(StatusBarText.tracks(trackIDs.count).capitalizedTracks)") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
            .padding(Spacing.l)
        }
        .frame(width: 480)
        .navigationTitle("New Sync Profile")
        .onAppear {
            container.syncViewModel?.clearError()
            // Removable volumes connected now; Rockbox players are recognised. The library's own
            // disk is never offered as a destination.
            devices = DeviceDetector.detectRockboxDevices().filter { $0.mountPoint != libraryVolume }
        }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { useFolder(url) }
        }
        .fileDialogMessage("Choose the folder or disk to sync to.")
        // D-SYNC-FOLDER-TO-OUTPUT: a folder or disk dropped anywhere on the sheet.
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.hasDirectoryPath || (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            useFolder(url)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private func deviceRow(_ device: DeviceDetector.RockboxDevice) -> some View {
        Button {
            destination = device.mountPoint
            if name.isEmpty { name = device.deviceName }
            preset = .rockbox
        } label: {
            HStack {
                Image(systemName: destination == device.mountPoint ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(destination == device.mountPoint ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Image(systemName: "externaldrive")
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.deviceName)
                    Text("Rockbox player · \(device.mountPoint) · \(device.availableSpace.formatted(.byteCount(style: .file))) free")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(device.deviceName), Rockbox player")
    }

    private func useFolder(_ url: URL) {
        destination = url.path
        if name.isEmpty { name = SyncDestination.deviceName(for: url.path) }
    }

    private func create() {
        guard let vm = container.syncViewModel, canCreate else { return }
        isCreating = true
        let chosenPreset = preset
        let detected = devices.contains { $0.mountPoint == destination }
        Task {
            let created = await vm.createProfile(name: trimmedName, outputFolder: destination, preset: chosenPreset,
                                                 trackIDs: trackIDs)
            isCreating = false
            guard let created else { return }
            if chosenPreset == .rockbox && detected {
                statusBar?.post("Rockbox device detected — device defaults applied")  // IMP-008
            } else if !trackIDs.isEmpty {
                statusBar?.post("Created “\(created.name)” with \(StatusBarText.tracks(trackIDs.count))")
            } else {
                statusBar?.post("Created the sync profile “\(created.name)” — add playlists or tracks")
            }
            if trackIDs.isEmpty { onCreated(created) }
            dismiss()
        }
    }
}

private extension String {
    /// `3 tracks` → `3 Tracks` (button Title Case, UC-COPY-02).
    var capitalizedTracks: String {
        replacingOccurrences(of: " tracks", with: " Tracks").replacingOccurrences(of: " track", with: " Track")
    }
}
