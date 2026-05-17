import SwiftUI

/// Collapsible settings form for a sync profile (D-02 / SYNC-v2-04).
///
/// GREENFIELD — no existing Form+Toggle+Picker pattern in MLM (per PATTERNS.md).
/// Wraps four toggles and one transcode-mode picker in a DisclosureGroup
/// that defaults to collapsed to reduce cognitive load on first view.
///
/// Each toggle/picker onChange commits immediately to the DB via
/// `vm.updateProfileSettings(...)` using local mirrors to provide
/// responsive feedback before the async write completes.
struct SyncSettingsForm: View {
    let profile: SyncProfile
    let vm: SyncViewModel

    @State private var isExpanded: Bool = false

    // Local mirrors for responsive feedback before async DB commit
    @State private var localM3U8: Bool
    @State private var localTranscodeMode: String
    @State private var localFat32: Bool
    @State private var localCleanup: Bool

    init(profile: SyncProfile, vm: SyncViewModel) {
        self.profile = profile
        self.vm = vm
        _localM3U8 = State(initialValue: profile.generateM3U8)
        _localTranscodeMode = State(initialValue: profile.transcodeMode)
        _localFat32 = State(initialValue: profile.fat32SafePaths)
        _localCleanup = State(initialValue: profile.cleanupRemovedFiles)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            Form {
                // Field 1: Generate M3U8 playlists (Rockbox/device use)
                Toggle("M3U8-Playlisten generieren", isOn: $localM3U8)
                    .onChange(of: localM3U8) { _, newValue in
                        Task { await vm.updateProfileSettings(generateM3U8: newValue) }
                    }

                // Field 2: Transcode mode
                Picker("Transcode-Modus", selection: $localTranscodeMode) {
                    Text("Originals behalten").tag("keep_originals")
                    Text("248 kbps AAC").tag("aac_248")
                    Text("320 kbps AAC").tag("aac_320")
                }
                .onChange(of: localTranscodeMode) { _, newValue in
                    Task { await vm.updateProfileSettings(transcodeMode: newValue) }
                }

                // Field 3: FAT32-safe filenames
                Toggle("FAT32-sichere Dateinamen", isOn: $localFat32)
                    .onChange(of: localFat32) { _, newValue in
                        Task { await vm.updateProfileSettings(fat32SafePaths: newValue) }
                    }

                // Field 4: Cleanup removed files from destination
                Toggle("Gelöschte Dateien vom Ziel entfernen", isOn: $localCleanup)
                    .onChange(of: localCleanup) { _, newValue in
                        Task { await vm.updateProfileSettings(cleanupRemovedFiles: newValue) }
                    }
            }
            .formStyle(.grouped)
            .padding(.vertical, 8)
        } label: {
            Text("Einstellungen")
                .font(MLMFont.sectionLabel)
                .foregroundColor(.mlmInkMuted)
        }
        .padding(.horizontal, 16)
        .background(Color.mlmSurface)
        // Re-sync local mirrors when profile identity changes (e.g., after VM reloads from DB)
        .onChange(of: profile.id) { _, _ in
            localM3U8 = profile.generateM3U8
            localTranscodeMode = profile.transcodeMode
            localFat32 = profile.fat32SafePaths
            localCleanup = profile.cleanupRemovedFiles
        }
    }
}
