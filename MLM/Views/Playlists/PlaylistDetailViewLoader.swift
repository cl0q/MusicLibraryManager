import SwiftUI

/// The playlist page by id — a sidebar row (`SidebarDestination.playlist`), a card
/// (`DetailRoute.playlist`, pushed) or the import window's `Open playlist`. Fetches the row
/// fresh, then shows `PlaylistDetailView` in its own content scaffold (the header slot is
/// the page's, UC-LAYOUT-06). States: loading (the real header frame with `Loading…` and
/// disabled Play / Shuffle, V-PLD.E29), not found (V-PLD.N03), error.
struct PlaylistDetailViewLoader: View {
    let playlistId: Int64
    /// Open in the `Download failed` scope (Show Failed Downloads).
    var initiallyShowFailedTracks = false
    let onBack: () -> Void
    let onTrackDoubleClick: ((Track, [Track]) -> Void)?

    @Environment(\.container) private var container

    private enum Phase: Equatable {
        case loading
        case loaded(Playlist)
        case notFound
        case failed
    }

    @State private var phase = Phase.loading

    var body: some View {
        Group {
            switch phase {
            case .loaded(let playlist):
                PlaylistDetailView(
                    playlist: playlist,
                    initiallyShowFailedTracks: initiallyShowFailedTracks,
                    onBack: onBack,
                    onTrackDoubleClick: onTrackDoubleClick
                )
            case .loading:
                ContentScaffold(showsDriveBanner: true) {
                    Color.clear
                } header: {
                    loadingHeader
                }
                .modifier(WindowTitleModifier())
            case .notFound:
                ContentScaffold(showsDriveBanner: false) {
                    PlaylistNotFoundView()
                }
                .modifier(WindowTitleModifier())
            case .failed:
                ContentScaffold(showsDriveBanner: false) {
                    ContentUnavailableView {
                        Label("Can’t load the playlist", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text("The library database didn’t answer. Your playlists and your music are not affected.")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                        Button("Show Logs") { ActivityRouter.shared.showLogs(for: nil) }
                    }
                }
                .modifier(WindowTitleModifier())
            }
        }
        .task(id: playlistId) { await load() }
        // Deleted elsewhere while open (its creation undone): the not-found page, not a stale one.
        .onReceive(NotificationCenter.default.publisher(for: .playlistDidChange)) { note in
            guard note.userInfo?["coverRevalidation"] == nil, (note.userInfo?["origin"] as? String) != "coverService",
                  (note.userInfo?["playlistId"] as? Int64).map({ $0 == playlistId }) ?? true else { return }
            Task { await recheck() }
        }
    }

    private var loadingHeader: some View {
        HStack(alignment: .bottom, spacing: Spacing.l) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.quaternary)
                .frame(width: 160, height: 160)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Playlist").font(.subheadline).foregroundStyle(.secondary)
                Text("Loading…").font(.title.bold()).foregroundStyle(.tertiary)
                HStack {
                    Button("Play") {}.buttonStyle(.borderedProminent).disabled(true)
                    Button("Shuffle") {}.disabled(true)
                }
                .padding(.top, Spacing.s)
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.l)
    }

    private func load() async {
        guard let repository = container.playlistRepository else {
            phase = .failed
            return
        }
        do {
            phase = try await repository.fetch(id: playlistId).map(Phase.loaded) ?? .notFound
        } catch {
            phase = .failed
        }
    }

    /// Only the gone case matters here; the page itself reloads its rows.
    private func recheck() async {
        guard case .loaded = phase, let repository = container.playlistRepository else { return }
        do {
            if try await repository.fetch(id: playlistId) == nil { phase = .notFound }
        } catch {
            // A read error is not "deleted": the page keeps what it shows.
        }
    }
}
