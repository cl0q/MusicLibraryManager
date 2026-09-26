import SwiftUI

/// Playlists and Tracks card sections showing profile content.
///
/// Clicking anywhere on the header row expands or collapses the section.
/// Plus buttons are placed directly in the card headers to add items.
/// Trash bin buttons appear directly to the left of the item names on hover,
/// dynamically morphing/fading in place of their default music icons.
struct SyncContentSections: View {
    let profile: SyncProfile
    let vm: SyncViewModel

    /// Hint pointing users at the library context-menu path for adding
    /// individual tracks to a profile (replaces the old 12k-row picker sheet).
    static let trackAddHint: String =
        "Add individual tracks from the Library: right-click a track and choose Sync to ▸ your profile from the context menu."

    @State private var playlistsExpanded: Bool = false
    @State private var tracksExpanded: Bool = false
    @State private var hoveredPlaylistId: Int64? = nil
    @State private var hoveredTrackId: Int64? = nil

    @State private var showPlaylistPicker = false
    @State private var pendingRemoval: PendingRemoval?

    private enum PendingRemoval {
        case playlist(Playlist)
        case track(Track)

        var displayName: String {
            switch self {
            case .playlist(let playlist):
                playlist.name
            case .track(let track):
                "\(track.artist) — \(track.title)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            // 1. Playlists Card
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    // Header expand trigger (clickable everywhere)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            playlistsExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 14))
                                .foregroundColor(.mlmAccent)
                                .frame(width: 24, height: 24)
                                .background(Color.mlmAccent.opacity(0.1))
                                .cornerRadius(6)
                            
                            Text("Playlists (\(vm.profilePlaylists.count))")
                                .font(MLMFont.bodyBold)
                                .foregroundColor(.mlmInk)
                            
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                    // Direct Action Add Button
                    Button {
                        showPlaylistPicker = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.mlmAccent)
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.plain)
                    .help("Add playlists…")

                    // Expand Chevron
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            playlistsExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.mlmInkMuted)
                            .rotationEffect(.degrees(playlistsExpanded ? 90 : 0))
                            .padding(.leading, 8)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                
                if playlistsExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider().background(Color.mlmEdgeSubtle)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                        
                        if vm.profilePlaylists.isEmpty {
                            Text("No playlists — select the plus button to add playlists")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(vm.profilePlaylists) { playlist in
                                    playlistRow(playlist)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
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

            // 2. Tracks Card
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    // Header expand trigger (clickable everywhere)
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            tracksExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "music.note")
                                .font(.system(size: 14))
                                .foregroundColor(.mlmAccent)
                                .frame(width: 24, height: 24)
                                .background(Color.mlmAccent.opacity(0.1))
                                .cornerRadius(6)

                            Text("Tracks (\(vm.profileTracks.count))")
                                .font(MLMFont.bodyBold)
                                .foregroundColor(.mlmInk)

                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(SyncContentSections.trackAddHint)

                    // Expand Chevron
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            tracksExpanded.toggle()
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.mlmInkMuted)
                            .rotationEffect(.degrees(tracksExpanded ? 90 : 0))
                            .padding(.leading, 8)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                
                if tracksExpanded {
                    VStack(alignment: .leading, spacing: 6) {
                        Divider().background(Color.mlmEdgeSubtle)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 6)
                        
                        if vm.profileTracks.isEmpty {
                            Text("No tracks — \(SyncContentSections.trackAddHint)")
                                .font(MLMFont.muted)
                                .foregroundColor(.mlmInkMuted)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 16)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(vm.profileTracks) { track in
                                    trackRow(track)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
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
        }
        .sheet(isPresented: $showPlaylistPicker) {
            PlaylistPickerSheet(vm: vm)
        }
        .alert(
            "Remove from profile?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            presenting: pendingRemoval
        ) { removal in
            Button("Remove", role: .destructive) {
                pendingRemoval = nil
                Task {
                    switch removal {
                    case .playlist(let playlist):
                        await vm.removePlaylists([playlist.id ?? -1])
                    case .track(let track):
                        await vm.removeTracks([track.id ?? -1])
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRemoval = nil
            }
        } message: { removal in
            Text(
                "“\(removal.displayName)” will no longer sync to \(profile.name)'s destination. "
                    + "This does not delete the library original. If enabled, destination cleanup happens on the next sync."
            )
        }
    }

    // MARK: - Playlist Row

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if hoveredPlaylistId == playlist.id {
                    Button {
                        pendingRemoval = .playlist(playlist)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.mlmError)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "music.note.list")
                        .foregroundColor(.mlmInkMuted)
                        .font(.system(size: 12))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 20, height: 20)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: hoveredPlaylistId)
            
            Text(playlist.name)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            hoveredPlaylistId == playlist.id
                ? Color.mlmBase.opacity(0.5)
                : Color.clear
        )
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                hoveredPlaylistId = hovering ? playlist.id : nil
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                pendingRemoval = .playlist(playlist)
            } label: {
                Label("Remove from profile", systemImage: "minus.circle")
            }
        }
    }

    // MARK: - Track Row

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 10) {
            ZStack {
                if hoveredTrackId == track.id {
                    Button {
                        pendingRemoval = .track(track)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundColor(.mlmError)
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: "music.note")
                        .foregroundColor(.mlmInkMuted)
                        .font(.system(size: 12))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 20, height: 20)
            .animation(.spring(response: 0.2, dampingFraction: 0.8), value: hoveredTrackId)
            
            Text("\(track.artist) — \(track.title)")
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .lineLimit(1)
            
            Spacer()
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
        .background(
            hoveredTrackId == track.id
                ? Color.mlmBase.opacity(0.5)
                : Color.clear
        )
        .cornerRadius(6)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                hoveredTrackId = hovering ? track.id : nil
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                pendingRemoval = .track(track)
            } label: {
                Label("Remove from profile", systemImage: "minus.circle")
            }
        }
    }
}
