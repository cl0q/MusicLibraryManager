import SwiftUI

/// Collapsible settings form for a sync profile.
///
/// Features custom icons, segmented controls, descriptions, rotating animated chevrons,
/// and full row clickability to expand/collapse. Commits changes instantly to the DB via
/// SyncViewModel.updateProfileSettings.
struct SyncSettingsForm: View {
    let profile: SyncProfile
    let vm: SyncViewModel

    @State private var isExpanded: Bool = false

    // Local mirrors for responsive feedback before async DB commit
    @State private var localM3U8: Bool
    @State private var localTranscodeMode: String
    @State private var localFat32: Bool
    @State private var localCleanup: Bool
    @State private var localPlaylistFormat: String

    init(profile: SyncProfile, vm: SyncViewModel) {
        self.profile = profile
        self.vm = vm
        _localM3U8 = State(initialValue: profile.generateM3U8)
        _localTranscodeMode = State(initialValue: profile.transcodeMode)
        _localFat32 = State(initialValue: profile.fat32SafePaths)
        _localCleanup = State(initialValue: profile.cleanupRemovedFiles)
        _localPlaylistFormat = State(initialValue: profile.playlistFormat)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Button - clickable everywhere
            Button {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.mlmAccent)
                        .frame(width: 24, height: 24)
                        .background(Color.mlmAccent.opacity(0.1))
                        .cornerRadius(6)
                    
                    Text("Einstellungen")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                    
                    Spacer()
                    
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.mlmInkMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if isExpanded {
                VStack(spacing: 12) {
                    Divider().background(Color.mlmEdgeSubtle)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)

                    VStack(spacing: 16) {
                        settingRow(
                            icon: "music.note.list",
                            title: "Wiedergabelisten",
                            description: "Erstellt Wiedergabelistendateien für Rockbox oder Doppi",
                            content: Toggle("", isOn: $localM3U8)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        )
                        .onChange(of: localM3U8) { _, newValue in
                            Task { await vm.updateProfileSettings(generateM3U8: newValue) }
                        }

                        if localM3U8 {
                            settingRow(
                                icon: "doc.plaintext",
                                title: "Format & App",
                                description: "Wähle das passende App-Profil (.m3u/.m3u8) als Ziel",
                                content: Picker("", selection: $localPlaylistFormat) {
                                    Text("Rockbox").tag("rockbox")
                                    Text("Doppi").tag("doppi")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 220)
                                .labelsHidden()
                            )
                            .padding(.leading, 16)
                            .onChange(of: localPlaylistFormat) { _, newValue in
                                Task { await vm.updateProfileSettings(playlistFormat: newValue) }
                            }
                        }

                        Divider().background(Color.mlmEdgeSubtle)

                        settingRow(
                            icon: "arrow.triangle.2.circlepath",
                            title: "Transcode-Modus",
                            description: "Lieder beim Kopieren konvertieren (AAC)",
                            content: Picker("", selection: $localTranscodeMode) {
                                Text("Originals").tag("keep_originals")
                                Text("248k AAC").tag("aac_248")
                                Text("320k AAC").tag("aac_320")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                            .labelsHidden()
                        )
                        .onChange(of: localTranscodeMode) { _, newValue in
                            Task { await vm.updateProfileSettings(transcodeMode: newValue) }
                        }

                        Divider().background(Color.mlmEdgeSubtle)

                        settingRow(
                            icon: "folder.badge.gearshape",
                            title: "Kompatible Pfade",
                            description: "Bereinigt Sonderzeichen im Dateipfad für FAT32/SD-Karten",
                            content: Toggle("", isOn: $localFat32)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        )
                        .onChange(of: localFat32) { _, newValue in
                            Task { await vm.updateProfileSettings(fat32SafePaths: newValue) }
                        }

                        Divider().background(Color.mlmEdgeSubtle)

                        settingRow(
                            icon: "trash",
                            title: "Aufräumen",
                            description: "Entfernt gelöschte Lieder automatisch vom Zielordner",
                            content: Toggle("", isOn: $localCleanup)
                                .toggleStyle(.switch)
                                .labelsHidden()
                        )
                        .onChange(of: localCleanup) { _, newValue in
                            Task { await vm.updateProfileSettings(cleanupRemovedFiles: newValue) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color.mlmSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.mlmEdgeSubtle, lineWidth: 1)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .onChange(of: profile.id) { _, _ in
            localM3U8 = profile.generateM3U8
            localTranscodeMode = profile.transcodeMode
            localFat32 = profile.fat32SafePaths
            localCleanup = profile.cleanupRemovedFiles
            localPlaylistFormat = profile.playlistFormat
        }
    }

    private func settingRow(icon: String, title: String, description: String, content: some View) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.mlmAccent)
                .frame(width: 28, height: 28)
                .background(Color.mlmAccent.opacity(0.1))
                .cornerRadius(8)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(MLMFont.bodyBold)
                    .foregroundColor(.mlmInk)
                Text(description)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmInkMuted)
                    .lineLimit(2)
            }

            Spacer()

            content
        }
    }
}
