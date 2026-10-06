import Observation
import SwiftUI

// MARK: - S-PLD-LINK: Link “‹playlist›” to a Source

/// The check behind the Link sheet: reads the pasted playlist link without writing anything
/// and compares it with the playlist (the existing link-diff engine). A mismatch is a result
/// in the sheet, not a second alert (A-PLD-LINKMISMATCH merged).
@MainActor
@Observable
final class PlaylistLinkModel {
    enum Phase: Equatable {
        case idle
        case checking
        /// `‹title›` on ‹Source› · ‹n› tracks, same tracks or the difference.
        case checked(title: String, source: String, trackCount: Int, diff: PlaylistLinkDiff)
        case notAPlaylist
        case signInExpired(source: String)
        case failed(String)

        var canLink: Bool {
            if case .checked = self { return true }
            return false
        }
    }

    var url: String {
        didSet { if url != oldValue { phase = .idle; pending = nil } }
    }
    private(set) var phase: Phase = .idle
    @ObservationIgnored private var pending: (preview: RemotePlaylistPreview, provider: any RemotePlaylistProvider)?
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    let playlist: Playlist

    init(playlist: Playlist) {
        self.playlist = playlist
        let external = playlist.externalId ?? ""
        url = external.hasPrefix("http://") || external.hasPrefix("https://") ? external : ""
    }

    /// The result's second sentence (`playlists.html` S-PLD-LINK).
    static func diffText(_ diff: PlaylistLinkDiff, source: String) -> String {
        guard diff.hasDifferences else { return "Same tracks as this playlist." }
        var parts: [String] = []
        if diff.remoteOnly > 0 {
            parts.append("\(StatusBarText.count(diff.remoteOnly, "track is", "tracks are")) only on \(source) — they are added the next time you choose Refresh from \(source).")
        }
        if diff.localOnly > 0 {
            parts.append("\(StatusBarText.count(diff.localOnly, "track is", "tracks are")) only in this playlist — they stay.")
        }
        return (parts + ["Nothing changes now."]).joined(separator: " ")
    }

    func check(container: DependencyContainer) {
        checkTask?.cancel()
        phase = .checking
        let text = url.trimmingCharacters(in: .whitespacesAndNewlines)
        checkTask = Task { await run(text, container: container) }
    }

    func cancel() {
        checkTask?.cancel()
        checkTask = nil
        if phase == .checking { phase = .idle }
    }

    private func run(_ text: String, container: DependencyContainer) async {
        guard let tracks = container.trackRepository, let sources = container.sourceRepository,
              let playlists = container.playlistRepository, !text.isEmpty else {
            phase = .notAPlaylist
            return
        }
        let provider: any RemotePlaylistProvider
        let sourceName: String
        switch URLDetector.classify(text) {
        case .youtubePlaylist:
            sourceName = "YouTube"
            provider = YouTubePlaylistProvider(downloader: YouTubeDownloader(), trackRepository: tracks,
                                               sourceRepository: sources, playlistRepository: playlists)
        case .soundcloudPlaylist:
            sourceName = "SoundCloud"
            guard let tokenStorage = container.tokenStorage, let oauth = container.oauthManager,
                  container.tokenAccessStatus?.inaccessibleServices.contains(.soundcloud) != true else {
                phase = .signInExpired(source: sourceName)
                return
            }
            let client = SoundCloudClient(tokenStorage: tokenStorage, oauthManager: oauth, trackRepository: tracks,
                                          sourceRepository: sources, playlistRepository: playlists)
            provider = SoundCloudPlaylistProvider(client: client, trackRepository: tracks, sourceRepository: sources,
                                                  playlistRepository: playlists)
        default:
            phase = .notAPlaylist
            return
        }
        let preview: RemotePlaylistPreview
        do {
            preview = try await provider.fetchPreview(fromURL: URLDetector.normalize(text))
        } catch RemotePlaylistProviderError.notAPlaylistURL {
            phase = .notAPlaylist
            return
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed((error as? PlainCauseError)?.plainCause ?? error.localizedDescription)
            return
        }
        guard !Task.isCancelled, let playlistID = playlist.id else { return }
        let local = (try? await playlists.fetchTracks(playlistId: playlistID)) ?? []
        let externalIDs = (try? await sources.fetchExternalIDs(trackIds: Set(local.compactMap(\.id)))) ?? [:]
        let diff = PlaylistLinkDiffComputer.compute(
            remote: preview.tracks.map { PlaylistDifferRemoteEntry(externalID: $0.externalID, title: $0.title, artist: $0.artist, originalPath: $0.originalPath) },
            local: local.map { PlaylistDifferLocalTrack(id: $0.id ?? -1, title: $0.title, artist: $0.artist, originalPath: $0.originalPath,
                                                        externalIDs: externalIDs[$0.id ?? -1] ?? []) }
        )
        pending = (preview, provider)
        phase = .checked(title: preview.title, source: sourceName, trackCount: preview.tracks.count, diff: diff)
    }

    /// The link to write (`source_id`, `external_id`) for the checked playlist.
    func pendingLink() async throws -> (PlaylistSourceLink, String) {
        guard let pending, case .checked(_, let source, _, _) = phase else { throw RemotePlaylistProviderError.previewUnavailable }
        let row = try await pending.provider.sourceRowForLinking()
        return (PlaylistSourceLink(sourceID: row.id, externalID: pending.preview.externalID), source)
    }
}

/// S-PLD-LINK: one sheet for the whole task — paste, Check, read the result inline, `Link
/// Playlist`. Linking adds and removes no track; success is a status-bar line with Undo
/// (A-PLD-LINKDONE merged). Cancel works while checking (UC-SHEET-04).
struct PlaylistLinkSheet: View {
    @State var model: PlaylistLinkModel

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @Environment(ShellActions.self) private var shell: ShellActions?
    @State private var linkError: String?
    @State private var isLinking = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            Text("Link “\(model.playlist.name)” to a Source")
                .font(.headline)
            Text("Paste the link of a SoundCloud or YouTube playlist. Linking doesn’t add or remove any track now. It tells MLM where Refresh from ‹Source› looks for new tracks.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("Playlist link", text: $model.url, prompt: Text("https://soundcloud.com/…/sets/…  ·  https://youtube.com/playlist?list=…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.check(container: container) }
                Button("Check") { model.check(container: container) }
                    .disabled(model.url.trimmingCharacters(in: .whitespaces).isEmpty || model.phase == .checking)
            }
            result
                .frame(minHeight: 44, alignment: .topLeading)
            if let linkError {
                Text(linkError).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    model.cancel()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Link Playlist") { link() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.phase.canLink || isLinking)
            }
        }
        .padding(Spacing.xl)
        .frame(width: 520)
    }

    @ViewBuilder
    private var result: some View {
        switch model.phase {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("Checking link…")
            }
        case .checked(let title, let source, let count, let diff):
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    SourceBrandDot(source: source)
                    Text("“\(title)”").fontWeight(.semibold)
                    Text("on \(source) · \(StatusBarText.tracks(count))").foregroundStyle(.secondary)
                }
                Text(PlaylistLinkModel.diffText(diff, source: source))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .notAPlaylist:
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Label("This isn’t a playlist link.", systemImage: "exclamationmark.triangle")
                Text("Use the link of a playlist or set.")
                    .foregroundStyle(.secondary)
            }
        case .signInExpired(let source):
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Label {
                    Text("\(source) sign-in expired")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                HStack(spacing: Spacing.xxs) {
                    Text("MLM can’t read this playlist until you sign in again.").foregroundStyle(.secondary)
                    Button("Reconnect") { openSettings(tab: .sources) }.buttonStyle(.link)
                }
            }
        case .failed(let cause):
            Label("Couldn’t check the link — \(cause).", systemImage: "exclamationmark.triangle")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func link() {
        guard let id = model.playlist.id, let edits = shell?.edits else { return }
        isLinking = true
        linkError = nil
        Task {
            defer { isLinking = false }
            do {
                let (link, source) = try await model.pendingLink()
                try await edits.linkPlaylist(id, name: model.playlist.name, to: link, sourceName: source)
                dismiss()
            } catch {
                linkError = UndoFailure.sentence("Couldn’t link “\(model.playlist.name)”", error) + "."
            }
        }
    }
}
