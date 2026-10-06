import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// **Edit Album Info** (S-ALB-EDIT, IMP-093, DEC-041) — also the card's `Get Info`: the cover
/// well, Title, Album artist, Year, Genre (completes from the existing genres) and the
/// Compilation toggle. Save changes the album and the album fields of its tracks in one undo
/// step; file tags follow `Write tags to files` and wait for the drive.
struct AlbumInfoSheet: View {
    let albumID: Int64

    @Environment(\.container) private var container
    @Environment(\.dismiss) private var dismiss
    @Environment(ShellActions.self) private var shell: ShellActions?

    @State private var album: Album?
    @State private var form: AlbumInfoForm?
    @State private var trackIDs: [Int64] = []
    @State private var genres: [String] = []
    @State private var writesTags = false
    @State private var drive = LibraryDriveState(volumeName: nil, isConnected: true)
    @State private var keyIsTaken = false
    @State private var missing = false
    @State private var isSaving = false
    @State private var failure: String?
    @State private var stagedCover: CoverSource?
    @State private var stagedImage: NSImage?
    @State private var coverRefusal: String?
    @State private var isChoosingCover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let album, form != nil {
                content(album)
            } else if missing {
                ContentUnavailableView("Album not found", systemImage: "square.stack",
                                       description: Text("This album is no longer in the library."))
                    .frame(maxHeight: .infinity)
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                .padding(Spacing.l)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 380)
        .task { await load() }
        .task(id: collisionKey) { await checkKey() }
        .fileImporter(isPresented: $isChoosingCover, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            stage(url)
        }
    }

    // MARK: Content

    private func content(_ album: Album) -> some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text("Edit Album Info").font(.headline)
                Text(AlbumInfoText.subtitle(trackCount: trackIDs.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], Spacing.l)
            HStack(alignment: .top, spacing: Spacing.l) {
                coverWell(album)
                Form {
                    TextField("Title", text: binding(\.title))
                    problemLine(.emptyTitle)
                    TextField("Album artist", text: binding(\.albumArtist))
                        .disabled(form?.isCompilation == true)
                    problemLine(.emptyAlbumArtist)
                    TextField("Year", text: binding(\.yearText))
                        .frame(maxWidth: 160)
                    problemLine(.badYear)
                    TextField("Genre", text: binding(\.genre))
                    genreSuggestions
                    Toggle("Compilation of tracks by various artists", isOn: Binding(
                        get: { form?.isCompilation ?? false },
                        set: { on in form?.setCompilation(on) }))
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
            }
            .padding(.horizontal, Spacing.l)
            if let note = AlbumInfoText.footnote(writesTags: writesTags, offlineVolume: drive.isOffline ? drive.volumeName : nil) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.l)
            }
            footer
        }
    }

    private func coverWell(_ album: Album) -> some View {
        VStack(spacing: Spacing.xs) {
            ZStack {
                if let stagedImage {
                    Image(nsImage: stagedImage)
                        .resizable()
                        .scaledToFill()
                } else {
                    AlbumCoverView(request: AlbumCoverRequest(albumID: albumID, coverPath: album.coverPath, firstTrackID: trackIDs.first), cornerRadius: 8)
                }
            }
            .frame(width: 104, height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                stage(url)
                return true
            }
            .accessibilityLabel("Cover of “\(album.title)”")
            Button("Choose…") { isChoosingCover = true }
            Text("or drop an image")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let coverRefusal {
                Text(coverRefusal)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 120)
            }
        }
        .padding(.top, Spacing.m)
    }

    @ViewBuilder
    private func problemLine(_ problem: AlbumInfoForm.Problem) -> some View {
        if form?.problem == problem {
            Text(AlbumInfoForm.sentence(for: problem))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Existing genres that complete what is typed, so no new spelling variant appears.
    @ViewBuilder
    private var genreSuggestions: some View {
        let names = AlbumInfoRules.genreSuggestions(typed: form?.genre ?? "", existing: genres)
        if !names.isEmpty {
            HStack(spacing: Spacing.s) {
                ForEach(names, id: \.self) { name in
                    Button(name) { form?.genre = name }
                        .buttonStyle(.link)
                }
            }
            .font(.caption)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if keyIsTaken {
                Label(AlbumInfoForm.keyTaken, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(AlbumInfoText.undoNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(Spacing.l)
    }

    private var canSave: Bool {
        guard let form, form.problem == nil, !keyIsTaken, !isSaving else { return false }
        return form.hasChanges || stagedCover != nil
    }

    private func binding(_ keyPath: WritableKeyPath<AlbumInfoForm, String>) -> Binding<String> {
        Binding(get: { form?[keyPath: keyPath] ?? "" }, set: { form?[keyPath: keyPath] = $0 })
    }

    // MARK: Work

    private func load() async {
        guard let repository = container.albumRepository, let manager = container.databaseManager,
              let row = try? await repository.fetch(id: albumID) else {
            missing = true
            return
        }
        let tracks = (try? await AlbumTrackRepository(database: manager.pool).tracks(of: albumID)) ?? []
        album = row
        trackIDs = tracks.compactMap(\.id)
        form = AlbumInfoForm(album: row, tracks: tracks)
        writesTags = await TagWriteSetting.isEnabled(container.configRepository)
        drive = LibraryDriveState.current(container)
        if let overview = try? await GenreRepository.live(container)?.overview() {
            genres = overview.genres.map(\.name)
        }
    }

    /// The title and album artist as they would be saved, while they differ from the album's.
    private var collisionKey: String {
        guard let form, let values = form.values,
              values.title != form.original.title || values.albumArtist != form.original.albumArtist else { return "" }
        return "\(values.albumArtist)\u{1F}\(values.title)"
    }

    private func checkKey() async {
        guard let form, let values = form.values, !collisionKey.isEmpty, let repository = container.albumRepository else {
            keyIsTaken = false
            return
        }
        let holder = try? await repository.albumWithKey(albumArtist: values.albumArtist, title: values.title,
                                                        variantKind: album?.variantKind, excluding: albumID)
        keyIsTaken = holder != nil
    }

    private func stage(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), AlbumCoverFiles.isImage(data), let image = NSImage(data: data) else {
            coverRefusal = DropWords.notACover(fileName: url.lastPathComponent)
            return
        }
        coverRefusal = nil
        stagedCover = .data(data)
        stagedImage = image
    }

    private func save() {
        guard canSave, let form, let values = form.values, let edits = shell?.edits else { return }
        isSaving = true
        failure = nil
        let cover = stagedCover
        let ids = trackIDs
        let original = form.original
        let volume = drive.volumeName
        let directory = AlbumCoverLoader.coversDirectory(container)
        Task {
            do {
                try await edits.editAlbumInfo(
                    albumID: albumID, original: original, new: values, trackIDs: ids, cover: cover, coversDirectory: directory,
                    tagEdit: TrackTagEdit.live(undo: nil), volumeName: volume)
                dismiss()
            } catch AlbumInfoError.keyTaken {
                keyIsTaken = true
                isSaving = false
            } catch is AlbumCoverFiles.Failure {
                coverRefusal = DropWords.notACover(fileName: nil)
                stagedCover = nil
                stagedImage = nil
                isSaving = false
            } catch {
                failure = "Couldn’t save the album info — the library database didn’t answer. Nothing was changed."
                isSaving = false
            }
        }
    }
}
