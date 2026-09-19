import SwiftUI

/// A floating Liquid Glass universal search panel.
///
/// Design: Sketch C (Liquid Glass) — a translucent glass panel floats over
/// a dimmed backdrop, with a prominent search bar, source indicator,
/// artwork-rich results, and keyboard shortcut hints.
///
/// Triggered when the user pastes a URL in the toolbar search field
/// or presses ⌘K (future).
struct UniversalSearchView: View {
    @State private var viewModel = UniversalSearchViewModel()
    @FocusState private var searchFocused: Bool
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            // Dimmed backdrop
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture(perform: onDismiss)

            // Glass panel
            glassPanel
                .frame(width: 680)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.state)
        .onAppear { searchFocused = true }
        .onExitCommand(perform: onDismiss)
    }

    // MARK: - Glass Panel

    private var glassPanel: some View {
        VStack(spacing: 0) {
            searchBar
            Divider().overlay(Color.white.opacity(0.06))
            resultsBody
            footer
        }
        .glassBackground(cornerRadius: 20)
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))

            TextField("", text: $viewModel.query, prompt:
                Text("Paste a URL or search for music…")
                    .foregroundColor(.white.opacity(0.25))
            )
            .textFieldStyle(.plain)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white)
            .focused($searchFocused)
            .onSubmit { Task { await viewModel.submit(viewModel.query) } }

            sourceTag
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    @ViewBuilder
    private var sourceTag: some View {
        let (label, color) = sourceInfo
        if !label.isEmpty {
            HStack(spacing: 6) {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.white.opacity(0.1), lineWidth: 0.5)
            )
        }
    }

    private var sourceInfo: (String, Color) {
        let q = viewModel.query
        if q.contains("youtube.com") || q.contains("youtu.be") {
            if q.contains("playlist") || q.contains("list=") {
                return ("YouTube · Playlist", .red)
            }
            return ("YouTube · Video", .red)
        }
        if q.contains("soundcloud.com") {
            if q.contains("/sets/") {
                return ("SoundCloud · Playlist", .orange)
            }
            return ("SoundCloud", .orange)
        }
        if q.contains("open.spotify.com") {
            return ("Spotify", .green)
        }
        if q.hasPrefix("http") {
            return ("Web Page", .blue)
        }
        if !q.isEmpty {
            return ("Search", .white.opacity(0.3))
        }
        return ("", .clear)
    }

    // MARK: - Results Body

    @ViewBuilder
    private var resultsBody: some View {
        switch viewModel.state {
        case .idle:
            placeholderBody
        case .resolving:
            resolvingBody
        case .searching:
            searchingBody
        case .resolved(let result):
            resolvedBody(result)
        case .playlistPreview:
            playlistPreviewBody
        case .results:
            resultsListBody
        case .error(let msg):
            errorBody(msg)
        }
    }

    private var placeholderBody: some View {
        VStack(spacing: 12) {
            Image(systemName: "link")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.15))
            Text("Paste a YouTube, SoundCloud, or direct audio URL")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var resolvingBody: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Resolving…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var searchingBody: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Searching…")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private func resolvedBody(_ result: UniversalSearchResult) -> some View {
        VStack(spacing: 0) {
            sectionLabel("Detected")
            resultCard(
                title: result.title ?? "Unknown Track",
                subtitle: [result.artist, sourceLabel(result.source)].compactMap { $0 }.joined(separator: " · "),
                artworkURL: result.artworkURL,
                source: result.source,
                actionLabel: "Download",
                actionStyle: .primary
            )
        }
    }

    private var playlistPreviewBody: some View {
        VStack(spacing: 0) {
            sectionLabel("Playlist")
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.white.opacity(0.06))
                    .frame(width: 56, height: 56)
                    .overlay(
                        Image(systemName: "list.bullet")
                            .font(.system(size: 20, weight: .light))
                            .foregroundStyle(.white.opacity(0.3))
                    )
                VStack(alignment: .leading, spacing: 4) {
                    Text("Playlist detected")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(viewModel.query)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.35))
                        .lineLimit(1)
                }
                Spacer()
                Button("Import") { }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(16)
        }
    }

    private var resultsListBody: some View {
        VStack(spacing: 0) {
            sectionLabel("Results")
            Text("Text search results appear here")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.25))
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity)
        }
    }

    private func errorBody(_ msg: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.yellow.opacity(0.5))
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Result Card

    private enum CardActionStyle { case primary, secondary }

    private func resultCard(
        title: String,
        subtitle: String,
        artworkURL: String?,
        source: ArtworkResolver.Source,
        actionLabel: String,
        actionStyle: CardActionStyle
    ) -> some View {
        HStack(spacing: 14) {
            // Artwork
            artworkView(url: artworkURL, source: source)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }

            Spacer()

            // Action button
            if actionStyle == .primary {
                Button(actionLabel) { }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            } else {
                Button(actionLabel) { }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func artworkView(url: String?, source: ArtworkResolver.Source) -> some View {
        if let urlStr = url, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    sourcePlaceholder(source)
                default:
                    ProgressView().controlSize(.mini)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(.white.opacity(0.03))
                }
            }
        } else {
            sourcePlaceholder(source)
        }
    }

    private func sourcePlaceholder(_ source: ArtworkResolver.Source) -> some View {
        ZStack {
            LinearGradient(
                colors: [sourceColor(source).opacity(0.3), sourceColor(source).opacity(0.1)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: sourceIcon(source))
                .font(.system(size: 18, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                kbd("↵"); Text("to action")
                Text("·").foregroundStyle(.white.opacity(0.15))
                kbd("tab"); Text("to navigate")
                Text("·").foregroundStyle(.white.opacity(0.15))
                kbd("esc"); Text("to close")
            }
            Spacer()
            Text("⌘K to reopen")
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.2))
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
    }

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .textCase(.uppercase)
            .tracking(0.06)
            .foregroundStyle(.white.opacity(0.25))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func kbd(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
            )
    }

    private func sourceLabel(_ source: ArtworkResolver.Source) -> String {
        switch source {
        case .youtube: return "YouTube"
        case .soundcloud: return "SoundCloud"
        case .directAudio: return "Audio File"
        case .genericWeb: return "Web"
        }
    }

    private func sourceIcon(_ source: ArtworkResolver.Source) -> String {
        switch source {
        case .youtube: return "play.rectangle.fill"
        case .soundcloud: return "cloud.fill"
        case .directAudio: return "waveform"
        case .genericWeb: return "globe"
        }
    }

    private func sourceColor(_ source: ArtworkResolver.Source) -> Color {
        switch source {
        case .youtube: return .red
        case .soundcloud: return .orange
        case .directAudio: return .green
        case .genericWeb: return .blue
        }
    }
}

// MARK: - Glass Background Modifier

extension View {
    /// Applies a translucent material background.
    /// Uses `.regularMaterial` which provides the blur/translucency effect.
    /// TODO: Adopt `.glass` / Liquid Glass API when the macOS 27 SDK exposes it.
    @ViewBuilder
    func glassBackground(cornerRadius: CGFloat) -> some View {
        self
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
