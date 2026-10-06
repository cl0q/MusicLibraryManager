import SwiftUI

// MARK: - The genre menus (CM-GENRE-ROW, CM-GENRED-MORE, V-GENRES.N02; UC-CM-02)

/// Where a genre menu is shown.
enum GenreMenuPlace: Equatable {
    /// A row of the genre list (CM-GENRE-ROW): `Open` and `Play` first.
    case row
    /// The genre page's `More` (CM-GENRED-MORE): Play and Shuffle are header buttons.
    case more
}

/// One item of a genre menu. The order and presence rules live in `GenreMenuModel` (tested).
enum GenreMenuItem: Hashable {
    case countHeader(Int)
    case open
    case play
    case playNext
    case addToQueue
    case addToPlaylist
    case addToSyncProfile
    case rename
    case merge
    case mergeWithAnother
}

/// The sections of a genre menu, in the one group order (DEC-039).
enum GenreMenuModel {
    static func sections(_ place: GenreMenuPlace, count: Int) -> [[GenreMenuItem]] {
        guard count > 0 else { return [] }
        let single = count == 1
        switch place {
        case .row:
            var sections: [[GenreMenuItem]] = []
            // UC-CM-04: a count header with several subjects; Open needs one.
            if !single { sections.append([.countHeader(count)]) }
            sections.append(single ? [.open, .play] : [.play])
            sections.append([.playNext, .addToQueue])
            sections.append([.addToPlaylist, .addToSyncProfile])
            sections.append(single ? [.rename] : [.merge])
            return sections
        case .more:
            return [[.playNext, .addToQueue], [.addToPlaylist, .addToSyncProfile], [.rename, .mergeWithAnother]]
        }
    }

    static func title(_ item: GenreMenuItem) -> String {
        switch item {
        case .countHeader(let n): GenreText.genres(n)
        case .open: "Open"
        case .play: "Play"
        case .playNext: "Play Next"
        case .addToQueue: "Add to Queue"
        case .addToPlaylist: "Add to Playlist"
        case .addToSyncProfile: "Add to Sync Profile"
        case .rename: "Rename Genre…"
        case .merge: "Merge Genres…"
        case .mergeWithAnother: "Merge with Another Genre…"
        }
    }
}

/// One builder for the genre row's context menu and the genre page's `More` (UC-CM-02).
struct GenreMenu: View {
    let genres: [GenreSummary]
    let place: GenreMenuPlace
    let actions: GenreActions
    var open: (GenreSummary) -> Void = { _ in }
    var rename: (GenreSummary) -> Void = { _ in }
    var merge: ([GenreSummary]) -> Void = { _ in }
    var mergeWithAnother: (GenreSummary) -> Void = { _ in }

    var body: some View {
        let sources = TrackMenuSources.shared
        ForEach(Array(GenreMenuModel.sections(place, count: genres.count).enumerated()), id: \.offset) { _, section in
            Section {
                ForEach(section, id: \.self) { item in
                    view(for: item, playlists: sources.playlists, profiles: sources.syncProfiles)
                }
            }
        }
    }

    @ViewBuilder
    private func view(for item: GenreMenuItem, playlists: [Playlist], profiles: [SyncProfile]) -> some View {
        switch item {
        case .countHeader:
            Text(GenreMenuModel.title(item))
        case .open:
            Button(GenreMenuModel.title(item)) { if let genre = genres.first { open(genre) } }
        case .play:
            Button {
                actions.play(genres)
            } label: {
                Label(GenreMenuModel.title(item), systemImage: "play.fill")
            }
        case .playNext:
            Button(GenreMenuModel.title(item)) { actions.playNext(genres) }
        case .addToQueue:
            Button(GenreMenuModel.title(item)) { actions.addToQueue(genres) }
        case .addToPlaylist:
            Menu(GenreMenuModel.title(item)) {
                AddToPlaylistMenuItems(
                    playlists: playlists,
                    showsKeyEquivalents: false,
                    newPlaylist: { actions.newPlaylist(genres) },
                    add: { actions.addToPlaylist($0, genres) }
                )
            }
        case .addToSyncProfile:
            Menu(GenreMenuModel.title(item)) {
                ForEach(profiles) { profile in
                    Button(profile.name) { actions.addToSyncProfile(profile, genres) }
                }
                if !profiles.isEmpty { Divider() }
                Button("New Sync Profile…") { actions.newSyncProfile(genres) }
            }
        case .rename:
            Button(GenreMenuModel.title(item)) { if let genre = genres.first { rename(genre) } }
        case .merge:
            Button(GenreMenuModel.title(item)) { merge(genres) }
        case .mergeWithAnother:
            Button(GenreMenuModel.title(item)) { if let genre = genres.first { mergeWithAnother(genre) } }
        }
    }
}

// MARK: - What the genre commands do

/// Play, queue and add a genre's tracks — through the same commands as a track selection
/// (`TrackCommandActions`, `ShellEdits`), so they confirm and undo the same way.
@MainActor
struct GenreActions {
    let container: DependencyContainer
    let shell: ShellActions?
    let statusBar: StatusBarCenter?
    let undo: UndoCenter?

    private func tracks(_ genres: [GenreSummary]) async -> [Track] {
        guard let repository = GenreRepository.live(container) else { return [] }
        return (try? await repository.tracks(genreKeys: Set(genres.map(\.key)))) ?? []
    }

    /// Play (or Shuffle) the genres' tracks that have a file; the rest is the queue context.
    func play(_ genres: [GenreSummary], shuffled: Bool = false) {
        guard !genres.isEmpty else { return }
        if let reason = TrackTableLiveState.drive(container).cantPlayReason {
            statusBar?.post(reason)
            return
        }
        Task {
            let rows = await tracks(genres)
            let playable = rows.filter(\.isLocal)
            let subject = GenreText.subject(genres.map(\.name))
            guard let first = playable.first else {
                statusBar?.post("Nothing to play — no track of \(subject) is downloaded")
                return
            }
            if genres.count == 1, let genre = genres.first {
                container.playbackViewModel?.willActivate(nil, from: PlaybackOrigin(
                    place: .genres, path: [.genre(genre.name)], listKey: GenreDetailView.persistenceKey,
                    container: .genre(key: genre.key, name: genre.name)))
            }
            if shuffled {
                await container.playbackViewModel?.playShuffled(playable)
            } else if let activate = shell?.activateTrack {
                activate(first, rows)
            } else {
                await container.playbackViewModel?.playTrack(first, queue: rows)
            }
        }
    }

    func playNext(_ genres: [GenreSummary]) {
        Task { TrackCommandActions.playNext(await tracks(genres), undo: undo) }
    }

    func addToQueue(_ genres: [GenreSummary]) {
        Task { TrackCommandActions.addToQueue(await tracks(genres), undo: undo) }
    }

    func addToPlaylist(_ playlistID: Int64, _ genres: [GenreSummary]) {
        Task {
            let ids = await tracks(genres).compactMap(\.id)
            await shell?.edits.addTracks(ids, toPlaylist: playlistID)
        }
    }

    /// A new playlist named after a single genre (UC-C5), else `Untitled Playlist`.
    func newPlaylist(_ genres: [GenreSummary]) {
        Task {
            let ids = await tracks(genres).compactMap(\.id)
            _ = await shell?.edits.newPlaylist(named: genres.count == 1 ? genres[0].name : nil, fromTrackIDs: ids)
        }
    }

    func newSyncProfile(_ genres: [GenreSummary]) {
        Task { TrackCommandActions.newSyncProfileFromSelection(await tracks(genres)) }
    }

    func addToSyncProfile(_ profile: SyncProfile, _ genres: [GenreSummary]) {
        guard let id = profile.id else { return }
        Task {
            let ids = await tracks(genres).compactMap(\.id)
            await shell?.edits.addTracks(ids, toSyncProfile: id, name: profile.name)
        }
    }
}
