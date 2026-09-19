import SwiftUI

/// Sources view — grid of streaming service cards.
///
/// Phase 8/9/10 — Shows connection status for each source
/// (Spotify, SoundCloud, Apple Music) with connect/disconnect buttons
/// and sync controls.
///
/// Layout:
/// ```
/// ┌──────────────────────────────────────────────────────────────┐
/// │  Sources                                                     │
/// ├──────────────────────────────────────────────────────────────┤
/// │  ┌──────────────┐ ┌──────────────┐ ┌──────────────┐         │
/// │  │ 🟢 Spotify   │ │ 🟠 SoundCloud│ │ 🔴 Apple     │         │
/// │  │ Connected    │ │ Connected    │ │ Music        │         │
/// │  │ 234 tracks   │ │ 585 tracks   │ │ Not connected│         │
/// │  │ [Sync] [Disc]│ │ [Sync] [Disc]│ │ [Connect]    │         │
/// │  └──────────────┘ └──────────────┘ └──────────────┘         │
/// └──────────────────────────────────────────────────────────────┘
/// ```
struct SourcesView: View {
    @Environment(\.container) private var container
    @State private var viewModel: SourcesViewModel?

    var body: some View {
        // [navperf] temporary instrumentation — remove after measurement
        let _ = print("[navperf] section-body sources \(Date().timeIntervalSince1970)")
        Group {
            if let viewModel {
                sourcesContent(viewModel)
            } else {
                ProgressView("Loading sources…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.mlmBase)
            }
        }
        .task {
            // [navperf] temporary instrumentation — remove after measurement
            print("[navperf] section-task-start sources \(Date().timeIntervalSince1970)")
            initializeViewModel()
            await viewModel?.loadSources()
            // [navperf] temporary instrumentation — remove after measurement
            print("[navperf] section-task-after-first-await sources \(Date().timeIntervalSince1970)")
        }
    }

    // MARK: - Content

    private func sourcesContent(_ viewModel: SourcesViewModel) -> some View {
        VStack(spacing: 0) {
            headerBar

            Divider()
                .background(Color.mlmEdge)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 12, alignment: .top)],
                    alignment: .leading,
                    spacing: 12
                ) {
                    // SoundCloud (highest priority — 585 tracks)
                    SourceCard(
                        source: .soundcloud,
                        viewModel: viewModel
                    )

                    // Spotify
                    SourceCard(
                        source: .spotify,
                        viewModel: viewModel
                    )

                    // Apple Music
                    SourceCard(
                        source: .appleMusic,
                        viewModel: viewModel
                    )

                    // YouTube (URL-based playlist import — no auth needed)
                    YouTubePlaylistCard()
                }
                .padding(16)
            }
        }
        .background(Color.mlmBase)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Text("Sources")
                .font(MLMFont.pageTitle)
                .foregroundColor(.mlmInk)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Init

    private func initializeViewModel() {
        guard viewModel == nil,
              let tokenStorage = container.tokenStorage,
              let sourceRepo = container.sourceRepository else { return }
        viewModel = SourcesViewModel(
            tokenStorage: tokenStorage,
            sourceRepository: sourceRepo,
            oauthManager: container.oauthManager,
            trackRepository: container.trackRepository,
            playlistRepository: container.playlistRepository,
            tokenAccessStatus: container.tokenAccessStatus,
            tokenRefreshService: container.tokenRefreshService
        )
    }

}

// MARK: - Source Card

/// A card showing connection status and controls for a single streaming source.
struct SourceCard: View {
    let source: TokenStorage.Service
    let viewModel: SourcesViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + name + status dot
            HStack(spacing: 8) {
                sourceIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)

                    Text(statusText)
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                }

                Spacer()

                statusDot
                    .accessibilityIdentifier("source_card")
                    .accessibilityLabel("\(source.displayName): \(statusText)")
            }

            Divider()
                .background(Color.mlmEdge)

            // Track count + last sync
            if isConnected {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tracks")
                            .font(MLMFont.badge)
                            .foregroundColor(.mlmInkMuted)
                        Text("\(viewModel.trackCount(for: source))")
                            .font(MLMFont.data)
                            .foregroundColor(.mlmInk)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Last Sync")
                            .font(MLMFont.badge)
                            .foregroundColor(.mlmInkMuted)
                        Text(viewModel.lastSyncDisplay(for: source))
                            .font(MLMFont.muted)
                            .foregroundColor(.mlmInkSecondary)
                    }
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                if isConnected {
                    Button {
                        Task { await viewModel.syncSource(source) }
                    } label: {
                        HStack(spacing: 4) {
                            if viewModel.isSyncing(source) {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text("Sync")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(viewModel.isSyncing(source))

                    if viewModel.isTokenInaccessible(source) {
                        Button {
                            Task { await viewModel.reconnectSource(source) }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.uturn.backward")
                                Text("Reconnect")
                            }
                        }
                        .disabled(viewModel.isReconnecting(source))
                    }

                    Button(role: .destructive) {
                        Task { await viewModel.disconnectSource(source) }
                    } label: {
                        Text("Disconnect")
                    }
                } else {
                    let credsMissing = !viewModel.hasCredentials(for: source)
                    Button {
                        Task { await viewModel.connectSource(source) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "link")
                            Text("Connect")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(brandColor)
                    .disabled(credsMissing)

                    if credsMissing, let hint = viewModel.credentialHint(for: source) {
                        Text(hint)
                            .font(MLMFont.muted)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
            }

            // Error message
            if let error = viewModel.error(for: source) {
                Text(error)
                    .font(MLMFont.muted)
                    .foregroundColor(.mlmError)
                    .lineLimit(2)
            }

            // Token inaccessibility (keychain needs one explicit allow,
            // e.g. after a rebuild changed the app's code identity)
            if viewModel.isTokenInaccessible(source) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("\(source.displayName) token inaccessible — reconnect in Settings")
                        .lineLimit(2)
                    Spacer()
                }
                .font(MLMFont.muted)
                .foregroundColor(.mlmWarning)
            }

            // Playlist browser (SoundCloud & Spotify, when connected)
            if isConnected, let remoteSource = remotePlaylistSource {
                Button {
                    AppDelegate.shared?.showRemotePlaylistsWindow(source: remoteSource)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "music.note.list")
                        Text("Playlists")
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .frame(minHeight: 220, alignment: .top)
        .background(Color.mlmSurface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.mlmEdge, lineWidth: 1)
        )
    }

    // MARK: - Helpers

    /// Maps the token-storage service to the remote-playlist browser source.
    /// Apple Music has no playlist browsing here.
    private var remotePlaylistSource: RemotePlaylistSource? {
        switch source {
        case .soundcloud: return .soundcloud
        case .spotify: return .spotify
        case .appleMusic: return nil
        }
    }

    private var isConnected: Bool {
        viewModel.isConnected(source)
    }

    private var statusText: String {
        if viewModel.isSyncing(source) { return "Syncing…" }
        return isConnected ? "Connected" : "Not connected"
    }

    private var statusDot: some View {
        Circle()
            .fill(isConnected ? Color.mlmSuccess : Color.mlmInkMuted)
            .frame(width: 8, height: 8)
    }

    private var sourceIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 24))
            .foregroundColor(brandColor)
            .frame(width: 36, height: 36)
    }

    private var iconName: String {
        switch source {
        case .spotify: "music.note.list"
        case .soundcloud: "cloud.fill"
        case .appleMusic: "music.note"
        }
    }

    private var brandColor: Color {
        switch source {
        case .spotify: .mlmBrandSpotify
        case .soundcloud: .mlmBrandSoundCloud
        case .appleMusic: .mlmBrandAppleMusic
        }
    }
}

// MARK: - YouTube Playlist Card

/// A card for importing a YouTube playlist by URL — no OAuth required.
struct YouTubePlaylistCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.red)
                    .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text("YouTube")
                        .font(MLMFont.bodyBold)
                        .foregroundColor(.mlmInk)
                    Text("Import a playlist")
                        .font(MLMFont.muted)
                        .foregroundColor(.mlmInkSecondary)
                }
                Spacer()
            }

            Divider()
                .background(Color.mlmEdge)

            Text("Paste a playlist URL to download tracks.")
                .font(MLMFont.muted)
                .foregroundColor(.mlmInkSecondary)

            Spacer()

            Button {
                AppDelegate.shared?.showRemotePlaylistsWindow(source: .youtube)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "music.note.list")
                    Text("Import playlist...")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(minHeight: 220, alignment: .top)
        .background(Color.mlmSurface)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.mlmEdge, lineWidth: 1)
        )
    }
}
