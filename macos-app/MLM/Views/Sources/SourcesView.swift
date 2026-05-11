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
            initializeViewModel()
            await viewModel?.loadSources()
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
            trackRepository: container.trackRepository
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
        case .spotify: .mlmSpotify
        case .soundcloud: .mlmSoundCloud
        case .appleMusic: .mlmAppleMusic
        }
    }
}
