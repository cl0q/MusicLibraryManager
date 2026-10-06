import AppKit
import SwiftUI

// MARK: - S-QUICKADD (DEC-018, import.html, UC-SHEET-01…07)

/// `Add from Link` — one link, what it is, one primary action (`Download` · `Show in Library`
/// · `Import…`). Cancel on Esc; errors inline above the buttons. A download closes the sheet;
/// its progress is in Activity and the status bar marks the start.
struct QuickAddSheet: View {
    @Bindable var model: QuickAddModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add from Link")
                .font(.headline)
                .padding([.horizontal, .top], 20)
            Form {
                Section {
                    HStack {
                        TextField("Link", text: $model.urlText, prompt: Text(QuickAddModel.placeholder))
                            .labelsHidden()
                            .onSubmit { model.detectNow() }
                        Button("Paste") {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                model.urlText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            }
                        }
                    }
                    detected
                }
                if showsPlaylistPicker {
                    Section {
                        Picker("Add to playlist", selection: $model.playlistID) {
                            Text("None").tag(Int64?.none)
                            ForEach(TrackMenuSources.shared.playlists.filter { $0.isLiked == 0 }, id: \.id) { playlist in
                                Text(playlist.name).tag(playlist.id)
                            }
                        }
                        if let note = model.queuedNote {
                            Text(note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            if let error = model.error {
                Text(error)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .frame(width: 500)
        .onAppear { TrackMenuSources.shared.loadIfNeeded() }
        .onChange(of: model.isFinished) { _, finished in
            if finished { dismiss() }
        }
    }

    private var showsPlaylistPicker: Bool {
        if case .track = model.phase { return true }
        if case .inLibrary(_, _, _, let hasFile, _) = model.phase { return !hasFile }
        return false
    }

    private var footer: some View {
        HStack {
            if model.primary == .download || model.primary == .importPlaylist {
                Text(QuickAddModel.footerRemark).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Cancel", role: .cancel) { model.cancel() }
                .keyboardShortcut(.cancelAction)
            if case .unsupported = model.phase {
                Button(LinkSuggestion.openInBrowser) { model.openInBrowser() }
            }
            Button(model.primaryTitle) {
                Task { await model.performPrimary() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.primary == nil || model.isStarting)
        }
        .padding(20)
    }

    // MARK: Detected item

    @ViewBuilder
    private var detected: some View {
        switch model.phase {
        case .empty:
            Text(QuickAddModel.emptyText).foregroundStyle(.secondary)
        case .notALink:
            Text("This isn’t a link. Paste a link that starts with https://.").foregroundStyle(.secondary)
        case .lookingUp(let link):
            item(cover: nil, title: nil, subtitle: nil, caption: LinkSuggestion.host(of: link.url)) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(LinkSuggestion.lookingUp)
                }
            }
        case .track(let link, let metadata):
            item(cover: metadata?.artworkURL, title: metadata?.title ?? LinkSuggestion.shortURL(link.url),
                 subtitle: metadata?.artist, caption: caption(link, metadata), source: link.source)
        case .inLibrary(let link, let trackID, let title, let hasFile, let detail):
            VStack(alignment: .leading, spacing: 6) {
                item(cover: nil, title: title, subtitle: nil, caption: caption(link, nil), source: link.source) {
                    HStack(spacing: 4) {
                        Image(systemName: hasFile ? "checkmark.circle" : "icloud")
                            .foregroundStyle(.secondary)
                        Text(hasFile ? LinkSuggestion.inLibraryTitle(title) : "In your library · Not downloaded")
                        if hasFile {
                            Button("Show") { model.environment.reveal(trackID); model.cancel() }
                                .buttonStyle(.link)
                        }
                    }
                }
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        case .playlist(let link, let metadata):
            VStack(alignment: .leading, spacing: 6) {
                item(cover: nil, title: metadata?.title ?? LinkSuggestion.shortURL(link.url), subtitle: metadata?.artist,
                     caption: playlistCaption(link, metadata), source: link.source)
                Text("Playlists are imported with a preview, so you can see what is new before anything is downloaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .unsupported:
            problem(symbol: "link", title: "MLM can’t add this link",
                    text: "It isn’t a track or playlist on SoundCloud, YouTube or Spotify. Check that you copied the whole link.")
        case .toolMissing:
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("yt-dlp not found").fontWeight(.semibold)
                    Text("YouTube links need the yt-dlp tool.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Settings ▸ Sources") { model.environment.openSettingsSources() }
            }
        case .signInExpired(let source):
            if let service = QuickAddModel.service(for: source), let accounts = model.environment.accounts {
                SourceAccountProblemView(service: service, state: accounts.state(of: service).needsSignIn ? accounts.state(of: service) : .signInExpired,
                                         accounts: accounts,
                                         message: "MLM needs your \(source.rawValue) sign-in to read this link.",
                                         compact: true,
                                         onSignedIn: { model.detectNow() })
            }
        case .unavailable(let source):
            problem(symbol: "lock", title: "This track is private or no longer available",
                    text: "\(source.rawValue) doesn’t offer it to your account.")
        }
    }

    private func caption(_ link: LinkSuggestion, _ metadata: LinkMetadata?) -> String {
        var parts = [link.source?.rawValue ?? LinkSuggestion.host(of: link.url)]
        if let seconds = metadata?.durationSeconds { parts.append(LinkSuggestion.time(seconds)) }
        return parts.joined(separator: " · ")
    }

    private func playlistCaption(_ link: LinkSuggestion, _ metadata: LinkMetadata?) -> String {
        var text = "\(link.source?.rawValue ?? "") playlist"
        if let count = metadata?.trackCount { text += " · \(ActivityNoun.track.counted(count))" }
        return text
    }

    private func problem(symbol: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func item(cover: String?, title: String?, subtitle: String?, caption: String,
                      source: LinkSource? = nil) -> some View {
        item(cover: cover, title: title, subtitle: subtitle, caption: caption, source: source) { EmptyView() }
    }

    private func item<Extra: View>(cover: String?, title: String?, subtitle: String?, caption: String,
                                   source: LinkSource? = nil, @ViewBuilder extra: () -> Extra) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: cover.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "music.note").foregroundStyle(.tertiary)
            }
            .frame(width: 56, height: 56)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).fontWeight(.semibold).lineLimit(2) }
                if let subtitle, !subtitle.isEmpty { Text(subtitle).foregroundStyle(.secondary) }
                extra()
                HStack(spacing: 4) {
                    if let source { SourceBrandDot(source: source.rawValue) }
                    Text(caption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}
