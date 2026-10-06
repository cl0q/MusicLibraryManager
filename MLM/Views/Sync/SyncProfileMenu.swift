import AppKit
import SwiftUI

/// The sheets and the delete alert of sync profiles, shared by the sidebar rows and the profile
/// pages (one host: `SyncProfileSheets`, attached to the sidebar).
@Observable
final class SyncPresenter {
    enum AddKind: String, Identifiable {
        case playlists, tracks
        var id: String { rawValue }
    }

    struct AddRequest: Identifiable {
        let profile: SyncProfile
        let kind: AddKind
        var id: String { "\(profile.id ?? 0)-\(kind.rawValue)" }
    }

    /// A-SYNC-DELETEPROFILE.
    var deleting: SyncProfile?
    /// S-SYNC-DESTINATION.
    var changingDestination: SyncProfile?
    /// S-SYNC-INGESTPREVIEW (Read Playlist Changes from Device…).
    var readingChanges: DevicePlaylistChangesModel?
    /// S-SYNC-PLAYLISTPICKER / the track picker.
    var adding: AddRequest?
    /// Inline rename of a profile's sidebar row (S-SYNC-RENAME → UC-SIDE-09).
    var renameRequest: Int64?
}

// MARK: - CM-SYNC-PROFILE / V-SYNC-DETAIL.N10 (one builder, UC-CM-02)

/// The sync profile menu: the sidebar row's context menu and the page's `More` (which omits
/// Open and the run controls the header shows as buttons). Groups in the UC-CM-01 order:
/// Primary · Info/edit · Locate · Remove. Items that can't apply are left out — except Sync Now
/// while the library drive is away, which stays disabled under its header line (UC-CM-05).
struct SyncProfileMenu: View {
    enum Place { case contextMenu, more }

    let profile: SyncProfile
    let place: Place

    @Environment(\.container) private var container
    @Environment(NavigationModel.self) private var navigation: NavigationModel?

    var body: some View {
        if let vm = container.syncViewModel, let id = profile.id {
            let state = vm.state(for: profile)
            let run = vm.run(for: profile)
            let connected = vm.destinations[id] == .connected
            let deviceName = SyncDestination.deviceName(for: profile.outputFolder)

            if place == .contextMenu {
                Section {
                    Button("Open") { navigation?.select(.syncProfile(id)) }
                    if let run {
                        if run.phase == .running { Button("Pause") { vm.pause(profile) } }
                        if run.phase == .paused { Button("Resume") { vm.resume(profile) } }
                        Button("Cancel") { vm.cancel(profile) }
                    } else if state.page == .libraryDriveAway, let drive = vm.libraryDrive().volumeName {
                        Section("“\(drive)” is not connected") {
                            Button("Sync Now") {}
                                .disabled(true)
                                .help(state.syncNowDisabledReason ?? "")
                        }
                    } else if state.canSyncNow {
                        Button("Sync Now") { vm.syncNow(profile) }
                    }
                }
            }

            Section {
                Button("Rename") { vm.presenter.renameRequest = id }
                Button("Duplicate") { Task { await vm.edits().duplicateSyncProfile(id, name: profile.name) } }
                Button("Change Destination…") { vm.presenter.changingDestination = profile }
                if connected {
                    Button("Read Playlist Changes from Device…") { readChanges(vm) }
                    let recompute = Button("Recompute Plan") { vm.recomputePlan(id) }
                    if place == .contextMenu {
                        recompute.keyboardShortcut("r", modifiers: .command)
                    } else {
                        recompute
                    }
                }
            }

            if connected || vm.canEject(profile) {
                Section {
                    if connected {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: profile.outputFolder)])
                        }
                    }
                    if vm.canEject(profile) {
                        Button("Eject “\(deviceName)”") { Task { await vm.eject(profile) } }
                    }
                }
            }

            Section {
                Button("Delete Sync Profile…", role: .destructive) { vm.presenter.deleting = profile }
            }
        }
    }

    private func readChanges(_ vm: SyncViewModel) {
        let model = DevicePlaylistChangesModel(profile: profile, service: vm.deviceChangeService())
        vm.presenter.readingChanges = model
        model.scan()
    }
}

// MARK: - Sheet host

/// Hosts the sync profile sheets and the delete alert once per window.
struct SyncProfileSheets: ViewModifier {
    @Environment(\.container) private var container

    func body(content: Content) -> some View {
        if let vm = container.syncViewModel {
            @Bindable var presenter = vm.presenter
            content
                // A-SYNC-DELETEPROFILE: not undoable, so confirmed (UC-UNDO-03). Cancel is the default.
                .alert(
                    "Delete the sync profile “\(presenter.deleting?.name ?? "")”?",
                    isPresented: Binding(get: { presenter.deleting != nil },
                                         set: { if !$0 { presenter.deleting = nil } }),
                    presenting: presenter.deleting
                ) { profile in
                    Button("Delete Sync Profile", role: .destructive) {
                        presenter.deleting = nil
                        Task { await vm.deleteProfile(profile) }
                    }
                    Button("Cancel", role: .cancel) { presenter.deleting = nil }
                        .keyboardShortcut(.defaultAction)
                } message: { profile in
                    Text(Self.deleteMessage(isSyncing: vm.run(for: profile) != nil))
                }
                .sheet(item: $presenter.changingDestination) { profile in
                    ChangeDestinationSheet(profile: profile)
                }
                .sheet(item: $presenter.adding) { request in
                    SyncAddContentSheet(profile: request.profile, initialKind: request.kind)
                }
                .sheet(item: $presenter.readingChanges) { model in
                    DeviceChangesSheet(model: model)
                }
        } else {
            content
        }
    }

    /// The consequence (UC-SHEET-13); a running sync is listed, not asked about.
    static func deleteMessage(isSyncing: Bool) -> String {
        let base = "The profile, its plan and its sync history are removed. Music on the device and in your library is not touched."
        return isSyncing ? base + " The running sync will be cancelled." : base
    }
}

extension DevicePlaylistChangesModel: Identifiable {
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension View {
    /// The sync profile sheets and alert (W3-SYNC).
    func syncProfileSheets() -> some View {
        modifier(SyncProfileSheets())
    }
}
