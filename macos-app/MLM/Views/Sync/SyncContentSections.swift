import SwiftUI

/// Two DisclosureGroups showing profile content: Playlists (N) and Tracks (N).
///
/// Pattern: PlaylistDetailView.swift trackRow + hover-trash + contextMenu (line 251-307).
/// Data sourced from SyncViewModel.profilePlaylists / profileTracks (non-optional [] arrays
/// populated in Wave 1 / 38-02).
///
/// Both sections default to collapsed (D-07 / UI-SPEC Surface 5) to reduce
/// cognitive load on first profile view.
struct SyncContentSections: View {
    let profile: SyncProfile
    let vm: SyncViewModel

    @State private var playlistsExpanded: Bool = false
    @State private var tracksExpanded: Bool = false
    @State private var hoveredPlaylistId: Int64? = nil
    @State private var hoveredTrackId: Int64? = nil

    var body: some View {
        VStack(spacing: 0) {
            // Playlists section
            DisclosureGroup(isExpanded: $playlistsExpanded) {
                if vm.profilePlaylists.isEmpty {
                    Text("Keine Playlists — oben hinzufügen")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .padding(.vertical, 8)
                        .padding(.leading, 4)
                } else {
                    ForEach(vm.profilePlaylists) { playlist in
                        playlistRow(playlist)
                    }
                }
            } label: {
                HStack {
                    Text("Playlists (\(vm.profilePlaylists.count))")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)

            Divider().background(Color.mlmEdgeSubtle)

            // Tracks section
            DisclosureGroup(isExpanded: $tracksExpanded) {
                if vm.profileTracks.isEmpty {
                    Text("Keine Tracks — oben hinzufügen")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkMuted)
                        .padding(.vertical, 8)
                        .padding(.leading, 4)
                } else {
                    ForEach(vm.profileTracks) { track in
                        trackRow(track)
                    }
                }
            } label: {
                HStack {
                    Text("Tracks (\(vm.profileTracks.count))")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Playlist Row

    private func playlistRow(_ playlist: Playlist) -> some View {
        HStack(spacing: 8) {
            Text(playlist.name)
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .lineLimit(1)
            Spacer()
            if hoveredPlaylistId == playlist.id {
                Button {
                    Task { await vm.removePlaylists([playlist.id ?? -1]) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.mlmError)
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 8)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            hoveredPlaylistId == playlist.id
                ? Color.mlmSurface
                : Color.clear
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredPlaylistId = hovering ? playlist.id : nil
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await vm.removePlaylists([playlist.id ?? -1]) }
            } label: {
                Label("Aus Profil entfernen", systemImage: "minus.circle")
            }
        }
    }

    // MARK: - Track Row

    private func trackRow(_ track: Track) -> some View {
        HStack(spacing: 8) {
            Text("\(track.artist) — \(track.title)")
                .font(MLMFont.body)
                .foregroundColor(.mlmInk)
                .lineLimit(1)
            Spacer()
            if hoveredTrackId == track.id {
                Button {
                    Task { await vm.removeTracks([track.id ?? -1]) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundColor(.mlmError)
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .padding(.trailing, 8)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .background(
            hoveredTrackId == track.id
                ? Color.mlmSurface
                : Color.clear
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                hoveredTrackId = hovering ? track.id : nil
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task { await vm.removeTracks([track.id ?? -1]) }
            } label: {
                Label("Aus Profil entfernen", systemImage: "minus.circle")
            }
        }
    }
}
